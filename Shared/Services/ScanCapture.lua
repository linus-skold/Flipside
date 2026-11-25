local _, ns = ...

-- Saves the price of an item when the player looks at its listings in the Auction House.
-- deps: store, serverTime, api, and the optional report, onCaptured, isScanRunning and keyFor(itemID, link).
-- api: commodityNum(itemID), commodityInfo(itemID, index), commodityFull(itemID),
--      itemNum(itemKey), itemInfo(itemKey, index), itemFull(itemKey). Result indexes start at 1.
local ScanCapture = {}
ns.ScanCapture = ScanCapture

local Capture = {}
Capture.__index = Capture

-- A legacy list row (TBC) has the buyout of the whole stack, so the unit price is the buyout divided by the count.
-- A Forever item result is different: its buyoutAmount is the price of one item (see ForeverBackend.LiveRows), so
-- _ReadItems uses it as it is.
local function UnitPriceFromBuyout(buyoutAmount, count)
    return buyoutAmount / count
end

-- A search result comes in pages. While the client says the result is not full, the capture asks for the next page
-- (api.commodityMore(itemID), api.itemMore(itemKey)). It stops at a full result, at a page with no new row and after
-- MAX_MORE_REQUESTS requests. api.isReady (optional) is the throttle gate: if it says false, the request waits.
local MAX_MORE_REQUESTS = 100
local MAX_READY_TRIES = 20
local READY_DELAY = 0.5
-- A row of an item result can have no link while the item data loads. The capture reads the result again after
-- LINK_DELAY seconds, at most MAX_LINK_TRIES times, before it saves the rest as a partial result.
local MAX_LINK_TRIES = 6
local LINK_DELAY = 0.5

-- A legacy browse page holds at most 50 rows. A longer list is a get-all result, which Flipside does not capture.
local MAX_PAGE_ROWS = 50

