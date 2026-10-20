local _, ns = ...

local Holdings = {}
ns.Holdings = Holdings

local STORE_KEY = "holdings"
local VERSION = 1
local LOCATIONS = { "bags", "bank", "mail", "auctions" }
local IS_LOCATION = {}
for _, location in ipairs(LOCATIONS) do
    IS_LOCATION[location] = true
end

local H = {}
H.__index = H

local function IsCount(value)
    return type(value) == "number" and value > 0 and value % 1 == 0 and value ~= math.huge
end

-- Returns the stored value of a character, or an empty one if it is not valid.
function H:_Read(character)
    local stored = self._db:GetFor(character, STORE_KEY)
    if type(stored) ~= "table" or type(stored.locations) ~= "table" then
        return { version = VERSION, locations = {} }
    end
    return stored
end

local function Add(map, key, character, location, count)
    local byCharacter = map[key]
    if not byCharacter then
        byCharacter = {}
        map[key] = byCharacter
    end
    local counts = byCharacter[character]
    if not counts then
        counts = {}
        byCharacter[character] = counts
    end
    counts[location] = (counts[location] or 0) + count
end

-- Returns the class file of a stored value (for example MAGE), or nil for old data.
local function ClassOf(stored)
    local class = stored.class
    return type(class) == "string" and class:match("^%u+$") and class or nil
end

-- Builds the exact and base count maps once; changes clear them.
function H:_Index()
    if self._index then
        return self._index
    end
    local index = { exact = {}, base = {}, seen = {}, class = {} }
    for _, character in ipairs(self._db:ListCharacters()) do
        local seen = {}
        index.class[character] = ClassOf(self:_Read(character))
        for _, location in ipairs(LOCATIONS) do
            local data = self:_Read(character).locations[location]
            if type(data) == "table" and type(data.items) == "table" then
                seen[location] = data.seen
                for key, count in pairs(data.items) do
                    local parsed = ns.ItemString.ParseKey(key)
                    if parsed and IsCount(count) then
                        Add(index.exact, key, character, location, count)
                        Add(index.base, string.format("%d", parsed.itemID), character, location, count)
                    end
                end
            end
        end
        index.seen[character] = seen
    end
    self._index = index
    return index
end

function Holdings.New(db, options)
    if type(db) ~= "table" then
        error("db must be a table", 2)
    end
    options = options or {}
    if type(options.character) ~= "string" or options.character == "" then
        error("options.character must be a string", 2)
    end
    if type(options.clock) ~= "function" then
        error("options.clock must be a function", 2)
    end
    return setmetatable({
        _db = db,
        _character = options.character,
        _clock = options.clock,
    }, H)
end

-- Replaces one location of the current character. Returns false if the DB is read-only.
function H:SetLocation(location, items)
    if not IS_LOCATION[location] then
        error("invalid location", 2)
    end
    if type(items) ~= "table" then
        error("items must be a table", 2)
    end
    local clean = {}
    for key, count in pairs(items) do
        if IsCount(count) and ns.ItemString.ParseKey(key) then
            clean[key] = count
        end
    end
    local current = self:_Read(self._character)
    local copy = { version = VERSION, locations = {} }
    for name, data in pairs(current.locations) do
        copy.locations[name] = data
    end
    copy.class = current.class
    copy.locations[location] = { seen = self._clock(), items = clean }
    local ok = self._db:SetFor(self._character, STORE_KEY, copy)
    self._index = nil
    return ok
end

local function IsBaseKey(parsed)
    return parsed.suffixID == 0 and #parsed.bonusIDs == 0
end

function H:Count(key)
    local result = { total = 0, characters = {} }
    local parsed = ns.ItemString.ParseKey(key)
    if not parsed then
        return result
    end
    local index = self:_Index()
    local map, lookup = index.exact, key
    if IsBaseKey(parsed) then
        map, lookup = index.base, string.format("%d", parsed.itemID)
    end
    for character, counts in pairs(map[lookup] or {}) do
        local entry = { name = character, class = index.class[character], total = 0, bags = 0, bank = 0, mail = 0,
            auctions = 0, seen = {} }
        for _, location in ipairs(LOCATIONS) do
            local n = counts[location] or 0
            entry[location] = n
            entry.total = entry.total + n
            entry.seen[location] = index.seen[character][location]
        end
        result.total = result.total + entry.total
        result.characters[#result.characters + 1] = entry
    end
    table.sort(result.characters, function(a, b)
        if a.total ~= b.total then
            return a.total > b.total
        end
        return a.name < b.name
    end)
    return result
end

function H:CountInBags(key)
    local parsed = ns.ItemString.ParseKey(key)
    if not parsed then
        return 0
    end
    local index = self:_Index()
    local map, lookup = index.exact, key
    if IsBaseKey(parsed) then
        map, lookup = index.base, string.format("%d", parsed.itemID)
    end
    local counts = (map[lookup] or {})[self._character]
    return counts and counts.bags or 0
end

-- Saves the class file of the current character (from UnitClass). Returns false if it is not valid or not saved.
function H:SetClass(class)
    if type(class) ~= "string" or not class:match("^%u+$") then
        return false
    end
    local current = self:_Read(self._character)
    if current.class == class then
        return true
    end
    local copy = { version = VERSION, class = class, locations = {} }
    for name, data in pairs(current.locations) do
        copy.locations[name] = data
    end
    local ok = self._db:SetFor(self._character, STORE_KEY, copy)
    self._index = nil
    return ok
end

-- Removes the holdings of one character; keeps its other keys.
function H:Forget(character)
    local ok = self._db:RemoveFor(character, STORE_KEY)
    self._index = nil
    return ok
end

function H:Characters()
    return self._db:ListCharacters()
end
