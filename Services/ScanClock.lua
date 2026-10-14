local _, ns = ...

local ScanClock = {}
ns.ScanClock = ScanClock

ScanClock.SECONDS_PER_DAY = 86400
ScanClock.COOLDOWN_SECONDS = 900
ScanClock.EVENT_TIMEOUT_SECONDS = 60
ScanClock.ITEM_LOAD_TIMEOUT_SECONDS = 30
ScanClock.MAX_SNAPSHOTS_PER_DAY = 4
ScanClock.RETENTION_DAYS_DEFAULT = 60
ScanClock.MARKET_WINDOW_DAYS = 14
ScanClock.MARKET_HALF_LIFE_DAYS = 2.2
ScanClock.RULESET_DEFAULT = "standard"

local function isFinite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Return the day number (UTC) of a server time.
function ScanClock.DayOf(serverTime)
    if not isFinite(serverTime) or serverTime < 0 then
        error("DayOf: serverTime must be a non-negative finite number", 2)
    end
    return math.floor(serverTime / ScanClock.SECONDS_PER_DAY)
end

-- Return the server time of 00:00 UTC of a day.
function ScanClock.DayStart(day)
    if not isFinite(day) or day < 0 or day ~= math.floor(day) then
        error("DayStart: day must be a non-negative integer", 2)
    end
    return day * ScanClock.SECONDS_PER_DAY
end

-- Return the hours from one server time to another.
function ScanClock.HoursBetween(fromTime, toTime)
    return (toTime - fromTime) / 3600
end

-- Return true if the server time is on a later day than lastDay.
function ScanClock.IsNewDay(lastDay, serverTime)
    return lastDay == nil or ScanClock.DayOf(serverTime) > lastDay
end
