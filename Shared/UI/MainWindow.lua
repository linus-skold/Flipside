local _, ns = ...

-- The Flipside window: page tabs along the bottom edge (Ledger, Groups, Operations, Lists, Tooltip, Formulas, About).

local MainWindow = {}
ns.MainWindow = MainWindow

local instance

local MIN_WIDTH, MIN_HEIGHT = 800, 540

-- The window if it exists, or nil.
function MainWindow.Get()
    return instance
end

local ABOUT_TEXT = "Groups sort items into trees. Operations hold the rules. Formulas check and save price formulas."

local SOUNDS_TEXT = "Play interface sounds"
local SHARE_TEXT = "Share prices with my guild"
local JUMP_TEXT = "Buying price jump warning %"
local MARKET_TEXT = "Buying market value source (formula)"
local GROUP_TEXT = "Share prices with my group"
local SHARE_HINT = "Off by default. Guild or group members share scan prices. Your own scans win over shared prices."

-- A page that says why it cannot open.
local function buildUnavailable(content)
    local label = ns.Kit.Label(content, "Settings are not available this session.", "bad")
    label:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
end

local function buildAbout(content, deps)
    local Kit = ns.Kit
    local title = Kit.Label(content, "Flipside", "title")
    title:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    local version = Kit.Label(content, deps.getVersionLine and deps.getVersionLine() or "", "normal")
    version:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -Kit.Theme.gap)
    local note = Kit.Label(content, ABOUT_TEXT, "highlight")
    note:SetPoint("TOPLEFT", version, "BOTTOMLEFT", 0, -Kit.Theme.gap * 2)
    local logButton = Kit.Button(content, "Open log", 120, function()
        if deps.openLog then
            deps.openLog()
        end
    end)
    logButton:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -Kit.Theme.gap * 2)
    local about = { title = title, version = version, note = note, logButton = logButton }
    local anchor = logButton
    local sounds = deps.sounds
    if sounds then
        local soundCheck = Kit.Check(content, SOUNDS_TEXT, function(checked)
            if not sounds.setEnabled(checked) then
                about.soundCheck:SetChecked(sounds.isEnabled())
            end
        end)
        soundCheck:SetPoint("TOPLEFT", logButton, "BOTTOMLEFT", 0, -Kit.Theme.gap * 2)
        soundCheck:SetChecked(sounds.isEnabled())
        about.soundCheck = soundCheck
        anchor = soundCheck
    end
    local sync = deps.guildSync
    if sync then
        local check = Kit.Check(content, SHARE_TEXT, function(checked)
            if not sync.setEnabled(checked) then
                about.shareCheck:SetChecked(sync.isEnabled())
            end
        end)
        check:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -Kit.Theme.gap * 2)
        check:SetChecked(sync.isEnabled())
        about.shareCheck = check
        local hintAnchor = check
        if sync.setGroupEnabled then
            local groupCheck = Kit.Check(content, GROUP_TEXT, function(checked)
                if not sync.setGroupEnabled(checked) then
                    about.groupCheck:SetChecked(sync.isGroupEnabled())
                end
            end)
            groupCheck:SetPoint("TOPLEFT", check, "BOTTOMLEFT", 0, -Kit.Theme.gap)
            groupCheck:SetChecked(sync.isGroupEnabled())
            about.groupCheck = groupCheck
            hintAnchor = groupCheck
        end
        local hint = Kit.Label(content, SHARE_HINT, "highlight")
        hint:SetPoint("TOPLEFT", hintAnchor, "BOTTOMLEFT", 4, -Kit.Theme.gap)
        about.shareHint = hint
        anchor = hint
    end
    -- The price jump warning of the Buying tab: the percent of rise between two price levels that asks first.
    local Buying = ns.BuyingTab
    if deps.db and Buying and Buying.ReadJumpPercent then
        local label = Kit.Label(content, JUMP_TEXT, "normal")
        label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", anchor == about.shareHint and -4 or 0, -Kit.Theme.gap * 2)
        local input = Kit.NumberInput(content, 36, {
            min = 1, max = 1000, hint = "1 - 1000",
            onChange = function(number)
                Buying.WriteJumpPercent(deps.db, number)
            end,
        })
        input:SetPoint("LEFT", label, "RIGHT", 6, 0)
        input:SetJustifyH("CENTER")
        input:SetNumber(Buying.ReadJumpPercent(deps.db))
        about.jumpLabel, about.jumpInput = label, input
        anchor = label
    end
    -- The market value of the Buying tab: the formula that gives the 100% of the % MV column.
    if deps.db and Buying and Buying.ReadMarketSource then
        local label = Kit.Label(content, MARKET_TEXT, "normal")
        label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", anchor == about.shareHint and -4 or 0, -Kit.Theme.gap * 2)
        local status = Kit.Label(content, "", "bad")
        -- The text that is saved now. Enter, then the focus loss, must save one time.
        local saved = Buying.ReadMarketSource(deps.db)
        local function save(text)
            text = text:match("^%s*(.-)%s*$")
            if text == "" then
                text = Buying.DEFAULT_MARKET_SOURCE
            end
            if text == saved then
                about.marketInput:SetText(text)
                return
            end
            local run = deps.formulaRun
            local _, err
            if run and run.Compile then
                _, err = run:Compile(text)
            end
            if err then
                status:SetText(err.message or "formula error")
                return
            end
            status:SetText("")
            about.marketInput:SetText(text)
            Buying.WriteMarketSource(deps.db, text)
            saved = text
        end
        local input = Kit.Input(content, 260, save, save)
        input:SetPoint("LEFT", label, "RIGHT", 6, 0)
        input:SetText(saved)
        -- A profile change gives another value: read the setting again when the box gets the focus.
        input:SetScript("OnEditFocusGained", function(box)
            saved = Buying.ReadMarketSource(deps.db)
            box:SetText(saved)
            status:SetText("")
        end)
        status:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -Kit.Theme.gap)
        about.marketLabel, about.marketInput, about.marketStatus = label, input, status
    end
    return about
