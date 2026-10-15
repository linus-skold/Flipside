local _, ns = ...

-- The Flipside window: page tabs along the bottom edge.

local MainWindow = {}
ns.MainWindow = MainWindow

local instance

local MIN_WIDTH, MIN_HEIGHT = 800, 540
local COG_ICON = "Interface\\Buttons\\UI-OptionsButton"

-- The window if it exists, or nil.
function MainWindow.Get()
    return instance
end

local ABOUT_TEXT = "Groups sort items into trees. Operations hold the rules. Formulas check and save price formulas."

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
    return { title = title, version = version, note = note }
end

-- Create the window once. deps: rules, customSources, readBags, keyFor, subscribe, formulaRun, formulaSources,
-- itemCache, itemNameIndex, getVersionLine, windowPosition and windowSize ({ get, set } for the saved place and size).
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
    local tooltipPage, ledgerPage, justBuilt
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
    -- The page loads the ledger each time it opens; the first open is in its build.
    local function openLedger()
        if justBuilt then
            justBuilt = false
        elseif ledgerPage then
            ledgerPage.Open()
        end
    end
    local tabs = Kit.CreatePageTabs(window, pages)
    for index, page in ipairs(pages) do
        if page.key == "tooltip" then
            tabs.buttons[index]:HookScript("OnClick", function()
                if tooltipPage and tooltipPage.Refresh then
                    tooltipPage.Refresh()
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
    -- The settings view (Formulas, About) opens over the page with the cog button in the title bar.
    local settings = CreateFrame("Frame", nil, window)
    settings:SetAllPoints(tabs.contents[1])
    settings:Hide()
    local settingsTabs = Kit.CreateTopTabs(settings, {
        { key = "formula", title = "Formulas" },
        { key = "about", title = "About" },
    })
    local settingsBuilt = false
    local function showSettings(key)
        if not settingsBuilt then
            settingsBuilt = true
            ns.FormulaPage.Build(settingsTabs:GetContent("formula"), deps)
            buildAbout(settingsTabs:GetContent("about"), deps)
        end
        for _, content in ipairs(tabs.contents) do
            content:Hide()
        end
        settings:Show()
        if key then
            settingsTabs:Select(key)
        end
    end
    local function hideSettings()
        if not settings:IsShown() then
            return
        end
        settings:Hide()
        local selected = tabs:GetSelected()
        for index, page in ipairs(pages) do
            tabs.contents[index]:SetShown(page.key == selected)
        end
    end
    for _, button in ipairs(tabs.buttons) do
        button:HookScript("OnClick", hideSettings)
    end
    local cog = CreateFrame("Button", nil, window)
    cog:SetSize(20, 20)
    if window.CloseButton then
        cog:SetPoint("RIGHT", window.CloseButton, "LEFT", -2, 0)
    else
        cog:SetPoint("TOPRIGHT", window, "TOPRIGHT", -30, -4)
    end
    -- The title container takes mouse clicks, so the cog must sit above it.
    cog:SetFrameLevel((window.TitleContainer or window):GetFrameLevel() + 10)
    cog:SetNormalTexture(COG_ICON)
    cog:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    cog:SetScript("OnClick", function()
        if settings:IsShown() then
            hideSettings()
        else
            showSettings()
        end
    end)

    local win = { frame = window, tabs = tabs, settings = settings, settingsTabs = settingsTabs, cog = cog }
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
        if key == "formula" or key == "about" then
            showSettings(key)
            return
        end
        hideSettings()
        local before = self.tabs:GetSelected()
        self.tabs:Select(key)
        if key == "ledger" and before ~= "ledger" and self.tabs:GetSelected() == "ledger" then
            openLedger()
        end
    end
    function win:GetSelectedPage()
        if settings:IsShown() then
            return "settings"
        end
        return self.tabs:GetSelected()
    end
    function win:ResetPosition()
        self.frame:ResetPosition()
    end
    instance = win
    return win
end
