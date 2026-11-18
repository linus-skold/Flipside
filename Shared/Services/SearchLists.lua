local _, ns = ...

-- Saved named search lists: a list is a name and an array of items for a multi-item live search.
-- The lists are saved in the profile (key "searchLists"), next to the groups and the operations.
-- Item: { itemID, key (optional), name (optional), count (optional) }. A list holds each item once (compared by key).
-- count is a whole number above 0 (the units to buy). A list saved before count existed has none.
-- A list has a kind: "search" (the default; an old list has no kind field) or "craft". The items of a craft list are
-- the materials. A craft list also has results: { { itemID, key, name, min, max } }, the items that the craft makes by
-- hand-typed amounts (min and max are whole numbers, 0 <= min <= max). It holds each result once (compared by key).

local SearchLists = {}
ns.SearchLists = SearchLists

local KEY = "searchLists"
local VERSION = 1
local MAX_NAME = 40
local READ_ONLY = "Settings are read-only; the change is not saved."

SearchLists.EVENT_OPEN = "Flipside.SearchListOpen"
SearchLists.EVENT_CHANGED = "Flipside.SearchListsChanged"
-- Open a list that is not saved: (name, items, autoSearch). The Buying tab shows it with a Save button.
SearchLists.EVENT_TEMP = "Flipside.SearchListTemp"

local Store = {}
Store.__index = Store

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Returns count if it is a whole number above 0, else nil.
local function cleanCount(count)
    if type(count) == "number" and count >= 1 and count % 1 == 0 then
        return count
    end
    return nil
end

local function copyItem(item)
    return { itemID = item.itemID, key = item.key, name = item.name, count = cleanCount(item.count) }
end

-- Returns a clean copy of an item, or nil and a text.
local function cleanItem(item)
    if type(item) ~= "table" then
        return nil, "the item is not valid"
    end
    local itemID, key = item.itemID, item.key
    if type(key) == "string" then
        local parsed = ns.ItemString.ParseKey(key)
        if not parsed then
            return nil, "the item key is not valid"
        end
        itemID = itemID or parsed.itemID
    else
        key = nil
    end
    if type(itemID) ~= "number" or itemID < 1 or itemID % 1 ~= 0 then
        return nil, "the item has no item ID"
    end
    key = key or string.format("%d", itemID)
    local name = type(item.name) == "string" and item.name ~= "" and item.name or nil
    return { itemID = itemID, key = key, name = name, count = cleanCount(item.count) }
end

local function isWhole(number, least)
    return type(number) == "number" and number >= least and number % 1 == 0
end

-- Returns min and max (max defaults to min), or nil and a text.
local function cleanRange(min, max)
    if max == nil then
        max = min
    end
    if not isWhole(min, 0) then
        return nil, "The min amount must be a whole number, 0 or more."
    end
    if not isWhole(max, min) then
        return nil, "The max amount must be a whole number, not below the min amount."
    end
    return min, max
end

-- Returns a clean copy of a result, or nil and a text.
local function cleanResult(result)
    local clean, err = cleanItem(result)
    if not clean then
        return nil, err
    end
    local min, max = cleanRange(result.min, result.max)
    if not min then
        return nil, max
    end
    return { itemID = clean.itemID, key = clean.key, name = clean.name, min = min, max = max }
end

