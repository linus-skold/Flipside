local _, ns = ...

-- Finds items by name with an Auction House browse query.
-- deps: bus, api, isAuctionHouseOpen, clock, and the optional after(seconds, fn).
-- api: sendBrowseQuery(query), getBrowseResults(), getItemKeyInfo(itemKey).
-- deps.event is the results event; the default is the Forever event name.
-- Timeout: after() fires the timeout. Without after(), clock() ends a stale search on the next call or event.
local AHNameSearch = {}
ns.AHNameSearch = AHNameSearch

local EVENT = "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"

-- Write one line to the diagnostics log; the Log module can be missing in a spec.
local function log(level, fmt, ...)
    if ns.Log then
        ns.Log.Writef("auction", level, fmt, ...)
    end
end
local TIMEOUT = 10

local Search = {}
Search.__index = Search

function AHNameSearch.New(deps)
    deps = deps or {}
    if type(deps.bus) ~= "table" or type(deps.api) ~= "table" or type(deps.isAuctionHouseOpen) ~= "function"
        or type(deps.clock) ~= "function" then
        error("deps must have bus, api, isAuctionHouseOpen and clock", 2)
    end
    return setmetatable({
        bus = deps.bus,
        api = deps.api,
        isOpen = deps.isAuctionHouseOpen,
        clock = deps.clock,
        after = deps.after,
        event = deps.event or EVENT,
        addedEvent = deps.addedEvent,
        pending = nil,
    }, Search)
end

-- End the running search and call its callback once.
function Search:_Finish(pending, results, err)
    if self.pending ~= pending then
        return
    end
    self.pending = nil
    local outcome = err or (type(results) == "table" and (#results .. " items")) or "no result"
    log(err and "warn" or "info", "name search '%s' done: %s", pending.name, outcome)
    self.bus:Unsubscribe(self.event, self)
    if self.addedEvent then
        self.bus:Unsubscribe(self.addedEvent, self)
    end
    pending.callback(results, err)
end

function Search:_IsStale()
    local pending = self.pending
    return pending ~= nil and self.clock() - pending.startedAt >= TIMEOUT
end

local function ByName(a, b)
    if a.name ~= b.name then
        return a.name < b.name
    end
    return a.itemID < b.itemID
end

-- Returns the item array, or nil and an error text.
function Search:_ReadResults(pending)
    local api = self.api
    local ok, rows = pcall(api.getBrowseResults)
    if not ok or type(rows) ~= "table" then
        return nil, "could not read the Auction House results"
    end
    local wanted = pending.exact and string.lower(pending.name) or nil
    local seen, items = pending.seen, pending.items
    for _, row in ipairs(rows) do
        local itemKey = type(row) == "table" and row.itemKey or nil
        local itemID = type(itemKey) == "table" and itemKey.itemID or nil
        local isPet = type(itemKey) == "table" and type(itemKey.battlePetSpeciesID) == "number"
            and itemKey.battlePetSpeciesID > 0
        if type(itemID) == "number" and not isPet and not seen[itemID] then
            local okInfo, info = pcall(api.getItemKeyInfo, itemKey)
            local name = okInfo and type(info) == "table" and info.itemName or nil
            if type(name) == "string" and name ~= "" and (not wanted or string.lower(name) == wanted) then
                seen[itemID] = true
                items[#items + 1] = { itemID = itemID, name = name, key = string.format("%d", itemID) }
            end
        end
    end
    table.sort(items, ByName)
    return items
end

-- Keep the search open after an event. Each event adds items. The search ends after a quiet time with no event.
function Search:_Settle(pending, items)
    pending.token = (pending.token or 0) + 1
    local token = pending.token
    if pending.onItems then
        pcall(pending.onItems, items)
    end
    pcall(self.after, pending.settle, function()
        if pending.token == token then
            self:_Finish(pending, items)
        end
    end)
end

function Search:_OnResults()
    local pending = self.pending
    if not pending then
        return
    end
    if self:_IsStale() then
        self:_Finish(pending, nil, "no answer from the Auction House")
        return
    end
    local items, err = self:_ReadResults(pending)
    if items and pending.settle and self.after then
        self:_Settle(pending, items)
    elseif items then
        self:_Finish(pending, items)
    else
        self:_Finish(pending, nil, err)
    end
end

-- Start a search. options.exact keeps only names that equal the text. The callback gets (items) or (nil, err).
-- options.settle (seconds) keeps the search open: each result event adds items, options.onItems(items) gets the
-- items found so far, and the callback runs once after that many seconds with no event. Needs after().
function Search:Find(name, callback, options)
    if type(callback) ~= "function" then
        error("Find: callback must be a function", 2)
    end
    if self:_IsStale() then
        self:_Finish(self.pending, nil, "no answer from the Auction House")
    end
    if self.pending then
        callback(nil, "a search is already running")
        return
    end
    local okOpen, open = pcall(self.isOpen)
    if not okOpen or not open then
        callback(nil, "open the Auction House to search it")
        return
    end
    local pending = {
        name = tostring(name or ""),
        callback = callback,
        exact = options ~= nil and options.exact == true,
        settle = options ~= nil and options.settle or nil,
        onItems = options ~= nil and options.onItems or nil,
        seen = {},
        items = {},
        startedAt = self.clock(),
    }
    self.pending = pending
    log("info", "name search '%s' started", pending.name)
    local function onEvent()
        self:_OnResults()
    end
    self.bus:Subscribe(self.event, self, onEvent)
    if self.addedEvent then
        self.bus:Subscribe(self.addedEvent, self, onEvent)
    end
    local okSend, err = pcall(self.api.sendBrowseQuery, { searchString = pending.name, sorts = {} })
    if not okSend then
        self:_Finish(pending, nil, "the Auction House search failed: " .. tostring(err))
        return
    end
    if self.after then
        pcall(self.after, TIMEOUT, function()
            self:_Finish(pending, nil, "no answer from the Auction House")
        end)
    end
end

function Search:IsBusy()
    return self.pending ~= nil
end