local function IsPositiveInteger(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

function ScanCapture.New(deps)
    deps = deps or {}
    if type(deps.store) ~= "table" or type(deps.serverTime) ~= "function" or type(deps.api) ~= "table" then
        error("deps must have store, serverTime and api", 2)
    end
    return setmetatable({
        store = deps.store,
        serverTime = deps.serverTime,
        api = deps.api,
        report = deps.report,
        onCaptured = deps.onCaptured,
        isScanRunning = deps.isScanRunning,
        keyFor = deps.keyFor,
        after = deps.after,
        paging = {},
        linkTries = {},
        failed = false,
    }, Capture)
end

-- Text key of an item key table, for the paging and link state.
local function ItemKeyText(itemKey)
    if type(itemKey) ~= "table" then
        return tostring(itemKey)
    end
    return table.concat({ tostring(itemKey.itemID), tostring(itemKey.itemLevel or 0),
        tostring(itemKey.itemSuffix or 0), tostring(itemKey.battlePetSpeciesID or 0) }, ":")
end

-- Send one request for more rows, if the throttle gate is open. Else try again after a short wait.
function Capture:_SendMore(id, state, request, tries)
    local isReady = self.api.isReady
    if isReady then
        local ok, ready = pcall(isReady)
        if ok and ready == false then
            if self.after and tries < MAX_READY_TRIES then
                self.after(READY_DELAY, function()
                    if self.paging[id] == state then
                        self:_SendMore(id, state, request, tries + 1)
                    end
                end)
            end
            return
        end
    end
    state.requests = state.requests + 1
    local ok, err = pcall(request)
    if not ok then
        self:_Fail(err)
    end
end

-- Ask for the next page of a result that is not full. count is the number of rows now.
function Capture:_RequestMore(id, count, request)
    if type(request) ~= "function" or count < 1 then
        return
    end
    local state = self.paging[id]
    if state and count < state.rows then
        state = nil -- a new search of the same item starts again
    end
    if state and state.requests > 0 and (count == state.rows or state.requests >= MAX_MORE_REQUESTS) then
        self.paging[id] = nil -- the last request gave no new row, or the cap is reached
        return
    end
    if not state then
        state = { rows = count, requests = 0 }
        self.paging[id] = state
    end
    state.rows = count
    self:_SendMore(id, state, request, 0)
end

-- Read an item result again after a short wait, if rows have no link yet. Gives true if it waits.
function Capture:_WaitForLinks(id, itemKey)
    local tries = self.linkTries[id] or 0
    if not self.after or tries >= MAX_LINK_TRIES then
        self.linkTries[id] = nil
        return false
    end
    self.linkTries[id] = tries + 1
    self.after(LINK_DELAY, function()
        self:OnItemResults(itemKey)
    end)
    return true
end

-- Report the first failure of a session.
function Capture:_Fail(err)
    if self.failed then
        return
    end
    self.failed = true
    if self.report then
        self.report("search capture failed: " .. tostring(err))
    end
end

function Capture:_CanCapture()
    if self.store:IsReadOnly() then
        return false
    end
    if self.isScanRunning then
        local ok, running = pcall(self.isScanRunning)
        if not ok or running then
            return false
        end
    end
    return true
end

-- Returns a list of { unitPrice, count } rows, or nil after a failure.
function Capture:_ReadCommodity(itemID)
    local api = self.api
    local ok, n = pcall(api.commodityNum, itemID)
    if not ok or type(n) ~= "number" then
        self:_Fail(ok and "bad row count" or n)
        return nil
    end
    local auctions = {}
    for index = 1, n do
        local okRow, info = pcall(api.commodityInfo, itemID, index)
        if not okRow then
            self:_Fail(info)
            return nil
        end
        if type(info) == "table" and IsPositiveInteger(info.quantity) and type(info.unitPrice) == "number" then
            auctions[#auctions + 1] = { unitPrice = info.unitPrice, count = info.quantity }
        end
    end
    return auctions
end

-- Returns a map of exact key to auctions, the number of rows with no link yet and the row count; or nil after a
-- failure.
function Capture:_ReadItems(itemKey)
    local api = self.api
    local ok, n = pcall(api.itemNum, itemKey)
    if not ok or type(n) ~= "number" then
        self:_Fail(ok and "bad row count" or n)
        return nil
    end
    local byKey, missing = {}, 0
    for index = 1, n do
        local okRow, info = pcall(api.itemInfo, itemKey, index)
        if not okRow then
            self:_Fail(info)
            return nil
        end
        if type(info) == "table" and type(info.itemLink) ~= "string" and type(info.buyoutAmount) == "number"
            and info.buyoutAmount > 0 and IsPositiveInteger(info.quantity) then
            missing = missing + 1 -- no link yet: the item data is still loading
        elseif type(info) == "table" and type(info.itemLink) == "string" and not ns.ScanKey.IsBattlePet(info.itemLink)
            and type(info.buyoutAmount) == "number" and info.buyoutAmount > 0
            and IsPositiveInteger(info.quantity) then
            local key = ns.ItemString.ToExactKey(info.itemLink)
            if key then
                local list = byKey[key]
                if not list then
                    list = {}
                    byKey[key] = list
                end
                list[#list + 1] = {
                    unitPrice = info.buyoutAmount, -- the price of one item, not of the stack
                    count = info.quantity,
                }
            end
        end
    end
    return byKey, missing, n
end

-- Save one item. A partial result keeps the old market value, quantity and auction count.
function Capture:_Save(key, auctions, full)
    local snap = ns.ScanMarket.Reduce(auctions)
    if not snap then
        return
    end
    local record = self.store:Get(key) or ns.ScanRecord.New()
    local partial = not full
    if partial then
        local old = record.latest
        if old then
            snap.market, snap.qty, snap.auctions = old.market, old.qty, old.auctions
        else
            snap.market = snap.min
        end
    end
    local ok, err = pcall(function()
        ns.ScanBucket.Override(record, snap, self.serverTime(), partial)
    end)
    if not ok then
        self:_Fail(err)
        return
    end
    if self.store:Put(key, record) and self.onCaptured then
        self.onCaptured(key, snap, partial)
    end
end

-- Save the rows of one legacy list page. rows: { itemID, count, buyout, link }; buyout is for the whole stack.
-- full is true if the page holds all results of the query. A row that has no key or no buyout is skipped.
function Capture:OnPageResults(rows, full)
    if type(rows) ~= "table" or #rows > MAX_PAGE_ROWS or not self:_CanCapture() then
        return
    end
    local keyFor = self.keyFor
    local byKey = {}
    for _, row in ipairs(rows) do
        if type(row) == "table" and type(row.buyout) == "number" and row.buyout > 0
            and IsPositiveInteger(row.count) and not ns.ScanKey.IsBattlePet(row.link) then
            local key
            if keyFor then
                local ok, value = pcall(keyFor, row.itemID, row.link)
                key = ok and value or nil
            else
                key = row.link and ns.ItemString.ToExactKey(row.link) or nil
            end
            if key then
                local list = byKey[key]
                if not list then
                    list = {}
                    byKey[key] = list
                end
                list[#list + 1] = { unitPrice = UnitPriceFromBuyout(row.buyout, row.count), count = row.count }
            end
        end
    end
    for key, auctions in pairs(byKey) do
        self:_Save(key, auctions, full == true)
    end
end

function Capture:OnCommodityResults(itemID)
    if not self:_CanCapture() then
        return
    end
    local key = ns.ItemString.ToBaseKey(itemID)
    if not key then
        return
    end
    local auctions = self:_ReadCommodity(itemID)
    if not auctions then
        return
    end
    local ok, full = pcall(self.api.commodityFull, itemID)
    if not ok then
        self:_Fail(full)
        return
    end
    local id = "c" .. tostring(itemID)
    if full == true then
        self.paging[id] = nil
    else
        local more = self.api.commodityMore
        self:_RequestMore(id, #auctions, more and function() return more(itemID) end)
    end
    self:_Save(key, auctions, full == true)
end

-- A result that is not full is saved as partial and the next page is requested. A full result with rows that have
-- no link waits for the links; if they do not come, the result is saved as partial.
function Capture:OnItemResults(itemKey)
    if not self:_CanCapture() then
        return
    end
    local byKey, missing, count = self:_ReadItems(itemKey)
    if not byKey then
        return
    end
    local ok, full = pcall(self.api.itemFull, itemKey)
    if not ok then
        self:_Fail(full)
        return
    end
    local id = "i" .. ItemKeyText(itemKey)
    if full == true then
        self.paging[id] = nil
        if missing > 0 and self:_WaitForLinks(id, itemKey) then
            return
        end
    else
        local more = self.api.itemMore
        self:_RequestMore(id, count, more and function() return more(itemKey) end)
    end
    if missing == 0 then
        self.linkTries[id] = nil
    end
    local complete = full == true and missing == 0
    for key, auctions in pairs(byKey) do
        self:_Save(key, auctions, complete)
    end
end
