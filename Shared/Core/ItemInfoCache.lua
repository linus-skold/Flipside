local _, ns = ...

local ItemInfoCache = {}
ns.ItemInfoCache = ItemInfoCache

local Cache = {}
Cache.__index = Cache

-- Builds an info table from the return values of C_Item.GetItemInfo.
function ItemInfoCache.FromItemInfo(...)
    local name, link, quality, itemLevel, minLevel, itemType, itemSubType, stackCount,
        equipLoc, icon, sellPrice, classID, subclassID, bindType, expansionID, setID,
        isCraftingReagent = ...
    if name == nil then
        return nil
    end
    return {
        name = name,
        link = link,
        quality = quality,
        itemLevel = itemLevel,
        minLevel = minLevel,
        itemType = itemType,
        itemSubType = itemSubType,
        stackCount = stackCount,
        equipLoc = equipLoc,
        icon = icon,
        sellPrice = sellPrice,
        classID = classID,
        subclassID = subclassID,
        bindType = bindType,
        expansionID = expansionID,
        setID = setID,
        isCraftingReagent = isCraftingReagent,
    }
end

local function isValidID(itemID)
    return type(itemID) == "number" and itemID > 0 and itemID == math.floor(itemID)
end

local function checkID(itemID)
    if not isValidID(itemID) then
        error("itemID must be a positive integer", 3)
    end
end

function ItemInfoCache.New(options)
    options = options or {}
    if type(options.getInfo) ~= "function" then
        error("options.getInfo must be a function", 2)
    end
    if type(options.requestLoad) ~= "function" then
        error("options.requestLoad must be a function", 2)
    end
    local self = setmetatable({}, Cache)
    self.getInfo = options.getInfo
    self.requestLoad = options.requestLoad
    self.onError = options.onError
    self.items = {} -- itemID -> { state, info, callbacks }
    return self
end

function Cache:_report(message)
    if self.onError then
        pcall(self.onError, message)
    end
end

-- Returns the entry for an item and creates it if needed.
function Cache:_entry(itemID)
    local entry = self.items[itemID]
    if not entry then
        entry = { state = "unknown" }
        self.items[itemID] = entry
    end
    return entry
end

-- Asks the client for stored data. Returns the info table or nil.
function Cache:_tryGetInfo(itemID)
    local ok, info = pcall(self.getInfo, itemID)
    if not ok then
        self:_report("getInfo failed for " .. itemID .. ": " .. tostring(info))
        return nil
    end
    return info
end

function Cache:_runCallbacks(itemID, entry)
    local callbacks = entry.callbacks
    entry.callbacks = nil
    if not callbacks then
        return
    end
    for i = 1, #callbacks do
        local ok, err = pcall(callbacks[i], itemID, entry.info, entry.state)
        if not ok then
            self:_report("callback failed for " .. itemID .. ": " .. tostring(err))
        end
    end
end

function Cache:Get(itemID)
    checkID(itemID)
    local entry = self.items[itemID]
    if entry and entry.state == "loaded" then
        return entry.info, "loaded"
    end
    local info = self:_tryGetInfo(itemID)
    if info then
        entry = self:_entry(itemID)
        entry.state = "loaded"
        entry.info = info
        return info, "loaded"
    end
    return nil, entry and entry.state or "unknown"
end

function Cache:GetState(itemID)
    checkID(itemID)
    local entry = self.items[itemID]
    return entry and entry.state or "unknown"
end

function Cache:Request(itemID, callback)
    checkID(itemID)
    local info, state = self:Get(itemID)
    if state == "loaded" then
        if callback then
            callback(itemID, info, "loaded")
        end
        return
    end
    if state == "failed" then
        if callback then
            callback(itemID, nil, "failed")
        end
        return
    end
    local entry = self:_entry(itemID)
    if callback then
        entry.callbacks = entry.callbacks or {}
        entry.callbacks[#entry.callbacks + 1] = callback
    end
    if state == "requested" then
        return
    end
    entry.state = "requested"
    local ok, err = pcall(self.requestLoad, itemID)
    if not ok then
        entry.state = "failed"
        self:_report("requestLoad failed for " .. itemID .. ": " .. tostring(err))
        self:_runCallbacks(itemID, entry)
    end
end

function Cache:OnLoadResult(itemID, success)
    if not isValidID(itemID) then
        return
    end
    local entry = self.items[itemID]
    local info
    if success then
        info = self:_tryGetInfo(itemID)
    end
    if not entry then
        if not info then
            return
        end
        entry = self:_entry(itemID)
    end
    if info then
        entry.state = "loaded"
        entry.info = info
    else
        entry.state = "failed"
    end
    self:_runCallbacks(itemID, entry)
end

function Cache:ResetFailed()
    local count = 0
    for _, entry in pairs(self.items) do
        if entry.state == "failed" then
            entry.state = "unknown"
            count = count + 1
        end
    end
    return count
end

function Cache:GetPendingCount()
    local count = 0
    for _, entry in pairs(self.items) do
        if entry.state == "requested" then
            count = count + 1
        end
    end
    return count
end

function Cache:Wipe()
    self.items = {}
end
