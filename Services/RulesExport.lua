local _, ns = ...

-- Text export and import of a group with its sub-groups, items, operations and custom sources.
-- The format is documented in docs/EXPORT_FORMAT.md.
--
-- FLIPSIDE-RULES 1            header, always the first line
-- group|<id>|<parent id>|<name>    parent id is empty for the exported group
-- item|<group id>|<item key>
-- op|<op id>|<type>|<name>
-- set|<op id>|<key>|<s, n or b>|<value>
-- attach|<group id>|<type>|<op id>
-- source|<name>|<formula text>
--
-- One record per line. In a value, "\\" is a backslash, "\|" a bar, "\n" a line feed, "\r" a carriage return.
-- A line that starts with "#" and an empty line are ignored.
--
-- Apply is not all-or-nothing. It checks as much as possible first (Parse and Preview).
-- If a later step still fails, it stops and reports the step. Earlier steps stay in the profile.

local RulesExport = {}
ns.RulesExport = RulesExport

local HEADER = "FLIPSIDE%-RULES"
local VERSION = 1
local MAX_NAME = 40
local MAX_SOURCE_NAME = 32
local NOT_FLIPSIDE = "This is not a Flipside rules export. Flipside does not accept TSM strings."

local function AcceptAll()
    return true
end

-- Escaping.

local ESCAPES = { ["\\"] = "\\\\", ["|"] = "\\|", ["\n"] = "\\n", ["\r"] = "\\r" }
local UNESCAPES = { ["\\"] = "\\", ["|"] = "|", ["n"] = "\n", ["r"] = "\r" }

local function Escape(value)
    return (tostring(value):gsub("[\\|\n\r]", ESCAPES))
end

