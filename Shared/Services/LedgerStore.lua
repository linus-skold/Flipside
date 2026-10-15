local _, ns = ...

-- The ledger records in the FlipsideLedgerDB table, for one region and ruleset (D22).
-- Layout: records[region][ruleset][Name-Realm] = list of records, in the order they were moved.
--         sums[region][ruleset][Name-Realm] = list of daily sums { day, source, item, count, qty, moneyIn, moneyOut }.
local LedgerStore = {}
ns.LedgerStore = LedgerStore

local SECONDS_PER_DAY = 86400
local SCHEMA_VERSION = 1

local Store = {}
Store.__index = Store

local function ensure(parent, key)
    if type(parent[key]) ~= "table" then
        parent[key] = {}
    end
    return parent[key]
end

local function dayOf(time)
    return math.floor(time / SECONDS_PER_DAY)
end

-- The table of a section for this region and ruleset; nil if it does not exist.
function Store:_Find(section)
    local top = self._saved[section]
    local byRegion = type(top) == "table" and top[self._region]
    local slot = type(byRegion) == "table" and byRegion[self._ruleset]
    return type(slot) == "table" and slot or nil
end

function Store:_Slot(section)
    return ensure(ensure(ensure(self._saved, section), self._region), self._ruleset)
end

-- Returns a number that grows when records are moved in or compacted. A page uses it to know when to draw again.
function Store:Revision()
    return self._revision
end

function Store:IsReadOnly()
    return self._readOnly
end

function Store:GetRegion()
    return self._region
end

function Store:GetRuleset()
    return self._ruleset
end

