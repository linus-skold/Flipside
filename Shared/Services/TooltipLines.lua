local _, ns = ...

-- Builds the tooltip rows of one item. Pure: no frames, no WoW API.

local TooltipLines = {}
ns.TooltipLines = TooltipLines

local WINDOW_DAYS = 14
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

-- Returns gold and silver as text; copper only below 1 silver.
function TooltipLines.FormatMoney(copper)
    copper = math.floor((copper or 0) + 0.5)
    if copper < 100 then
        return copper .. "c"
    end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local parts = {}
    if gold > 0 then
        parts[#parts + 1] = withSeparators(gold) .. "g"
    end
    if silver > 0 then
        parts[#parts + 1] = silver .. "s"
    end
    return table.concat(parts, " ")
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

-- Returns an array of { left, right, color } rows.
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

    for _, line in ipairs(config.lines or {}) do
        if line.enabled ~= false then
            rows[#rows + 1] = dataRow(line, ctx, state)
        end
    end

    local key = ns.ItemString and (ns.ItemString.ToExactKey(ctx.input))
    groupRows(ctx, rows, key, config)
    if config.showCounts then
        countRows(ctx, rows, key)
    end
    return rows
end
