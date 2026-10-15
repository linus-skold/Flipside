local _, ns = ...

local RulesStore = {}
ns.RulesStore = RulesStore

local GROUPS_KEY = "groups"
local OPERATIONS_KEY = "operations"
local READ_ONLY = "settings are read-only"
local MAX_NAME = 40

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

local function IsID(value)
    return type(value) == "number" and value >= 1 and value % 1 == 0 and value ~= math.huge
end

local function IsType(opType)
    for _, known in ipairs(ns.OperationSchema.TYPES) do
        if known == opType then
            return true
        end
    end
    return false
end

-- Returns the trimmed name, or nil and a message.
local function CleanName(name)
    if type(name) ~= "string" then
        return nil, "name must be a string"
    end
    local trimmed = name:match("^%s*(.-)%s*$")
    if #trimmed < 1 or #trimmed > MAX_NAME then
        return nil, "name must have 1 to 40 characters"
    end
    return trimmed
end

local function NewOperations()
    return { version = 1, nextID = 1, ops = {} }
end

-- Returns true if the operations data is well formed. Otherwise returns false and a message.
local function ValidateOperations(data)
    if type(data) ~= "table" or data.version ~= 1 then
        return false, "operations data has an unknown version"
    end
    if not IsID(data.nextID) or type(data.ops) ~= "table" then
        return false, "operations data is malformed"
    end
    local seen = {}
    for id, op in pairs(data.ops) do
        if not IsID(id) or id >= data.nextID or type(op) ~= "table" then
            return false, "operations data has an invalid operation"
        end
        if not IsType(op.type) or type(op.settings) ~= "table" then
            return false, "operations data has an invalid operation"
        end
        local clean = CleanName(op.name)
        if clean ~= op.name then
            return false, "operations data has an invalid name"
        end
        local nameKey = op.type .. ":" .. clean:lower()
        if seen[nameKey] then
            return false, "operations data has a duplicate name"
        end
        seen[nameKey] = true
    end
    return true
end

local function NameTaken(data, opType, name, exceptID)
    local lowered = name:lower()
    for id, op in pairs(data.ops) do
        if op.type == opType and id ~= exceptID and op.name:lower() == lowered then
            return true
        end
    end
    return false
end

function Store:_Warn(message)
    if self._onWarning then
        self._onWarning(message)
    end
end

function Store:_Load()
    local groups = self._db:Get("profile", GROUPS_KEY)
    local operations = self._db:Get("profile", OPERATIONS_KEY)
    local problem
    if groups ~= nil then
        local ok, message = ns.GroupTree.Validate(groups)
        if not ok then
            problem = "groups data is invalid (" .. tostring(message) .. ")"
        end
    end
    if not problem and operations ~= nil then
        local ok, message = ValidateOperations(operations)
        if not ok then
            problem = message
        end
    end
    if problem then
        self._loadFailed = true
        self:_Warn("Flipside groups and operations are read-only: " .. problem .. ".")
    end
    self._groups = groups ~= nil and DeepCopy(groups) or ns.GroupTree.NewData()
    self._operations = operations ~= nil and DeepCopy(operations) or NewOperations()
    if problem then
        if not ns.GroupTree.Validate(self._groups) then
            self._groups = ns.GroupTree.NewData()
        end
        if not ValidateOperations(self._operations) then
            self._operations = NewOperations()
        end
    end
end

function Store:IsReadOnly()
    return self._loadFailed or self._db:IsReadOnly() or false
end

-- Runs fn on the working copies and saves the listed keys. Rolls back on any failure.
function Store:_Change(kinds, fn)
    if self:IsReadOnly() then
        return nil, READ_ONLY
    end
    local oldGroups, oldOperations = self._groups, self._operations
    self._groups, self._operations = DeepCopy(oldGroups), DeepCopy(oldOperations)
    self._changed = nil
    local results = { fn() }
    local function rollback()
        self._groups, self._operations = oldGroups, oldOperations
    end
    if results[1] == nil then
        rollback()
        return nil, results[2]
    end
    local changed = self._changed or kinds
    self._changed = nil
    for _, kind in ipairs(changed) do
        local value = kind == "groups" and self._groups or self._operations
        local key = kind == "groups" and GROUPS_KEY or OPERATIONS_KEY
        if not self._db:Set("profile", key, DeepCopy(value)) then
            rollback()
            return nil, READ_ONLY
        end
    end
    if self._onChange then
        for _, kind in ipairs(changed) do
            self._onChange(kind)
        end
    end
    return unpack(results)
