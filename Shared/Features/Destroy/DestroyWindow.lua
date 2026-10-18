local _, ns = ...

-- The Destroy window: a free window with the bag items that match the Destroy rules, and the actions Destroy,
-- Ignore and Skip. The Destroy button is a secure button: one click starts one Disenchant cast.
-- A second tab lists the ignored items. The rules are in ns.DestroyRules.
local DestroyWindow = {}
ns.DestroyWindow = DestroyWindow

local instance

local PAD = 20
local ROW_HEIGHT = 20
local REFRESH_DELAY = 0.3
local MODE_ITEMS, MODE_IGNORED = "items", "ignored"

-- Return the item name in the colour of its quality.
local function coloured(Kit, quality, name)
    return Kit.QualityText(quality, name)
end

-- Create the window once. deps:
--   store: a DestroyRules.NewStore result.
--   readStacks(): array of { bag, slot, itemID, link } for the bag slots.
--   itemInfo(itemID): the item info table or nil. requestInfo(itemID, callback(itemID, info, state)).
--   player(): { level, class }.  disenchant(): spell name or nil, spell known (boolean).
--   inCombat(): boolean.  bus: the event bus.  after(seconds, fn).  print(text).
--   position: optional { get, set } for the window position.
-- Skipped items are kept in memory only: they show again after /reload.
function DestroyWindow.Create(deps)
    if instance then
        return instance
    end
    local Kit = ns.Kit
    local store = deps.store
    local frame = Kit.CreateWindow("FlipsideDestroyWindow", {
        width = 520,
        height = 480,
        title = "Flipside Destroy",
        square = true,
        savePosition = deps.position,
    })
    local view = { frame = frame, rows = {}, skipped = {}, mode = MODE_ITEMS, selectedKey = nil }
    instance = view
    local pending = false

    -- Rules, row 1: the quality range.
    local qualityLabel = Kit.Label(frame, "Quality from", "normal")
    qualityLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -40)
    local minDrop = Kit.Dropdown(frame, 100, {
        items = DestroyWindow.QualityItems(),
        value = 2,
        onChange = function(value)
            view:ChangeRules(function(config)
                config.minQuality = value
                config.maxQuality = math.max(config.maxQuality, value)
            end)
        end,
    })
    minDrop:SetPoint("LEFT", qualityLabel, "RIGHT", 6, 0)
    local toLabel = Kit.Label(frame, "to", "normal")
    toLabel:SetPoint("LEFT", minDrop, "RIGHT", 6, 0)
    local maxDrop = Kit.Dropdown(frame, 100, {
        items = DestroyWindow.QualityItems(),
        value = 4,
        onChange = function(value)
            view:ChangeRules(function(config)
                config.maxQuality = value
                config.minQuality = math.min(config.minQuality, value)
            end)
        end,
    })
    maxDrop:SetPoint("LEFT", toLabel, "RIGHT", 6, 0)

    -- Rules, row 2: the level rule and the unequippable rule.
    local levelCheck = Kit.Check(frame, "Required level at most your level minus", function(on)
        view:ChangeRules(function(config)
            config.levelRule = on
        end)
    end)
    levelCheck:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD - 4, -66)
    local gapInput = Kit.NumberInput(frame, 30, {
        min = 0,
        max = 80,
        onChange = function(number)
            if number then
                view:ChangeRules(function(config)
                    config.levelGap = number
                end)
            end
        end,
    })
    gapInput:SetPoint("LEFT", levelCheck, "RIGHT", 250, 0)
    local equipCheck = Kit.Check(frame, "Your class cannot equip it", function(on)
        view:ChangeRules(function(config)
            config.unequippableRule = on
        end)
    end)
    equipCheck:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD - 4, -90)

    -- The two tabs.
    local itemsTab = Kit.Button(frame, "Items", 90, function()
        view:SetMode(MODE_ITEMS)
    end)
    itemsTab:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -122)
    local ignoredTab = Kit.Button(frame, "Ignored", 90, function()
        view:SetMode(MODE_IGNORED)
    end)
    ignoredTab:SetPoint("LEFT", itemsTab, "RIGHT", 6, 0)
    local countLabel = Kit.Label(frame, "", "small")
    countLabel:SetPoint("LEFT", ignoredTab, "RIGHT", 12, 0)

    -- The list of matching items. A click on a row selects it.
    local list = Kit.CreateList(frame, {
        rowHeight = ROW_HEIGHT,
        inset = true,
        retainScroll = true,
        initRow = function(row, data)
            if not row.destroy then
                local cells = {}
                cells.select = row:CreateTexture(nil, "BACKGROUND")
                cells.select:SetAllPoints(row)
                cells.select:SetColorTexture(1, 1, 1, 0.15)
                cells.icon = row:CreateTexture(nil, "ARTWORK")
                cells.icon:SetSize(16, 16)
                cells.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
                cells.slot = Kit.Label(row, "", "small")
                cells.slot:SetPoint("RIGHT", row, "RIGHT", -6, 0)
                cells.slot:SetWidth(50)
                cells.slot:SetJustifyH("RIGHT")
                cells.level = Kit.Label(row, "", "small")
                cells.level:SetPoint("RIGHT", cells.slot, "LEFT", -8, 0)
                cells.level:SetWidth(40)
                cells.level:SetJustifyH("RIGHT")
                cells.name = Kit.Label(row, "", "normal")
                cells.name:SetPoint("LEFT", cells.icon, "RIGHT", 6, 0)
                cells.name:SetPoint("RIGHT", cells.level, "LEFT", -6, 0)
                cells.name:SetJustifyH("LEFT")
                if cells.name.SetWordWrap then
                    cells.name:SetWordWrap(false)
                end
                row.destroy = cells
                row:SetScript("OnClick", function(self)
                    view:Select(self.destroyData.key)
                end)
            end
            local cells = row.destroy
            row.destroyData = data
            cells.icon:SetTexture(data.icon)
            cells.name:SetText(coloured(Kit, data.quality, data.name))
            cells.level:SetText("Lv " .. data.minLevel)
            cells.slot:SetText(data.bag .. "/" .. data.slot)
            cells.select:SetShown(data.key == view.selectedKey)
        end,
    })
    list.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -150)
    list.frame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, 78)

    -- The list of ignored items. Each row has a Remove button.
    local ignoredList = Kit.CreateList(frame, {
        rowHeight = ROW_HEIGHT,
        inset = true,
        initRow = function(row, data)
            if not row.remove then
                row.label = Kit.Label(row, "", "normal")
                row.label:SetPoint("LEFT", row, "LEFT", 6, 0)
                row.remove = Kit.Button(row, "Remove", 70, function(self)
                    view:RemoveIgnored(self:GetParent().ignoredID)
                end)
                row.remove:SetHeight(18)
                row.remove:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            end
            row.ignoredID = data.itemID
            row.label:SetText(data.text)
        end,
    })
    ignoredList.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -150)
    ignoredList.frame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, 78)
    ignoredList.frame:Hide()

    -- The message line and the three actions.
    local status = Kit.Label(frame, "", "small")
    status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, 52)
    local destroyButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate, SecureActionButtonTemplate")
    destroyButton:SetSize(160, 24)
    destroyButton:SetText("Destroy")
    -- The clients use the key-down mode by default, so the button needs both click phases.
    destroyButton:RegisterForClicks("AnyUp", "AnyDown")
    destroyButton:SetAttribute("type", "macro")
    destroyButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, 16)
    -- Write the macro to the log before the secure handler runs. SetScript PreClick is not a hook.
    destroyButton:SetScript("PreClick", function(self)
        if deps.log then
            deps.log("macrotext: " .. tostring(self:GetAttribute("macrotext")) .. ", type: "
                .. tostring(self:GetAttribute("type")) .. ", enabled: " .. tostring(self:IsEnabled()))
        end
    end)
    local ignoreButton = Kit.Button(frame, "Ignore", 100, function()
        view:Ignore()
    end)
    ignoreButton:SetPoint("LEFT", destroyButton, "RIGHT", 8, 0)
    local skipButton = Kit.Button(frame, "Skip", 100, function()
        view:Skip()
    end)
    skipButton:SetPoint("LEFT", ignoreButton, "RIGHT", 8, 0)

    view.list, view.ignoredList, view.status = list, ignoredList, status
    view.destroyButton, view.ignoreButton, view.skipButton = destroyButton, ignoreButton, skipButton
    view.minDrop, view.maxDrop, view.levelCheck = minDrop, maxDrop, levelCheck
    view.gapInput, view.equipCheck = gapInput, equipCheck
    view.itemsTab, view.ignoredTab = itemsTab, ignoredTab

    -- The row that the actions use: the selected row, else the first row.
    function view:Current()
        for _, row in ipairs(self.rows) do
            if row.key == self.selectedKey then
                return row
            end
        end
        return self.rows[1]
    end

    -- Set the Destroy button for the current row. The client blocks a change of the attributes in combat.
    function view:UpdateAction()
        local row = self:Current()
        local spellName, known = deps.disenchant()
        local message, canDestroy
        if not (spellName and known) then
            message, canDestroy = "You do not know Disenchant.", false
        elseif deps.inCombat() then
            message, canDestroy = "Destroy is not possible in combat.", false
        elseif not row then
            message, canDestroy = "No item matches the rules.", false
        else
            canDestroy = true
            message = "Next: " .. coloured(Kit, row.quality, row.name) .. " in bag " .. row.bag .. ", slot " .. row.slot
            destroyButton:SetAttribute("macrotext", "/cast " .. spellName .. "\n/use " .. row.bag .. " " .. row.slot)
        end
        destroyButton:SetEnabled(canDestroy)
        ignoreButton:SetEnabled(row ~= nil)
        skipButton:SetEnabled(row ~= nil)
        status:SetText(message)
        return canDestroy
    end

    local function showControls(config)
        minDrop:SetValue(config.minQuality)
        maxDrop:SetValue(config.maxQuality)
        levelCheck:SetChecked(config.levelRule)
        gapInput:SetNumber(config.levelGap)
        equipCheck:SetChecked(config.unequippableRule)
    end

    local function refreshIgnored()
        local data = {}
        for _, itemID in ipairs(ns.DestroyRules.IgnoredIDs(store.Ignored())) do
            local info = deps.itemInfo(itemID)
            data[#data + 1] = {
                itemID = itemID,
                text = info and coloured(Kit, info.quality, info.name) or ("Item " .. itemID),
            }
        end
        view.ignoredRows = data
        ignoredList:SetData(data)
        return #data
    end

    local function scheduleRefresh()
        if pending or not frame:IsShown() then
            return
        end
        pending = true
        deps.after(REFRESH_DELAY, function()
            pending = false
            if frame:IsShown() then
                view:Refresh()
            end
        end)
    end

    -- Read the bags again and fill the lists.
    function view:Refresh()
        local config = store.Config()
        showControls(config)
        local rows, unknown = ns.DestroyRules.Rows(deps.readStacks(), deps.itemInfo, config, deps.player(),
            store.Ignored(), self.skipped)
        for itemID in pairs(unknown) do
            deps.requestInfo(itemID, function(_, _, state)
                if state == "loaded" then
                    scheduleRefresh()
                end
            end)
        end
        self.rows = rows
        list:SetData(rows)
        local ignoredCount = refreshIgnored()
        countLabel:SetText(#rows .. " to destroy, " .. ignoredCount .. " ignored")
        self:UpdateAction()
    end

    -- Change the saved rules: mutate(config) edits a copy. The list refreshes.
    function view:ChangeRules(mutate)
        local config = store.Config()
        mutate(config)
        store.SetConfig(config)
        self:Refresh()
    end

    function view:SetMode(mode)
        self.mode = mode
        list.frame:SetShown(mode == MODE_ITEMS)
        ignoredList.frame:SetShown(mode == MODE_IGNORED)
    end

    function view:Select(key)
        self.selectedKey = key
        list:SetData(self.rows)
        self:UpdateAction()
    end

    -- Add the current item to the saved ignore list.
    function view:Ignore()
        local row = self:Current()
        if not row then
            return false
        end
        if not store.SetIgnored(row.itemID, true) then
            deps.print("settings are read-only; the item was not ignored")
            return false
        end
        deps.print("ignored " .. (row.link or row.name))
        self:Refresh()
        return true
    end

    -- Hide the current item until /reload.
    function view:Skip()
        local row = self:Current()
        if not row then
            return false
        end
        self.skipped[row.key] = true
        self:Refresh()
        return true
    end

    function view:RemoveIgnored(itemID)
        store.SetIgnored(itemID, false)
        self:Refresh()
    end

    function view.Toggle()
        frame:Toggle()
    end

    frame:SetScript("OnShow", function()
        view:Refresh()
    end)
    deps.bus:Subscribe("BAG_UPDATE_DELAYED", "Flipside.DestroyWindow", scheduleRefresh)
    deps.bus:Subscribe("PLAYER_REGEN_DISABLED", "Flipside.DestroyWindow", function()
        if frame:IsShown() then
            view:UpdateAction()
        end
    end)
    deps.bus:Subscribe("PLAYER_REGEN_ENABLED", "Flipside.DestroyWindow", function()
        if frame:IsShown() then
            view:UpdateAction()
        end
    end)
    view:SetMode(MODE_ITEMS)
    return view
end

-- Return the window if it exists, else nil.
function DestroyWindow.Get()
    return instance
end

-- The items of the two quality drop-downs.
function DestroyWindow.QualityItems()
    local items = {}
    for index, item in ipairs(ns.DestroyRules.QUALITIES) do
        items[index] = { value = item.value, text = item.text }
    end
    return items
end
