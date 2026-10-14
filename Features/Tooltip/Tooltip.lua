local _, ns = ...

-- Adds the Flipside price and count lines to item tooltips through the client tooltip post call.

local Tooltip = {}
ns.Tooltip = Tooltip

Tooltip.stats = { count = 0, total = 0, max = 0 }

local HEADER_COLOR = { 1, 0.82, 0 }
local DIM_COLOR = { 0.6, 0.6, 0.6 }

-- Returns the item link of the tooltip data, or nil.
local function linkOf(deps, data)
    if type(data) ~= "table" then
        return nil
    end
    if data.guid and deps.itemLinkByGUID then
        local link = deps.itemLinkByGUID(data.guid)
        if type(link) == "string" then
            return link
        end
    end
    if type(data.hyperlink) == "string" then
        return data.hyperlink
    end
    if type(data.id) == "number" then
        return string.format("item:%d", data.id)
    end
    return nil
end

-- Returns the stack count of the bag slot that owns the tooltip, or nil.
local function stackCountOf(deps, tooltip)
    if not (deps.containerItemInfo and tooltip.GetOwner) then
        return nil
    end
    local owner = tooltip:GetOwner()
    if type(owner) ~= "table" or not owner.GetBagID then
        return nil
    end
    local info = deps.containerItemInfo(owner:GetBagID(), owner:GetID())
    return type(info) == "table" and type(info.stackCount) == "number" and info.stackCount or nil
end

local function addRows(tooltip, rows)
    if #rows == 0 then
        return
    end
    tooltip:AddLine(" ")
    tooltip:AddLine("Flipside", HEADER_COLOR[1], HEADER_COLOR[2], HEADER_COLOR[3])
    for _, row in ipairs(rows) do
        if row.color == "dim" then
            tooltip:AddDoubleLine(row.left or "", row.right or "", DIM_COLOR[1], DIM_COLOR[2], DIM_COLOR[3],
                DIM_COLOR[1], DIM_COLOR[2], DIM_COLOR[3])
        else
            tooltip:AddDoubleLine(row.left or "", row.right or "")
        end
    end
end

-- Returns the rows of one item with the current settings, or with the given config.
function Tooltip.Rows(deps, input, stackMode, stackCount, config)
    return ns.TooltipLines.Build({
        config = config or deps.tooltipConfig:Get(),
        input = input,
        stackCount = stackCount,
        stackMode = stackMode or false,
        formulaRun = deps.formulaRun,
        rules = deps.rules,
        holdings = deps.holdings,
        getRecord = deps.getRecord,
        now = deps.now and deps.now() or 0,
    })
end

-- deps: tooltipConfig, formulaRun, rules, holdings, getRecord, now, isAltDown, itemLinkByGUID,
-- containerItemInfo, processor, itemType, clock, report.
function Tooltip.Attach(deps)
    local stats = { count = 0, total = 0, max = 0 }
    Tooltip.stats = stats
    local reported = false

    local function report(message)
        if reported or not deps.report then
            return
        end
        reported = true
        deps.report(message)
    end

    local function build(tooltip, data)
        local link = linkOf(deps, data)
        if not link then
            return
        end
        local stackMode = deps.isAltDown and deps.isAltDown() or false
        local stackCount = stackMode and stackCountOf(deps, tooltip) or nil
        addRows(tooltip, Tooltip.Rows(deps, link, stackMode, stackCount))
    end

    local function onTooltip(tooltip, data)
        local start = deps.clock()
        local ok, err = pcall(function()
            if tooltip.IsForbidden and tooltip:IsForbidden() then
                return
            end
            build(tooltip, data)
        end)
        local elapsed = deps.clock() - start
        stats.count = stats.count + 1
        stats.total = stats.total + elapsed
        if elapsed > stats.max then
            stats.max = elapsed
        end
        if not ok then
            report("tooltip lines failed: " .. tostring(err))
        end
    end

    local processor = deps.processor
    if type(processor) ~= "table" or type(processor.AddTooltipPostCall) ~= "function" or deps.itemType == nil then
        report("tooltip hook not available")
        return nil
    end
    local ok, err = pcall(processor.AddTooltipPostCall, deps.itemType, onTooltip)
    if not ok then
        report("tooltip hook failed: " .. tostring(err))
        return nil
    end
    return { OnTooltip = onTooltip, stats = stats }
end
