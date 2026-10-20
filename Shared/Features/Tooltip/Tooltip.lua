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

local KEY_CLASS = Enum and Enum.ItemClass and Enum.ItemClass.Key or 13
local BIND = Enum and Enum.ItemBind or {}
local NEVER_ON_AH = { [BIND.OnAcquire or 1] = true, [BIND.Quest or 4] = true }
-- Account bind types exist only on a client that defines them.
for _, name in ipairs({ "ToWoWAccount", "ToBnetAccount" }) do
    if BIND[name] then
        NEVER_ON_AH[BIND[name]] = true
    end
end

-- Returns true if the item is a key. An unknown class gives false.
local function isKey(deps, link)
    local instant = deps.itemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)
    if not instant then
        return false
    end
    local _, _, _, _, _, classID = instant(link)
    return classID == KEY_CLASS
end

-- Returns true if the bind type (14th return of GetItemInfo) is soulbound for good. An unknown type gives false.
local function isBindNever(deps, link)
    local getInfo = deps.itemInfo or (C_Item and C_Item.GetItemInfo)
    if not getInfo then
        return false
    end
    return NEVER_ON_AH[select(14, getInfo(link))] == true
end

-- Returns an ItemLocation for the bag slot or equipment slot that owns the tooltip, or nil.
local function locationOf(deps, tooltip)
    local make = deps.itemLocation or (ItemLocation and ItemLocation.CreateFromBagAndSlot and ItemLocation)
    local owner = tooltip.GetOwner and tooltip:GetOwner()
    if not make or type(owner) ~= "table" or not owner.GetID then
        return nil
    end
    local bagID = owner.GetBagID and owner:GetBagID()
    if bagID then
        return make:CreateFromBagAndSlot(bagID, owner:GetID())
    end
    local parent = owner.GetParent and owner:GetParent()
    local parentName = type(parent) == "table" and parent.GetName and parent:GetName()
    if type(parentName) == "string" and parentName:match("^ContainerFrame%d+$") then
        return make:CreateFromBagAndSlot(parent:GetID(), owner:GetID())
    end
    local name = owner.GetName and owner:GetName()
    if type(name) == "string" and name:match("^Character%a+Slot$") then
        return make:CreateFromEquipmentSlot(owner:GetID())
    end
    return nil
end

-- Returns true if the item at the tooltip owner is bound now. An unknown owner gives false.
local function isBoundNow(deps, tooltip)
    local isBound = deps.isBound or (C_Item and C_Item.IsBound)
    if not isBound then
        return false
    end
    local location = locationOf(deps, tooltip)
    return location ~= nil and isBound(location) == true
end

-- Returns true if the vendor sell price is 0 and no scan record exists. An unknown price gives false.
local function isUnsellable(deps, link)
    local getInfo = deps.itemInfo or (C_Item and C_Item.GetItemInfo)
    if not getInfo then
        return false
    end
    local sellPrice = select(11, getInfo(link))
    if sellPrice ~= 0 then
        return false
    end
    local key = ns.ItemString and ns.ItemString.ToExactKey(link)
    return not (key and deps.getRecord and type(deps.getRecord(key)) == "table")
end

-- Returns the stack count of the bag slot that owns the tooltip, or nil.
local function stackCountOf(deps, tooltip)
    if not (deps.containerItemInfo and tooltip.GetOwner) then
        return nil
    end
    local owner = tooltip:GetOwner()
    if type(owner) ~= "table" then
        return nil
    end
    local bag, slot
    if owner.GetBagID then
        bag, slot = owner:GetBagID(), owner:GetID()
    elseif owner.GetItemLocation then
        -- Forever bank buttons have no bag ID; their item location gives the bag and the slot.
        local location = owner:GetItemLocation()
        if type(location) == "table" and location.GetBagAndSlot then
            bag, slot = location:GetBagAndSlot()
        end
    end
    if not bag then
        return nil
    end
    local info = deps.containerItemInfo(bag, slot)
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

-- Returns the colour of a class file as 6 hex digits, or nil. TBC has no C_ClassColor, Forever has both.
local function classColorHex(class)
    local colors = _G.RAID_CLASS_COLORS
    local c = type(colors) == "table" and colors[class]
    if type(c) ~= "table" then
        return nil
    end
    if type(c.colorStr) == "string" and #c.colorStr >= 6 then
        return c.colorStr:sub(-6)
    end
    if type(c.r) == "number" and type(c.g) == "number" and type(c.b) == "number" then
        return string.format("%02x%02x%02x", math.floor(c.r * 255 + 0.5), math.floor(c.g * 255 + 0.5),
            math.floor(c.b * 255 + 0.5))
    end
    return nil
end
Tooltip.ClassColorHex = classColorHex