end

-- Create the window once. deps: rules, customSources, readBags, keyFor, subscribe, formulaRun, formulaSources,
-- itemCache, itemNameIndex, searchLists (the Lists page), getVersionLine, guildSync ({ isEnabled, setEnabled }),
-- windowPosition and windowSize ({ get, set } for the saved place and size).
function MainWindow.Create(deps)
    if instance then
        return instance
    end
    deps = deps or {}
    local Kit = ns.Kit
    local window = Kit.CreateWindow("FlipsideMainWindow", {
        width = 800,
        height = 540,
        title = "Flipside",
        portrait = "Interface\\Icons\\INV_Misc_Coin_02",
        savePosition = deps.windowPosition,
        resize = {
            minWidth = MIN_WIDTH,
            minHeight = MIN_HEIGHT,
            get = deps.windowSize and deps.windowSize.get,
            set = deps.windowSize and deps.windowSize.set,
        },
    })
    local tooltipPage, ledgerPage, listsPage, justBuilt
    local pages = {}
    if ns.LedgerPage then
        table.insert(pages, {
            key = "ledger",
            title = "Ledger",
            build = function(content)
                ledgerPage = ns.LedgerPage.Build(content, deps)
                justBuilt = true
            end,
        })
    end
    local rest = {
        {
            key = "groups",
            title = "Groups",
            build = function(content)
                if deps.rules then
                    ns.GroupsPage.Build(content, deps)
                else
                    buildUnavailable(content)
                end
            end,
        },
        {
            key = "operations",
            title = "Operations",
            build = function(content)
                if deps.rules then
                    ns.OperationsPage.Build(content, deps)
                else
                    buildUnavailable(content)
                end
            end,
        },
    }
    for _, page in ipairs(rest) do
        table.insert(pages, page)
    end
    if ns.ListsPage then
        table.insert(pages, {
            key = "lists",
            title = "Lists",
            build = function(content)
                if deps.searchLists then
                    listsPage = ns.ListsPage.Build(content, deps)
                else
                    buildUnavailable(content)
                end
            end,
        })
    end
    if ns.TooltipPage then
        table.insert(pages, {
            key = "tooltip",
            title = "Tooltip",
            build = function(content)
                if deps.tooltipConfig then
                    tooltipPage = ns.TooltipPage.Build(content, deps)
                else
                    buildUnavailable(content)
                end
            end,
        })
    end
    table.insert(pages, {
        key = "formula",
        title = "Formulas",
        build = function(content)
            ns.FormulaPage.Build(content, deps)
        end,
    })
    table.insert(pages, {
        key = "about",
        title = "About",
        build = function(content)
            buildAbout(content, deps)
        end,
    })
    -- The page loads the ledger each time it opens; the first open is in its build.
    local function openLedger()
        if justBuilt then
            justBuilt = false
        elseif ledgerPage then
            ledgerPage.Open()
        end
    end
    local flavour = ns.Flavour or {}
    local tabs = Kit.CreatePageTabs(window, pages, { template = flavour.pageTabTemplate })
    for index, page in ipairs(pages) do
        if page.key == "tooltip" then
            tabs.buttons[index]:HookScript("OnClick", function()
                if tooltipPage and tooltipPage.Refresh then
                    tooltipPage.Refresh()
                end
            end)
        elseif page.key == "lists" then
            -- Live prices and scan data change while the page is closed.
            tabs.buttons[index]:HookScript("OnClick", function()
                if listsPage and listsPage.Refresh then
                    listsPage.Refresh()
                end
            end)
        elseif page.key == "ledger" then
            tabs.buttons[index]:HookScript("OnClick", openLedger)
            window:HookScript("OnShow", function()
                if tabs:GetSelected() == "ledger" then
                    openLedger()
                end
            end)
        end
    end
    local win = { frame = window, tabs = tabs }
    function win:Show()
        self.frame:Show()
    end
    function win:Hide()
        self.frame:Hide()
    end
    function win:Toggle()
        self.frame:Toggle()
    end
    function win:IsShown()
        return self.frame:IsShown() and true or false
    end
    function win:SelectPage(key)
        local before = self.tabs:GetSelected()
        self.tabs:Select(key)
        if key == "ledger" and before ~= "ledger" and self.tabs:GetSelected() == "ledger" then
            openLedger()
        end
    end
    -- Show the window on the Lists page. If id is a list, select it. The Buying tab uses it (Edit lists).
    function win:OpenLists(id)
        self:Show()
        self:SelectPage("lists")
        if listsPage and not (id and listsPage.Select(id)) then
            listsPage.Refresh()
        end
    end
    function win:GetSelectedPage()
        return self.tabs:GetSelected()
    end
    function win:ResetPosition()
        self.frame:ResetPosition()
    end
    instance = win
    return win
end
