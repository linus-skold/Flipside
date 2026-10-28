local _, ns = ...

-- Saved scan records for one region and ruleset, with a schema version.
-- With options.realm the records are also keyed by realm: data[region][realm][ruleset].
local ScanStore = {}
ns.ScanStore = ScanStore

local Store = {}
Store.__index = Store

local function DeepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for k, v in pairs(value) do
        copy[DeepCopy(k)] = DeepCopy(v)
    end
    return copy
end

local function CheckText(value, what)
    if type(value) ~= "string" or value == "" then
        error("options." .. what .. " must be a non-empty string", 3)
    end
end

function Store:_Warn(message)
    if self._onWarning then
        self._onWarning(message)
    end
end

function Store:_CanWrite()
    if not self._readOnly then
        return true
    end
    if not self._warnedWrite then
        self._warnedWrite = true
        self:_Warn("Flipside scan data is read-only; changes are not saved.")
    end
    return false
end

function Store:_Slot()
    local data = self._saved.data
    local byRegion = type(data) == "table" and data[self._region]
    if self._realm and type(byRegion) == "table" then
        byRegion = byRegion[self._realm]
    end
    local slot = type(byRegion) == "table" and byRegion[self._ruleset]
    return type(slot) == "table" and slot or nil
end

function Store:_Items()
    local slot = self:_Slot()
    local items = slot and slot.items
    return type(items) == "table" and items or nil
end

-- Save the time of a scan commit for this region, realm (TBC) and ruleset. A full scan (partial false) sets the time of
-- the last full scan. A partial scan only marks that the last scan was partial. Returns false if nothing is saved.
function Store:SetLastScan(time, partial)
    local slot = self:_Slot()
    if type(time) ~= "number" or not slot or not self:_CanWrite() then
        return false
    end
    if partial then
        slot.lastPartial = time
    else
        slot.lastFull = time
        slot.lastPartial = nil
    end
    return true
end

-- Returns the time of the last full scan (or nil), and true if a partial scan came after it.
function Store:GetLastScan()
    local slot = self:_Slot()
    local full = slot and type(slot.lastFull) == "number" and slot.lastFull or nil
    local partial = slot and type(slot.lastPartial) == "number" and (full == nil or slot.lastPartial >= full)
    return full, partial == true
end

local function CheckKey(key)
    if type(key) ~= "string" or key == "" then
        error("key must be a non-empty string", 3)
    end
end

function Store:Get(key)
    CheckKey(key)
    local cached = self._cache[key]
    if cached then
        return cached
    end
    if self._removed[key] then
        return nil
    end
    local items = self:_Items()
    local text = items and items[key]
    if text == nil then
        return nil
    end
    local record = type(text) == "string" and ns.ScanRecord.Decode(text) or nil
    if not record then
        if not self._warnedKeys[key] then
            self._warnedKeys[key] = true
            self:_Warn("Flipside scan data for item " .. key .. " is unreadable and was ignored.")
        end
        return nil
    end
    self._cache[key] = record
    return record
end

function Store:Put(key, record)
    CheckKey(key)
    local ok, message = ns.ScanRecord.Validate(record)
    if not ok then
        error("invalid record: " .. tostring(message), 2)
    end
    if not self:_CanWrite() then
        return false
    end
    self._cache[key] = record
    self._changed[key] = true
    self._removed[key] = nil
    self._writeVersion = self._writeVersion + 1
    return true
end

function Store:Remove(key)
    CheckKey(key)
    if not self:_CanWrite() then
        return false
    end
    self._cache[key] = nil
    self._changed[key] = nil
    self._removed[key] = true
    self._writeVersion = self._writeVersion + 1
    return true
end

function Store:Keys()
    local seen = {}
    local items = self:_Items()
    if items then
        for key in pairs(items) do
            if type(key) == "string" and not self._removed[key] then
                seen[key] = true
            end
        end
    end
    for key in pairs(self._changed) do
        seen[key] = true
    end
    local keys = {}
    for key in pairs(seen) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

