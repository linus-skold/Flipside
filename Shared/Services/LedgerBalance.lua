local _, ns = ...

-- The gold balance over time for the Ledger page graph (SPEC 5.8 point 9). Pure: it reads a store, writes nothing.
-- The balance at time t is: anchor + (money change up to t) - (money change up to the anchor time).
-- The anchor is the live GetMoney() of the current character, or the last saved balance of another one.
local LedgerBalance = {}
ns.LedgerBalance = LedgerBalance

local SECONDS_PER_DAY = 86400
-- The key of the balance snapshot in the character scope of the main settings. The value is { copper, time }.
LedgerBalance.KEY = "ledger.balance"
-- The most points that a series holds. Longer series are thinned.
LedgerBalance.MAX_POINTS = 365

local COPPER_PER_SILVER, COPPER_PER_GOLD = 100, 10000

-- The signed copper change of a full record. A record without a money flow (post, expired, log) gives 0.
-- A record with the source "unknown" counts, because it is a real money change.
function LedgerBalance.Delta(record)
    local direction = ns.LedgerRecord.Direction(record.type)
    local money = record.money or 0
    if direction == "in" then
        return money
    elseif direction == "out" then
        return -money
    end
    return 0
end

-- The signed copper change of a daily sum.
function LedgerBalance.SumDelta(sum)
    return (sum.moneyIn or 0) - (sum.moneyOut or 0)
end

-- Saves the balance of the current character. Returns true if it was saved.
function LedgerBalance.WriteSnapshot(db, copper, time)
    if type(copper) ~= "number" or copper < 0 or type(time) ~= "number" or not db then
        return false
    end
    return db:Set("character", LedgerBalance.KEY, { copper = copper, time = time }) ~= false
end

-- Returns { copper, time } of the saved balance of a character, or nil.
function LedgerBalance.ReadSnapshot(db, character)
    local value = db and db:GetFor(character, LedgerBalance.KEY)
    if type(value) == "table" and type(value.copper) == "number" and type(value.time) == "number" then
        return value
    end
    return nil
end

