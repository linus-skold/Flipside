local _, ns = ...

local TooltipConfig = {}
ns.TooltipConfig = TooltipConfig

local KEY = "tooltip"
local READ_ONLY = "settings are read-only"
local MAX_LABEL = 30
local MAX_LINES = 12
local TABLE_LABEL = "Price table"
local VERSION = 2
local FLAGS = { showGroup = true, showOperation = true, showCounts = true }
-- showVendor is new: a stored config without it gets true, so it is not checked on load.
local SETTABLE_FLAGS = { showGroup = true, showOperation = true, showCounts = true, showVendor = true }
local PERIODS = { "1d", "14d", "30d", "60d" }
local STATS = { "min", "avg", "max", "market" }
local FIELDS = {
    label = true, formula = true, showAge = true, showSamples = true, enabled = true, altStack = true, color = true,
}
local BOOL_FIELDS = { showAge = true, showSamples = true, enabled = true, altStack = true }

local Config = {}
Config.__index = Config

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

local function IsID(value)
    return type(value) == "number" and value >= 1 and value % 1 == 0 and value ~= math.huge
end

-- The price table is a line with kind "table": it shows the Min/Avg/Max/Market table of the windows.
local function NewTableLine(id)
    return {
        id = id,
        kind = "table",
        label = TABLE_LABEL,
        formula = "",
        showAge = false,
        showSamples = false,
        enabled = true,
        altStack = true,
    }
end

local function NewDefaults()
    return {
        version = VERSION,
        nextID = 2,
        showGroup = true,
        showOperation = true,
        showCounts = true,
        showVendor = true,
        periods = { ["1d"] = true, ["14d"] = true, ["30d"] = true, ["60d"] = true },
        stats = { min = true, avg = true, max = true, market = true },
        lines = { NewTableLine(1) },
    }
end

-- The version 1 default lines. A stored line that still equals one of them is replaced by the price table.
local LEGACY_DEFAULTS = {
    [1] = { label = "Market", formula = "scanmarket", showAge = true, showSamples = true, enabled = true },
    [2] = { label = "Min", formula = "scanlow", showAge = true, showSamples = false, enabled = true },
    [3] = { label = "Max", formula = "scanhigh", showAge = false, showSamples = false, enabled = true },
}

local function IsLegacyDefault(line)
    local default = LEGACY_DEFAULTS[line.id]
    if not default or line.kind ~= nil then
        return false
    end
    for field, value in pairs(default) do
        if line[field] ~= value then
            return false
        end
    end
    return true
end

local function CountCustom(lines)
    local count = 0
    for _, line in ipairs(lines) do
        if line.kind ~= "table" then
            count = count + 1
        end
    end
    return count
end

