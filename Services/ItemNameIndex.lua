local _, ns = ...

-- Finds scanned items by name. The index lives in memory only; keys never hold names (D20).
local ItemNameIndex = {}
ns.ItemNameIndex = ItemNameIndex

local MIN_LENGTH = 2
local DEFAULT_LIMIT = 8

local Index = {}
Index.__index = Index

local function trim(text)
    return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

-- Returns the text for a choice: "Name (2589)" or "Name (variant 12345#s-34)".
function ItemNameIndex.Describe(match)
    if match.key == string.format("%d", match.itemID) then
        return string.format("%s (%d)", match.name, match.itemID)
    end
    return string.format("%s (variant %s)", match.name, match.key)
end

-- Returns an item id text or an item string that the formula lookup resolves to the key, or nil.
function ItemNameIndex.ToInput(key)
    local parsed = ns.ItemString.ParseKey(key)
    if not parsed then
        return nil
    end
    if parsed.suffixID == 0 and #parsed.bonusIDs == 0 then
        return string.format("%d", parsed.itemID)
    end
    local fields = { string.format("%d", parsed.itemID) }
    for i = 2, 13 do
        fields[i] = ""
    end
    if parsed.suffixID ~= 0 then
        fields[7] = string.format("%d", parsed.suffixID)
    end
    if #parsed.bonusIDs > 0 then
        fields[13] = string.format("%d", #parsed.bonusIDs)
        for _, id in ipairs(parsed.bonusIDs) do
            fields[#fields + 1] = string.format("%d", id)
        end
    end
    return "item:" .. table.concat(fields, ":")
end

-- deps: store (Keys, GetVersion), itemCache (Get, Request).
function ItemNameIndex.New(deps)
    if type(deps) ~= "table" or type(deps.store) ~= "table" or type(deps.itemCache) ~= "table" then
        error("deps.store and deps.itemCache must be tables", 2)
    end
    return setmetatable({
        store = deps.store,
        itemCache = deps.itemCache,
        version = nil,
        items = {}, -- array of { itemID, keys, name, lower }
        names = {}, -- itemID -> name, kept for the session
        requested = {},
    }, Index)
end

function Index:_Rebuild()
    local byID, items = {}, {}
    for _, key in ipairs(self.store:Keys()) do
        local parsed = ns.ItemString.ParseKey(key)
        if parsed then
            local item = byID[parsed.itemID]
            if not item then
                item = { itemID = parsed.itemID, keys = {} }
                byID[parsed.itemID] = item
                items[#items + 1] = item
            end
            item.keys[#item.keys + 1] = key
        end
    end
    for _, item in ipairs(items) do
        table.sort(item.keys)
    end
    self.items = items
    self.version = self.store:GetVersion()
end

-- Reads the names that the client has now and requests the others once. Returns the pending count.
function Index:_Refresh()
    local pending = 0
    for _, item in ipairs(self.items) do
        local id = item.itemID
        if not self.names[id] then
            local info, state = self.itemCache:Get(id)
            if info and info.name then
                self.names[id] = info.name
            elseif state ~= "failed" then
                pending = pending + 1
                if not self.requested[id] then
                    self.requested[id] = true
                    self.itemCache:Request(id)
                end
            end
        end
        item.name = self.names[id]
        item.lower = item.name and item.name:lower() or nil
    end
    return pending
end

local function byOrder(a, b)
    if a.lower ~= b.lower then
        return a.lower < b.lower
    end
    if a.itemID ~= b.itemID then
        return a.itemID < b.itemID
    end
    return a.key < b.key
end

-- Returns matches ({ itemID, name, key }, one for each stored key) and the count of items without a name.
function Index:Find(query, limit)
    if self.version ~= self.store:GetVersion() then
        self:_Rebuild()
    end
    local pending = self:_Refresh()
    local text = trim(query):lower()
    local groups = { {}, {}, {} }
    if #text >= MIN_LENGTH then
        for _, item in ipairs(self.items) do
            local lower = item.lower
            local group
            if lower == text then
                group = groups[1]
            elseif lower and lower:sub(1, #text) == text then
                group = groups[2]
            elseif lower and lower:find(text, 1, true) then
                group = groups[3]
            end
            if group then
                for _, key in ipairs(item.keys) do
                    group[#group + 1] = { itemID = item.itemID, name = item.name, key = key, lower = lower }
                end
            end
        end
    end
    local matches = {}
    limit = limit or DEFAULT_LIMIT
    for _, group in ipairs(groups) do
        table.sort(group, byOrder)
        for _, entry in ipairs(group) do
            if #matches >= limit then
                return matches, pending
            end
            matches[#matches + 1] = { itemID = entry.itemID, name = entry.name, key = entry.key }
        end
    end
    return matches, pending
end

-- Returns { kind = "item", input }, { kind = "name", matches, pendingCount } or { kind = "error", message }.
function Index:Resolve(input)
    if ns.ItemString.ToBaseKey(input) then
        return { kind = "item", input = input }
    end
    local text = trim(input)
    if #text < MIN_LENGTH then
        return { kind = "error", message = "type at least " .. MIN_LENGTH .. " characters of the name" }
    end
    local matches, pending = self:Find(text, DEFAULT_LIMIT)
    return { kind = "name", matches = matches, pendingCount = pending }
end
