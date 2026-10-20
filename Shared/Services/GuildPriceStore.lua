local _, ns = ...

-- Prices that guild members shared (SPEC 3.5). The data is separate from the local scan store.
-- The saved table holds, for each scope, items[key] = "min,market,qty,time". Keep the newest entry for each item.
-- A reader gives the newer of the local scan record and the shared record (a tie goes to the local record).

local GuildPriceStore = {}
ns.GuildPriceStore = GuildPriceStore

local MAX_ITEMS_DEFAULT = 5000
local MAX_FUTURE_SECONDS = 86400

local Store = {}
Store.__index = Store

local function isCount(value)
    return type(value) == "number" and value >= 0 and value == math.floor(value) and value <= 2 ^ 52
end

local function decode(text)
    if type(text) ~= "string" then
        return nil
    end
    local min, market, qty, time = string.match(text, "^(%d+),(%d+),(%d+),(%d+)$")
    if not min then
        return nil
    end
    return { min = tonumber(min), market = tonumber(market), qty = tonumber(qty), time = tonumber(time) }
end

-- Open the store of one scope in a saved table. options: scope (text), maxItems (5000), now() (server time).
function GuildPriceStore.New(saved, options)
    if type(saved) ~= "table" then
        error("saved must be a table", 2)
    end
    if type(options) ~= "table" or type(options.scope) ~= "string" or options.scope == "" then
        error("options.scope must be a non-empty string", 2)
    end
    local slot = saved[options.scope]
    if type(slot) ~= "table" then
        slot = {}
        saved[options.scope] = slot
    end
    if type(slot.items) ~= "table" then
        slot.items = {}
    end
    local self = setmetatable({
        _slot = slot,
        _maxItems = options.maxItems or MAX_ITEMS_DEFAULT,
        _now = options.now,
        _cache = {},
        _records = {},
        _version = 0,
        _count = 0,
    }, Store)
    for _ in pairs(slot.items) do
        self._count = self._count + 1
    end
    return self
end

-- Return { min, market, qty, time } of an item, or nil.
function Store:Get(key)
    local cached = self._cache[key]
    if cached then
        return cached
    end
    local entry = decode(self._slot.items[key])
    if entry then
        self._cache[key] = entry
    end
    return entry
end

-- Return a scan record (see ScanRecord) made from the shared entry of an item, or nil.
-- The record has a latest value (marked partial) and one day entry, so the scan sources can read it.
function Store:Record(key)
    local cached = self._records[key]
    if cached then
        return cached
    end
    local entry = self:Get(key)
    if not entry then
        return nil
    end
    local record = {
        latest = { time = entry.time, min = entry.min, market = entry.market, qty = entry.qty, auctions = 0,
            partial = true },
        days = { { day = ns.ScanClock.DayOf(entry.time), min = entry.min, market = entry.market, qty = entry.qty,
            scans = 1 } },
    }
    self._records[key] = record
    return record
end

-- Return a list of the item keys in the store.
function Store:Keys()
    local keys = {}
    for key in pairs(self._slot.items) do
        keys[#keys + 1] = key
    end
    return keys
end

function Store:Count()
    return self._count
end

-- Return a number that grows with each change.
function Store:Version()
    return self._version
end

-- Return the newest item time in the store, or 0.
function Store:Newest()
    local newest = 0
    for key in pairs(self._slot.items) do
        local entry = self:Get(key)
        if entry and entry.time > newest then
            newest = entry.time
        end
    end
    return newest
end

local function evict(self)
    local over = self._count - self._maxItems
    if over <= 0 then
        return
    end
    local list = {}
    for key in pairs(self._slot.items) do
        local entry = self:Get(key)
        list[#list + 1] = { key = key, time = entry and entry.time or 0 }
    end
    table.sort(list, function(a, b)
        if a.time ~= b.time then
            return a.time < b.time
        end
        return a.key < b.key
    end)
    for i = 1, over do
        local key = list[i].key
        self._slot.items[key] = nil
        self._cache[key] = nil
        self._records[key] = nil
        self._count = self._count - 1
    end
end

-- Merge a list of entries { key, min, market, qty, time }. An entry replaces an older one only.
-- Return the number of entries kept and the number skipped.
function Store:Merge(entries)
    local now = self._now and self._now() or nil
    local kept, skipped = 0, 0
    for _, entry in ipairs(entries) do
        local valid = type(entry.key) == "string" and entry.key ~= "" and isCount(entry.min) and isCount(entry.market)
            and isCount(entry.qty) and isCount(entry.time) and entry.min > 0 and entry.market > 0
            and not (now and entry.time > now + MAX_FUTURE_SECONDS)
        local old = valid and self:Get(entry.key)
        if valid and not (old and old.time >= entry.time) then
            if not old then
                self._count = self._count + 1
            end
            self._slot.items[entry.key] = string.format("%.0f,%.0f,%.0f,%.0f", entry.min, entry.market, entry.qty,
                entry.time)
            self._cache[entry.key] = nil
            self._records[entry.key] = nil
            kept = kept + 1
        else
            skipped = skipped + 1
        end
    end
    if kept > 0 then
        self._version = self._version + 1
        evict(self)
    end
    return kept, skipped
end

-- Remove all shared prices of this scope.
function Store:Clear()
    self._slot.items = {}
    self._cache = {}
    self._records = {}
    self._count = 0
    self._version = self._version + 1
end

local Reader = {}
Reader.__index = Reader

-- Return a reader. options: localStore (needs Get and GetVersion), guildStore, isEnabled().
-- The newest scan time wins, no matter who scanned. On equal times the local record wins.
-- Shared data counts only while sharing is on.
function GuildPriceStore.NewReader(options)
    return setmetatable({
        localStore = options.localStore,
        guildStore = options.guildStore,
        isEnabled = options.isEnabled,
    }, Reader)
end

-- Return the local record, the shared entry and true if the shared entry is newer than the local record.
-- On equal times the local record wins.
local function choose(self, key)
    local record = self.localStore:Get(key)
    if not self.isEnabled() then
        return record, nil, false
    end
    local entry = self.guildStore:Get(key)
    if not entry then
        return record, nil, false
    end
    if not record then
        return nil, entry, true
    end
    local latest = record.latest
    local localTime = type(latest) == "table" and tonumber(latest.time) or 0
    return record, entry, entry.time > localTime
end

function Reader:Get(key)
    local record, _, useGuild = choose(self, key)
    if useGuild then
        return self.guildStore:Record(key)
    end
    return record
end

-- Return true if the price of the item comes from shared data (it is newer than the local record).
function Reader:IsGuild(key)
    if type(key) ~= "string" then
        return false
    end
    local _, _, useGuild = choose(self, key)
    return useGuild
end

-- Return a number that changes when the local data, the shared data or the setting changes.
function Reader:GetVersion()
    return self.localStore:GetVersion() + self.guildStore:Version() + (self.isEnabled() and 1000000 or 0)
end