-- Appends records under their character. Returns the number of records stored, or false if read-only.
function Store:Move(records)
    if self._readOnly then
        return false
    end
    local slot = self:_Slot("records")
    local count = 0
    for _, record in ipairs(records) do
        if ns.LedgerRecord.Validate(record) then
            local list = ensure(slot, record.char)
            list[#list + 1] = record
            count = count + 1
        end
    end
    self._revision = self._revision + count
    return count
end

-- Returns the sorted names of the characters that have records or sums.
function Store:Characters()
    local seen = {}
    for _, section in ipairs({ "records", "sums" }) do
        local slot = self:_Find(section)
        if slot then
            for char in pairs(slot) do
                seen[char] = true
            end
        end
    end
    local names = {}
    for char in pairs(seen) do
        names[#names + 1] = char
    end
    table.sort(names)
    return names
end

-- Calls fn(list) for the list of one character, or of every character if char is nil.
local function eachList(slot, char, fn)
    if not slot then
        return
    end
    if char ~= nil then
        if type(slot[char]) == "table" then
            fn(slot[char])
        end
        return
    end
    local names = {}
    for name in pairs(slot) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        fn(slot[name])
    end
end

local function inRange(time, fromTime, toTime)
    return (fromTime == nil or time >= fromTime) and (toTime == nil or time <= toTime)
end

-- Returns the full records in a time range, oldest first. options: char (nil = all), fromTime, toTime (both inclusive).
function Store:Records(options)
    options = options or {}
    local result = {}
    eachList(self:_Find("records"), options.char, function(list)
        for _, record in ipairs(list) do
            if inRange(record.time, options.fromTime, options.toTime) then
                result[#result + 1] = record
            end
        end
    end)
    table.sort(result, function(a, b)
        return a.time < b.time
    end)
    return result
end

-- Returns the daily sums in a time range. A day counts if any part of it is in the range.
function Store:Sums(options)
    options = options or {}
    local firstDay = options.fromTime and dayOf(options.fromTime)
    local lastDay = options.toTime and dayOf(options.toTime)
    local result = {}
    eachList(self:_Find("sums"), options.char, function(list)
        for _, sum in ipairs(list) do
            if (firstDay == nil or sum.day >= firstDay) and (lastDay == nil or sum.day <= lastDay) then
                result[#result + 1] = sum
            end
        end
    end)
    return result
end

local function addTo(totals, source, count, qty, moneyIn, moneyOut)
    local entry = totals[source]
    if not entry then
        entry = { count = 0, qty = 0, moneyIn = 0, moneyOut = 0 }
        totals[source] = entry
    end
    entry.count = entry.count + count
    entry.qty = entry.qty + qty
    entry.moneyIn = entry.moneyIn + moneyIn
    entry.moneyOut = entry.moneyOut + moneyOut
end

-- Returns source -> { count, qty, moneyIn, moneyOut } from the full records and the daily sums in a range.
-- Log records are left out. The options are the same as for Records.
function Store:SumsBySource(options)
    local totals = {}
    for _, record in ipairs(self:Records(options)) do
        if record.type ~= "log" then
            local direction = ns.LedgerRecord.Direction(record.type)
            addTo(totals, record.source, 1, record.qty or 0,
                direction == "in" and record.money or 0, direction == "out" and record.money or 0)
        end
    end
    for _, sum in ipairs(self:Sums(options)) do
        addTo(totals, sum.source, sum.count, sum.qty, sum.moneyIn, sum.moneyOut)
    end
    return totals
end

-- Replaces the old records of one list by daily sums. Returns the number of records that were compacted.
local function compactList(list, sums, cutoffDay, logCutoff)
    local index = {}
    for _, sum in ipairs(sums) do
        index[sum.day .. "|" .. sum.source .. "|" .. sum.item] = sum
    end
    local kept, compacted = {}, 0
    for _, record in ipairs(list) do
        if record.type == "log" then
            if record.time >= logCutoff then
                kept[#kept + 1] = record
            else
                compacted = compacted + 1
            end
        elseif dayOf(record.time) >= cutoffDay then
            kept[#kept + 1] = record
        else
            local item = record.item or ""
            local day = dayOf(record.time)
            local key = day .. "|" .. record.source .. "|" .. item
            local sum = index[key]
            if not sum then
                sum = { day = day, source = record.source, item = item, count = 0, qty = 0, moneyIn = 0, moneyOut = 0 }
                index[key] = sum
                sums[#sums + 1] = sum
            end
            local direction = ns.LedgerRecord.Direction(record.type)
            sum.count = sum.count + 1
            sum.qty = sum.qty + (record.qty or 0)
            sum.moneyIn = sum.moneyIn + (direction == "in" and record.money or 0)
            sum.moneyOut = sum.moneyOut + (direction == "out" and record.money or 0)
            compacted = compacted + 1
        end
    end
    for i = 1, math.max(#list, #kept) do
        list[i] = kept[i]
    end
    return compacted
end

-- Turns records older than the retention days into daily sums (UTC days), for every region, ruleset and
-- character. Log records older than logDays are deleted without a sum. It runs once for each day unless force.
-- Returns the number of records that were removed from the full records.
function Store:Compact(now, options)
    options = options or {}
    if self._readOnly then
        return 0
    end
    local today = dayOf(now)
    if not options.force and self._saved.lastCompact == today then
        return 0
    end
    local retention = options.retentionDays or ns.LedgerRecord.Defaults()["ledger.retentionDays"]
    local logDays = options.logDays or ns.LedgerRecord.Defaults()["ledger.logDays"]
    local cutoffDay = today - retention
    local logCutoff = now - logDays * SECONDS_PER_DAY
    local total = 0
    local records = type(self._saved.records) == "table" and self._saved.records or {}
    for region, byRegion in pairs(records) do
        for ruleset, byRuleset in pairs(byRegion) do
            for char, list in pairs(byRuleset) do
                local bySums = ensure(ensure(ensure(self._saved, "sums"), region), ruleset)
                total = total + compactList(list, ensure(bySums, char), cutoffDay, logCutoff)
            end
        end
    end
    self._saved.lastCompact = today
    self._revision = self._revision + total
    return total
end

-- saved is the FlipsideLedgerDB table. options: region, ruleset, onWarning(message).
function LedgerStore.New(saved, options)
    if type(saved) ~= "table" then
        error("saved must be a table", 2)
    end
    options = options or {}
    for _, name in ipairs({ "region", "ruleset" }) do
        if type(options[name]) ~= "string" or options[name] == "" then
            error("options." .. name .. " must be a non-empty string", 2)
        end
    end
    local self = setmetatable({
        _saved = saved,
        _region = options.region,
        _ruleset = options.ruleset,
        _readOnly = false,
        _revision = 0,
    }, Store)
    local stored = saved._schema
    if stored == nil then
        saved._schema = SCHEMA_VERSION
    elseif type(stored) ~= "number" or stored < 1 or stored % 1 ~= 0 or stored > SCHEMA_VERSION then
        self._readOnly = true
        if options.onWarning then
            options.onWarning("the ledger data has an unknown schema version; it is read-only.")
        end
    end
    return self
end