-- Splits one line at the bars that are not escaped. Returns the fields, or nil and a message.
local function SplitLine(line)
    local fields, buffer = {}, {}
    local i, size = 1, #line
    while i <= size do
        local ch = line:sub(i, i)
        if ch == "\\" then
            local replacement = UNESCAPES[line:sub(i + 1, i + 1)]
            if not replacement then
                return nil, "bad escape sequence"
            end
            buffer[#buffer + 1] = replacement
            i = i + 2
        elseif ch == "|" then
            fields[#fields + 1] = table.concat(buffer)
            buffer = {}
            i = i + 1
        else
            local stop = line:find("[\\|]", i) or (size + 1)
            buffer[#buffer + 1] = line:sub(i, stop - 1)
            i = stop
        end
    end
    fields[#fields + 1] = table.concat(buffer)
    return fields
end

-- Names and formulas.

local function CleanName(name)
    local trimmed = name:match("^%s*(.-)%s*$")
    if #trimmed < 1 or #trimmed > MAX_NAME then
        return nil
    end
    return trimmed
end

-- Returns base .. suffix, with the base cut so that the whole is not longer than max.
local function Fit(base, suffix, max)
    local room = max - #suffix
    if #base > room then
        local cut = room
        while cut > 0 do
            local nextByte = base:byte(cut + 1)
            if nextByte and nextByte >= 0x80 and nextByte < 0xC0 then
                cut = cut - 1
            else
                break
            end
        end
        base = base:sub(1, cut):match("^(.-)%s*$")
    end
    return base .. suffix
end

local function Collect(node, used)
    local kind = node.kind
    if kind == "name" then
        used[node.name] = true
    elseif kind == "neg" then
        Collect(node.expr, used)
    elseif kind == "bin" then
        Collect(node.left, used)
        Collect(node.right, used)
    elseif kind == "call" then
        for _, arg in ipairs(node.args) do
            Collect(arg, used)
        end
    end
end

-- Returns the lower case names in a formula text, sorted. A text that does not parse gives none.
local function NamesIn(text)
    local tree = ns.FormulaParse.Parse(text)
    local list = {}
    if tree then
        local used = {}
        Collect(tree, used)
        for name in pairs(used) do
            list[#list + 1] = name
        end
        table.sort(list)
    end
    return list
end

-- Replaces names in a formula text. The map goes from old lower case name to new name.
local function Rewrite(text, map)
    if next(map) == nil then
        return text
    end
    local out, i, size = {}, 1, #text
    while i <= size do
        local ch = text:sub(i, i)
        if ch:find("[%a_]") then
            local word = text:match("^[%w_]+", i)
            out[#out + 1] = map[word:lower()] or word
            i = i + #word
        elseif ch:find("[%d.]") then
            local word = text:match("^[%w_.]+", i)
            out[#out + 1] = word
            i = i + #word
        else
            out[#out + 1] = ch
            i = i + 1
        end
    end
    return table.concat(out)
end

local function FormulaKeys(opType)
    local list = {}
    for _, field in ipairs(ns.OperationSchema.Fields(opType)) do
        if field.kind == "formula" then
            list[#list + 1] = field.key
        end
    end
    return list
end

local function SameSettings(a, b)
    for key, value in pairs(a) do
        if b[key] ~= value then
            return false
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end
    return true
end

-- Export.

local function EncodeValue(value)
    if type(value) == "boolean" then
        return "b", tostring(value)
    elseif type(value) == "number" then
        return "n", string.format("%.17g", value)
    end
    return "s", tostring(value)
end

local function Record(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = Escape((select(i, ...)))
    end
    return table.concat(parts, "|")
end

-- Returns the export text for a group and everything below it, or nil and a message.
function RulesExport.Export(rules, customSources, groupID)
    if not rules:Name(groupID) then
        return nil, "The group does not exist."
    end
    local lines = { "FLIPSIDE-RULES " .. VERSION }
    local localID, groupList = {}, {}
    local function visit(id, parentLocal)
        local number = #groupList + 1
        groupList[number] = id
        localID[id] = number
        lines[#lines + 1] = Record("group", number, parentLocal or "", rules:Name(id))
        for _, childID in ipairs(rules:Children(id)) do
            visit(childID, number)
        end
    end
    visit(groupID)

    for _, id in ipairs(groupList) do
        for _, key in ipairs(rules:ItemsIn(id)) do
            lines[#lines + 1] = Record("item", localID[id], key)
        end
    end

    local opLocal, opList, attachLines = {}, {}, {}
    for _, id in ipairs(groupList) do
        for _, opType in ipairs(ns.OperationSchema.TYPES) do
            local opID, from = rules:EffectiveOperation(id, opType)
            if opID and (from == id or id == groupID) then
                if not opLocal[opID] then
                    opList[#opList + 1] = opID
                    opLocal[opID] = #opList
                end
                attachLines[#attachLines + 1] = Record("attach", localID[id], opType, opLocal[opID])
            end
        end
    end

    local texts = {}
    for number, opID in ipairs(opList) do
        local op = rules:GetOperation(opID)
        lines[#lines + 1] = Record("op", number, op.type, op.name)
        for _, field in ipairs(ns.OperationSchema.Fields(op.type)) do
            local tag, text = EncodeValue(op.settings[field.key])
            lines[#lines + 1] = Record("set", number, field.key, tag, text)
            if field.kind == "formula" then
                texts[#texts + 1] = op.settings[field.key]
            end
        end
    end
    for _, line in ipairs(attachLines) do
        lines[#lines + 1] = line
    end

    local found = {}
    local function addSources(text)
        for _, name in ipairs(NamesIn(text)) do
            local sourceText = customSources:Get(name)
            if sourceText and not found[name] then
                found[name] = sourceText
                addSources(sourceText)
            end
        end
    end
    for _, text in ipairs(texts) do
        addSources(text)
    end
    local names = {}
    for name in pairs(found) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        lines[#lines + 1] = Record("source", name, found[name])
    end
    return table.concat(lines, "\n") .. "\n"
end

-- Parse.

local function ToID(text)
    local number = tonumber(text)
    if number and number >= 1 and number % 1 == 0 and number < 2 ^ 31 then
        return number
    end
    return nil
end

local function DecodeValue(tag, text)
    if tag == "s" then
        return text
    elseif tag == "n" then
        local number = tonumber(text)
        if number and number == number then
            return number
        end
    elseif tag == "b" and (text == "true" or text == "false") then
        return text == "true"
    end
    return nil
end

local function CheckHeader(text)
    local first = text:match("^[^\n]*"):gsub("\r$", "")
    if not first:find("^" .. HEADER) then
        return nil, NOT_FLIPSIDE
    end
    local version = first:match("^" .. HEADER .. " (%d+)%s*$")
    if not version then
        return nil, NOT_FLIPSIDE
    end
    version = tonumber(version)
    if version > VERSION then
        return nil, "This export uses format version " .. version .. ". This Flipside reads version "
            .. VERSION .. ". Update Flipside to import it."
    end
    if version < 1 then
        return nil, NOT_FLIPSIDE
    end
    return true
end

local Handlers = {}

function Handlers.group(data, f, state)
    local id, parent = ToID(f[2]), nil
    local name = CleanName(f[4] or "")
    if not id or not name or state.groups[id] then
        return "invalid group record"
    end
    local depth = 0
    if f[3] == "" then
        if #data.groups > 0 then
            return "only the first group can have no parent"
        end
    else
        parent = ToID(f[3])
        if not parent or not state.groups[parent] then
            return "the parent group is not defined before this group"
        end
        depth = state.groups[parent].depth + 1
        local siblingKey = parent .. ":" .. name:lower()
        if state.siblings[siblingKey] then
            return "two sub-groups have the same name"
        end
        state.siblings[siblingKey] = true
    end
    if #data.groups == 0 and f[3] ~= "" then
        return "the first group must have no parent"
    end
    if depth > ns.GroupTree.MAX_DEPTH - 1 then
        return "the groups are too deep"
    end
    local group = { id = id, parent = parent, name = name, depth = depth }
    data.groups[#data.groups + 1] = group
    state.groups[id] = group
    data.height = math.max(data.height, depth)
end

function Handlers.item(data, f, state)
    local group = state.groups[ToID(f[2]) or 0]
    if not group or not f[3] or not ns.ItemString.ParseKey(f[3]) then
        return "invalid item record"
    end
    if state.keys[f[3]] then
        return "an item is listed two times"
    end
    state.keys[f[3]] = true
    data.items[#data.items + 1] = { group = group.id, key = f[3] }
end

function Handlers.op(data, f, state)
    local id, opType = ToID(f[2]), f[3]
    local known = false
    for _, t in ipairs(ns.OperationSchema.TYPES) do
        known = known or t == opType
    end
    local name = CleanName(f[4] or "")
    if not id or not known or not name or state.ops[id] then
        return "invalid operation record"
    end
    local nameKey = opType .. ":" .. name:lower()
    if state.opNames[nameKey] then
        return "two operations of one type have the same name"
    end
    state.opNames[nameKey] = true
    local op = { id = id, type = opType, name = name, settings = {} }
    data.ops[#data.ops + 1] = op
    state.ops[id] = op
end

function Handlers.set(_, f, state)
    local op = state.ops[ToID(f[2]) or 0]
    if not op or not f[3] or not f[4] or not f[5] then
        return "invalid setting record"
    end
    local value = DecodeValue(f[4], f[5])
    if value == nil then
        return "invalid setting value"
    end
    if op.settings[f[3]] ~= nil then
        return "a setting is listed two times"
    end
    local ok, message = ns.OperationSchema.ValidateField(op.type, f[3], value, AcceptAll)
    if not ok then
        return "setting '" .. f[3] .. "': " .. tostring(message)
    end
    op.settings[f[3]] = value
end

function Handlers.attach(data, f, state)
    local group, op = state.groups[ToID(f[2]) or 0], state.ops[ToID(f[4] or "") or 0]
    if not group or not op or op.type ~= f[3] then
        return "invalid attachment record"
    end
    local slot = group.id .. ":" .. op.type
    if state.attached[slot] then
        return "a group has two operations of one type"
    end
    state.attached[slot] = true
    data.attach[#data.attach + 1] = { group = group.id, type = op.type, op = op.id }
end

function Handlers.source(data, f, state)
    local name, text = f[2], f[3]
    if not name or not text then
        return "invalid custom source record"
    end
    local ok, message = ns.CustomSources.CheckName(name)
    if not ok then
        return message
    end
    if state.sources[name] then
        return "a custom source is listed two times"
    end
    state.sources[name] = true
    data.sources[#data.sources + 1] = { name = name, text = text }
end

local COUNTS = { group = 4, item = 3, op = 4, set = 5, attach = 4, source = 3 }

-- Returns the data table, or nil and a message.
function RulesExport.Parse(text)
    if type(text) ~= "string" then
        return nil, NOT_FLIPSIDE
    end
    text = text:gsub("^\239\187\191", ""):match("^%s*(.-)%s*$")
    local ok, message = CheckHeader(text)
    if not ok then
        return nil, message
    end
    local data = { groups = {}, items = {}, ops = {}, attach = {}, sources = {}, height = 0 }
    local state = { groups = {}, siblings = {}, keys = {}, ops = {}, opNames = {}, attached = {}, sources = {} }
    local number = 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        number = number + 1
        line = line:gsub("\r$", "")
        if number > 1 and line ~= "" and line:sub(1, 1) ~= "#" then
            local fields, splitMessage = SplitLine(line)
            local problem = splitMessage
            if fields then
                local handler = Handlers[fields[1]]
                if not handler then
                    problem = "unknown record type"
                elseif #fields ~= COUNTS[fields[1]] then
                    problem = "wrong number of fields"
                else
                    problem = handler(data, fields, state)
                end
            end
            if problem then
                return nil, "Line " .. number .. ": " .. problem .. "."
            end
        end
    end
    if #data.groups == 0 then
        return nil, "The export has no group."
    end
    for _, op in ipairs(data.ops) do
        op.settings = ns.OperationSchema.Normalize(op.type, op.settings)
    end
    return data
end

-- Plan, Preview and Apply.

local function Taken(set, name)
    return set[name:lower()] == true
end

local function BuildPlan(rules, customSources, data, parentID)
    if type(data) ~= "table" or not rules:Name(parentID) then
        return nil, "The parent group does not exist."
    end
    local parentDepth = #rules:Path(parentID) - 1
    if parentDepth + 1 + data.height > ns.GroupTree.MAX_DEPTH then
        return nil, "The groups are too deep. The group tree can have " .. ns.GroupTree.MAX_DEPTH
            .. " levels. Choose a parent group that is higher in the tree."
    end
    local summary = {
        groups = #data.groups, items = #data.items, itemsMoved = 0,
        operationsNew = 0, operationsReused = 0, customNew = 0, customReused = 0, renames = {},
    }
    local plan = { summary = summary, sources = {}, ops = {} }

    -- The exported group takes a free name below the parent.
    local siblings = {}
    for _, childID in ipairs(rules:Children(parentID)) do
        siblings[rules:Name(childID):lower()] = true
    end
    local rootName = data.groups[1].name
    plan.rootName = rootName
    local n = 2
    while Taken(siblings, plan.rootName) do
        plan.rootName = Fit(rootName, " (" .. n .. ")", MAX_NAME)
        n = n + 1
    end
    if plan.rootName ~= rootName then
        summary.renames[#summary.renames + 1] = { kind = "group", from = rootName, to = plan.rootName }
    end

    local current = {}
    rules:Walk(function(id)
        for _, key in ipairs(rules:ItemsIn(id)) do
            current[key] = true
        end
    end)
    for _, item in ipairs(data.items) do
        if current[item.key] then
            summary.itemsMoved = summary.itemsMoved + 1
        end
    end

    -- Custom sources: dependencies first.
    local byName, order, visited = {}, {}, {}
    for _, source in ipairs(data.sources) do
        byName[source.name] = source
    end
    local function order_(source)
        if visited[source.name] then
            return
        end
        visited[source.name] = true
        for _, dep in ipairs(NamesIn(source.text)) do
            if byName[dep] then
                order_(byName[dep])
            end
        end
        order[#order + 1] = source
    end
    for _, source in ipairs(data.sources) do
        order_(source)
    end
    local renameMap, assigned = {}, {}
    for _, source in ipairs(order) do
        local text = Rewrite(source.text, renameMap)
        local existing = customSources:Get(source.name)
        local entry = { name = source.name, finalName = source.name, text = text }
        if existing == nil then
            summary.customNew = summary.customNew + 1
        elseif existing == text then
            entry.reuse = true
            summary.customReused = summary.customReused + 1
        else
            local candidate, count = Fit(source.name, "_imported", MAX_SOURCE_NAME), 2
            while customSources:Get(candidate) ~= nil or byName[candidate] or assigned[candidate] do
                candidate = Fit(source.name, "_imported" .. count, MAX_SOURCE_NAME)
                count = count + 1
            end
            entry.finalName = candidate
            renameMap[source.name] = candidate
            summary.customNew = summary.customNew + 1
            summary.renames[#summary.renames + 1] = { kind = "custom", from = source.name, to = candidate }
        end
        assigned[entry.finalName] = true
        plan.sources[#plan.sources + 1] = entry
    end

    -- Operations.
    local assignedNames = {}
    for _, op in ipairs(data.ops) do
        local settings = {}
        for key, value in pairs(op.settings) do
            settings[key] = value
        end
        for _, key in ipairs(FormulaKeys(op.type)) do
            settings[key] = Rewrite(settings[key], renameMap)
        end
        local entry = { id = op.id, type = op.type, name = op.name, finalName = op.name, settings = settings }
        local existingNames, same = {}, nil
        for _, listed in ipairs(rules:ListOperations(op.type)) do
            existingNames[listed.name:lower()] = true
            if listed.name:lower() == op.name:lower()
                and SameSettings(rules:GetOperation(listed.id).settings, settings) then
                same = listed.id
            end
        end
        local function free(name)
            return not existingNames[name:lower()] and not (assignedNames[op.type] or {})[name:lower()]
        end
        if same then
            entry.reuse = same
            summary.operationsReused = summary.operationsReused + 1
        else
            if not free(op.name) then
                local count = 1
                repeat
                    local suffix = count == 1 and " (imported)" or (" (imported " .. count .. ")")
                    entry.finalName = Fit(op.name, suffix, MAX_NAME)
                    count = count + 1
                until free(entry.finalName)
                summary.renames[#summary.renames + 1] = { kind = "operation", from = op.name, to = entry.finalName }
            end
            assignedNames[op.type] = assignedNames[op.type] or {}
            assignedNames[op.type][entry.finalName:lower()] = true
            summary.operationsNew = summary.operationsNew + 1
        end
        plan.ops[#plan.ops + 1] = entry
    end
    return plan
end

-- Returns the summary of what Apply would do, or nil and a message. Changes nothing.
function RulesExport.Preview(rules, customSources, data, parentID)
    local plan, message = BuildPlan(rules, customSources, data, parentID)
    if not plan then
        return nil, message
    end
    return plan.summary
end

local function Stop(step, message)
    return nil, "Import stopped at step '" .. step .. "': " .. tostring(message)
        .. " Earlier steps stay in your profile."
end

-- Imports the data below the parent group. Returns true and the summary, or nil and a message.
function RulesExport.Apply(rules, customSources, data, parentID, compile)
    local plan, message = BuildPlan(rules, customSources, data, parentID)
    if not plan then
        return nil, message
    end
    if rules:IsReadOnly() or customSources:IsReadOnly() then
        return nil, "Settings are read-only. Nothing was imported."
    end

    for _, source in ipairs(plan.sources) do
        if not source.reuse then
            local ok, err = customSources:Set(source.finalName, source.text, compile)
            if not ok then
                return Stop("custom source " .. source.finalName, err)
            end
        end
    end

    local opIDs = {}
    for _, op in ipairs(plan.ops) do
        if op.reuse then
            opIDs[op.id] = op.reuse
        else
            local step = "operation " .. op.finalName
            local id, err = rules:CreateOperation(op.type, op.finalName)
            if not id then
                return Stop(step, err)
            end
            opIDs[op.id] = id
            for _, field in ipairs(ns.OperationSchema.Fields(op.type)) do
                local ok, setError = rules:SetSetting(id, field.key, op.settings[field.key])
                if not ok then
                    return Stop(step .. ", setting " .. field.key, setError)
                end
            end
        end
    end

    local groupIDs = {}
    for _, group in ipairs(data.groups) do
        local name = group.parent and group.name or plan.rootName
        local id, err = rules:CreateGroup(group.parent and groupIDs[group.parent] or parentID, name)
        if not id then
            return Stop("group " .. name, err)
        end
        groupIDs[group.id] = id
    end

    for _, link in ipairs(data.attach) do
        local ok, err = rules:AttachOperation(groupIDs[link.group], link.type, opIDs[link.op])
        if not ok then
            return Stop("attach " .. link.type .. " operation", err)
        end
    end

    local keys = {}
    for _, item in ipairs(data.items) do
        keys[item.group] = keys[item.group] or {}
        table.insert(keys[item.group], item.key)
    end
    for _, group in ipairs(data.groups) do
        if keys[group.id] then
            local added, err = rules:AddItems(keys[group.id], groupIDs[group.id])
            if not added then
                return Stop("items of group " .. group.name, err)
            end
        end
    end
    plan.summary.groupID = groupIDs[data.groups[1].id]
    return true, plan.summary
end