function Store:CountItems()
    return #self:Keys()
end

function Store:Flush()
    if self._readOnly then
        return 0
    end
    local items = self:_Items()
    for key in pairs(self._removed) do
        items[key] = nil
    end
    self._removed = {}
    local written = 0
    for key in pairs(self._changed) do
        local ok, text = pcall(ns.ScanRecord.Encode, self._cache[key])
        if ok then
            items[key] = text
            written = written + 1
        else
            self:_Warn("Flipside scan data for item " .. key .. " was not saved: " .. tostring(text))
        end
    end
    self._changed = {}
    return written
end

-- Returns a number that grows by 1 on each successful Put and Remove.
function Store:GetVersion()
    return self._writeVersion
end

function Store:IsReadOnly()
    return self._readOnly
end

function Store:GetSchemaVersion()
    return self._version
end

function Store:GetRegion()
    return self._region
end

function Store:GetRealm()
    return self._realm
end

function Store:GetRuleset()
    return self._ruleset
end

-- Runs migrations on a copy; returns the copy, or nil and a message.
local function Migrate(saved, from, to, migrations)
    local data = DeepCopy(saved)
    for step = from + 1, to do
        local fn = migrations and migrations[step]
        if type(fn) ~= "function" then
            return nil, "migration to version " .. step .. " failed: missing migration"
        end
        local ok, err = pcall(fn, data)
        if not ok then
            return nil, "migration to version " .. step .. " failed: " .. tostring(err)
        end
    end
    return data
end

local function EnsureTable(parent, key)
    if type(parent[key]) ~= "table" then
        parent[key] = {}
    end
    return parent[key]
end

function ScanStore.New(saved, options)
    if type(saved) ~= "table" then
        error("saved must be a table", 2)
    end
    options = options or {}
    CheckText(options.region, "region")
    CheckText(options.ruleset, "ruleset")
    if options.realm ~= nil then
        CheckText(options.realm, "realm")
    end
    local version = options.schemaVersion
    if type(version) ~= "number" or version < 1 or version % 1 ~= 0 then
        error("options.schemaVersion must be an integer >= 1", 2)
    end

    local self = setmetatable({
        _saved = saved,
        _region = options.region,
        _realm = options.realm,
        _ruleset = options.ruleset,
        _onWarning = options.onWarning,
        _readOnly = false,
        _cache = {},
        _changed = {},
        _removed = {},
        _warnedKeys = {},
        _writeVersion = 0,
    }, Store)

    local stored = saved._schema
    if stored == nil then
        stored = next(saved) == nil and version or 0
    end
    self._version = stored

    if type(stored) ~= "number" or stored < 0 or stored % 1 ~= 0 then
        self._readOnly = true
        self:_Warn("Flipside scan data has an invalid schema version; it is read-only.")
    elseif stored > version then
        self._readOnly = true
        self:_Warn("Flipside scan data uses schema version " .. stored
            .. ", but this addon supports version " .. version .. "; it is read-only.")
    elseif stored < version then
        local data, err = Migrate(saved, stored, version, options.migrations)
        if data then
            for k in pairs(saved) do
                saved[k] = nil
            end
            for k, v in pairs(data) do
                saved[k] = v
            end
            self._version = version
        else
            self._readOnly = true
            self:_Warn("Flipside scan data was not upgraded from version " .. stored .. " to " .. version
                .. " (" .. err .. "); it is read-only.")
        end
    end

    if not self._readOnly then
        saved._schema = version
        local byRegion = EnsureTable(EnsureTable(saved, "data"), self._region)
        if self._realm then
            byRegion = EnsureTable(byRegion, self._realm)
        end
        local slot = EnsureTable(byRegion, self._ruleset)
        EnsureTable(slot, "items")
        if type(options.meta) == "table" then
            slot.meta = DeepCopy(options.meta)
        elseif type(slot.meta) ~= "table" then
            slot.meta = {}
        end
    end

    return self
end
