local _, ns = ...

-- Saved named search lists: a list is a name and an array of items for a multi-item live search.
-- The lists are saved in the profile (key "searchLists"), next to the groups and the operations.
-- Item: { itemID, key (optional), name (optional) }. A list holds each item once (compared by key).

local SearchLists = {}
ns.SearchLists = SearchLists

local KEY = "searchLists"
local VERSION = 1
local MAX_NAME = 40
local READ_ONLY = "Settings are read-only; the change is not saved."

SearchLists.EVENT_OPEN = "Flipside.SearchListOpen"
SearchLists.EVENT_CHANGED = "Flipside.SearchListsChanged"

local Store = {}
Store.__index = Store

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function copyItem(item)
    return { itemID = item.itemID, key = item.key, name = item.name }
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
    return { itemID = itemID, key = key, name = name }
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

-- Returns { { id, name, count } } sorted by name.
function Store:List()
    local out = {}
    for id, list in pairs(self:_Data().lists) do
        out[#out + 1] = { id = id, name = list.name, count = #list.items }
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

-- Returns { id, name, items } (a copy), or nil.
function Store:Get(id)
    local list = self:_Data().lists[id]
    if not list then
        return nil
    end
    local items = {}
    for index, item in ipairs(list.items) do
        items[index] = copyItem(item)
    end
    return { id = id, name = list.name, items = items }
end

-- Make a list. Returns the id, or nil and a text (a name that is empty, too long or taken).
function Store:Create(name, items)
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
