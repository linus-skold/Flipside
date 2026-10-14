local _, ns = ...

-- Keeps the latest values, today's snapshots and the daily history of one item record.

local ScanBucket = {}
ns.ScanBucket = ScanBucket

local SNAP_FIELDS = { "min", "market", "qty", "auctions" }

local function isCount(v)
    return type(v) == "number" and v >= 0 and v == math.floor(v) and v < 2 ^ 52
end

local function checkSnap(snap)
    if type(snap) ~= "table" then
        return false
    end
    for _, key in ipairs(SNAP_FIELDS) do
        if not isCount(snap[key]) then
            return false
        end
    end
    return true
end

local function average(snaps, key)
    local sum = 0
    for _, snap in ipairs(snaps) do
        sum = sum + snap[key]
    end
    return math.floor(sum / #snaps + 0.5)
end

local function insertDay(days, entry)
    for i, existing in ipairs(days) do
        if existing.day == entry.day then
            days[i] = entry
            return
        elseif existing.day > entry.day then
            table.insert(days, i, entry)
            return
        end
    end
    days[#days + 1] = entry
end

-- Turn an earlier day's snapshots into one daily record. Return true if it did.
function ScanBucket.RollUp(record, currentDay)
    local today = record.today
    if not today or today.day >= currentDay then
        return false
    end
    insertDay(record.days, {
        day = today.day,
        min = average(today.snaps, "min"),
        market = average(today.snaps, "market"),
        qty = average(today.snaps, "qty"),
        scans = #today.snaps,
    })
    record.today = nil
    return true
end

-- Store a scan result. Only a complete scan adds a snapshot.
function ScanBucket.Apply(record, snap, serverTime, partial)
    if not checkSnap(snap) then
        error("Apply: snap must have non-negative integer min, market, qty and auctions", 2)
    end
    local day = ns.ScanClock.DayOf(serverTime)
    ScanBucket.RollUp(record, day)
    local time = math.floor(serverTime)
    record.latest = {
        time = time,
        min = snap.min,
        market = snap.market,
        qty = snap.qty,
        auctions = snap.auctions,
        partial = partial and true or false,
    }
    if partial then
        return
    end
    if not record.today then
        record.today = { day = day, snaps = {} }
    end
    local snaps = record.today.snaps
    snaps[#snaps + 1] = {
        time = time,
        min = snap.min,
        market = snap.market,
        qty = snap.qty,
        auctions = snap.auctions,
    }
    while #snaps > ns.ScanClock.MAX_SNAPSHOTS_PER_DAY do
        table.remove(snaps, 1)
    end
end

-- Remove daily records that are too old. Return the number removed.
function ScanBucket.Prune(record, currentDay, retentionDays)
    retentionDays = retentionDays or ns.ScanClock.RETENTION_DAYS_DEFAULT
    if not isCount(retentionDays) or retentionDays < 1 then
        error("Prune: retentionDays must be an integer >= 1", 2)
    end
    local limit = currentDay - retentionDays
    local kept, removed = {}, 0
    for _, entry in ipairs(record.days) do
        if entry.day <= limit then
            removed = removed + 1
        else
            kept[#kept + 1] = entry
        end
    end
    if removed > 0 then
        record.days = kept
    end
    return removed
end

-- Return true if the record holds no data.
function ScanBucket.IsEmpty(record)
    return record.latest == nil and record.today == nil and #record.days == 0
end

-- Handle an item that a complete scan did not see. Do not change latest.
function ScanBucket.MarkUnseen(record, serverTime)
    ScanBucket.RollUp(record, ns.ScanClock.DayOf(serverTime))
end
