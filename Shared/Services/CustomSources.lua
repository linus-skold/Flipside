local _, ns = ...

-- Named formulas stored in the profile; usable as sources in any formula.

local CustomSources = {}
ns.CustomSources = CustomSources

local KEY = "customSources"
local VERSION = 1
local MIN_LENGTH, MAX_LENGTH = 2, 32

local Store = {}
Store.__index = Store

function CustomSources.New(db, options)
    options = options or {}
    local self = setmetatable({}, Store)
    self.db = db
    self.onWarning = options.onWarning
    self.onChange = options.onChange
    self.isBuiltin = options.isBuiltin
    self.version = 0
    self.seen = nil
    return self
end

local function lowerName(name)
    return type(name) == "string" and name:lower() or nil
end

function Store:_isBuiltin(name)
    if self.isBuiltin then
        return self.isBuiltin(name) and true or false
    end
    if name == "invalid" or ns.FormulaFunctions.IsKnown(name) then
        return true
    end
    return ns.FormulaSources.New():Status(name) ~= "unknown"
end

-- Returns the current sources map (a reference; do not change it).
function Store:_map()
    local data = self.db:Get("profile", KEY)
    local map = type(data) == "table" and type(data.sources) == "table" and data.sources or {}
    if data ~= self.seen then
        self.seen = data
        self.version = self.version + 1
    end
    return map
end

function Store:_write(map)
    if not self.db:Set("profile", KEY, { version = VERSION, sources = map }) then
        return nil, "Settings are read-only; the change is not saved."
    end
    self.version = self.version + 1
    self.seen = self.db:Get("profile", KEY)
    if self.onChange then
        self.onChange()
    end
    return true
end

function Store:Version()
    self:_map()
    return self.version
end

function Store:IsReadOnly()
    return self.db:IsReadOnly() and true or false
end

function Store:Get(name)
    name = lowerName(name)
    if not name then
        return nil
    end
    local text = self:_map()[name]
    return type(text) == "string" and text or nil
end

function Store:List()
    local list = {}
    for name, text in pairs(self:_map()) do
        list[#list + 1] = { name = name, text = text }
    end
    table.sort(list, function(a, b)
        return a.name < b.name
    end)
    return list
end

-- Returns true, or false plus a message, for a custom source name.
function CustomSources.CheckName(name)
    if type(name) ~= "string" then
        return false, "The name must be text."
    end
    if #name < MIN_LENGTH or #name > MAX_LENGTH then
        return false, "The name must have " .. MIN_LENGTH .. " to " .. MAX_LENGTH .. " characters."
    end
    if not name:match("^[a-z][a-z0-9_]*$") then
        return false, "The name must start with a letter and use only letters, digits and underscore."
    end
    return true
end

local function collect(node, used)
    local kind = node.kind
    if kind == "name" then
        used[node.name] = true
    elseif kind == "neg" then
        collect(node.expr, used)
    elseif kind == "bin" then
        collect(node.left, used)
        collect(node.right, used)
    elseif kind == "call" then
        for i = 1, #node.args do
            collect(node.args[i], used)
        end
    end
end

-- Returns a sorted list of the names in the text, or nil plus the parse error.
local function namesIn(text)
    local tree, err = ns.FormulaParse.Parse(text)
    if not tree then
        return nil, err
    end
    local used, list = {}, {}
    collect(tree, used)
    for name in pairs(used) do
        list[#list + 1] = name
    end
    table.sort(list)
    return list
end

-- Returns the loop chain as a list of names, or nil.
local function findLoop(map, start)
    local path, onPath, done = {}, {}, {}
    local function visit(name)
        path[#path + 1] = name
        onPath[name] = #path
        local names = namesIn(map[name]) or {}
        for _, dep in ipairs(names) do
            if map[dep] then
                if onPath[dep] then
                    local chain = {}
                    for i = onPath[dep], #path do
                        chain[#chain + 1] = path[i]
                    end
                    chain[#chain + 1] = dep
                    return chain
                elseif not done[dep] then
                    local found = visit(dep)
                    if found then
                        return found
                    end
                end
            end
        end
        done[name] = true
        path[#path] = nil
        onPath[name] = nil
        return nil
    end
    return visit(start)
end

local function messageOf(err)
    if type(err) == "table" then
        return err.message or "The formula is not valid."
    end
    return tostring(err or "The formula is not valid.")
end

local function copy(map)
    local out = {}
    for k, v in pairs(map) do
        out[k] = v
    end
    return out
end

-- Saves a custom source. Returns true, or nil plus a message.
function Store:Set(name, text, compile)
    name = lowerName(name)
    local ok, message = CustomSources.CheckName(name)
    if not ok then
        return nil, message
    end
    if self:_isBuiltin(name) then
        return nil, "'" .. name .. "' is already a built-in name."
    end
    if type(text) ~= "string" then
        return nil, "The formula must be text."
    end
    if self:IsReadOnly() then
        if self.onWarning then
            self.onWarning("Settings are read-only; the change is not saved.")
        end
        return nil, "Settings are read-only; the change is not saved."
    end
    local _, perr = namesIn(text)
    if perr then
        return nil, messageOf(perr)
    end
    local map = copy(self:_map())
    map[name] = text
    local chain = findLoop(map, name)
    if chain then
        return nil, "loop: " .. table.concat(chain, " -> ")
    end
    if compile then
        local compiled, err = compile(text)
        if not compiled then
            return nil, messageOf(err)
        end
    end
    return self:_write(map)
end

-- Deletes a custom source. Returns true, or nil plus a message.
function Store:Delete(name)
    name = lowerName(name)
    local map = self:_map()
    if not name or map[name] == nil then
        return nil, "Unknown custom source."
    end
    local users = {}
    for other, text in pairs(map) do
        if other ~= name then
            for _, dep in ipairs(namesIn(text) or {}) do
                if dep == name then
                    users[#users + 1] = other
                    break
                end
            end
        end
    end
    if #users > 0 then
        table.sort(users)
        return nil, "'" .. name .. "' is used by: " .. table.concat(users, ", ")
    end
    local out = copy(map)
    out[name] = nil
    return self:_write(out)
end
