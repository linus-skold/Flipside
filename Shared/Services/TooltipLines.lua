local _, ns = ...

-- Builds the tooltip rows of one item. Pure: no frames, no WoW API.

local TooltipLines = {}
ns.TooltipLines = TooltipLines

local WINDOW_DAYS = 14
local WINDOWS = {
    { days = 1, label = "1d" },
    { days = 14, label = "14d" },
    { days = 30, label = "30d" },
    { days = 60, label = "60d" },
}
local COLUMNS = { "Min", "Avg", "Max", "Market" }
local NO_VALUE = "-"
local NO_PRICES = "Prices"
local SEP = " \194\183 "
local INVALID = "invalid price"
local LATER = "not available yet"

local function withSeparators(n)
    local text = string.format("%d", n)
    local out = text
    repeat
        text = out
        out = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    until out == text
    return out
end

-- Returns every non-zero unit as text, such as "12g 40s 7c". Rounds half up to whole copper. "0c" for zero.
function TooltipLines.FormatMoney(copper)
    copper = math.floor((copper or 0) + 0.5)
    if copper == 0 then
        return "0c"
    end
    local sign = ""
    if copper < 0 then
        sign, copper = "-", -copper
    end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local rest = copper % 100
    local parts = {}
    if gold > 0 then
        parts[#parts + 1] = withSeparators(gold) .. "g"
    end
    if silver > 0 then
        parts[#parts + 1] = silver .. "s"
    end
    if rest > 0 then
        parts[#parts + 1] = rest .. "c"
    end
    return sign .. table.concat(parts, " ")
end

function TooltipLines.FormatAge(hours)
    if hours < 1 then
        return "< 1 h"
    end
    if hours >= 48 then
        return string.format("%d d", math.floor(hours / 24 + 0.5))
    end
    return string.format("%d h", math.floor(hours + 0.5))
end

local function dataRow(line, ctx, state)
    if line.kind == "table" then
        return ctx.tableRow()
    end
    local copper, info
    if ctx.formulaRun then
        copper, info = ctx.formulaRun:Evaluate(line.formula or "", ctx.input)
    end
    local label = line.label or ""
    local stack = ctx.stackCount
    local right
    if copper then
        if ctx.stackMode and stack and stack > 1 then
            copper = copper * stack
            label = label .. " (stack of " .. stack .. ")"
        end
        right = TooltipLines.FormatMoney(copper)
        if line.showAge or line.showSamples then
            local sources = state.sources(info and info.key)
            if line.showAge and sources and sources.scanAge then
                right = right .. SEP .. TooltipLines.FormatAge(sources.scanAge) .. " old"
            end
            if line.showSamples and sources and sources.scanSamples then
                right = right .. SEP .. sources.scanSamples .. "/" .. WINDOW_DAYS .. " days"
            end
        end
    elseif info and info.later and #info.later > 0 then
        right = LATER
    else
        right = INVALID
    end
    return { left = label, right = right, color = copper and "normal" or "dim" }
end

-- Returns one entry per server day: { day, min, market, low, high }. min and market are the daily values.
local function dayEntries(record, currentDay)
    local list, hasToday = {}, false
    for _, d in ipairs(record.days or {}) do
        list[#list + 1] = { day = d.day, min = d.min, market = d.market, low = d.min, high = d.min }
        hasToday = hasToday or d.day == currentDay
    end
    local today = record.today
    local snaps = today and today.snaps
    if snaps and #snaps > 0 then
        local sumMin, sumMarket, low, high = 0, 0, nil, nil
        for _, snap in ipairs(snaps) do
            sumMin, sumMarket = sumMin + snap.min, sumMarket + snap.market
            low = (not low or snap.min < low) and snap.min or low
            high = (not high or snap.min > high) and snap.min or high
        end
        list[#list + 1] =
            { day = today.day, min = sumMin / #snaps, market = sumMarket / #snaps, low = low, high = high }
        hasToday = hasToday or today.day == currentDay
    end
    local latest = record.latest
    if not hasToday and latest and ns.ScanClock.DayOf(latest.time) == currentDay then
        list[#list + 1] =
            { day = currentDay, min = latest.min, market = latest.market, low = latest.min, high = latest.min }
    end
    return list
end

-- Returns the values of one window from the day entries; a field is nil when the window has no data.
local function windowValues(entries, currentDay, days)
    local first = currentDay - days
    local count, sumMin, sumMarket, low, high = 0, 0, 0, nil, nil
    for _, e in ipairs(entries) do
        if e.day > first and e.day <= currentDay then
            count = count + 1
            sumMin, sumMarket = sumMin + e.min, sumMarket + e.market
            local top = days == 1 and e.high or e.min
            low = (not low or e.low < low) and e.low or low
            high = (not high or top > high) and top or high
        end
    end
    if count == 0 then
        return {}
    end
    return { min = low, avg = sumMin / count, max = high, market = sumMarket / count }
end

-- Returns an array of { days, label, min, avg, max, market } in copper for the windows 1, 14, 30 and 60 days.
-- 1d is today. The other windows are today and the earlier days, so N days in all. A field is nil without data.
function TooltipLines.Windows(record, now)
    local currentDay = ns.ScanClock.DayOf(now or 0)
    local entries = dayEntries(record, currentDay)
    local out = {}
    for i, window in ipairs(WINDOWS) do
        local values = windowValues(entries, currentDay, window.days)
        values.days, values.label = window.days, window.label
        out[i] = values
    end
    return out
end

local function tableModel(ctx, key)
    local record = key and ctx.getRecord and ctx.getRecord(key)
    if type(record) ~= "table" then
        return { left = NO_PRICES, right = INVALID, color = "dim" }
    end
    local windows = TooltipLines.Windows(record, ctx.now)
    local stack = ctx.stackMode and ctx.stackCount and ctx.stackCount > 1 and ctx.stackCount or 1
    local rows, any = {}, false
    for i, w in ipairs(windows) do
        local cells = {}
        for j, field in ipairs({ "min", "avg", "max", "market" }) do
            if w[field] then
                any = true
                cells[j] = TooltipLines.FormatMoney(w[field] * stack)
            else
                cells[j] = NO_VALUE
            end
        end
        rows[i] = { label = w.label, cells = cells }
    end
    if not any then
        return { left = NO_PRICES, right = INVALID, color = "dim" }
    end
    local parts = {}
    if record.latest then
        local hours = ns.ScanClock.HoursBetween(record.latest.time, ctx.now or 0)
        parts[#parts + 1] = "updated " .. TooltipLines.FormatAge(hours) .. " ago"
    end
    if stack > 1 then
        parts[#parts + 1] = "stack of " .. stack
    end
    local header = "Flipside" .. (#parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or "")
    return { kind = "table", header = header, columns = COLUMNS, rows = rows }
end

local function groupRows(ctx, rows, key, config)
    local rules = ctx.rules
    if not rules or not key then
        return
    end
    local groupID = rules:GroupOf(key)
    if not groupID then
        return
    end
    if config.showGroup and (groupID ~= 1 or config.showBaseGroup) then
        local path = rules:Path(groupID)
        if path and #path > 0 then
            rows[#rows + 1] = { left = "Group: " .. table.concat(path, " > "), color = "dim" }
        end
    end
    if config.showOperation then
        local types = ns.OperationSchema and ns.OperationSchema.TYPES or { "selling", "buying", "vendoring" }
        for _, opType in ipairs(types) do
            local opID, fromGroup = rules:EffectiveOperation(groupID, opType)
            local op = opID and rules:GetOperation(opID)
            if op then
                local text = opType:sub(1, 1):upper() .. opType:sub(2) .. ": " .. op.name
                if fromGroup ~= groupID then
                    local path = rules:Path(fromGroup)
                    text = text .. " (from " .. (path and path[#path] or tostring(fromGroup)) .. ")"
                end
                rows[#rows + 1] = { left = text, color = "dim" }
            end
        end
    end
end

local function countRows(ctx, rows, key)
    local holdings = ctx.holdings
    if not holdings or not key then
        return
    end
    local count = holdings:Count(key)
    if not count then
        return
    end
    rows[#rows + 1] = { left = "Total: " .. (count.total or 0), color = "normal" }
    for _, char in ipairs(count.characters or {}) do
        local places = {}
        for _, place in ipairs({ "bags", "bank", "mail", "auctions" }) do
            if (char[place] or 0) > 0 then
                places[#places + 1] = place .. " " .. char[place]
            end
        end
        local text = char.name .. ": " .. (char.total or 0)
        if #places > 0 then
            text = text .. " (" .. table.concat(places, ", ") .. ")"
        end
        rows[#rows + 1] = { left = text, color = "dim" }
    end
end

-- Returns an array of { left, right, color } rows. A price table row is { kind = "table", header, columns, rows }.
function TooltipLines.Build(ctx)
    local rows = {}
    local config = ctx and ctx.config
    if not config then
        return rows
    end
    local state = { cache = {} }
    state.sources = function(key)
        if not key or not ctx.getRecord or not ns.ScanSources then
            return nil
        end
        local cached = state.cache[key]
        if cached == nil then
            cached = ns.ScanSources.Compute(ctx.getRecord(key), ctx.now or 0) or false
            state.cache[key] = cached
        end
        return cached or nil
    end

    local key = ns.ItemString and (ns.ItemString.ToExactKey(ctx.input))
    local tableCtx = setmetatable({ tableRow = function() return tableModel(ctx, key) end }, { __index = ctx })
    for _, line in ipairs(config.lines or {}) do
        if line.enabled ~= false then
            rows[#rows + 1] = dataRow(line, tableCtx, state)
        end
    end

    groupRows(ctx, rows, key, config)
    if config.showCounts then
        countRows(ctx, rows, key)
    end
    return rows
end
