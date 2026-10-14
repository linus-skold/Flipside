local _, ns = ...

-- Price record of one item, and its compact text form for SavedVariables.
--
-- Text form, version 1: four fields, separated by ";".
--   <version>;<latest>;<today>;<days>
--   latest = time,min,market,qty,auctions,partial     (partial is 1 or 0)
--   today  = day|snap|snap...                         (1 to 4 snaps)
--   snap   = time,min,market,qty,auctions
--   days   = entry|entry...                           (day ascending)
--   entry  = day,min,market,qty,scans
-- An absent section is an empty field. All numbers are non-negative decimals.
-- Example: 1;1760000000,5000,5200,40,6,0;20376|1760000000,5000,5200,40,6;20375,4900,5100,300,3
--   (the example has no line break)

local ScanRecord = {}
ns.ScanRecord = ScanRecord

local VERSION = 1
local MAX_SNAPS = 4
local MAX_NUMBER = 2 ^ 52
local MAX_DIGITS = 15

local LATEST_KEYS = { "time", "min", "market", "qty", "auctions" }
local SNAP_KEYS = { "time", "min", "market", "qty", "auctions" }
local DAY_KEYS = { "day", "min", "market", "qty", "scans" }

local function isCount(v)
    return type(v) == "number" and v >= 0 and v <= MAX_NUMBER and v == math.floor(v)
end

local function checkFields(t, keys, label)
    if type(t) ~= "table" then
        return false, label .. " must be a table"
    end
    for _, key in ipairs(keys) do
        if not isCount(t[key]) then
            return false, label .. "." .. key .. " must be a non-negative integer"
        end
    end
    return true
end

-- Check the shape of a record. Return true, or false plus a message.
function ScanRecord.Validate(record)
    if type(record) ~= "table" then
        return false, "record must be a table"
    end
    local latest = record.latest
    if latest ~= nil then
        local ok, err = checkFields(latest, LATEST_KEYS, "latest")
        if not ok then
            return false, err
        end
        if type(latest.partial) ~= "boolean" then
            return false, "latest.partial must be a boolean"
        end
    end
    local today = record.today
    if today ~= nil then
        if type(today) ~= "table" then
            return false, "today must be a table"
        end
        if not isCount(today.day) then
            return false, "today.day must be a non-negative integer"
        end
        local snaps = today.snaps
        if type(snaps) ~= "table" or #snaps == 0 then
            return false, "today.snaps must have at least 1 snap"
        end
        if #snaps > MAX_SNAPS then
            return false, "today.snaps must have at most " .. MAX_SNAPS .. " snaps"
        end
        for i = 1, #snaps do
            local ok, err = checkFields(snaps[i], SNAP_KEYS, "today.snaps[" .. i .. "]")
            if not ok then
                return false, err
            end
        end
    end
    local days = record.days
    if type(days) ~= "table" then
        return false, "days must be a table"
    end
    local previous
    for i = 1, #days do
        local ok, err = checkFields(days[i], DAY_KEYS, "days[" .. i .. "]")
        if not ok then
            return false, err
        end
        if previous and days[i].day <= previous then
            return false, "days must be sorted by day, ascending, without duplicates"
        end
        previous = days[i].day
    end
    return true
end

-- Return an empty record.
function ScanRecord.New()
    return { latest = nil, today = nil, days = {} }
end

local function join(t, keys)
    local parts = {}
    for i, key in ipairs(keys) do
        parts[i] = string.format("%.0f", t[key])
    end
    return table.concat(parts, ",")
end

-- Return the text form of a valid record. Raise an error for an invalid record.
function ScanRecord.Encode(record)
    local ok, err = ScanRecord.Validate(record)
    if not ok then
        error("Encode: " .. err, 2)
    end
    local latest = ""
    if record.latest then
        latest = join(record.latest, LATEST_KEYS) .. "," .. (record.latest.partial and "1" or "0")
    end
    local today = ""
    if record.today then
        local parts = { string.format("%.0f", record.today.day) }
        for i, snap in ipairs(record.today.snaps) do
            parts[i + 1] = join(snap, SNAP_KEYS)
        end
        today = table.concat(parts, "|")
    end
    local days = {}
    for i, entry in ipairs(record.days) do
        days[i] = join(entry, DAY_KEYS)
    end
    return VERSION .. ";" .. latest .. ";" .. today .. ";" .. table.concat(days, "|")
end

-- Split text on one plain separator. Keep empty fields.
local function split(text, sep)
    local parts = {}
    local start = 1
    while true do
        local at = string.find(text, sep, start, true)
        if not at then
            parts[#parts + 1] = string.sub(text, start)
            return parts
        end
        parts[#parts + 1] = string.sub(text, start, at - 1)
        start = at + 1
    end
end

local function toNumber(text)
    if not string.match(text, "^%d+$") or #text > MAX_DIGITS then
        return nil
    end
    return tonumber(text)
end

-- Read "a,b,c" into a table with the given keys. Return nil plus a message on failure.
local function readFields(text, keys, label)
    local parts = split(text, ",")
    if #parts ~= #keys then
        return nil, label .. " must have " .. #keys .. " fields"
    end
    local t = {}
    for i, key in ipairs(keys) do
        local n = toNumber(parts[i])
        if not n then
            return nil, label .. " has a field that is not a number"
        end
        t[key] = n
    end
    return t
end

local function decodeLatest(text)
    local parts = split(text, ",")
    if #parts ~= 6 then
        return nil, "latest must have 6 fields"
    end
    local partial = table.remove(parts)
    if partial ~= "0" and partial ~= "1" then
        return nil, "latest partial flag must be 0 or 1"
    end
    local latest, err = readFields(table.concat(parts, ","), LATEST_KEYS, "latest")
    if not latest then
        return nil, err
    end
    latest.partial = partial == "1"
    return latest
end

local function decodeToday(text)
    local parts = split(text, "|")
    local day = toNumber(parts[1])
    if not day then
        return nil, "today day is not a number"
    end
    if #parts < 2 then
        return nil, "today must have at least 1 snap"
    end
    if #parts - 1 > MAX_SNAPS then
        return nil, "today must have at most " .. MAX_SNAPS .. " snaps"
    end
    local snaps = {}
    for i = 2, #parts do
        local snap, err = readFields(parts[i], SNAP_KEYS, "snap")
        if not snap then
            return nil, err
        end
        snaps[#snaps + 1] = snap
    end
    return { day = day, snaps = snaps }
end

local function decodeDays(text)
    local days = {}
    if text == "" then
        return days
    end
    for _, part in ipairs(split(text, "|")) do
        local entry, err = readFields(part, DAY_KEYS, "day entry")
        if not entry then
            return nil, err
        end
        days[#days + 1] = entry
    end
    return days
end

-- Read the text form. Return a record, or nil plus a message.
function ScanRecord.Decode(text)
    if type(text) ~= "string" then
        return nil, "text must be a string"
    end
    local sections = split(text, ";")
    if sections[1] ~= tostring(VERSION) then
        return nil, "unknown format version"
    end
    if #sections ~= 4 then
        return nil, "text must have 4 sections"
    end
    local record = ScanRecord.New()
    local err
    if sections[2] ~= "" then
        record.latest, err = decodeLatest(sections[2])
        if not record.latest then
            return nil, err
        end
    end
    if sections[3] ~= "" then
        record.today, err = decodeToday(sections[3])
        if not record.today then
            return nil, err
        end
    end
    record.days, err = decodeDays(sections[4])
    if not record.days then
        return nil, err
    end
    local ok, verr = ScanRecord.Validate(record)
    if not ok then
        return nil, verr
    end
    return record
end