end

-- Groups.

function Store:CreateGroup(parentID, name)
    return self:_Change({ "groups" }, function()
        return ns.GroupTree.Create(self._groups, parentID, name)
    end)
end

function Store:RenameGroup(id, name)
    return self:_Change({ "groups" }, function()
        return ns.GroupTree.Rename(self._groups, id, name)
    end)
end

function Store:MoveGroup(id, parentID)
    return self:_Change({ "groups" }, function()
        return ns.GroupTree.Move(self._groups, id, parentID)
    end)
end

function Store:DeleteGroup(id)
    return self:_Change({ "groups" }, function()
        return ns.GroupTree.Delete(self._groups, id)
    end)
end

function Store:AddItem(key, groupID)
    return self:_Change({ "groups" }, function()
        return ns.GroupTree.AddItem(self._groups, key, groupID)
    end)
end

-- Adds the valid keys in one save. Returns the number added.
function Store:AddItems(keys, groupID)
    return self:_Change({ "groups" }, function()
        if not ns.GroupTree.Exists(self._groups, groupID) then
            return nil, "group does not exist"
        end
        local added = 0
        for _, key in ipairs(keys or {}) do
            if ns.GroupTree.AddItem(self._groups, key, groupID) then
                added = added + 1
            end
        end
        return added
    end)
end

function Store:RemoveItem(key)
    return self:_Change({ "groups" }, function()
        return ns.GroupTree.RemoveItem(self._groups, key)
    end)
end

function Store:GroupOf(key)
    return ns.GroupTree.GroupOf(self._groups, key)
end

function Store:Children(id)
    return ns.GroupTree.Children(self._groups, id)
end

function Store:Name(id)
    return ns.GroupTree.Name(self._groups, id)
end

function Store:Path(id)
    return ns.GroupTree.Path(self._groups, id)
end

function Store:ItemsIn(id)
    return ns.GroupTree.ItemsIn(self._groups, id)
end

function Store:CountItems(id, recursive)
    return ns.GroupTree.CountItems(self._groups, id, recursive)
end

function Store:Walk(fn)
    return ns.GroupTree.Walk(self._groups, fn)
end

-- Operations.

function Store:CreateOperation(opType, name)
    if not IsType(opType) then
        return nil, "unknown operation type"
    end
    return self:_Change({ "operations" }, function()
        local clean, message = CleanName(name)
        if not clean then
            return nil, message
        end
        local data = self._operations
        if NameTaken(data, opType, clean) then
            return nil, "an operation of this type has this name"
        end
        local id = data.nextID
        data.nextID = id + 1
        data.ops[id] = { type = opType, name = clean, settings = ns.OperationSchema.Defaults(opType) }
        return id
    end)
end

function Store:RenameOperation(id, name)
    return self:_Change({ "operations" }, function()
        local op = self._operations.ops[id]
        if not op then
            return nil, "operation does not exist"
        end
        local clean, message = CleanName(name)
        if not clean then
            return nil, message
        end
        if NameTaken(self._operations, op.type, clean, id) then
            return nil, "an operation of this type has this name"
        end
        op.name = clean
        return true
    end)
end

function Store:DuplicateOperation(id, newName)
    return self:_Change({ "operations" }, function()
        local data = self._operations
        local op = data.ops[id]
        if not op then
            return nil, "operation does not exist"
        end
        local clean, message = CleanName(newName)
        if not clean then
            return nil, message
        end
        if NameTaken(data, op.type, clean) then
            return nil, "an operation of this type has this name"
        end
        local newID = data.nextID
        data.nextID = newID + 1
        data.ops[newID] = { type = op.type, name = clean, settings = DeepCopy(op.settings) }
        return newID
    end)
end

-- Deletes the operation and detaches it from all groups.
function Store:DeleteOperation(id)
    return self:_Change({ "operations" }, function()
        if not self._operations.ops[id] then
            return nil, "operation does not exist"
        end
        self._operations.ops[id] = nil
        local removed = ns.GroupTree.DetachOperation(self._groups, id)
        if removed > 0 then
            self._changed = { "operations", "groups" }
        end
        return true
    end)
end

