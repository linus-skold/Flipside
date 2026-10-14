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

-- deps: store (Keys, GetVersion), itemCache (Get, Request), clientLookup(name) -> itemID, link, name (optional).
function ItemNameIndex.New(deps)
    if type(deps) ~= "table" or type(deps.store) ~= "table" or type(deps.itemCache) ~= "table" then
        error("deps.store and deps.itemCache must be tables", 2)
    end
    return setmetatable({
        store = deps.store,
        itemCache = deps.itemCache,
        clientLookup = deps.clientLookup,
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

local QUOTES = { '"', "\226\128\156", "\226\128\157" } -- straight, left curly, right curly

local function quoteAt(text, fromEnd)
    for _, q in ipairs(QUOTES) do
        local part = fromEnd and text:sub(#text - #q + 1) or text:sub(1, #q)
        if part == q then
            return #q
        end
    end
end

-- Returns { text (trimmed, lower case), exact, raw (trimmed, original case) }; text in quotes is exact.
function ItemNameIndex.ParseQuery(text)
    local raw = trim(text)
    local head, tail = quoteAt(raw, false), quoteAt(raw, true)
    local exact = false
    if head and tail and #raw >= head + tail then
        raw = trim(raw:sub(head + 1, #raw - tail))
        exact = true
    end
    return { text = raw:lower(), exact = exact, raw = raw }
end

-- Returns matches ({ itemID, name, key, source }), one for each stored key, and the count of items without a name.
-- options.exclude is a set of keys to leave out.
function Index:Find(query, limit, options)
    if self.version ~= self.store:GetVersion() then
        self:_Rebuild()
    end
    local pending = self:_Refresh()
    local parsed = ItemNameIndex.ParseQuery(query)
    local text = parsed.text
    local exclude = options and options.exclude or {}
    local groups = { {}, {}, {} }
    if #text >= MIN_LENGTH then
        for _, item in ipairs(self.items) do
            local lower = item.lower
            local group
            if lower == text then
                group = groups[1]
            elseif not parsed.exact and lower and lower:sub(1, #text) == text then
                group = groups[2]
            elseif not parsed.exact and lower and lower:find(text, 1, true) then
                group = groups[3]
            end
            if group then
                for _, key in ipairs(item.keys) do
                    if not exclude[key] then
                        group[#group + 1] = { itemID = item.itemID, name = item.name, key = key, lower = lower }
                    end
                end
            end
        end
    end
    local matches, seen = {}, {}
    limit = limit or DEFAULT_LIMIT
    for _, group in ipairs(groups) do
        table.sort(group, byOrder)
        for _, entry in ipairs(group) do
            if #matches < limit then
                matches[#matches + 1] = { itemID = entry.itemID, name = entry.name, key = entry.key, source = "scan" }
                seen[entry.key] = true
            end
        end
    end
    if self.clientLookup and #text >= MIN_LENGTH and (parsed.exact or #matches < limit) then
        local itemID, _, name = self.clientLookup(parsed.raw)
        local key = itemID and ns.ItemString.ToBaseKey(itemID)
        if key and not seen[key] and not exclude[key] and #matches < limit then
            matches[#matches + 1] = { itemID = itemID, name = name, key = key, source = "client" }
        end
    end
    return matches, pending
end
-- Returns { kind = "item", input }, { kind = "name", matches, pendingCount } or { kind = "error", message }.
function Index:Resolve(input, options)
    if ns.ItemString.ToBaseKey(input) then
        return { kind = "item", input = input }
    end
    local text = trim(input)
    if #text < MIN_LENGTH then
        return { kind = "error", message = "type at least " .. MIN_LENGTH .. " characters of the name" }
    end
    local matches, pending = self:Find(text, DEFAULT_LIMIT, options)
    return { kind = "name", matches = matches, pendingCount = pending }
end
