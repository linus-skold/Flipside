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
    local ns, built, deps, strings, listsPage

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
        listsPage = { refreshed = 0, selected = {} }
        ns.ListsPage = {
            Build = function(content, d)
                table.insert(built, { page = "lists", content = content, deps = d })
                return {
                    Refresh = function()
                        listsPage.refreshed = listsPage.refreshed + 1
                    end,
                    Select = function(id)
                        table.insert(listsPage.selected, id)
                        return id == 7
                    end,
                }
            end,
        }
        deps = {
            searchLists = {},
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

    it("has seven page tabs, with Lists after Operations", function()
        local win = ns.MainWindow.Create(deps)
        assert.are.equal(7, #win.frame.Tabs)
        assert.are.equal("Ledger", win.frame.Tabs[1]:GetText())
        assert.are.equal("Groups", win.frame.Tabs[2]:GetText())
        assert.are.equal("Operations", win.frame.Tabs[3]:GetText())
        assert.are.equal("Lists", win.frame.Tabs[4]:GetText())
        assert.are.equal("Tooltip", win.frame.Tabs[5]:GetText())
    end)

    describe("Lists page", function()
        it("builds with the deps when it is selected", function()
            local win = ns.MainWindow.Create(deps)
            assert.are.equal(1, #built)
            win:SelectPage("lists")
            assert.are.equal("lists", built[2].page)
            assert.are.equal(deps, built[2].deps)
            assert.are.equal("lists", win:GetSelectedPage())
        end)

        it("says that settings are missing without the lists object", function()
            deps.searchLists = nil
            local win = ns.MainWindow.Create(deps)
            win:SelectPage("lists")
            assert.are.equal(1, #built)
            assert.is_true(strings["Settings are not available this session."])
        end)

        it("draws the page again when its tab is clicked", function()
            local win = ns.MainWindow.Create(deps)
            win:SelectPage("lists")
            local before = listsPage.refreshed
            win.frame.Tabs[4].scripts.OnClick(win.frame.Tabs[4])
            assert.are.equal(before + 1, listsPage.refreshed)
        end)

        it("opens on the Lists page with the list selected, from OpenLists", function()
            local win = ns.MainWindow.Create(deps)
            win:OpenLists(7)
            assert.is_true(win:IsShown())
            assert.are.equal("lists", win:GetSelectedPage())
            assert.are.same({ 7 }, listsPage.selected)
            local before = listsPage.refreshed
            win:OpenLists(99)
            assert.are.same({ 7, 99 }, listsPage.selected)
            assert.are.equal(before + 1, listsPage.refreshed)
        end)

        it("is not a tab when the page module is missing", function()
            ns.ListsPage = nil
            local win = ns.MainWindow.Create(deps)
            assert.are.equal(6, #win.frame.Tabs)
        end)
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

    it("has an Open log button on the About page", function()
        local opened = 0
        deps.openLog = function()
            opened = opened + 1
        end
        local win = ns.MainWindow.Create(deps)
        win:SelectPage("about")
        local button
        for _, object in ipairs(mock.objects) do
            if object.kind == "Button" and object:GetText() == "Open log" then
                button = object
            end
        end
        assert.is_not_nil(button)
        button.scripts.OnClick(button)
        assert.are.equal(1, opened)
    end)

    it("shows the sounds check on the About page and saves a click", function()
        local on = true
        deps.sounds = {
            isEnabled = function()
                return on
            end,
            setEnabled = function(value)
                on = value
                return true
            end,
        }
        local win = ns.MainWindow.Create(deps)
        win:SelectPage("about")
        local check
        for _, object in ipairs(mock.objects) do
            local text = object.kind == "CheckButton" and object.Text and object.Text:GetText()
            if text == "Play interface sounds" then
                check = object
            end
        end
        assert.is_not_nil(check)
        assert.is_true(check:GetChecked())
        check:SetChecked(false)
        check.scripts.OnClick(check)
        assert.is_false(on)
    end)

    describe("price jump warning on the About page", function()
        local written

        local function findInput()
            for _, object in ipairs(mock.objects) do
                if object.kind == "EditBox" and object.SetNumber then
                    return object
                end
            end
        end

        before_each(function()
            written = nil
            ns.BuyingTab = {
                ReadJumpPercent = function()
                    return 25
                end,
                WriteJumpPercent = function(db, value)
                    written = { db = db, value = value }
                    return true
                end,
            }
            deps.db = {}
        end)

        it("shows the saved percent and saves a change", function()
            local win = ns.MainWindow.Create(deps)
            win:SelectPage("about")
            assert.is_true(strings["Buying price jump warning %"])
            local input = findInput()
            assert.is_not_nil(input)
            assert.are.equal("25", input:GetText())
            input:SetText("40")
            input.scripts.OnEnterPressed(input)
            assert.are.same({ db = deps.db, value = 40 }, written)
        end)

        it("is not there with no settings database", function()
            deps.db = nil
            local win = ns.MainWindow.Create(deps)
            win:SelectPage("about")
            assert.is_nil(findInput())
        end)
    end)

    describe("market value source on the About page", function()
        local written

        -- The text box of the formula: the only box that is not a number box.
        local function findInput()
            for _, object in ipairs(mock.objects) do
                if object.kind == "EditBox" and not object.SetNumber then
                    return object
                end
            end
        end

        local function enter(input, text)
            input:SetText(text)
            input.scripts.OnEnterPressed(input)
        end

        before_each(function()
            written = nil
            ns.BuyingTab = {
                DEFAULT_MARKET_SOURCE = "scanmarket",
                ReadMarketSource = function()
                    return "tsmmarket"
                end,
                WriteMarketSource = function(db, text)
                    written = { db = db, text = text }
                    return true
                end,
            }
            deps.db = {}
            deps.formulaRun = {
                Compile = function(_, text)
                    if text == "bad(" then
                        return nil, { message = "syntax error" }
                    end
                    return {}
                end,
            }
        end)

        it("shows the saved formula and saves a valid change", function()
            local win = ns.MainWindow.Create(deps)
            win:SelectPage("about")
            assert.is_true(strings["Buying market value source (formula)"])
            local input = findInput()
            assert.is_not_nil(input)
            assert.are.equal("tsmmarket", input:GetText())
            enter(input, "scanmarket * 2")
            assert.are.same({ db = deps.db, text = "scanmarket * 2" }, written)
        end)

        it("saves one time for Enter and the focus loss that follows", function()
            local writes = 0
            ns.BuyingTab.WriteMarketSource = function(db, text)
                writes = writes + 1
                written = { db = db, text = text }
                return true
            end
            local win = ns.MainWindow.Create(deps)
            win:SelectPage("about")
            local input = findInput()
            enter(input, "scanmarket * 2")
            input.scripts.OnEditFocusLost(input)
            assert.are.equal(1, writes)
        end)

        it("reads the setting again when the box gets the focus", function()
            local win = ns.MainWindow.Create(deps)
            win:SelectPage("about")
            local input = findInput()
            input:SetText("typed")
            input.scripts.OnEditFocusGained(input)
            assert.are.equal("tsmmarket", input:GetText())
        end)

        it("does not save a formula that does not compile", function()
            local win = ns.MainWindow.Create(deps)
            win:SelectPage("about")
            enter(findInput(), "bad(")
            assert.is_nil(written)
        end)

        it("goes back to the default for an empty formula", function()
            local win = ns.MainWindow.Create(deps)
            win:SelectPage("about")
            enter(findInput(), "   ")
            assert.are.same({ db = deps.db, text = "scanmarket" }, written)
        end)

        it("is not there with no settings database", function()
            deps.db = nil
            local win = ns.MainWindow.Create(deps)
            win:SelectPage("about")
            assert.is_nil(findInput())
        end)
    end)

    describe("guild sharing check on the About page", function()
        local enabled, changes

        local function findCheck()
            for _, object in ipairs(mock.objects) do
                local text = object.kind == "CheckButton" and object.Text and object.Text:GetText()
                if text == "Share prices with my guild" then
                    return object
                end
            end
        end

        before_each(function()
            enabled, changes = false, 0
            deps.guildSync = {
                isEnabled = function()
                    return enabled
                end,
                setEnabled = function(on)
                    changes = changes + 1
                    enabled = on
                    return true
                end,
            }
        end)

        it("shows the saved setting and saves a click", function()
            enabled = true
            local win = ns.MainWindow.Create(deps)
            win:SelectPage("about")
            local check = findCheck()
            assert.is_not_nil(check)
            assert.is_true(check:GetChecked())
            check:SetChecked(false)
            check.scripts.OnClick(check)
            assert.are.equal(1, changes)
            assert.is_false(enabled)
        end)

        it("goes back to the saved value when the setting cannot change", function()
            deps.guildSync.setEnabled = function()
                return false
            end
            local win = ns.MainWindow.Create(deps)
            win:SelectPage("about")
            local check = findCheck()
            check:SetChecked(true)
            check.scripts.OnClick(check)
            assert.is_false(check:GetChecked())
        end)

        it("is not there when guild sharing is not available", function()
            deps.guildSync = nil
            local win = ns.MainWindow.Create(deps)
            win:SelectPage("about")
            assert.is_nil(findCheck())
        end)
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

    describe("Formulas and About tabs", function()
        it("are page tabs and the window has no cog", function()
            local win = ns.MainWindow.Create(deps)
            assert.are.equal("Formulas", win.frame.Tabs[6]:GetText())
            assert.are.equal("About", win.frame.Tabs[7]:GetText())
            assert.is_nil(win.cog)
            assert.is_nil(win.settings)
            assert.is_nil(win.settingsTabs)
        end)

        it("builds the Formulas page on the first open", function()
            local win = ns.MainWindow.Create(deps)
            assert.are.equal(1, #built)
            win:SelectPage("formula")
            assert.are.equal(2, #built)
            assert.are.equal(deps, built[2].deps)
            assert.are.equal("formula", win:GetSelectedPage())
            win:SelectPage("ledger")
            win:SelectPage("formula")
            assert.are.equal(2, #built)
        end)

        it("shows the About text", function()
            local win = ns.MainWindow.Create(deps)
            win:SelectPage("about")
            assert.are.equal("about", win:GetSelectedPage())
            assert.is_true(win.tabs.contents[7]:IsShown())
            assert.is_true(strings["Flipside"])
            assert.is_true(strings["Client 1.60.1"])
            assert.is_true(strings["Groups sort items into trees. Operations hold the rules. "
                .. "Formulas check and save price formulas."])
        end)

        it("fit in the window at the minimum width", function()
            local win = ns.MainWindow.Create(deps)
            assert.are.equal(7, #win.frame.Tabs)
            local total = 0
            for _, tab in ipairs(win.frame.Tabs) do
                total = total + tab:GetWidth()
            end
            assert.is_true(total <= 800 - 2 * ns.Kit.Theme.padding)
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
        assert.is_true(win.tabs.contents[5]:IsShown())
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
