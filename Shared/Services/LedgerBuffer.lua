local _, ns = ...

-- The ledger buffer in the Main DB (account scope, key ledger.buffer). It holds the records until the
-- ledger addon takes them (SPEC 5.8 point 1).
local LedgerBuffer = {}
ns.LedgerBuffer = LedgerBuffer

local KEY = "ledger.buffer"

local Buffer = {}
Buffer.__index = Buffer

-- Returns a whole-number setting, or the default if the DB has none or a bad value.
local function setting(db, key)
    local value = db:Get("account", key)
    if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
        value = ns.LedgerRecord.Defaults()[key]
    end
    return value
end

function Buffer:Cap()
    return setting(self._db, "ledger.bufferCap")
end

function Buffer:HardLimit()
    return math.max(setting(self._db, "ledger.hardLimit"), self:Cap())
end

-- The stored list; creates it if it is missing. Returns nil if the DB is read-only.
function Buffer:_List()
    local list = self._db:Get("account", KEY)
    if type(list) ~= "table" then
        list = {}
        if not self._db:Set("account", KEY, list) then
            return nil
        end
    end
    return list
end

-- Returns the number of buffered records.
function Buffer:Count()
    local list = self._db:Get("account", KEY)
    return type(list) == "table" and #list or 0
end

-- Returns the number of records dropped in this session.
function Buffer:Dropped()
    return self._dropped
end

-- Appends a record. At the cap it calls onCap. Above the hard limit it drops the oldest record.
-- Returns true, or false and a message.
function Buffer:Add(record)
    local ok, message = ns.LedgerRecord.Validate(record)
    if not ok then
        return false, message
    end
    local list = self:_List()
    if not list then
        return false, "settings are read-only"
    end
    local copy = {}
    for name, value in pairs(record) do
        copy[name] = value
    end
    local hardLimit = self:HardLimit()
    while #list >= hardLimit do
        table.remove(list, 1)
        self._dropped = self._dropped + 1
        if not self._warned and self._warn then
            self._warned = true
            self._warn("the ledger buffer is full; the oldest records are dropped")
        end
    end
    list[#list + 1] = copy
    if #list >= self:Cap() and self._onCap then
        self._onCap()
    end
    return true
end

-- Returns all records and clears the buffer.
function Buffer:Drain()
    local list = self._db:Get("account", KEY)
    if type(list) ~= "table" or #list == 0 then
        return {}
    end
    if not self._db:Set("account", KEY, {}) then
        return {}
    end
    return list
end

-- Puts records back in front of the buffer after a failed move.
function Buffer:Restore(records)
    if #records == 0 then
        return
    end
    local list = self:_List()
    if not list then
        return
    end
    for i = #records, 1, -1 do
        table.insert(list, 1, records[i])
    end
    while #list > self:HardLimit() do
        table.remove(list, 1)
        self._dropped = self._dropped + 1
    end
end

-- Sets the function that Add calls when the buffer is at the cap.
function Buffer:SetOnCap(fn)
    self._onCap = fn
end

-- db is the settings DB. options: warn(message), onCap().
function LedgerBuffer.New(db, options)
    if type(db) ~= "table" then
        error("db must be a table", 2)
    end
    options = options or {}
    return setmetatable({
        _db = db,
        _warn = options.warn,
        _onCap = options.onCap,
        _dropped = 0,
        _warned = false,
    }, Buffer)
end