-- Returns the money changes of one character, oldest first: a list of { time, delta }. A daily sum is placed at the
-- start of its day. buffered is an optional list of records that are not in the store yet.
function LedgerBalance.Events(store, character, fromTime, buffered)
    local events = {}
    local function add(time, delta)
        if delta ~= 0 then
            events[#events + 1] = { time = time, delta = delta }
        end
    end
    for _, record in ipairs(store:Records({ char = character, fromTime = fromTime })) do
        add(record.time, LedgerBalance.Delta(record))
    end
    for _, sum in ipairs(store:Sums({ char = character, fromTime = fromTime })) do
        add(sum.day * SECONDS_PER_DAY, LedgerBalance.SumDelta(sum))
    end
    for _, record in ipairs(buffered or {}) do
        if record.char == character and (fromTime == nil or record.time >= fromTime) then
            add(record.time, LedgerBalance.Delta(record))
        end
    end
    table.sort(events, function(a, b)
        return a.time < b.time
    end)
    return events
end

-- Returns a function balance(t) for one character. anchor is { copper, time }. The result is never below 0.
function LedgerBalance.Curve(events, anchor)
    local times, totals, sum = {}, {}, 0
    for index, event in ipairs(events) do
        sum = sum + event.delta
        times[index], totals[index] = event.time, sum
    end
    -- The total change of all events up to and including t.
    local function changeUpTo(t)
        local low, high = 0, #times
        while low < high do
            local middle = math.ceil((low + high) / 2)
            if times[middle] <= t then
                low = middle
            else
                high = middle - 1
            end
        end
        return low > 0 and totals[low] or 0
    end
    local base = anchor.copper - changeUpTo(anchor.time)
    return function(t)
        return math.max(base + changeUpTo(t), 0)
    end
end

-- Keeps at most max entries of a list, the first and the last included.
local function thin(list, max)
    if #list <= max then
        return list
    end
    local result = {}
    for i = 1, max do
        result[i] = list[math.floor((i - 1) * (#list - 1) / (max - 1) + 1.5)]
    end
    return result
end

-- Builds the balance series. args:
--   store: the ledger store (Records, Sums)
--   characters: the names to include (one name, or all names for "All characters")
--   live: { char, copper } for the current character, or nil. Its anchor time is args.now.
--   snapshot(char): { copper, time } or nil. It is the anchor of a character that is not live.
--   buffered: optional records that are not in the store yet
--   now: the server time
--   rangeKey: "today", "7", "30", "180" or "all"; rangeStart: the first second of the range, or nil
-- Returns { points = list of { x, y, day }, mode = "records" or "days", included = names, omitted = names }.
-- A character without an anchor is left out and is in omitted.
function LedgerBalance.Series(args)
    local now = args.now
    local rangeStart = args.rangeStart or nil
    local mode = args.rangeKey == "today" and "records" or "days"
    local curves, included, omitted, allEvents = {}, {}, {}, {}
    for _, character in ipairs(args.characters) do
        local anchor
        if args.live and args.live.char == character and type(args.live.copper) == "number" then
            anchor = { copper = args.live.copper, time = now }
        else
            anchor = args.snapshot and args.snapshot(character) or nil
        end
        if anchor then
            local from = rangeStart
            if from and anchor.time < from then
                from = anchor.time
            end
            local events = LedgerBalance.Events(args.store, character, from, args.buffered)
            curves[#curves + 1] = LedgerBalance.Curve(events, anchor)
            included[#included + 1] = character
            for _, event in ipairs(events) do
                allEvents[#allEvents + 1] = event
            end
        else
            omitted[#omitted + 1] = character
        end
    end
    local function total(t)
        local sum = 0
        for _, curve in ipairs(curves) do
            sum = sum + curve(t)
        end
        return sum
    end

    local points = {}
    local endDay = math.floor(now / SECONDS_PER_DAY)
    if #curves == 0 then
        return { points = points, mode = mode, included = included, omitted = omitted }
    end
    if mode == "records" then
        local start = rangeStart or endDay * SECONDS_PER_DAY
        points[1] = { x = start, y = total(start - 1) }
        local last = start
        local seen = {}
        local times = {}
        for _, event in ipairs(allEvents) do
            if event.time > start and event.time <= now and not seen[event.time] then
                seen[event.time] = true
                times[#times + 1] = event.time
            end
        end
        table.sort(times)
        for _, time in ipairs(times) do
            points[#points + 1] = { x = time, y = total(time) }
            last = time
        end
        if last < now then
            points[#points + 1] = { x = now, y = total(now) }
        end
    else
        local startDay = rangeStart and math.floor(rangeStart / SECONDS_PER_DAY)
        if not startDay then
            startDay = endDay
            for _, event in ipairs(allEvents) do
                startDay = math.min(startDay, math.floor(event.time / SECONDS_PER_DAY))
            end
        end
        for day = startDay, endDay do
            local t = day == endDay and now or (day + 1) * SECONDS_PER_DAY - 1
            points[#points + 1] = { x = day * SECONDS_PER_DAY, y = total(t), day = day }
        end
    end
    return { points = thin(points, LedgerBalance.MAX_POINTS), mode = mode, included = included, omitted = omitted }
end

-- The y axis for a money graph. Returns { max, step, ticks, unit, unitSize }: the max is a clean value above
-- maxCopper, the axis starts at 0, and there are 3 to 5 ticks. The unit is copper, silver or gold.
function LedgerBalance.MoneyScale(maxCopper)
    maxCopper = math.max(maxCopper or 0, 2)
    local unit, unitSize = "c", 1
    if maxCopper >= 2 * COPPER_PER_GOLD then
        unit, unitSize = "g", COPPER_PER_GOLD
    elseif maxCopper >= 2 * COPPER_PER_SILVER then
        unit, unitSize = "s", COPPER_PER_SILVER
    end
    local units = maxCopper / unitSize
    local step, count = 1, 0
    local magnitude = 1
    while true do
        for _, factor in ipairs({ 1, 2, 5 }) do
            local candidate = factor * magnitude
            local n = math.ceil(units / candidate - 1e-9)
            if n <= 4 then
                step, count = candidate, math.max(n, 2)
                break
            end
        end
        if count > 0 then
            break
        end
        magnitude = magnitude * 10
    end
    local ticks = {}
    for i = 0, count do
        ticks[#ticks + 1] = i * step * unitSize
    end
    return { max = count * step * unitSize, step = step * unitSize, ticks = ticks, unit = unit, unitSize = unitSize }
end

-- The text of an x value on the axis. dateFn is the date function of the client (date or os.date).
function LedgerBalance.AxisText(x, mode, dateFn)
    if mode == "records" then
        return dateFn("%H:%M", x)
    end
    return dateFn("!%Y-%m-%d", x)
end

-- The hover lines of a point: the title is the date, the next line is the balance. money(copper) gives the text.
function LedgerBalance.HoverLines(point, mode, dateFn, money)
    local date
    if mode == "records" then
        date = dateFn("%Y-%m-%d %H:%M", point.x)
    else
        date = dateFn("!%Y-%m-%d", point.x)
    end
    return { date, "Balance: " .. money(point.y) }
end