local function addRows(tooltip, rows)
    if #rows == 0 then
        return
    end
    local title = "Flipside"
    for _, row in ipairs(rows) do
        if row.header then
            title = row.header
            break
        end
    end
    tooltip:AddLine(" ")
    tooltip:AddLine(title, HEADER_COLOR[1], HEADER_COLOR[2], HEADER_COLOR[3])
    for _, row in ipairs(rows) do
        if row.kind == "table" then
            addTable(tooltip, row)
        elseif row.rgb then
            local c = row.rgb
            tooltip:AddDoubleLine(row.left or "", row.right or "", c[1], c[2], c[3], c[1], c[2], c[3])
        elseif row.color == "dim" then
            tooltip:AddDoubleLine(row.left or "", row.right or "", DIM_COLOR[1], DIM_COLOR[2], DIM_COLOR[3],
                DIM_COLOR[1], DIM_COLOR[2], DIM_COLOR[3])
        else
            tooltip:AddDoubleLine(row.left or "", row.right or "")
        end
    end
end
-- Returns the vendor sell price (11th return of GetItemInfo) of the item, or nil.
local function sellPriceOf(deps, link)
    local getInfo = deps.itemInfo or (C_Item and C_Item.GetItemInfo)
    if not getInfo or not link then
        return nil
    end
    local price = select(11, getInfo(link))
    return type(price) == "number" and price or nil
end

-- Returns the rows of one item with the current settings, or with the given config.
function Tooltip.Rows(deps, input, stackMode, stackCount, config)
    return ns.TooltipLines.Build({
        sellPrice = sellPriceOf(deps, input),
        config = config or deps.tooltipConfig:Get(),
        input = input,
        stackCount = stackCount,
        stackMode = stackMode or false,
        formulaRun = deps.formulaRun,
        rules = deps.rules,
        holdings = deps.holdings,
        getRecord = deps.getRecord,
        isGuild = deps.isGuild,
        currentRealmOnly = deps.currentRealmOnly or false,
        realm = deps.realm and deps.realm() or nil,
        classColor = deps.classColor or classColorHex,
        now = deps.now and deps.now() or 0,
    })
end

-- deps: itemInfoInstant (optional, default C_Item.GetItemInfoInstant), itemInfo (optional, default C_Item.GetItemInfo),
-- isBound (default C_Item.IsBound), itemLocation (default ItemLocation),
-- tooltipConfig, formulaRun, rules, holdings, getRecord, isGuild(key) (optional), now, isAltDown, containerItemInfo,
-- clock, report, bus (optional; with it, Alt up or down shows the tooltip again), currentRealmOnly, realm(),
-- classColor(classFile) (default: RAID_CLASS_COLORS).
-- deps.hook (default ns.TooltipHook) has Install(onItem, opts); it calls onItem(tooltip, link) for each item tooltip.
function Tooltip.Attach(deps)
    local stats = { count = 0, total = 0, max = 0 }
    Tooltip.stats = stats
    local reported = false
    local shown -- the item tooltip that holds our rows: { tooltip, alt }

    local function report(message)
        if reported or not deps.report then
            return
        end
        reported = true
        deps.report(message)
    end

    local function build(tooltip, link, stackCount)
        if shown and shown.tooltip == tooltip then
            shown = nil
        end
        if ns.TooltipTable then
            ns.TooltipTable.Release(tooltip)
        end
        if not link or isQuestItem(deps, link) or isKey(deps, link) or isBindNever(deps, link)
            or isBoundNow(deps, tooltip) or isUnsellable(deps, link) then
            return
        end
        local stackMode = deps.isAltDown and deps.isAltDown() or false
        if stackMode and stackCount == nil then
            stackCount = stackCountOf(deps, tooltip)
        end
        addRows(tooltip, Tooltip.Rows(deps, link, stackMode, stackMode and stackCount or nil))
        shown = { tooltip = tooltip, alt = stackMode }
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

    -- Alt went up or down over a tooltip with our rows: ask the owner to show the tooltip again.
    -- The owner OnEnter script is the one that the client runs on hover, so the hook builds the rows again.
    local function onModifier(_, key)
        if not shown or type(key) ~= "string" or not key:find("ALT", 1, true) then
            return
        end
        local tooltip = shown.tooltip
        if not (tooltip.IsShown and tooltip:IsShown()) then
            shown = nil
            return
        end
        if (deps.isAltDown and deps.isAltDown() or false) == shown.alt then
            return
        end
        local owner = tooltip.GetOwner and tooltip:GetOwner()
        local onEnter = type(owner) == "table" and owner.GetScript and owner:GetScript("OnEnter")
        if type(onEnter) == "function" then
            local ok, err = pcall(onEnter, owner)
            if not ok then
                report("tooltip refresh failed: " .. tostring(err))
            end
        end
    end
    if deps.bus then
        deps.bus:Subscribe("MODIFIER_STATE_CHANGED", "Flipside.Tooltip", onModifier)
    end

    local hook = deps.hook or ns.TooltipHook
    if type(hook) ~= "table" or type(hook.Install) ~= "function" then
        report("tooltip hook not available")
        return nil
    end
    if not hook.Install(onItem, { report = report }) then
        return nil
    end
    return { OnItem = onItem, OnModifier = onModifier, stats = stats }
end

-- Entry point for a flavour hook: add the Flipside lines to one item tooltip.
-- link is the item link or nil. stackCount is optional; with Alt down the bag owner of the tooltip gives it.
function Tooltip.OnItem(tooltip, link, stackCount)
    if Tooltip.handler then
        Tooltip.handler(tooltip, link, stackCount)
    end
end