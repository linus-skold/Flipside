local _, ns = ...

-- Adds the Flipside price and count lines to item tooltips. The client hook that calls it lives in a flavour file.

local Tooltip = {}
ns.Tooltip = Tooltip

Tooltip.stats = { count = 0, total = 0, max = 0 }

local HEADER_COLOR = { 1, 0.82, 0 }
local DIM_COLOR = { 0.6, 0.6, 0.6 }

local QUEST_ITEM_CLASS = Enum and Enum.ItemClass and Enum.ItemClass.Questitem or 12

-- Returns true if the item is a quest item. An unknown class gives false.
local function isQuestItem(deps, link)
    local instant = deps.itemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)
    if not instant then
        return false
    end
    local _, _, _, _, _, classID = instant(link)
    return classID == QUEST_ITEM_CLASS
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

-- Returns the left text line of a tooltip by index, or nil.
local function leftLine(tooltip, index)
    if tooltip.GetLeftLine then
        return tooltip:GetLeftLine(index)
    end
    local name = tooltip.GetName and tooltip:GetName()
    return name and _G[name .. "TextLeft" .. index] or nil
end

-- Adds a blank tooltip line for each table row and draws the table over them. Returns false if it cannot.
local function addDrawnTable(tooltip, model)
    local TT = ns.TooltipTable
    local state = TT and tooltip.NumLines and tooltip.SetMinimumWidth and TT.For(tooltip)
    if not state then
        return false
    end
    local first = tooltip:NumLines() + 1
    local width = state.view:Set(model)
    for _ = 1, #model.rows + 1 do
        tooltip:AddLine(" ")
    end
    local lines = {}
    for i = 1, #model.rows + 1 do
        lines[i] = leftLine(tooltip, first + i - 1)
        if not lines[i] then
            return true
        end
    end
    state.view:Place(function(index)
        return lines[index], 0
    end)
    tooltip:SetMinimumWidth(TT.TooltipWidth(width), false)
    state.minWidth = true
    return true
end

local function addTable(tooltip, model)
    if addDrawnTable(tooltip, model) then
        return
    end
    tooltip:AddDoubleLine("", table.concat(model.columns, "  "))
    for _, row in ipairs(model.rows) do
        tooltip:AddDoubleLine(row.label, table.concat(row.cells, "  "))
    end
end

local function addRows(tooltip, rows)
    if #rows == 0 then
        return
    end
    local title = "Flipside"
    for _, row in ipairs(rows) do
        if row.kind == "table" then
            title = row.header
            break
        end
    end
    tooltip:AddLine(" ")
    tooltip:AddLine(title, HEADER_COLOR[1], HEADER_COLOR[2], HEADER_COLOR[3])
    for _, row in ipairs(rows) do
        if row.kind == "table" then
            addTable(tooltip, row)
        elseif row.color == "dim" then
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

-- deps: itemInfoInstant (optional, default C_Item.GetItemInfoInstant),
-- tooltipConfig, formulaRun, rules, holdings, getRecord, now, isAltDown, containerItemInfo, clock, report.
-- deps.hook (default ns.TooltipHook) has Install(onItem, opts); it calls onItem(tooltip, link) for each item tooltip.
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

    local function build(tooltip, link, stackCount)
        if ns.TooltipTable then
            ns.TooltipTable.Release(tooltip)
        end
        if not link or isQuestItem(deps, link) then
            return
        end
        local stackMode = deps.isAltDown and deps.isAltDown() or false
        if stackMode and stackCount == nil then
            stackCount = stackCountOf(deps, tooltip)
        end
        addRows(tooltip, Tooltip.Rows(deps, link, stackMode, stackMode and stackCount or nil))
    end

    local function onItem(tooltip, link, stackCount)
        local start = deps.clock()
        local ok, err = pcall(function()
            if tooltip.IsForbidden and tooltip:IsForbidden() then
                return
            end
            build(tooltip, link, stackCount)
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
    Tooltip.handler = onItem

    local hook = deps.hook or ns.TooltipHook
    if type(hook) ~= "table" or type(hook.Install) ~= "function" then
        report("tooltip hook not available")
        return nil
    end
    if not hook.Install(onItem, { report = report }) then
        return nil
    end
    return { OnItem = onItem, stats = stats }
end

-- Entry point for a flavour hook: add the Flipside lines to one item tooltip.
-- link is the item link or nil. stackCount is optional; with Alt down the bag owner of the tooltip gives it.
function Tooltip.OnItem(tooltip, link, stackCount)
    if Tooltip.handler then
        Tooltip.handler(tooltip, link, stackCount)
    end
end