local _, ns = ...

local GroupTree = {}
ns.GroupTree = GroupTree

local BASE_ID = 1
local BASE_NAME = "Base"
local MAX_DEPTH = 8
local MAX_NAME = 40
GroupTree.BASE_ID = BASE_ID
GroupTree.MAX_DEPTH = MAX_DEPTH
GroupTree.MAX_NAME_LENGTH = MAX_NAME

local function IsID(value)
    return type(value) == "number" and value >= 1 and value % 1 == 0 and value ~= math.huge
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

local function Children(data, id)
    local list = {}
    for childID, node in pairs(data.nodes) do
        if node.parent == id then
            list[#list + 1] = childID
        end
    end
    table.sort(list, function(a, b)
        local nameA, nameB = data.nodes[a].name:lower(), data.nodes[b].name:lower()
        if nameA ~= nameB then
            return nameA < nameB
        end
        return a < b
    end)
    return list
end

local function NameTaken(data, parentID, name, exceptID)
    local lowered = name:lower()
    for childID, node in pairs(data.nodes) do
        if node.parent == parentID and childID ~= exceptID and node.name:lower() == lowered then
            return true
        end
    end
    return false
end

-- Returns a fresh data table with only the Base group.
function GroupTree.NewData()
    return {
        version = 1,
        nextID = 2,
        nodes = { [BASE_ID] = { name = BASE_NAME } },
        items = {},
        attach = {},
    }
end

function GroupTree.Exists(data, id)
    return data.nodes[id] ~= nil
end

function GroupTree.Parent(data, id)
    local node = data.nodes[id]
    return node and node.parent
end

function GroupTree.Name(data, id)
    local node = data.nodes[id]
    return node and node.name
end

-- Returns the number of levels below the Base group, or nil if the id is unknown.
function GroupTree.Depth(data, id)
    if not data.nodes[id] then
        return nil
    end
    local depth = 0
    local node = data.nodes[id]
    while node.parent do
        depth = depth + 1
        node = data.nodes[node.parent]
    end
    return depth
end

-- Returns the names from the Base group down to the group.
function GroupTree.Path(data, id)
    if not data.nodes[id] then
        return nil
    end
    local path = {}
    local current = id
    while current do
        table.insert(path, 1, data.nodes[current].name)
        current = data.nodes[current].parent
    end
    return path
end

-- Returns the child ids sorted by name, ignoring case.
function GroupTree.Children(data, id)
    return Children(data, id)
end

-- Calls fn(id, depth) for each group, depth first, in sorted order.
function GroupTree.Walk(data, fn)
    local function visit(id, depth)
        fn(id, depth)
        for _, childID in ipairs(Children(data, id)) do
            visit(childID, depth + 1)
        end
    end
    visit(BASE_ID, 0)
end

local function Height(data, id)
    local height = 0
    for _, childID in ipairs(Children(data, id)) do
        height = math.max(height, 1 + Height(data, childID))
    end
    return height
end

function GroupTree.Create(data, parentID, name)
    if not data.nodes[parentID] then
        return nil, "parent group does not exist"
    end
    local clean, message = CleanName(name)
    if not clean then
        return nil, message
    end
    if GroupTree.Depth(data, parentID) + 1 > MAX_DEPTH then
        return nil, "group tree is too deep"
    end
    if NameTaken(data, parentID, clean) then
        return nil, "a sibling group has this name"
    end
    local id = data.nextID
    data.nextID = id + 1
    data.nodes[id] = { name = clean, parent = parentID }
    return id
end

function GroupTree.Rename(data, id, name)
    if not data.nodes[id] then
        return nil, "group does not exist"
    end
    if id == BASE_ID then
        return nil, "the Base group cannot be renamed"
    end
    local clean, message = CleanName(name)
    if not clean then
        return nil, message
    end
    if NameTaken(data, data.nodes[id].parent, clean, id) then
        return nil, "a sibling group has this name"
    end
    data.nodes[id].name = clean
    return true
end

function GroupTree.Move(data, id, newParentID)
    if not data.nodes[id] then
        return nil, "group does not exist"
    end
    if id == BASE_ID then
        return nil, "the Base group cannot be moved"
    end
    if not data.nodes[newParentID] then
        return nil, "parent group does not exist"
    end
    local current = newParentID
    while current do
        if current == id then
            return nil, "a group cannot move into itself or its sub-groups"
        end
        current = data.nodes[current].parent
    end
    if GroupTree.Depth(data, newParentID) + 1 + Height(data, id) > MAX_DEPTH then
        return nil, "group tree is too deep"
    end
    if NameTaken(data, newParentID, data.nodes[id].name, id) then
        return nil, "a sibling group has this name"
    end
    data.nodes[id].parent = newParentID
    return true
end

-- Deletes a group and its sub-groups. Returns true and the list of deleted ids.
function GroupTree.Delete(data, id)
    if not data.nodes[id] then
        return nil, "group does not exist"
    end
    if id == BASE_ID then
        return nil, "the Base group cannot be deleted"
    end
    local parentID = data.nodes[id].parent
    local deleted, set = {}, {}
    local function collect(groupID)
        deleted[#deleted + 1] = groupID
        set[groupID] = true
        for _, childID in ipairs(Children(data, groupID)) do
            collect(childID)
        end
    end
    collect(id)
    for key, groupID in pairs(data.items) do
        if set[groupID] then
            if parentID == BASE_ID then
                data.items[key] = nil
            else
                data.items[key] = parentID
            end
        end
    end
    for _, groupID in ipairs(deleted) do
        data.nodes[groupID] = nil
        data.attach[groupID] = nil
    end
    return true, deleted
end

function GroupTree.AddItem(data, key, groupID)
    if not ns.ItemString.ParseKey(key) then
        return nil, "invalid item key"
    end
    if not data.nodes[groupID] then
        return nil, "group does not exist"
    end
    if groupID == BASE_ID then
        data.items[key] = nil
    else
        data.items[key] = groupID
    end
    return true
end

function GroupTree.RemoveItem(data, key)
    data.items[key] = nil
    return true
end

-- Returns the group id of an item: exact key, then base key, else Base.
function GroupTree.GroupOf(data, key)
    local found = data.items[key]
    if found then
        return found
    end
    local baseKey = ns.ItemString.KeyToBaseKey(key)
    if baseKey then
        return data.items[baseKey] or BASE_ID
    end
    return BASE_ID
end

-- Returns the sorted keys stored for a group. Base returns an empty array.
function GroupTree.ItemsIn(data, groupID)
    local list = {}
    if groupID ~= BASE_ID then
        for key, id in pairs(data.items) do
            if id == groupID then
                list[#list + 1] = key
            end
        end
        table.sort(list)
    end
    return list
end

local function IsInside(data, groupID, ancestorID)
    local current = groupID
    while current do
        if current == ancestorID then
            return true
        end
        current = data.nodes[current] and data.nodes[current].parent
    end
    return false
end

function GroupTree.CountItems(data, groupID, recursive)
    local count = 0
    for _, id in pairs(data.items) do
        if id == groupID or (recursive and IsInside(data, id, groupID)) then
            count = count + 1
        end
    end
    return count
end

function GroupTree.Attach(data, groupID, opType, opID)
    if not data.nodes[groupID] then
        return nil, "group does not exist"
    end
    if type(opType) ~= "string" or opType == "" then
        return nil, "invalid operation type"
    end
    if not IsID(opID) then
        return nil, "invalid operation id"
    end
    data.attach[groupID] = data.attach[groupID] or {}
    data.attach[groupID][opType] = opID
    return true
end

function GroupTree.Detach(data, groupID, opType)
    local slot = data.attach[groupID]
    if slot then
        slot[opType] = nil
        if next(slot) == nil then
            data.attach[groupID] = nil
        end
    end
    return true
end

function GroupTree.Attached(data, groupID, opType)
    local slot = data.attach[groupID]
    return slot and slot[opType]
end

-- Returns the operation id and the group id it comes from, walking up to Base.
function GroupTree.Effective(data, groupID, opType)
    local current = groupID
    while current and data.nodes[current] do
        local opID = GroupTree.Attached(data, current, opType)
        if opID then
            return opID, current
        end
        current = data.nodes[current].parent
    end
    return nil
end

-- Removes an operation from all groups. Returns the number of removed links.
function GroupTree.DetachOperation(data, opID)
    local removed = 0
    for groupID, slot in pairs(data.attach) do
        for opType, id in pairs(slot) do
            if id == opID then
                slot[opType] = nil
                removed = removed + 1
            end
        end
        if next(slot) == nil then
            data.attach[groupID] = nil
        end
    end
    return removed
end

-- Returns true if the saved data is valid. Otherwise returns false and a message.
function GroupTree.Validate(data)
    if type(data) ~= "table" then
        return false, "data is not a table"
    end
    if data.version ~= 1 then
        return false, "unknown version"
    end
    if type(data.nodes) ~= "table" or type(data.items) ~= "table" or type(data.attach) ~= "table" then
        return false, "missing nodes, items or attach"
    end
    if not IsID(data.nextID) then
        return false, "invalid nextID"
    end
    local base = data.nodes[BASE_ID]
    if type(base) ~= "table" or base.name ~= BASE_NAME or base.parent ~= nil then
        return false, "invalid Base group"
    end
    local seen = {}
    for id, node in pairs(data.nodes) do
        if not IsID(id) or id >= data.nextID then
            return false, "invalid group id"
        end
        if type(node) ~= "table" then
            return false, "invalid group"
        end
        if id ~= BASE_ID then
            local clean = CleanName(node.name)
            if clean ~= node.name then
                return false, "invalid group name"
            end
            if not IsID(node.parent) or node.parent == id or type(data.nodes[node.parent]) ~= "table" then
                return false, "invalid parent"
            end
            local siblingKey = node.parent .. ":" .. node.name:lower()
            if seen[siblingKey] then
                return false, "duplicate sibling name"
            end
            seen[siblingKey] = true
        end
    end
    for id in pairs(data.nodes) do
        local depth, current = 0, id
        while data.nodes[current].parent do
            depth = depth + 1
            if depth > MAX_DEPTH then
                return false, "group tree is too deep or has a cycle"
            end
            current = data.nodes[current].parent
        end
        if current ~= BASE_ID then
            return false, "group is not under Base"
        end
    end
    for key, groupID in pairs(data.items) do
        if not ns.ItemString.ParseKey(key) then
            return false, "invalid item key"
        end
        if not IsID(groupID) or groupID == BASE_ID or not data.nodes[groupID] then
            return false, "invalid item group"
        end
    end
    for groupID, slot in pairs(data.attach) do
        if not data.nodes[groupID] or type(slot) ~= "table" then
            return false, "invalid attachment group"
        end
        for opType, opID in pairs(slot) do
            if type(opType) ~= "string" or not IsID(opID) then
                return false, "invalid attachment"
            end
        end
    end
    return true
end