function Store:GetOperation(id)
    local op = self._operations.ops[id]
    if not op then
        return nil
    end
    return {
        id = id,
        name = op.name,
        type = op.type,
        settings = ns.OperationSchema.Normalize(op.type, DeepCopy(op.settings)),
    }
end

-- Returns { id, name, type } entries sorted by name. A nil type lists all types.
function Store:ListOperations(opType)
    local list = {}
    for id, op in pairs(self._operations.ops) do
        if opType == nil or op.type == opType then
            list[#list + 1] = { id = id, name = op.name, type = op.type }
        end
    end
    table.sort(list, function(a, b)
        local nameA, nameB = a.name:lower(), b.name:lower()
        if nameA ~= nameB then
            return nameA < nameB
        end
        return a.id < b.id
    end)
    return list
end

local function AcceptAll()
    return true
end

function Store:SetSetting(id, key, value)
    return self:_Change({ "operations" }, function()
        local op = self._operations.ops[id]
        if not op then
            return nil, "operation does not exist"
        end
        local ok, message = ns.OperationSchema.ValidateField(op.type, key, value, self._compile or AcceptAll)
        if not ok then
            return nil, message
        end
        op.settings[key] = value
        return true
    end)
end

function Store:GroupsUsing(id)
    local list = {}
    for groupID, slot in pairs(self._groups.attach) do
        for _, opID in pairs(slot) do
            if opID == id then
                list[#list + 1] = groupID
                break
            end
        end
    end
    table.sort(list)
    return list
end

-- Attachments.

function Store:AttachOperation(groupID, opType, opID)
    return self:_Change({ "groups" }, function()
        local op = self._operations.ops[opID]
        if not op then
            return nil, "operation does not exist"
        end
        if op.type ~= opType then
            return nil, "operation type does not match"
        end
        return ns.GroupTree.Attach(self._groups, groupID, opType, opID)
    end)
end

function Store:DetachOperation(groupID, opType)
    return self:_Change({ "groups" }, function()
        if not ns.GroupTree.Exists(self._groups, groupID) then
            return nil, "group does not exist"
        end
        return ns.GroupTree.Detach(self._groups, groupID, opType)
    end)
end

function Store:EffectiveOperation(groupID, opType)
    return ns.GroupTree.Effective(self._groups, groupID, opType)
end

-- Make one built-in operation and attach it to Base if Base has none of that type.
local function SeedOperation(self, data, opType, baseName, settings)
    local name = baseName
    local suffix = 1
    while NameTaken(data, opType, name) do
        suffix = suffix + 1
        name = baseName .. " (" .. suffix .. ")"
    end
    local id = data.nextID
    data.nextID = id + 1
    data.ops[id] = { type = opType, name = name, settings = settings }
    if not ns.GroupTree.Attached(self._groups, 1, opType) then
        ns.GroupTree.Attach(self._groups, 1, opType, id)
    end
    return id
end

-- Once for each profile and type: make the built-in selling and buying operations on Base.
-- Each attaches only if Base has no operation of that type. A deleted operation does not come back.
function Store:_SeedDefault()
    local first = self._operations
    if (first.defaultSeeded and first.defaultBuyingSeeded) or self:IsReadOnly() then
        return
    end
    local onChange = self._onChange
    self._onChange = nil
    self:_Change({ "operations", "groups" }, function()
        local Schema, data = ns.OperationSchema, self._operations
        if not data.defaultSeeded then
            SeedOperation(self, data, "selling", Schema.DEFAULT_SELLING_NAME, Schema.DefaultSellingSettings())
            data.defaultSeeded = true
        end
        if not data.defaultBuyingSeeded then
            SeedOperation(self, data, "buying", Schema.DEFAULT_BUYING_NAME, Schema.DefaultBuyingSettings())
            data.defaultBuyingSeeded = true
        end
        return true
    end)
    self._onChange = onChange
end
-- db is a SettingsDB object. Options: onWarning, onChange, compile.
-- seedDefault = true makes the default selling and buying operations once for the profile.
function RulesStore.New(db, options)
    if type(db) ~= "table" then
        error("db must be a SettingsDB object", 2)
    end
    options = options or {}
    local self = setmetatable({
        _db = db,
        _onWarning = options.onWarning,
        _onChange = options.onChange,
        _compile = options.compile,
        _loadFailed = false,
    }, Store)
    self:_Load()
    if options.seedDefault == true then
        self:_SeedDefault()
    end
    return self
end
