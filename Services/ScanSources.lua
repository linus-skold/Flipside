local _, ns = ...

-- Scan-based price source values of one item, computed from its record.
-- Read-side only: the record is never changed.

local ScanSources = {}
ns.ScanSources = ScanSources

-- Source names as the spec writes them, and the result field of each.
ScanSources.NAMES = {
    "ScanMin",
    "ScanRecent",
    "ScanMarket",
    "ScanHistorical",
    "ScanQty",
    "ScanAge",
    "ScanSamples",
}

ScanSources.FIELD = {
    ScanMin = "scanMin",
    ScanRecent = "scanRecent",
    ScanMarket = "scanMarket",
    ScanHistorical = "scanHistorical",
    ScanQty = "scanQty",
    ScanAge = "scanAge",
    ScanSamples = "scanSamples",
}

local function roundHalfUp(value)
    return math.floor(value + 0.5)
end

-- Return the average market value of the snapshots of today, or nil.
local function todayMarket(today)
    local snaps = today and today.snaps
    if not snaps or #snaps == 0 then
        return nil
    end
    local sum = 0
    for i = 1, #snaps do
        sum = sum + snaps[i].market
    end
    return sum / #snaps
end

-- Compute the source values of a record at server time "now".
-- Options: windowDays (14), halfLifeDays (2.2), historyDays (60).
function ScanSources.Compute(record, now, options)
    local clock = ns.ScanClock
    options = options or {}
    local windowDays = options.windowDays or clock.MARKET_WINDOW_DAYS
    local halfLifeDays = options.halfLifeDays or clock.MARKET_HALF_LIFE_DAYS
    local historyDays = options.historyDays or clock.RETENTION_DAYS_DEFAULT

    local result = { scanSamples = 0, scanDays = 0 }
    if type(record) ~= "table" then
        return result
    end

    local latest = record.latest
    if latest then
        result.scanMin = latest.min
        result.scanRecent = latest.market
        result.scanQty = latest.qty
        result.scanAge = clock.HoursBetween(latest.time, now)
        result.scanPartial = latest.partial
    end

    local currentDay = clock.DayOf(now)
    local weightSum, valueSum, samples = 0, 0, 0
    local historySum, historyCount = 0, 0

    local function addToWindow(age, market)
        local weight = 0.5 ^ (age / halfLifeDays)
        weightSum = weightSum + weight
        valueSum = valueSum + weight * market
        samples = samples + 1
    end

    local today = record.today
    if today and today.day == currentDay then
        local market = todayMarket(today)
        if market and windowDays > 0 then
            addToWindow(0, market)
        end
    end

    local days = record.days or {}
    for i = 1, #days do
        local entry = days[i]
        local age = currentDay - entry.day
        if age >= 0 and age < historyDays then
            historySum = historySum + entry.market
            historyCount = historyCount + 1
        end
        -- Today's unrolled snapshots win over a daily entry of the same day.
        local isToday = age == 0 and today and today.day == currentDay and todayMarket(today)
        if age >= 0 and age < windowDays and not isToday then
            addToWindow(age, entry.market)
        end
    end

    if weightSum > 0 then
        result.scanMarket = roundHalfUp(valueSum / weightSum)
    end
    if historyCount > 0 then
        result.scanHistorical = roundHalfUp(historySum / historyCount)
    end
    result.scanSamples = samples
    result.scanDays = historyCount
    return result
end