local function cleanResults(results)
    local out, seen = {}, {}
    for _, result in ipairs(results or {}) do
        local clean = type(result) == "table" and cleanResult(result)
        if clean and not seen[clean.key] then
            seen[clean.key] = true
            out[#out + 1] = clean
        end
    end
    return out
end

local function cleanItems(items)
    local out, seen = {}, {}
    for _, item in ipairs(items or {}) do
        local clean = cleanItem(item)
        if clean and not seen[clean.key] then
            seen[clean.key] = true
            out[#out + 1] = clean
        end
    end
    return out
end

local function cleanName(name)
    local text = trim(name)
    if text == "" then
        return nil, "Enter a name."
    end
    if #text > MAX_NAME then
        return nil, "Use a name of at most " .. MAX_NAME .. " characters."
    end
    return text
end

-- Returns the data (a copy); a missing or damaged value gives an empty set.
function Store:_Data()
    local data = self.db:Get("profile", KEY)
    if type(data) ~= "table" or type(data.lists) ~= "table" or type(data.nextID) ~= "number" then
        return { version = VERSION, nextID = 1, lists = {} }
    end
    return data
end

-- Runs fn(data) on a copy and saves it. fn returns a result, or nil and a text.
function Store:_Change(fn)
    if self.db:IsReadOnly() then
        return nil, READ_ONLY
    end
    local data = self:_Data()
    local result, err = fn(data)
    if result == nil then
        return nil, err
    end
    if not self.db:Set("profile", KEY, data) then
        return nil, READ_ONLY
    end
    if self.bus then
        self.bus:Emit(SearchLists.EVENT_CHANGED)
    end
    return result
end

local function findByName(data, name, exceptID)
    local lower = name:lower()
    for id, list in pairs(data.lists) do
        if id ~= exceptID and list.name:lower() == lower then
            return id
        end
    end
    return nil
end

-- db: a SettingsDB object. options: bus (EventBus), isAuctionHouseOpen() (both optional).
-- With a bus, the object records "Flipside.SearchListOpen" requests that come while the Auction House is closed.
function SearchLists.New(db, options)
    if type(db) ~= "table" then
        error("db must be a SettingsDB object", 2)
    end
    options = options or {}
    local self = setmetatable({ db = db, bus = options.bus, isOpen = options.isAuctionHouseOpen }, Store)
    if self.bus and self.isOpen then
        self.bus:Subscribe(SearchLists.EVENT_OPEN, self, function(_, id, autoSearch)
            if not self.isOpen() then
                self.requested = { id = id, autoSearch = autoSearch == true }
            end
        end)
    end
    return self
end

local function kindOf(list)
    return list.kind == "craft" and "craft" or "search"
end

-- Returns { { id, name, count, kind } } sorted by name. kind is "search" or "craft".
function Store:List()
    local out = {}
    for id, list in pairs(self:_Data().lists) do
        out[#out + 1] = { id = id, name = list.name, count = #list.items, kind = kindOf(list) }
    end
    table.sort(out, function(a, b)
        local x, y = a.name:lower(), b.name:lower()
        if x ~= y then
            return x < y
        end
        return a.id < b.id
    end)
    return out
end

-- Returns { id, name, kind, items, results } (a copy), or nil. An item is { itemID, key, name, count }; count can
-- be nil. kind is "search" or "craft". results is { { itemID, key, name, min, max } }, always empty for a search list.
function Store:Get(id)
    local list = self:_Data().lists[id]
    if not list then
        return nil
    end
    local items = {}
    for index, item in ipairs(list.items) do
        items[index] = copyItem(item)
    end
    local kind = kindOf(list)
    return { id = id, name = list.name, kind = kind, items = items,
        results = kind == "craft" and cleanResults(list.results) or {} }
end

-- Make a list. kind is "craft" for a craft list; any other value makes a search list.
-- Returns the id, or nil and a text (a name that is empty, too long or taken).
function Store:Create(name, items, kind)
    local clean, err = cleanName(name)
    if not clean then
        return nil, err
    end
    return self:_Change(function(data)
        if findByName(data, clean) then
            return nil, "A list with this name exists."
        end
        local id = data.nextID
        data.nextID = id + 1
        data.lists[id] = { name = clean, items = cleanItems(items) }
        if kind == "craft" then
            data.lists[id].kind = "craft"
            data.lists[id].results = {}
        end
        return id
    end)
end

-- Replace the items of the list with this name, or make the list. Returns the id.
function Store:Upsert(name, items)
    local clean, err = cleanName(name)
    if not clean then
        return nil, err
    end
    return self:_Change(function(data)
        local id = findByName(data, clean)
        if id then
            data.lists[id].items = cleanItems(items)
            return id
        end
        id = data.nextID
        data.nextID = id + 1
        data.lists[id] = { name = clean, items = cleanItems(items) }
        return id
    end)
end

function Store:Rename(id, name)
    local clean, err = cleanName(name)
    if not clean then
        return nil, err
    end
    return self:_Change(function(data)
        local list = data.lists[id]
        if not list then
            return nil, "The list does not exist."
        end
        if findByName(data, clean, id) then
            return nil, "A list with this name exists."
        end
        list.name = clean
        return true
    end)
end

function Store:Delete(id)
    local result, err = self:_Change(function(data)
        if not data.lists[id] then
            return nil, "The list does not exist."
        end
        data.lists[id] = nil
        return true
    end)
    if result and self.requested and self.requested.id == id then
        self.requested = nil
    end
    return result, err
end

-- Add one item to the end of a list. A second add of the same key fails.
function Store:AddItem(id, item)
    local clean, err = cleanItem(item)
    if not clean then
        return nil, err
    end
    return self:_Change(function(data)
        local list = data.lists[id]
        if not list then
            return nil, "The list does not exist."
        end
        for _, existing in ipairs(list.items) do
            if existing.key == clean.key then
                return nil, "The item is in the list."
            end
        end
        list.items[#list.items + 1] = clean
        return true
    end)
end

-- Set the count of the item at a place of a list. A count that is not a whole number above 0 clears it.
function Store:SetCount(id, index, count)
    return self:_Change(function(data)
        local list = data.lists[id]
        if not list then
            return nil, "The list does not exist."
        end
        if type(index) ~= "number" or not list.items[index] then
            return nil, "The list has no item at this place."
        end
        list.items[index].count = cleanCount(count)
        return true
    end)
end

function Store:RemoveItem(id, index)
    return self:_Change(function(data)
        local list = data.lists[id]
        if not list then
            return nil, "The list does not exist."
        end
        if type(index) ~= "number" or not list.items[index] then
            return nil, "The list has no item at this place."
        end
        table.remove(list.items, index)
        return true
    end)
end

local function craftList(data, id)
    local list = data.lists[id]
    if not list then
        return nil, "The list does not exist."
    end
    if list.kind ~= "craft" then
        return nil, "The list is not a craft list."
    end
    -- Clean the results first, so that an index is the place that Get shows (it drops a damaged entry).
    list.results = cleanResults(list.results)
    return list
end

-- Add a result to the end of a craft list. result is { itemID, key (optional), name (optional), min, max }.
-- max defaults to min. A second add of the same key fails.
function Store:AddResult(id, result)
    local clean, err = cleanResult(type(result) == "table" and result or {})
    if not clean then
        return nil, err
    end
    return self:_Change(function(data)
        local list, listErr = craftList(data, id)
        if not list then
            return nil, listErr
        end
        for _, existing in ipairs(list.results) do
            if existing.key == clean.key then
                return nil, "The item is a result of the list."
            end
        end
        list.results[#list.results + 1] = clean
        return true
    end)
end

-- Set the min and max amount of the result at a place of a craft list. max defaults to min.
function Store:SetResult(id, index, min, max)
    local lowest, highest = cleanRange(min, max)
    if not lowest then
        return nil, highest
    end
    return self:_Change(function(data)
        local list, err = craftList(data, id)
        if not list then
            return nil, err
        end
        if type(index) ~= "number" or not list.results[index] then
            return nil, "The list has no result at this place."
        end
        list.results[index].min, list.results[index].max = lowest, highest
        return true
    end)
end

function Store:RemoveResult(id, index)
    return self:_Change(function(data)
        local list, err = craftList(data, id)
        if not list then
            return nil, err
        end
        if type(index) ~= "number" or not list.results[index] then
            return nil, "The list has no result at this place."
        end
        table.remove(list.results, index)
        return true
    end)
end

-- The last open request that came while the Auction House was closed: { id, autoSearch }, or nil.
function Store:Requested()
    local request = self.requested
    if request and not self:Get(request.id) then
        self.requested = nil
        return nil
    end
    return request
end

function Store:ClearRequested()
    self.requested = nil
end
