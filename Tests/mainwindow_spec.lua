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
        deps = {
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
        assert.are.equal("Groups", win.frame.Tabs[1]:GetText())
        assert.are.equal("Operations", win.frame.Tabs[2]:GetText())
        assert.are.equal("Formulas", win.frame.Tabs[3]:GetText())
        assert.are.equal("About", win.frame.Tabs[4]:GetText())
    end)

    it("builds the pages with the deps when they are selected", function()
        local win = ns.MainWindow.Create(deps)
        assert.are.equal(1, #built)
        assert.are.equal("groups", built[1].page)
        assert.are.equal(deps, built[1].deps)
        win:SelectPage("operations")
        assert.are.equal("operations", built[2].page)
        assert.are.equal(deps, built[2].deps)
        win:SelectPage("formula")
        assert.are.equal(deps, built[3].deps)
    end)

    it("says that settings are missing on the rules pages when there are no rules", function()
        deps.rules = nil
        local win = ns.MainWindow.Create(deps)
        win:SelectPage("operations")
        assert.are.equal(0, #built)
        assert.is_true(strings["Settings are not available this session."])
    end)

    it("shows the About text", function()
        local win = ns.MainWindow.Create(deps)
        win:SelectPage("about")
        assert.is_true(strings["Flipside"])
        assert.is_true(strings["Client 1.60.1"])
        assert.is_true(strings["Groups sort items into trees. Operations hold the rules. "
            .. "Formulas check and save price formulas."])
    end)

    it("selects pages", function()
        local win = ns.MainWindow.Create(deps)
        assert.are.equal("groups", win.tabs:GetSelected())
        win:SelectPage("about")
        assert.are.equal("about", win.tabs:GetSelected())
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
