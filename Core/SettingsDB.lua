local _, ns = ...

local SettingsDB = {}
ns.SettingsDB = SettingsDB

local DEFAULT_PROFILE = "Default"
local MAP_KEY = "a/profiles.map"
local LIST_KEY = "a/profiles.list"
local SCOPES = { account = true, profile = true, character = true }

local DB = {}
DB.__index = DB

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

local function CheckName(name, what)
    if type(name) ~= "string" or name == "" or name:find("/", 1, true) then
        error("invalid " .. what .. " name", 3)
    end
end

local function StartsWith(text, prefix)
    return text:sub(1, #prefix) == prefix
end

-- Returns the stored key for a scope, or raises an error.
function DB:_Key(scope, key)
    if not SCOPES[scope] then
        error("invalid scope", 3)
    end
    CheckName(key, "key")
    if scope == "account" then
        return "a/" .. key
    elseif scope == "profile" then
        return "p/" .. self:GetProfile() .. "/" .. key
    end
    return "c/" .. self._character .. "/" .. key
end

-- Returns true if writes are allowed; otherwise warns once and returns false.
function DB:_CanWrite()
    if not self._readOnly then
        return true
    end
    if not self._warnedWrite then
        self._warnedWrite = true
        self:_Warn("Flipside settings are read-only; changes are not saved.")
    end
    return false
end

function DB:_Warn(message)
    if self._onWarning then
        self._onWarning(message)
    end
end

function DB:_Map()
    return self._saved[MAP_KEY] or {}
end

function DB:_List()
    return self._saved[LIST_KEY] or {}
end

-- Removes every key that starts with the prefix.
function DB:_RemovePrefix(prefix)
    local doomed = {}
    for k in pairs(self._saved) do
        if type(k) == "string" and StartsWith(k, prefix) then
            doomed[#doomed + 1] = k
        end
    end
    for _, k in ipairs(doomed) do
        self._saved[k] = nil
    end
end

function DB:Get(scope, key)
    local value = self._saved[self:_Key(scope, key)]
    if value == nil then
        local defaults = self._defaults[scope]
        if defaults then
            value = DeepCopy(defaults[key])
        end
    end
    return value
end

function DB:Set(scope, key, value)
    local storedKey = self:_Key(scope, key)
    if scope == "account" and (storedKey == MAP_KEY or storedKey == LIST_KEY) then
        error("reserved key", 2)
    end
    if not self:_CanWrite() then
        return false
    end
    self._saved[storedKey] = value
    return true
end

function DB:IsReadOnly()
    return self._readOnly
end

function DB:GetSchemaVersion()
    return self._version
end

function DB:GetProfile()
    return self:_Map()[self._character] or DEFAULT_PROFILE
end

function DB:SetProfile(name)
    CheckName(name, "profile")
    if not self:_CanWrite() then
        return false
    end
    self._saved[MAP_KEY][self._character] = name
    self._saved[LIST_KEY][name] = true
    return true
end

function DB:ListProfiles()
    local names = {}
    for name in pairs(self:_List()) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

function DB:CopyProfile(from, to)
    CheckName(from, "profile")
    CheckName(to, "profile")
    if not self:_List()[from] then
        error("profile does not exist", 2)
    end
    if not self:_CanWrite() then
        return false
    end
    if from == to then
        return true
    end
    local fromPrefix = "p/" .. from .. "/"
    local toPrefix = "p/" .. to .. "/"
    local copies = {}
    for k, v in pairs(self._saved) do
        if type(k) == "string" and StartsWith(k, fromPrefix) then
            copies[toPrefix .. k:sub(#fromPrefix + 1)] = DeepCopy(v)
        end
    end
    self:_RemovePrefix(toPrefix)
    for k, v in pairs(copies) do
        self._saved[k] = v
    end
    self._saved[LIST_KEY][to] = true
    return true
end

function DB:DeleteProfile(name)
    CheckName(name, "profile")
    if name == DEFAULT_PROFILE then
        error("cannot delete the Default profile", 2)
    end
    if not self:_List()[name] then
        error("profile does not exist", 2)
    end
    if not self:_CanWrite() then
        return false
    end
    self:_RemovePrefix("p/" .. name .. "/")
    local map = self._saved[MAP_KEY]
    for character, profile in pairs(map) do
        if profile == name then
            map[character] = DEFAULT_PROFILE
        end
    end
    self._saved[LIST_KEY][name] = nil
    return true
end

function DB:ResetCharacter(character)
    CheckName(character, "character")
    if not self:_CanWrite() then
        return false
    end
    self:_RemovePrefix("c/" .. character .. "/")
    self._saved[MAP_KEY][character] = nil
    return true
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

function SettingsDB.New(saved, options)
    if type(saved) ~= "table" then
        error("saved must be a table", 2)
    end
    options = options or {}
    local version = options.schemaVersion
    if type(options.character) ~= "string" or options.character == "" or options.character:find("/", 1, true) then
        error("options.character must be a valid string", 2)
    end
    if type(version) ~= "number" or version < 1 or version % 1 ~= 0 then
        error("options.schemaVersion must be an integer >= 1", 2)
    end

    local self = setmetatable({
        _saved = saved,
        _character = options.character,
        _defaults = options.defaults or {},
        _onWarning = options.onWarning,
        _readOnly = false,
    }, DB)

    local stored = saved._schema
    if stored == nil then
        stored = next(saved) == nil and version or 0
    end
    self._version = stored

    if type(stored) ~= "number" or stored < 0 or stored % 1 ~= 0 then
        self._readOnly = true
        self:_Warn("Flipside settings have an invalid schema version; they are read-only.")
    elseif stored > version then
        self._readOnly = true
        self:_Warn("Flipside settings use schema version " .. stored
            .. ", but this addon supports version " .. version .. "; they are read-only.")
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
            self:_Warn("Flipside settings were not upgraded from version " .. stored .. " to " .. version
                .. " (" .. err .. "); they are read-only.")
        end
    end

    if not self._readOnly then
        saved._schema = version
        if type(saved[MAP_KEY]) ~= "table" then
            saved[MAP_KEY] = {}
        end
        if type(saved[LIST_KEY]) ~= "table" then
            saved[LIST_KEY] = {}
        end
        local map = saved[MAP_KEY]
        if map[self._character] == nil then
            map[self._character] = DEFAULT_PROFILE
        end
        saved[LIST_KEY][DEFAULT_PROFILE] = true
        saved[LIST_KEY][map[self._character]] = true
    end

    return self
end