-- Returns version 2 data from valid version 1 data: untouched default lines go, the price table comes first.
local function Migrate(old)
    local data = DeepCopy(old)
    data.version = VERSION
    data.lines = { NewTableLine(old.nextID) }
    data.nextID = old.nextID + 1
    for _, line in ipairs(old.lines) do
        if not IsLegacyDefault(line) then
            data.lines[#data.lines + 1] = DeepCopy(line)
        end
    end
    return data
end

-- Returns the trimmed label, or nil and a message.
local function CleanLabel(label)
    if type(label) ~= "string" then
        return nil, "label must be a string"
    end
    local trimmed = label:match("^%s*(.-)%s*$")
    if #trimmed < 1 or #trimmed > MAX_LABEL then
        return nil, "label must have 1 to 30 characters"
    end
    return trimmed
end

local function Validate(data, version)
    if type(data) ~= "table" or data.version ~= version then
        return false, "tooltip data has an unknown version"
    end
    if not IsID(data.nextID) or type(data.lines) ~= "table" or CountCustom(data.lines) > MAX_LINES then
        return false, "tooltip data is malformed"
    end
    for flag in pairs(FLAGS) do
        if type(data[flag]) ~= "boolean" then
            return false, "tooltip data is malformed"
        end
    end
    local seen, tableSeen = {}, false
    for i, line in ipairs(data.lines) do
        if type(line) ~= "table" or not IsID(line.id) or line.id >= data.nextID or seen[line.id] then
            return false, "tooltip data has an invalid line"
        end
        seen[line.id] = true
        if line.kind == "table" then
            if version ~= VERSION or tableSeen or line.label ~= TABLE_LABEL or line.formula ~= "" then
                return false, "tooltip data has an invalid line"
            end
            tableSeen = true
        elseif line.kind ~= nil or CleanLabel(line.label) ~= line.label or type(line.formula) ~= "string"
            or line.formula:match("^%s*$") then
            return false, "tooltip data has an invalid line"
        end
        for field in pairs(BOOL_FIELDS) do
            local missingAlt = field == "altStack" and line[field] == nil
            if type(line[field]) ~= "boolean" and not missingAlt then
                return false, "tooltip data has an invalid line"
            end
        end
        if data.lines[i + 1] == nil and next(data.lines, i) ~= nil then
            return false, "tooltip data is malformed"
        end
    end
    return true
end

-- Returns true if value is a colour { r, g, b } with parts from 0 to 1.
local function IsColor(value)
    if type(value) ~= "table" then
        return false
    end
    for i = 1, 3 do
        if type(value[i]) ~= "number" or value[i] ~= value[i] or value[i] < 0 or value[i] > 1 then
            return false
        end
    end
    return true
end

local function CheckFormula(compile, formula)
    if type(formula) ~= "string" or formula:match("^%s*$") then
        return nil, "Enter a formula."
    end
    if compile then
        local compiled, err = compile(formula)
        if not compiled then
            local msg = (type(err) == "table" and err.message) or tostring(err)
            local pos = type(err) == "table" and err.pos
            if pos then
                msg = msg .. " (at position " .. tostring(pos) .. ")"
            end
            return nil, msg
        end
    end
    return true
end

-- A stored line without altStack gets the default true. Missing or malformed new settings get the defaults.
-- A malformed line colour is dropped.
local function FillAltStack(data)
    if type(data.showVendor) ~= "boolean" then
        data.showVendor = true
    end
    for field, names in pairs({ periods = PERIODS, stats = STATS }) do
        if type(data[field]) ~= "table" then
            data[field] = {}
        end
        for _, name in ipairs(names) do
            if type(data[field][name]) ~= "boolean" then
                data[field][name] = true
            end
        end
    end
    for _, line in ipairs(data.lines) do
        if line.altStack == nil then
            line.altStack = true
        end
        if line.color ~= nil and not IsColor(line.color) then
            line.color = nil
        end
    end
end

function Config:_Load()
    local stored = self._db:Get("profile", KEY)
    if stored == nil then
        self._data = NewDefaults()
        return
    end
    local ok, message = Validate(stored, stored.version == 1 and 1 or VERSION)
    if ok and stored.version == 1 then
        self._data = Migrate(stored)
        FillAltStack(self._data)
        return
    end
    if not ok then
        self._loadFailed = true
        self._data = NewDefaults()
        if self._onWarning then
            self._onWarning("Flipside tooltip settings are read-only: " .. message .. ".")
        end
        return
    end
    self._data = DeepCopy(stored)
    FillAltStack(self._data)
end

function Config:IsReadOnly()
    return self._loadFailed or self._db:IsReadOnly() or false
end

-- Runs fn on a working copy, saves it, and rolls back on failure.
function Config:_Change(fn)
    if self:IsReadOnly() then
        return nil, READ_ONLY
    end
    local old = self._data
    self._data = DeepCopy(old)
    local ok, message = fn(self._data)
    if not ok then
        self._data = old
        return nil, message
    end
    if not self._db:Set("profile", KEY, DeepCopy(self._data)) then
        self._data = old
        return nil, READ_ONLY
    end
    if self._onChange then
        self._onChange()
    end
    return true
end

local function IndexOf(data, id)
    for i, line in ipairs(data.lines) do
        if line.id == id then
            return i
        end
    end
    return nil
end

function Config:Get()
    return DeepCopy(self._data)
end

function Config:AddLine(label, formula)
    return self:_Change(function(data)
        local clean, message = CleanLabel(label)
        if not clean then
            return nil, message
        end
        if CountCustom(data.lines) >= MAX_LINES then
            return nil, "a tooltip can have 12 lines at most"
        end
        local ok, err = CheckFormula(self._compile, formula)
        if not ok then
            return nil, err
        end
        data.lines[#data.lines + 1] = {
            id = data.nextID,
            label = clean,
            formula = formula,
            showAge = false,
            showSamples = false,
            enabled = true,
            altStack = true,
        }
        data.nextID = data.nextID + 1
        return true
    end)
end

function Config:UpdateLine(id, fields)
    return self:_Change(function(data)
        local index = IndexOf(data, id)
        if not index then
            return nil, "line does not exist"
        end
        if type(fields) ~= "table" then
            return nil, "fields must be a table"
        end
        local line = data.lines[index]
        for field, value in pairs(fields) do
            if not FIELDS[field] then
                return nil, "unknown field " .. tostring(field)
            end
            if line.kind == "table" and field ~= "enabled" and field ~= "altStack" then
                return nil, "the price table has only an on/off setting and an Alt setting"
            end
            if BOOL_FIELDS[field] then
                if type(value) ~= "boolean" then
                    return nil, field .. " must be true or false"
                end
                line[field] = value
            elseif field == "color" then
                -- nil or false removes the colour: the line has the default colour again.
                if not value then
                    line.color = nil
                elseif IsColor(value) then
                    line.color = { value[1], value[2], value[3] }
                else
                    return nil, "color must be { r, g, b } with parts from 0 to 1"
                end
            elseif field == "label" then
                local clean, message = CleanLabel(value)
                if not clean then
                    return nil, message
                end
                line.label = clean
            else
                local ok, err = CheckFormula(self._compile, value)
                if not ok then
                    return nil, err
                end
                line.formula = value
            end
        end
        return true
    end)
end

function Config:RemoveLine(id)
    return self:_Change(function(data)
        local index = IndexOf(data, id)
        if not index then
            return nil, "line does not exist"
        end
        if data.lines[index].kind == "table" then
            return nil, "the price table cannot be removed; turn it off"
        end
        table.remove(data.lines, index)
        return true
    end)
end

-- Moves the line by delta places and stops at the ends of the list.
function Config:MoveLine(id, delta)
    return self:_Change(function(data)
        local index = IndexOf(data, id)
        if not index then
            return nil, "line does not exist"
        end
        if type(delta) ~= "number" or delta % 1 ~= 0 then
            return nil, "delta must be a whole number"
        end
        local target = math.max(1, math.min(#data.lines, index + delta))
        local line = table.remove(data.lines, index)
        table.insert(data.lines, target, line)
        return true
    end)
end

function Config:SetFlag(name, value)
    return self:_Change(function(data)
        if not SETTABLE_FLAGS[name] then
            return nil, "unknown flag"
        end
        if type(value) ~= "boolean" then
            return nil, "value must be true or false"
        end
        data[name] = value
        return true
    end)
end

-- Turns one price window ("1d", "14d", "30d", "60d") on or off.
function Config:SetPeriod(label, value)
    return self:_SetChoice("periods", PERIODS, label, value)
end

-- Turns one price stat ("min", "avg", "max", "market") on or off.
function Config:SetStat(name, value)
    return self:_SetChoice("stats", STATS, name, value)
end

function Config:_SetChoice(field, names, name, value)
    return self:_Change(function(data)
        local known = false
        for _, one in ipairs(names) do
            known = known or one == name
        end
        if not known then
            return nil, "unknown " .. field .. " name"
        end
        if type(value) ~= "boolean" then
            return nil, "value must be true or false"
        end
        data[field][name] = value
        return true
    end)
end

function Config:ResetDefaults()
    return self:_Change(function(data)
        local defaults = NewDefaults()
        for k in pairs(data) do
            data[k] = nil
        end
        for k, v in pairs(defaults) do
            data[k] = v
        end
        return true
    end)
end

-- db is a SettingsDB object. Options: compile, onChange, onWarning.
function TooltipConfig.New(db, options)
    if type(db) ~= "table" then
        error("db must be a SettingsDB object", 2)
    end
    options = options or {}
    local self = setmetatable({
        _db = db,
        _compile = options.compile,
        _onChange = options.onChange,
        _onWarning = options.onWarning,
        _loadFailed = false,
    }, Config)
    self:_Load()
    return self
end
