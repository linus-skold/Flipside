local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local KIT = { "Theme", "Window", "Widgets", "Tabs", "List", "Combat" }

local function load()
    local ns = {}
    for _, name in ipairs(KIT) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    assert(loadfile(manifest.path("MainWindow")))("Flipside", ns)
    return ns
end

describe("MainWindow", function()
    local ns, built, deps, strings

    before_each(function()
        mock.reset()
        local methods = getmetatable(CreateFrame("Frame")).__index
        methods.SetJustifyH = function() end
        strings = {}
        local create = _G.CreateFrame
        _G.CreateFrame = function(...)
            local f = create(...)
            local make = f.CreateFontString
            f.CreateFontString = function(self, ...)
                local fs = make(self, ...)
                local setText = fs.SetText
                fs.SetText = function(s, text)
                    strings[text] = true
                    setText(s, text)
                end
                return fs
            end
            return f
        end
        ns = load()
        built = {}
        ns.FormulaPage = {
            Build = function(content, d)
                table.insert(built, { content = content, deps = d })
            end,
        }
        ns.GroupsPage = {
            Build = function(content, d)
                table.insert(built, { page = "groups", content = content, deps = d })
            end,
        }
        ns.OperationsPage = {
            Build = function(content, d)
                table.insert(built, { page = "operations", content = content, deps = d })
            end,
        }
        ns.LedgerPage = {
            Build = function(content, d)
                table.insert(built, { page = "ledger", content = content, deps = d })
                return { Open = function() end }
            end,
        }
        ns.TooltipPage = {
            Build = function(content, d)
                table.insert(built, { page = "tooltip", content = content, deps = d })
                return {}
            end,
        }
        deps = {
            tooltipConfig = {},
            rules = {},
            formulaRun = {},
            getVersionLine = function()
                return "Client 1.60.1"
            end,
        }
    end)

    after_each(function()
        mock.teardown()
    end)

    it("creates the window once", function()
        local first = ns.MainWindow.Create(deps)
        assert.are.equal(first, ns.MainWindow.Create(deps))
        local count = 0
        for _, f in ipairs(mock.frames) do
            if f.name == "FlipsideMainWindow" then
                count = count + 1
            end
        end
        assert.are.equal(1, count)
    end)

    it("has the size and the title", function()
        local win = ns.MainWindow.Create(deps)
        assert.are.equal(800, win.frame.width)
        assert.are.equal(540, win.frame.height)
        assert.are.equal("Flipside", win.frame.title)
    end)

    it("uses a client icon as the portrait", function()
        local win = ns.MainWindow.Create(deps)
        assert.are.equal("Interface\\Icons\\INV_Misc_Coin_02", win.frame.portrait)
    end)

    it("has four page tabs", function()
        local win = ns.MainWindow.Create(deps)
        assert.are.equal(4, #win.frame.Tabs)
        assert.are.equal("Ledger", win.frame.Tabs[1]:GetText())
        assert.are.equal("Groups", win.frame.Tabs[2]:GetText())
        assert.are.equal("Operations", win.frame.Tabs[3]:GetText())
        assert.are.equal("Tooltip", win.frame.Tabs[4]:GetText())
    end)

    it("builds the pages with the deps when they are selected", function()
        local win = ns.MainWindow.Create(deps)
        assert.are.equal(1, #built)
        assert.are.equal("ledger", built[1].page)
        win:SelectPage("groups")
        assert.are.equal("groups", built[2].page)
        assert.are.equal(deps, built[2].deps)
        win:SelectPage("operations")
        assert.are.equal("operations", built[3].page)
        assert.are.equal(deps, built[3].deps)
    end)

    describe("resize", function()
        local function screen(width, height)
            local parent = _G.UIParent
            rawset(parent, "GetWidth", function() return width end)
            rawset(parent, "GetHeight", function() return height end)
        end

        it("sets the bounds, 800 x 540 up to the screen size", function()
            screen(1920, 1080)
            local win = ns.MainWindow.Create(deps)
            assert.is_true(win.frame.resizable)
            assert.are.same({ 800, 540, 1920, 1080 }, win.frame.resizeBounds)
            assert.is_not_nil(win.frame.ResizeGrip)
        end)

        it("uses SetMinResize and SetMaxResize on an older client", function()
            screen(1920, 1080)
            local methods = getmetatable(CreateFrame("Frame")).__index
            methods.SetResizeBounds = nil
            local calls = {}
            methods.SetMinResize = function(_, w, h)
                calls.min = { w, h }
            end
            methods.SetMaxResize = function(_, w, h)
                calls.max = { w, h }
            end
            ns.MainWindow.Create(deps)
            assert.are.same({ 800, 540 }, calls.min)
            assert.are.same({ 1920, 1080 }, calls.max)
        end)

        it("saves the size when the grip is released", function()
            local saved
            deps.windowSize = { get = function() end, set = function(size) saved = size end }
            local win = ns.MainWindow.Create(deps)
            local grip = win.frame.ResizeGrip
            grip.scripts.OnMouseDown(grip)
            assert.are.equal("BOTTOMRIGHT", win.frame.sizing)
            win.frame:SetSize(900, 600)
            grip.scripts.OnMouseUp(grip)
            assert.is_nil(win.frame.sizing)
            assert.are.same({ width = 900, height = 600 }, saved)
        end)

        it("restores the saved size and keeps it inside the bounds", function()
            screen(1920, 1080)
            deps.windowSize = { get = function() return { width = 1000, height = 700 } end, set = function() end }
            local win = ns.MainWindow.Create(deps)
            assert.are.equal(1000, win.frame.width)
            assert.are.equal(700, win.frame.height)
        end)

        it("clamps a saved size that is too small or too big", function()
            screen(1920, 1080)
            deps.windowSize = { get = function() return { width = 100, height = 5000 } end, set = function() end }
            local win = ns.MainWindow.Create(deps)
            assert.are.equal(800, win.frame.width)
            assert.are.equal(1080, win.frame.height)
        end)
    end)

    describe("settings view", function()
        it("opens with the cog and closes with a second click", function()
            local win = ns.MainWindow.Create(deps)
            assert.is_false(win.settings:IsShown())
            win.cog.scripts.OnClick(win.cog)
            assert.is_true(win.settings:IsShown())
            assert.are.equal("settings", win:GetSelectedPage())
            assert.is_false(win.tabs.contents[1]:IsShown())
            win.cog.scripts.OnClick(win.cog)
            assert.is_false(win.settings:IsShown())
            assert.is_true(win.tabs.contents[1]:IsShown())
            assert.are.equal("ledger", win:GetSelectedPage())
        end)

        it("puts the cog above the title container", function()
            local win = ns.MainWindow.Create(deps)
            assert.are.equal(510, win.frame.TitleContainer:GetFrameLevel())
            assert.is_true(win.cog:GetFrameLevel() > win.frame.TitleContainer:GetFrameLevel())
        end)

        it("closes when a main tab is clicked", function()
            local win = ns.MainWindow.Create(deps)
            win.cog.scripts.OnClick(win.cog)
            win.frame.Tabs[2].scripts.OnClick(win.frame.Tabs[2])
            assert.is_false(win.settings:IsShown())
            assert.are.equal("groups", win:GetSelectedPage())
            assert.is_true(win.tabs.contents[2]:IsShown())
        end)

        it("has the sub-tabs Formulas and About", function()
            local win = ns.MainWindow.Create(deps)
            assert.are.equal("Formulas", win.settingsTabs.buttons[1]:GetText())
            assert.are.equal("About", win.settingsTabs.buttons[2]:GetText())
        end)

        it("builds the Formulas page on the first open", function()
            local win = ns.MainWindow.Create(deps)
            assert.are.equal(1, #built)
            win.cog.scripts.OnClick(win.cog)
            assert.are.equal(2, #built)
            assert.are.equal(deps, built[2].deps)
            win.cog.scripts.OnClick(win.cog)
            win.cog.scripts.OnClick(win.cog)
            assert.are.equal(2, #built)
        end)

        it("shows the About text", function()
            local win = ns.MainWindow.Create(deps)
            win:SelectPage("about")
            assert.are.equal("settings", win:GetSelectedPage())
            assert.are.equal("about", win.settingsTabs:GetSelected())
            assert.is_true(strings["Flipside"])
            assert.is_true(strings["Client 1.60.1"])
            assert.is_true(strings["Groups sort items into trees. Operations hold the rules. "
                .. "Formulas check and save price formulas."])
        end)
    end)

    it("says that settings are missing on the rules pages when there are no rules", function()
        deps.rules = nil
        local win = ns.MainWindow.Create(deps)
        win:SelectPage("operations")
        assert.are.equal(1, #built)
        assert.are.equal("ledger", built[1].page)
        assert.is_true(strings["Settings are not available this session."])
    end)

    it("selects pages", function()
        local win = ns.MainWindow.Create(deps)
        assert.are.equal("ledger", win.tabs:GetSelected())
        win:SelectPage("tooltip")
        assert.are.equal("tooltip", win.tabs:GetSelected())
        assert.is_false(win.tabs.contents[1]:IsShown())
        assert.is_true(win.tabs.contents[4]:IsShown())
    end)

    it("shows, hides and toggles", function()
        local win = ns.MainWindow.Create(deps)
        assert.is_false(win:IsShown())
        win:Show()
        assert.is_true(win:IsShown())
        win:Hide()
        assert.is_false(win:IsShown())
        win:Toggle()
        assert.is_true(win:IsShown())
        win:Toggle()
        assert.is_false(win:IsShown())
    end)
end)
