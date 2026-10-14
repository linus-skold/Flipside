local _, ns = ...

-- The Flipside window: page tabs along the bottom edge.

local MainWindow = {}
ns.MainWindow = MainWindow

local instance

local function buildAbout(content, deps)
    local Kit = ns.Kit
    local title = Kit.Label(content, "Flipside", "title")
    title:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    local version = Kit.Label(content, deps.getVersionLine and deps.getVersionLine() or "", "normal")
    version:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -Kit.Theme.gap)
    local note = Kit.Label(content, "Groups and operations come with the next update.", "highlight")
    note:SetPoint("TOPLEFT", version, "BOTTOMLEFT", 0, -Kit.Theme.gap * 2)
    return { title = title, version = version, note = note }
end

-- Create the window once. deps: formulaRun, formulaSources, itemCache, getVersionLine.
function MainWindow.Create(deps)
    if instance then
        return instance
    end
    deps = deps or {}
    local Kit = ns.Kit
    local window = Kit.CreateWindow("FlipsideMainWindow", { width = 800, height = 540, title = "Flipside" })
    local tabs = Kit.CreatePageTabs(window, {
        {
            key = "formula",
            title = "Formulas",
            build = function(content)
                ns.FormulaPage.Build(content, deps)
            end,
        },
        {
            key = "about",
            title = "About",
            build = function(content)
                buildAbout(content, deps)
            end,
        },
    })
    local win = { frame = window, tabs = tabs }
    function win:Show()
        window:Show()
    end
    function win:Hide()
        window:Hide()
    end
    function win:Toggle()
        window:Toggle()
    end
    function win:IsShown()
        return window:IsShown() and true or false
    end
    function win:SelectPage(key)
        tabs:Select(key)
    end
    instance = win
    return win
end
