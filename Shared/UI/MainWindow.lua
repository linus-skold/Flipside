local _, ns = ...

-- The Flipside window: page tabs along the bottom edge.

local MainWindow = {}
ns.MainWindow = MainWindow

local instance

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
-- itemCache, itemNameIndex, getVersionLine, windowPosition ({ get, set } for the saved position).
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
    function win:GetSelectedPage()
        return self.tabs:GetSelected()
    end
    function win:ResetPosition()
        self.frame:ResetPosition()
    end
    instance = win
    return win
end
