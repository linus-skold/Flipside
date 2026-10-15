local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local FILES = { "Theme", "Window", "Widgets", "Tabs", "List", "Columns", "Tree", "Combat", "Graph" }

local function loadKit()
    local ns = {}
    for _, name in ipairs(FILES) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns.Kit, ns
end

describe("Kit", function()
    local Kit, ns

    before_each(function()
        mock.reset()
        Kit, ns = loadKit()
    end)

    after_each(function()
        mock.teardown()
    end)

    it("sets only ns.Kit on the namespace", function()
        local keys = {}
        for key in pairs(ns) do
            table.insert(keys, key)
        end
        assert.are.same({ "Kit" }, keys)
    end)

    it("uses only ns.Kit and no Flipside name in the kit files", function()
        for _, name in ipairs(FILES) do
            local file = assert(io.open(manifest.path(name), "rb"))
            local source = file:read("*a")
            file:close()
            for use in source:gmatch("%f[%w_]ns%.([%w_]+)") do
                assert.are.equal("Kit", use, name)
            end
            assert.is_nil(source:find("Flipside", 1, true), name)
        end
    end)

    describe("Theme", function()
        it("has a font for each role", function()
            for _, role in ipairs({ "title", "normal", "highlight", "small", "disabled", "good", "bad", "number" }) do
                assert.is_string(Kit.Theme.fonts[role])
                assert.are.equal(Kit.Theme.fonts[role], Kit.Font(role))
            end
        end)

        it("falls back to the normal font", function()
            assert.are.equal("GameFontNormal", Kit.Font("nope"))
            assert.are.equal("GameFontNormal", Kit.Font(nil))
        end)

        it("has spacing and textures", function()
            assert.are.equal(12, Kit.Theme.padding)
            assert.are.equal(20, Kit.Theme.rowHeight)
            assert.are.equal(6, Kit.Theme.gap)
            assert.is_string(Kit.Theme.rowHighlight)
            assert.is_string(Kit.Theme.divider)
        end)
    end)

    describe("Window", function()
        it("creates a hidden window from the portrait template", function()
            local w = Kit.CreateWindow("TestWindow", { width = 300, height = 200, title = "Hello" })
            assert.are.equal("PortraitFrameTemplate", w.template)
            assert.are.equal("Hello", w.title)
            assert.are.equal(300, w.width)
            assert.are.equal(200, w.height)
            assert.is_false(w:IsShown())
            assert.is_true(w.clamped)
            assert.is_true(w.movable)
            assert.are.same({ "TestWindow" }, _G.UISpecialFrames)
        end)

        it("falls back to the button frame template", function()
            mock.missingTemplates.PortraitFrameTemplate = true
            local w = Kit.CreateWindow("TestWindow", { title = "x" })
            assert.are.equal("ButtonFrameTemplate", w.template)
        end)

        it("sets or hides the portrait", function()
            local a = Kit.CreateWindow("A", { portrait = "Interface\\Icons\\Foo" })
            assert.are.equal("Interface\\Icons\\Foo", a.portrait)
            local b = Kit.CreateWindow("B", {})
            assert.is_false(b.portraitShown)
        end)

        it("uses medium strata, is toplevel and raises on show", function()
            local w = Kit.CreateWindow("TestWindow", {})
            assert.are.equal("MEDIUM", w.strata)
            assert.is_true(w.toplevel)
            w:GetScript("OnShow")(w)
            assert.are.equal(1, w.raised)
            local d = Kit.CreateWindow("Other", { strata = "DIALOG" })
            assert.are.equal("DIALOG", d.strata)
        end)

        it("toggles", function()
            local w = Kit.CreateWindow("TestWindow", {})
            w:Toggle()
            assert.is_true(w:IsShown())
            w:Toggle()
            assert.is_false(w:IsShown())
        end)

        it("drags by the title area", function()
            local w = Kit.CreateWindow("TestWindow", {})
            local handle = w.TitleContainer
            assert.are.same({ "LeftButton" }, handle.dragButtons)
            handle:GetScript("OnDragStart")(handle)
            assert.is_true(w.moving)
            handle:GetScript("OnDragStop")(handle)
            assert.is_false(w.moving)
        end)
    end)

    describe("Widgets", function()
        local parent
        before_each(function()
            parent = CreateFrame("Frame", "P")
        end)

        it("button calls onClick", function()
            local clicks = 0
            local b = Kit.Button(parent, "Go", 80, function()
                clicks = clicks + 1
            end)
            assert.are.equal("UIPanelButtonTemplate", b.template)
            assert.are.equal("Go", b:GetText())
            b:GetScript("OnClick")(b)
            assert.are.equal(1, clicks)
        end)

        it("label uses the role font", function()
            local l = Kit.Label(parent, "Hi", "bad")
            assert.are.equal("GameFontRed", l.fontObject)
            assert.are.equal("Hi", l:GetText())
        end)

        it("input calls onEnter with the text and clears focus", function()
            local got
            local input = Kit.Input(parent, 100, function(text)
                got = text
            end)
            assert.are.equal("InputBoxTemplate", input.template)
            input:SetText("abc")
            input:GetScript("OnEnterPressed")(input)
            assert.are.equal("abc", got)
            input:GetScript("OnEscapePressed")(input)
            assert.are.equal(2, input.focusCleared)
        end)

        it("check calls onChange", function()
            local got
            local c = Kit.Check(parent, "Opt", function(v)
                got = v
            end)
            assert.are.equal("Opt", c.Text:GetText())
            c:SetChecked(true)
            c:GetScript("OnClick")(c)
            assert.is_true(got)
            c:SetChecked(false)
            c:GetScript("OnClick")(c)
            assert.is_false(got)
        end)

        it("divider uses the atlas", function()
            assert.are.equal("Options_HorizontalDivider", Kit.Divider(parent).atlas)
        end)

        it("money shows text and a dash", function()
            local m = Kit.Money(parent)
            assert.are.equal("-", m:GetText())
            m:SetCopper(12345)
            assert.are.equal("12345c", m:GetText())
            m:SetCopper(nil)
            assert.are.equal("-", m:GetText())
        end)

        it("tooltip shows on enter and hides on leave", function()
            local f = CreateFrame("Frame", nil, parent)
            Kit.Tooltip(f, "Title", { "one", "two" })
            f:GetScript("OnEnter")(f)
            assert.is_true(mock.tooltip.shown)
            assert.are.equal("Title", mock.tooltip.title)
            assert.are.same({ "one", "two" }, mock.tooltip.lines)
            f:GetScript("OnLeave")(f)
            assert.is_false(mock.tooltip.shown)
        end)
    end)

    describe("Page tabs", function()
        local window, built, tabs

        before_each(function()
            window = Kit.CreateWindow("TabWindow", {})
            built = {}
            local function page(key)
                return {
                    key = key,
                    title = key,
                    build = function(content)
                        built[key] = (built[key] or 0) + 1
                        assert.is_not_nil(content)
                    end,
                }
            end
            tabs = Kit.CreatePageTabs(window, { page("a"), page("b") })
        end)

        it("selects the first page and builds it once", function()
            assert.are.equal("a", tabs:GetSelected())
            assert.are.equal(1, built.a)
            assert.is_nil(built.b)
            tabs:Select("a")
            assert.are.equal(1, built.a)
        end)

        it("switches the shown content and calls PanelTemplates_SetTab", function()
            tabs:Select("b")
            assert.are.equal("b", tabs:GetSelected())
            assert.are.equal(1, built.b)
            assert.is_false(tabs.contents[1]:IsShown())
            assert.is_true(tabs.contents[2]:IsShown())
            local last = mock.tabCalls[#mock.tabCalls]
            assert.are.same({ "tab", window, 2 }, last)
            tabs:Select("a")
            tabs:Select("b")
            assert.are.equal(1, built.b)
        end)

        it("sets the tab count and creates the tab buttons", function()
            assert.are.same({ "num", window, 2 }, mock.tabCalls[1])
            assert.are.equal(2, #window.Tabs)
            assert.are.equal("PanelTabButtonTemplate", window.Tabs[1].template)
            assert.are.equal(2, window.Tabs[2]:GetID())
            window.Tabs[2]:GetScript("OnClick")(window.Tabs[2])
            assert.are.equal("b", tabs:GetSelected())
        end)

        it("ignores an unknown key", function()
            tabs:Select("zzz")
            assert.are.equal("a", tabs:GetSelected())
        end)
    end)

    describe("Tab sizing", function()
        local function pages(...)
            local list = {}
            for _, title in ipairs({ ... }) do
                list[#list + 1] = { key = title, title = title }
            end
            return list
        end

        it("TabWidth is text + padding, at least the minimum", function()
            assert.are.equal(70, Kit.TabWidth(50, 20))
            assert.are.equal(60, Kit.TabWidth(10, 20, 60))
            assert.are.equal(50, Kit.TabWidth(50))
        end)

        it("FitTabWidths keeps widths that fit", function()
            assert.are.same({ 100, 80 }, Kit.FitTabWidths({ 100, 80 }, 200, 3))
        end)

        it("FitTabWidths shrinks all tabs so that the total fits", function()
            local fitted = Kit.FitTabWidths({ 120, 120, 60 }, 240, 3)
            local sum = 0
            for _, width in ipairs(fitted) do
                sum = sum + width
            end
            assert.is_true(sum + 6 <= 240)
            assert.is_true(fitted[1] < 120 and fitted[3] < 60)
            assert.are.equal(fitted[1], fitted[2])
        end)

        it("FitTabWidths never goes below the minimum", function()
            assert.are.same({ 40, 40 }, Kit.FitTabWidths({ 100, 100 }, 20, 3))
        end)

        it("page tabs size to the text through the client helper", function()
            local window = Kit.CreateWindow("FitWindow1", {})
            window:SetSize(800, 540)
            local tabs = Kit.CreatePageTabs(window, pages("Groups", "Operations"), { tabPadding = 4, minTabWidth = 20 })
            assert.are.equal(6 * 6 + 4 + 32, tabs.buttons[1]:GetWidth())
            assert.are.equal(10 * 6 + 4 + 32, tabs.buttons[2]:GetWidth())
            assert.are.equal(4, window.tabPadding)
        end)

        it("page tabs never extend past the window width", function()
            local window = Kit.CreateWindow("FitWindow2", {})
            window:SetSize(300, 540)
            local tabs = Kit.CreatePageTabs(window, pages("Groups and more", "Operations list", "Formulas pg", "About"))
            local total = 3 * 3
            for _, tab in ipairs(tabs.buttons) do
                total = total + tab:GetWidth()
            end
            assert.is_true(total <= 300 - 2 * Kit.Theme.padding)
        end)

        it("page tabs use the template of the option", function()
            local window = Kit.CreateWindow("FitWindow3", {})
            window:SetSize(800, 540)
            local tabs = Kit.CreatePageTabs(window, pages("A"), { template = "CharacterFrameTabButtonTemplate" })
            assert.are.equal("CharacterFrameTabButtonTemplate", tabs.buttons[1].template)
            assert.are.equal("FitWindow3Tab1", tabs.buttons[1]:GetName())
        end)

        it("an unnamed window still gets named page tabs", function()
            local window = CreateFrame("Frame")
            window:SetSize(800, 540)
            local tabs = Kit.CreatePageTabs(window, pages("A", "B"))
            assert.is_string(tabs.buttons[1]:GetName())
            assert.are_not.equal(tabs.buttons[1]:GetName(), tabs.buttons[2]:GetName())
        end)

        it("top tabs size to the text with padding and a minimum width", function()
            local tabs = Kit.CreateTopTabs(CreateFrame("Frame"), { { "a", "Rules and more" }, { "b", "I" } }, {
                tabPadding = 10, minTabWidth = 50,
            })
            assert.are.equal(14 * 6 + 10 + 32, tabs.buttons[1]:GetWidth())
            assert.are.equal(50 + 32, tabs.buttons[2]:GetWidth())
        end)

        it("top tabs use the template of the option", function()
            local tabs = Kit.CreateTopTabs(CreateFrame("Frame"), { { "a", "A" } }, { template = "TabButtonTemplate" })
            assert.are.equal("TabButtonTemplate", tabs.buttons[1].template)
        end)

        it("without the client helper the width comes from the text width", function()
            _G.PanelTemplates_TabResize = nil
            local tabs = Kit.CreateTopTabs(CreateFrame("Frame"), { { "a", "Items" } }, { tabPadding = 12 })
            assert.are.equal(5 * 6 + 12, tabs.buttons[1]:GetWidth())
        end)
    end)
    describe("List", function()
        it("passes data to the data provider", function()
            local inited = {}
            local list = Kit.CreateList(CreateFrame("Frame"), {
                rowHeight = 24,
                initRow = function(row, data)
                    table.insert(inited, data)
                    row.data = data
                end,
            })
            assert.are.equal("WowScrollBoxList", list.box.template)
            assert.are.equal(24, mock.scrollInit.view.extent)
            local rows = { { id = 1 }, { id = 2 } }
            list:SetData(rows)
            assert.are.same(rows, list.box.dataProvider.data)
            assert.are.same(rows, list:GetData())

            local row = CreateFrame("Button")
            mock.scrollInit.view.initializer(row, rows[1])
            assert.are.equal(Kit.Theme.rowHighlight, row.highlightTexture)
            assert.are.equal("ADD", row.highlightMode)
            assert.are.same({ rows[1] }, inited)
        end)

        it("falls back to plain rows when ScrollUtil is missing", function()
            _G.ScrollUtil = nil
            local seen = {}
            local list = Kit.CreateList(CreateFrame("Frame"), {
                initRow = function(row, data)
                    seen[row] = data
                end,
            })
            assert.is_nil(list.box)
            list:SetData({ "x", "y" })
            assert.are.equal(2, #list.rows)
            assert.are.equal("x", seen[list.rows[1]])
            assert.are.equal(Kit.Theme.rowHighlight, list.rows[1].highlightTexture)
            list:SetData({ "z" })
            assert.is_true(list.rows[1]:IsShown())
            assert.is_false(list.rows[2]:IsShown())
        end)
    end)

    describe("Input focus lost", function()
        it("calls onFocusLost with the text", function()
            local got
            local input = Kit.Input(CreateFrame("Frame"), 100, nil, function(text)
                got = text
            end)
            input:SetText("xyz")
            input:GetScript("OnEditFocusLost")(input)
            assert.are.equal("xyz", got)
        end)

        it("sets no focus script without the argument", function()
            local input = Kit.Input(CreateFrame("Frame"), 100)
            assert.is_nil(input:GetScript("OnEditFocusLost"))
        end)
    end)

    describe("Dropdown", function()
        local parent, items, got
        before_each(function()
            parent = CreateFrame("Frame")
            items = { { value = "a", text = "Alpha" }, { value = "b", text = "Beta" } }
            got = {}
        end)

        local function make(value)
            return Kit.Dropdown(parent, 140, {
                items = items,
                value = value,
                onChange = function(v)
                    table.insert(got, v)
                end,
            })
        end

        it("uses the client template and lists radio items", function()
            local d = make("a")
            assert.are.equal("WowStyle1DropdownTemplate", d.template)
            assert.are.equal(140, d.width)
            assert.are.equal(2, #d.menuItems)
            assert.are.equal("Beta", d.menuItems[2].text)
            assert.is_true(d.menuItems[1].isSelected())
            assert.is_false(d.menuItems[2].isSelected())
        end)

        it("picks an item, sets the value and calls onChange", function()
            local d = make("a")
            d.menuItems[2].pick()
            assert.are.equal("b", d:GetValue())
            assert.are.same({ "b" }, got)
            assert.is_true(d.menuItems[2].isSelected())
        end)

        it("SetValue does not call onChange", function()
            local d = make()
            d:SetValue("b")
            assert.are.equal("b", d:GetValue())
            assert.is_true(d.menuItems[2].isSelected())
            assert.are.same({}, got)
        end)

        it("SetItems rebuilds the menu", function()
            local d = make("a")
            d:SetItems({ { value = 1, text = "One" } })
            assert.are.equal(1, #d.menuItems)
            assert.are.equal("One", d.menuItems[1].text)
        end)

        it("keeps the items and the value off the client frame", function()
            local d = make("a")
            assert.is_nil(d.items)
            assert.is_nil(d.value)
        end)

        it("opens the menu with plain string texts and boolean selection", function()
            local d = make("a")
            d:OpenMenu()
            assert.is_true(d.menuOpen)
            d:SetValue(nil)
            d:OpenMenu()
        end)

        it("copies the items so a later change by the caller has no effect", function()
            local d = make("a")
            items[1].text = 5
            d:OpenMenu()
            assert.are.equal("Alpha", d.menuItems[1].text)
        end)

        it("raises a Lua error for bad input before the menu code runs", function()
            assert.has_error(function()
                Kit.Dropdown(parent, 100, { items = "x" })
            end)
            assert.has_error(function()
                Kit.Dropdown(parent, 100, { items = { { value = "a", text = 5 } } })
            end)
            assert.has_error(function()
                Kit.Dropdown(parent, 100, { items = { { text = "A" } } })
            end)
            assert.has_error(function()
                Kit.Dropdown(parent, 100, { items = { "a" } })
            end)
            assert.has_error(function()
                Kit.Dropdown(parent, 100, { onChange = "no" })
            end)
            local d = make("a")
            assert.has_error(function()
                d:SetItems({ { value = "a", text = {} } })
            end)
            assert.has_error(function()
                d:SetItems("x")
            end)
            d:OpenMenu()
            assert.are.equal(2, #d.menuItems)
        end)

        it("falls back to a cycling button without the template", function()
            mock.missingTemplates.WowStyle1DropdownTemplate = true
            local d = make("a")
            assert.are.equal("UIPanelButtonTemplate", d.template)
            assert.are.equal("Alpha", d:GetText())
            d:GetScript("OnClick")(d)
            assert.are.equal("b", d:GetValue())
            assert.are.equal("Beta", d:GetText())
            d:GetScript("OnClick")(d)
            assert.are.equal("a", d:GetValue())
            assert.are.same({ "b", "a" }, got)
            d:SetValue("b")
            assert.are.equal("Beta", d:GetText())
            d:SetItems({ { value = "z", text = "Zed" } })
            assert.are.equal("", d:GetText())
        end)
    end)

    describe("NumberInput", function()
        local parent, got
        local function make(options)
            options = options or {}
            options.onChange = function(n)
                table.insert(got, n or "nil")
            end
            return Kit.NumberInput(parent, 80, options)
        end
        before_each(function()
            parent = CreateFrame("Frame")
            got = {}
        end)

        it("is numeric for non-negative integers only", function()
            assert.is_true(make().numeric)
            assert.is_nil(make({ allowNegative = true }).numeric)
            assert.are.equal("InputBoxTemplate", make().template)
        end)

        it("gives nil for empty or bad text", function()
            local n = make()
            assert.is_nil(n:GetNumber())
            n:SetText("abc")
            assert.is_nil(n:GetNumber())
            n:SetNumber(7)
            assert.are.equal(7, n:GetNumber())
            n:SetNumber(nil)
            assert.are.equal("", n:GetText())
        end)

        it("gives nil out of range and shows the bad-font hint", function()
            local n = make({ min = 1, max = 10 })
            assert.are.equal("GameFontRed", n.hint.fontObject)
            assert.is_false(n.hint:IsShown())
            n:SetNumber(5)
            assert.are.equal(5, n:GetNumber())
            assert.is_false(n.hint:IsShown())
            n:SetNumber(11)
            assert.is_nil(n:GetNumber())
            assert.is_true(n.hint:IsShown())
            n:SetNumber(0)
            assert.is_nil(n:GetNumber())
            n:SetText("")
            n:GetScript("OnTextChanged")(n)
            assert.is_false(n.hint:IsShown())
        end)

        it("accepts a negative number when allowed", function()
            local n = make({ allowNegative = true, min = -5 })
            n:SetNumber(-3)
            assert.are.equal(-3, n:GetNumber())
            n:SetNumber(-9)
            assert.is_nil(n:GetNumber())
        end)

        it("calls onChange on Enter, then not again on focus loss", function()
            local n = make({ min = 1, max = 10 })
            n:SetText("4")
            n:GetScript("OnEnterPressed")(n)
            n:GetScript("OnEditFocusLost")(n)
            assert.are.same({ 4 }, got)
        end)

        it("calls onChange on focus loss and with nil for out of range", function()
            local n = make({ min = 1, max = 10 })
            n:SetText("6")
            n:GetScript("OnEditFocusLost")(n)
            n:SetText("99")
            n:GetScript("OnEditFocusLost")(n)
            assert.are.same({ 6, "nil" }, got)
        end)

        it("SetNumber does not call onChange", function()
            local n = make()
            n:SetNumber(3)
            assert.are.same({}, got)
        end)
    end)

    describe("Confirm", function()
        it("registers the dialog once and shows the text", function()
            Kit.Confirm("KIT_TEST_ONE", "Delete it?", function() end)
            local dialog = _G.StaticPopupDialogs.KIT_TEST_ONE
            assert.are.equal("%s", dialog.text)
            assert.are.equal("Accept", dialog.button1)
            assert.are.equal("Cancel", dialog.button2)
            assert.are.equal(0, dialog.timeout)
            assert.is_true(dialog.hideOnEscape)
            assert.is_true(dialog.whileDead)
            assert.are.equal("Delete it?", mock.popup.text)
            Kit.Confirm("KIT_TEST_ONE", "Again?", function() end)
            assert.are.equal(dialog, _G.StaticPopupDialogs.KIT_TEST_ONE)
            assert.are.equal("Again?", mock.popup.text)
        end)

        it("calls the accept callback of the latest call once", function()
            local calls = {}
            Kit.Confirm("KIT_TEST_ONE", "a", function()
                table.insert(calls, "first")
            end)
            Kit.Confirm("KIT_TEST_ONE", "b", function()
                table.insert(calls, "second")
            end)
            local dialog = _G.StaticPopupDialogs.KIT_TEST_ONE
            mock.acceptPopup()
            dialog.OnAccept()
            assert.are.same({ "second" }, calls)
        end)

        it("keeps the callbacks of two dialogs apart", function()
            local calls = {}
            Kit.Confirm("KIT_TEST_ONE", "a", function()
                table.insert(calls, "one")
            end)
            Kit.Confirm("KIT_TEST_TWO", "b", function()
                table.insert(calls, "two")
            end)
            _G.StaticPopupDialogs.KIT_TEST_ONE.OnAccept()
            assert.are.same({ "one" }, calls)
            mock.acceptPopup()
            assert.are.same({ "one", "two" }, calls)
        end)

        it("clears the callback on cancel", function()
            local calls = 0
            Kit.Confirm("KIT_TEST_ONE", "a", function()
                calls = calls + 1
            end)
            mock.cancelPopup()
            _G.StaticPopupDialogs.KIT_TEST_ONE.OnAccept()
            assert.are.equal(0, calls)
        end)
    end)

    describe("Tree", function()
        local nodes, selected

        local function visibleIds(tree)
            local ids = {}
            for _, node in ipairs(tree.box.dataProvider:GetVisible()) do
                table.insert(ids, node:GetData().id)
            end
            return ids
        end

        before_each(function()
            selected = {}
            nodes = {
                { id = "a", text = "A", children = { { id = "a1", text = "A1" }, { id = "a2", text = "A2" } } },
                { id = "b", text = "B" },
            }
        end)

        local function make(options)
            options = options or {}
            options.onSelect = function(node)
                table.insert(selected, node.id)
            end
            return Kit.CreateTree(CreateFrame("Frame"), options)
        end

        it("builds a tree view with the row height", function()
            local tree = make({ rowHeight = 22 })
            tree:SetNodes(nodes)
            assert.are.equal("WowScrollBoxList", tree.box.template)
            assert.are.equal(22, mock.scrollInit.view.extent)
            assert.are.same({ "a", "a1", "a2", "b" }, visibleIds(tree))
            assert.is_true(tree.box.retainScroll)
        end)

        it("passes node, depth, collapse state and children to initRow", function()
            local seen = {}
            local tree = make({
                initRow = function(_, node, depth, isCollapsed, hasChildren)
                    seen[node.id] = { depth, isCollapsed, hasChildren }
                end,
            })
            tree:SetNodes(nodes)
            tree:SetCollapsed("a", true)
            for _, treeNode in ipairs(tree.box.dataProvider:GetVisible()) do
                mock.scrollInit.view.initializer(CreateFrame("Button"), treeNode)
            end
            assert.are.same({ 1, true, true }, seen.a)
            assert.are.same({ 1, false, false }, seen.b)
            assert.is_nil(seen.a1)
        end)

        it("shows the default row with a toggle and a label", function()
            local tree = make()
            tree:SetNodes(nodes)
            local row = CreateFrame("Button")
            mock.scrollInit.view.initializer(row, tree.box.dataProvider.nodes[1])
            assert.are.equal("A", row.label:GetText())
            assert.is_true(row.toggle:IsShown())
            assert.are.equal("-", row.toggle.glyph:GetText())
            row.toggle:GetScript("OnClick")(row.toggle)
            assert.is_true(tree:IsCollapsed("a"))
            assert.are.same({ "a", "b" }, visibleIds(tree))
            local leaf = CreateFrame("Button")
            mock.scrollInit.view.initializer(leaf, tree.box.dataProvider.nodes[2])
            assert.is_false(leaf.toggle:IsShown())
        end)

        it("selects by id, calls onSelect and ignores an unknown id", function()
            local tree = make()
            tree:SetNodes(nodes)
            tree:Select("a2")
            assert.are.equal("a2", tree:GetSelected())
            assert.are.same({ "a2" }, selected)
            tree:Select("zzz")
            assert.are.equal("a2", tree:GetSelected())
            assert.are.same({ "a2" }, selected)
        end)

        it("selects with a click on the row", function()
            local tree = make()
            tree:SetNodes(nodes)
            local row = CreateFrame("Button")
            mock.scrollInit.view.initializer(row, tree.box.dataProvider.nodes[2])
            row:GetScript("OnClick")(row)
            assert.are.equal("b", tree:GetSelected())
            mock.scrollInit.view.initializer(row, tree.box.dataProvider.nodes[2])
            assert.is_true(row.selection:IsShown())
        end)

        it("keeps selection and collapse state on Refresh and new nodes", function()
            local tree = make()
            tree:SetNodes(nodes)
            tree:Select("a2")
            tree:SetCollapsed("a", true)
            tree:Refresh()
            assert.are.equal("a2", tree:GetSelected())
            assert.are.same({ "a", "b" }, visibleIds(tree))
            tree:SetNodes({ nodes[1], { id = "c", text = "C" } })
            assert.are.equal("a2", tree:GetSelected())
            assert.are.same({ "a", "c" }, visibleIds(tree))
            tree:SetCollapsed("a", false)
            assert.are.same({ "a", "a1", "a2", "c" }, visibleIds(tree))
        end)

        it("clears the selection when the node is gone", function()
            local tree = make()
            tree:SetNodes(nodes)
            tree:Select("b")
            tree:SetNodes({ nodes[1] })
            assert.is_nil(tree:GetSelected())
        end)

        describe("fallback list", function()
            local tree
            before_each(function()
                _G.CreateTreeDataProvider = nil
                _G.ScrollUtil = nil
                tree = make()
                tree:SetNodes(nodes)
            end)

            it("uses a flat indented list", function()
                assert.is_nil(tree.box)
                assert.are.equal(4, #tree.list.rows)
                assert.are.equal("A", tree.list.rows[1].label:GetText())
                assert.are.equal("A1", tree.list.rows[2].label:GetText())
                local point = tree.list.rows[2].toggle.points[1]
                assert.are.equal(14, point[4])
                assert.are.equal(tree.list.frame, tree.frame)
            end)

            it("collapses, selects and refreshes by id", function()
                tree:SetCollapsed("a", true)
                assert.is_false(tree.list.rows[2]:IsShown() and tree.list.rows[3]:IsShown())
                assert.are.equal("B", tree.list.rows[2].label:GetText())
                tree:Select("b")
                tree:Refresh()
                assert.are.equal("b", tree:GetSelected())
                assert.is_true(tree.list.rows[2].selection:IsShown())
                assert.is_false(tree.list.rows[1].selection:IsShown())
                assert.is_true(tree:IsCollapsed("a"))
                assert.are.same({ "b" }, selected)
            end)
        end)
    end)
    describe("MultiLineInput", function()
        local parent
        before_each(function()
            parent = CreateFrame("Frame")
        end)

        it("uses the client template and sizes the edit box", function()
            local input = Kit.MultiLineInput(parent, 300, 120)
            assert.are.equal("InputScrollFrameTemplate", input.template)
            assert.are.equal(300, input.width)
            assert.are.equal(120, input.height)
            assert.are.equal(282, input.EditBox.width)
            assert.is_false(input.CharCount:IsShown())
        end)

        it("sets and gets text", function()
            local input = Kit.MultiLineInput(parent, 300, 120)
            input:SetText("a\nb")
            assert.are.equal("a\nb", input:GetText())
            assert.are.equal("a\nb", input.EditBox:GetText())
        end)

        it("calls onChange with the text on focus loss", function()
            local got = {}
            local input = Kit.MultiLineInput(parent, 300, 120, {
                onChange = function(text)
                    table.insert(got, text)
                end,
            })
            input.EditBox:SetText("typed")
            assert.are.same({}, got)
            input.EditBox:GetScript("OnEditFocusLost")(input.EditBox)
            assert.are.same({ "typed" }, got)
        end)

        it("focuses and highlights", function()
            local input = Kit.MultiLineInput(parent, 300, 120)
            input:SetFocus()
            assert.is_true(input.EditBox.focused)
            input:HighlightAll()
            assert.is_true(input.EditBox.highlighted)
        end)

        it("read only: selects on focus, undoes user edits, does not call onChange", function()
            local calls = 0
            local input = Kit.MultiLineInput(parent, 300, 120, {
                readOnly = true,
                onChange = function()
                    calls = calls + 1
                end,
            })
            local box = input.EditBox
            input:SetText("export")
            box:GetScript("OnEditFocusGained")(box)
            assert.is_true(box.highlighted)
            box:SetText("changed")
            box:GetScript("OnTextChanged")(box, true)
            assert.are.equal("export", input:GetText())
            box:GetScript("OnEditFocusLost")(box)
            assert.are.equal(0, calls)
        end)

        it("read only accepts SetText from code", function()
            local input = Kit.MultiLineInput(parent, 300, 120, { readOnly = true })
            input:SetText("one")
            input.EditBox:GetScript("OnTextChanged")(input.EditBox, false)
            assert.are.equal("one", input:GetText())
            input:SetText("two")
            assert.are.equal("two", input:GetText())
        end)
    end)

    describe("EditorDialog", function()
        it("builds a movable window with an input and two buttons", function()
            local d = Kit.EditorDialog("EditorA", { help = "Help text" })
            assert.is_true(d.movable)
            assert.is_false(d:IsShown())
            assert.are.same({ "EditorA" }, _G.UISpecialFrames)
            assert.are.equal("InputScrollFrameTemplate", d.input.template)
            assert.are.equal("Save", d.saveButton:GetText())
            assert.are.equal("Cancel", d.cancelButton:GetText())
            assert.is_nil(d.closeButton)
        end)

        it("opens with title and text", function()
            local d = Kit.EditorDialog("EditorA")
            d:Open("Edit", "hello", function() end)
            assert.is_true(d:IsShown())
            assert.are.equal("Edit", d.title)
            assert.are.equal("hello", d.input:GetText())
        end)

        it("Save calls onSave once with the text and closes", function()
            local d = Kit.EditorDialog("EditorA")
            local got = {}
            d:Open("Edit", "hello", function(text)
                table.insert(got, text)
            end)
            d.input.EditBox:SetText("new")
            d.saveButton:GetScript("OnClick")(d.saveButton)
            assert.are.same({ "new" }, got)
            assert.is_false(d:IsShown())
            d.saveButton:GetScript("OnClick")(d.saveButton)
            assert.are.same({ "new" }, got)
        end)

        it("Cancel closes and does not call onSave", function()
            local d = Kit.EditorDialog("EditorA")
            local calls = 0
            d:Open("Edit", "x", function()
                calls = calls + 1
            end)
            d.cancelButton:GetScript("OnClick")(d.cancelButton)
            assert.is_false(d:IsShown())
            d.saveButton:GetScript("OnClick")(d.saveButton)
            assert.are.equal(0, calls)
        end)

        it("does not call onSave after Escape closes it", function()
            local d = Kit.EditorDialog("EditorA")
            local calls = 0
            d:Open("Edit", "x", function()
                calls = calls + 1
            end)
            d:Hide()
            d.saveButton:GetScript("OnClick")(d.saveButton)
            assert.are.equal(0, calls)
        end)

        it("reuses the dialog by name and uses the latest callback", function()
            local a = Kit.EditorDialog("EditorA")
            assert.are.equal(a, Kit.EditorDialog("EditorA", { help = "other" }))
            assert.are_not.equal(a, Kit.EditorDialog("EditorB"))
            local got = {}
            a:Open("1", "one", function()
                table.insert(got, "first")
            end)
            a:Open("2", "two", function()
                table.insert(got, "second")
            end)
            assert.are.equal("two", a.input:GetText())
            a.saveButton:GetScript("OnClick")(a.saveButton)
            assert.are.same({ "second" }, got)
        end)

        it("read only: Close button only and text selected", function()
            local d = Kit.EditorDialog("ExportA", { readOnly = true })
            assert.is_nil(d.saveButton)
            assert.are.equal("Close", d.closeButton:GetText())
            d:Open("Export", "string", function() end)
            assert.are.equal("string", d.input:GetText())
            assert.is_true(d.input.EditBox.highlighted)
            d.closeButton:GetScript("OnClick")(d.closeButton)
            assert.is_false(d:IsShown())
        end)
    end)

    describe("Tree drag and drop", function()
        local nodes, drops, tree, rows

        local function setup(options, fallback)
            if fallback then
                _G.CreateTreeDataProvider = nil
                _G.ScrollUtil = nil
            end
            options = options or {}
            options.onDrop = options.onDrop or function(dragged, target)
                table.insert(drops, { dragged, target })
            end
            tree = Kit.CreateTree(CreateFrame("Frame"), options)
            tree:SetNodes(nodes)
            rows = {}
            if fallback then
                rows = tree.list.rows
            else
                for index, treeNode in ipairs(tree.box.dataProvider:GetVisible()) do
                    local row = CreateFrame("Button")
                    mock.scrollInit.view.initializer(row, treeNode)
                    rows[index] = row
                    tree.box.rowFrames[index] = row
                end
            end
        end

        local function over(row)
            for _, r in ipairs(rows) do
                r.mouseOver = (r == row)
            end
            tree.frame.mouseOver = row ~= nil
        end

        local function drag(row)
            row:GetScript("OnDragStart")(row)
        end

        local function release(row)
            row:GetScript("OnDragStop")(row)
        end

        before_each(function()
            drops = {}
            nodes = {
                { id = "a", text = "A", children = { { id = "a1", text = "A1" } } },
                { id = "b", text = "B" },
            }
        end)

        for _, fallback in ipairs({ false, true }) do
            local label = fallback and " (fallback list)" or ""

            it("drops on a row" .. label, function()
                setup(nil, fallback)
                assert.are.same({ "LeftButton" }, rows[1].dragButtons)
                drag(rows[3])
                over(rows[1])
                release(rows[3])
                assert.are.same({ { "b", "a" } }, drops)
            end)

            it("drops on the empty area with a nil target" .. label, function()
                setup(nil, fallback)
                drag(rows[2])
                over(nil)
                tree.frame.mouseOver = true
                release(rows[2])
                assert.are.same({ { "a1", nil } }, drops)
            end)

            it("does not drop outside the tree" .. label, function()
                setup(nil, fallback)
                drag(rows[2])
                over(nil)
                tree.frame.mouseOver = false
                release(rows[2])
                assert.are.same({}, drops)
            end)

            it("does not drop on itself" .. label, function()
                setup(nil, fallback)
                drag(rows[3])
                over(rows[3])
                release(rows[3])
                assert.are.same({}, drops)
            end)

            it("is blocked by canDrag" .. label, function()
                setup({
                    canDrag = function(id)
                        return id ~= "a"
                    end,
                }, fallback)
                drag(rows[1])
                assert.is_nil(tree.dragging)
                over(rows[3])
                release(rows[1])
                assert.are.same({}, drops)
                drag(rows[3])
                assert.are.equal("b", tree.dragging)
            end)
        end

        it("shows the dragged text near the cursor and tracks the scale", function()
            setup()
            rawget(_G, "UIParent").scale = 2
            mock.cursor = { 200, 100 }
            drag(rows[3])
            local ghost = tree.ghost
            assert.is_true(ghost:IsShown())
            assert.are.equal("B", ghost.label:GetText())
            assert.are.equal("TOOLTIP", ghost.strata)
            mock.update()
            assert.are.same({ "TOPLEFT", UIParent, "BOTTOMLEFT", 112, 38 }, ghost.points[1])
            release(rows[3])
            assert.is_false(ghost:IsShown())
        end)

        it("highlights the row under the cursor and clears it on release", function()
            setup()
            drag(rows[3])
            over(rows[1])
            mock.update()
            assert.are.equal("a", tree.dropTarget)
            assert.is_true(rows[1].dropMark:IsShown())
            assert.is_false(rows[2].dropMark:IsShown())
            over(rows[2])
            mock.update()
            assert.is_false(rows[1].dropMark:IsShown())
            assert.is_true(rows[2].dropMark:IsShown())
            over(rows[3])
            mock.update()
            assert.is_nil(tree.dropTarget)
            assert.is_false(rows[3].dropMark:IsShown())
            over(rows[1])
            mock.update()
            release(rows[3])
            assert.is_nil(tree.dropTarget)
            assert.is_nil(tree.dragging)
            assert.is_false(rows[1].dropMark:IsShown())
        end)

        it("sets no drag scripts without onDrop", function()
            tree = Kit.CreateTree(CreateFrame("Frame"), {})
            tree:SetNodes(nodes)
            local row = CreateFrame("Button")
            mock.scrollInit.view.initializer(row, tree.box.dataProvider.nodes[1])
            assert.is_nil(row.dragButtons)
            assert.is_nil(row:GetScript("OnDragStart"))
        end)
    end)
    describe("AfterCombat", function()
        it("runs now outside combat", function()
            local ran = 0
            Kit.AfterCombat(function()
                ran = ran + 1
            end)
            assert.are.equal(1, ran)
        end)

        it("waits for PLAYER_REGEN_ENABLED in combat and runs once", function()
            mock.inCombat = true
            local ran = 0
            Kit.AfterCombat(function()
                ran = ran + 1
            end)
            assert.are.equal(0, ran)
            assert.is_true(mock.isRegistered("PLAYER_REGEN_ENABLED"))
            mock.inCombat = false
            mock.fire("PLAYER_REGEN_ENABLED")
            assert.are.equal(1, ran)
            mock.fire("PLAYER_REGEN_ENABLED")
            assert.are.equal(1, ran)
        end)
    end)

    describe("Layering", function()
        it("puts the editor dialog on a higher strata, top level, and raises it on open", function()
            local d = Kit.EditorDialog("EditorLayer")
            assert.are.equal("DIALOG", d.strata)
            assert.is_true(d.toplevel)
            assert.is_nil(d.raised)
            d:Open("T", "x", function() end)
            assert.are.equal(1, d.raised)
            d:Open("T", "y", function() end)
            assert.are.equal(2, d.raised)
        end)

        it("puts the confirm pop-up on the full screen dialog strata and raises it", function()
            mock.popupFrame = CreateFrame("Frame")
            Kit.Confirm("KIT_LAYER", "Sure?", function() end)
            assert.are.equal("FULLSCREEN_DIALOG", mock.popupFrame.strata)
            assert.are.equal(1, mock.popupFrame.raised)
        end)

        it("keeps the drag ghost on the tooltip strata", function()
            local tree = Kit.CreateTree(CreateFrame("Frame"), { onDrop = function() end })
            tree:SetNodes({ { id = "a", text = "A" } })
            local row = CreateFrame("Button")
            mock.scrollInit.view.initializer(row, tree.box.dataProvider.nodes[1])
            row:GetScript("OnDragStart")(row)
            assert.are.equal("TOOLTIP", tree.ghost.strata)
        end)
    end)

    describe("Top tabs", function()
        local parent, tabs, picked

        before_each(function()
            parent = CreateFrame("Frame", "SubFrame")
            parent.Tabs = { "page tab" }
            picked = {}
            tabs = Kit.CreateTopTabs(parent, { { "rules", "Rules" }, { "items", "Items" } }, {
                onSelect = function(key)
                    table.insert(picked, key)
                end,
            })
        end)

        it("uses the client top tab template with the tab text", function()
            assert.are.equal(2, #tabs.buttons)
            assert.are.equal("PanelTopTabButtonTemplate", tabs.buttons[1].template)
            assert.are.equal("Items", tabs.buttons[2]:GetText())
            assert.are.equal(2, tabs.buttons[2]:GetID())
        end)

        it("anchors the first tab to the top edge of the parent", function()
            local point = tabs.buttons[1].points[1]
            assert.are.equal("TOPLEFT", point[1])
            assert.are.equal(parent, point[2])
            assert.are.equal("TOPLEFT", point[3])
        end)

        it("works on a sub-frame: own Tabs array, the parent Tabs stay", function()
            assert.are.same({ "page tab" }, parent.Tabs)
            assert.are.equal(tabs.buttons, tabs.holder.Tabs)
            assert.are.same({ "num", tabs.holder, 2 }, mock.tabCalls[1])
            assert.are.same({ "tab", tabs.holder, 1 }, mock.tabCalls[2])
        end)

        it("selects the first tab without calling onSelect", function()
            assert.are.equal("rules", tabs:GetSelected())
            assert.are.same({}, picked)
            assert.is_true(tabs:GetContent("rules"):IsShown())
            assert.is_false(tabs:GetContent("items"):IsShown())
        end)

        it("gives one content frame for each tab, below the tabs", function()
            local rules, items = tabs:GetContent("rules"), tabs:GetContent("items")
            assert.are_not.equal(rules, items)
            assert.are.equal(parent, rules:GetParent())
            assert.are.equal(-30, rules.points[1][5])
            assert.is_nil(tabs:GetContent("nope"))
        end)

        it("Select switches the content, calls PanelTemplates_SetTab and onSelect", function()
            tabs:Select("items")
            assert.are.equal("items", tabs:GetSelected())
            assert.is_false(tabs:GetContent("rules"):IsShown())
            assert.is_true(tabs:GetContent("items"):IsShown())
            assert.are.same({ "tab", tabs.holder, 2 }, mock.tabCalls[#mock.tabCalls])
            assert.are.same({ "items" }, picked)
            tabs:Select("items")
            assert.are.same({ "items" }, picked)
        end)

        it("selects with a click on a tab", function()
            tabs.buttons[2]:GetScript("OnClick")(tabs.buttons[2])
            assert.are.equal("items", tabs:GetSelected())
            assert.are.same({ "items" }, picked)
        end)

        it("ignores an unknown key and takes a start key", function()
            tabs:Select("zzz")
            assert.are.equal("rules", tabs:GetSelected())
            local other = Kit.CreateTopTabs(CreateFrame("Frame"), { { "a", "A" }, { "b", "B" } }, { selected = "b" })
            assert.are.equal("b", other:GetSelected())
        end)
    end)

    describe("Inset", function()
        it("uses the client inset template", function()
            assert.are.equal("InsetFrameTemplate", Kit.Inset(CreateFrame("Frame")).template)
        end)

        it("falls back to a plain frame without the template", function()
            mock.missingTemplates.InsetFrameTemplate = true
            assert.are.equal("Frame", Kit.Inset(CreateFrame("Frame")).kind)
        end)

        it("wraps a list when inset is true", function()
            local list = Kit.CreateList(CreateFrame("Frame"), { inset = true })
            assert.are.equal("InsetFrameTemplate", list.frame.template)
            assert.are.equal(Kit.Theme.insetPadding, list.box.points[1][2])
            assert.are.equal(list.frame, list.box:GetParent())
            local plain = Kit.CreateList(CreateFrame("Frame"), {})
            assert.is_nil(plain.frame.template)
        end)

        it("wraps a fallback list rows inside the padding", function()
            _G.ScrollUtil = nil
            local list = Kit.CreateList(CreateFrame("Frame"), { inset = true })
            list:SetData({ "x" })
            assert.are.equal("InsetFrameTemplate", list.frame.template)
            assert.are.equal(4, list.rows[1].points[1][4])
            assert.are.equal(-4, list.rows[1].points[1][5])
        end)

        it("wraps a tree when inset is true", function()
            local tree = Kit.CreateTree(CreateFrame("Frame"), { inset = true })
            assert.are.equal("InsetFrameTemplate", tree.frame.template)
            assert.are.equal(tree.frame, tree.box:GetParent())
            assert.is_nil(Kit.CreateTree(CreateFrame("Frame"), {}).frame.template)
        end)

        it("gives tree content insets on the ScrollBox path", function()
            local plain = Kit.CreateTree(CreateFrame("Frame"), {})
            assert.is_nil(plain.list)
            assert.are.same({ left = 0, right = 16 }, plain.contentInsets)
            local tree = Kit.CreateTree(CreateFrame("Frame"), { inset = true })
            local pad = Kit.Theme.insetPadding
            assert.are.same({ left = pad, right = 16 + pad }, tree.contentInsets)
        end)

        it("gives tree content insets on the fallback path", function()
            _G.CreateTreeDataProvider = nil
            _G.ScrollUtil = nil
            local tree = Kit.CreateTree(CreateFrame("Frame"), { inset = true })
            local pad = Kit.Theme.insetPadding
            assert.are.same({ left = pad, right = pad }, tree.contentInsets)
        end)

        it("wraps a fallback tree when inset is true", function()
            _G.CreateTreeDataProvider = nil
            _G.ScrollUtil = nil
            local tree = Kit.CreateTree(CreateFrame("Frame"), { inset = true })
            assert.are.equal("InsetFrameTemplate", tree.frame.template)
        end)
    end)

    describe("list skin", function()
        local skin = {
            backgroundAtlas = "bg", stripeAtlases = { "s1", "s2" }, highlightAtlas = "hover", selectAtlas = "pick",
        }

        it("puts the background atlas inside the inset border", function()
            local inset = Kit.Inset(CreateFrame("Frame"), skin)
            assert.are.equal("InsetFrameTemplate", inset.template)
            assert.are.equal("bg", inset.skinBackground.atlas)
            assert.are.same({ "TOPLEFT", inset, "TOPLEFT", 3, -3 }, inset.skinBackground.points[1])
            assert.are.same({ "BOTTOMRIGHT", inset, "BOTTOMRIGHT", -3, 3 }, inset.skinBackground.points[2])
        end)

        it("adds no background without a skin", function()
            assert.is_nil(Kit.Inset(CreateFrame("Frame")).skinBackground)
        end)

        it("skins a row with a stripe and a hover texture, and alternates the stripe", function()
            local row = CreateFrame("Button")
            assert.is_true(Kit.SkinRow(row, skin, true))
            assert.are.equal("s1", row.kitStripe.atlas)
            assert.are.equal("hover", row.kitHover.atlas)
            assert.are.equal("ADD", row.kitHover.blendMode)
            assert.are.equal("HIGHLIGHT", row.kitHover.layer)
            assert.is_nil(row.highlightTexture)
            Kit.SkinRow(row, skin, false)
            assert.are.equal("s2", row.kitStripe.atlas)
        end)

        it("gives the Kit highlight texture to a row without a skin", function()
            local row = CreateFrame("Button")
            assert.is_false(Kit.SkinRow(row, nil))
            assert.are.equal(Kit.Theme.rowHighlight, row.highlightTexture)
        end)

        it("makes the selection texture from the select atlas or the Kit texture", function()
            local row = CreateFrame("Button")
            local picked = Kit.SelectionTexture(row, skin, 0.4)
            assert.are.equal("pick", picked.atlas)
            assert.are.equal("ADD", picked.blendMode)
            assert.are.equal(0.4, picked.alpha)
            assert.are.equal(row, picked.allPoints)
            assert.are.equal(Kit.Theme.rowHighlight, Kit.SelectionTexture(row).texture)
        end)

        it("registers the stripe alternation on the scroll box", function()
            local callback
            _G.ScrollUtil.RegisterAlternateRowBehavior = function(box, fn)
                callback = { box = box, fn = fn }
            end
            local list = Kit.CreateList(CreateFrame("Frame"), { inset = true, skin = skin })
            assert.are.equal(list.box, callback.box)
            assert.are.equal("bg", list.frame.skinBackground.atlas)
            local row = CreateFrame("Button")
            callback.fn(row, true)
            assert.are.equal("s1", row.kitStripe.atlas)
            callback.fn(row, false)
            assert.are.equal("s2", row.kitStripe.atlas)
        end)

        it("skins the rows of a list and a tree", function()
            local list = Kit.CreateList(CreateFrame("Frame"), { skin = skin, initRow = function() end })
            local row = CreateFrame("Button")
            mock.scrollInit.view.initializer(row, {})
            assert.are.equal("hover", row.kitHover.atlas)
            local tree = Kit.CreateTree(CreateFrame("Frame"), { inset = true, skin = skin })
            assert.are.equal("bg", tree.frame.skinBackground.atlas)
            local treeRow = CreateFrame("Button")
            mock.scrollInit.view.initializer(treeRow, {
                GetData = function() return { id = "a", text = "A" } end,
                GetDepth = function() return 1 end,
                IsCollapsed = function() return false end,
                GetNodes = function() return {} end,
            })
            assert.are.equal("pick", treeRow.selection.atlas)
            assert.are.equal("hover", treeRow.kitHover.atlas)
            assert.is_not_nil(list)
        end)

        it("stripes the fallback rows by position", function()
            _G.ScrollUtil = nil
            local list = Kit.CreateList(CreateFrame("Frame"), { skin = skin })
            list:SetData({ "x", "y" })
            assert.are.equal("s1", list.rows[1].kitStripe.atlas)
            assert.are.equal("s2", list.rows[2].kitStripe.atlas)
        end)
    end)

    describe("IconButton", function()
        it("creates the client close button template and calls onClick", function()
            local got = 0
            local button = Kit.IconButton(CreateFrame("Frame"), "close", function()
                got = got + 1
            end)
            assert.are.equal("UIPanelCloseButtonNoScripts", button.template)
            assert.are.equal(20, button.width)
            button:GetScript("OnClick")(button)
            assert.are.equal(1, got)
        end)

        it("shows the tooltip text", function()
            local button = Kit.IconButton(CreateFrame("Frame"), "close", nil, "Remove")
            button:GetScript("OnEnter")(button)
            assert.is_true(mock.tooltip.shown)
            assert.are.equal("Remove", mock.tooltip.title)
            button:GetScript("OnLeave")(button)
            assert.is_false(mock.tooltip.shown)
        end)

        it("sets no tooltip script without text and rejects an unknown kind", function()
            local button = Kit.IconButton(CreateFrame("Frame"), "close")
            assert.is_nil(button:GetScript("OnEnter"))
            assert.has_error(function()
                Kit.IconButton(CreateFrame("Frame"), "nope")
            end)
        end)
    end)

    describe("ContextMenu", function()
        it("opens the client menu with a title and entries", function()
            local owner = CreateFrame("Button")
            local ran = {}
            Kit.ContextMenu(owner, {
                { text = "Rename", onClick = function() table.insert(ran, "rename") end },
                { text = "Delete", onClick = function() table.insert(ran, "delete") end, disabled = true },
            }, { title = "Group" })
            assert.are.equal(owner, mock.menu.owner)
            assert.are.equal("Group", mock.menu.title)
            assert.are.equal(2, #mock.menu.items)
            assert.are.equal("Rename", mock.menu.items[1].text)
            assert.is_true(mock.menu.items[1].enabled)
            assert.is_false(mock.menu.items[2].enabled)
            mock.menu.items[1].onClick()
            assert.are.same({ "rename" }, ran)
        end)

        it("has no title line without the option and does nothing without the menu API", function()
            Kit.ContextMenu(CreateFrame("Button"), { { text = "A" } })
            assert.is_nil(mock.menu.title)
            _G.MenuUtil = nil
            assert.is_nil(Kit.ContextMenu(CreateFrame("Button"), {}))
        end)
    end)

    describe("Tree right click", function()
        local rightClicks, selected

        local function make(fallback)
            if fallback then
                _G.CreateTreeDataProvider = nil
                _G.ScrollUtil = nil
            end
            rightClicks, selected = {}, {}
            local tree = Kit.CreateTree(CreateFrame("Frame"), {
                onSelect = function(node)
                    table.insert(selected, node.id)
                end,
                onRightClick = function(id, row)
                    table.insert(rightClicks, { id, row })
                end,
            })
            tree:SetNodes({ { id = "a", text = "A" }, { id = "b", text = "B" } })
            local row
            if fallback then
                row = tree.list.rows[2]
            else
                row = CreateFrame("Button")
                mock.scrollInit.view.initializer(row, tree.box.dataProvider.nodes[2])
            end
            return tree, row
        end

        for _, fallback in ipairs({ false, true }) do
            local label = fallback and " (fallback list)" or ""

            it("calls onRightClick with the id and row, and does not select" .. label, function()
                local tree, row = make(fallback)
                assert.are.same({ "LeftButtonUp", "RightButtonUp" }, row.clickButtons)
                row:GetScript("OnClick")(row, "RightButton")
                assert.are.equal(1, #rightClicks)
                assert.are.equal("b", rightClicks[1][1])
                assert.are.equal(row, rightClicks[1][2])
                assert.are.same({}, selected)
                assert.is_nil(tree:GetSelected())
            end)

            it("still selects with a left click" .. label, function()
                local tree, row = make(fallback)
                row:GetScript("OnClick")(row, "LeftButton")
                assert.are.equal("b", tree:GetSelected())
                assert.are.same({ "b" }, selected)
                assert.are.same({}, rightClicks)
            end)
        end

        it("registers no extra clicks and ignores a right click without the option", function()
            local tree = Kit.CreateTree(CreateFrame("Frame"), {})
            tree:SetNodes({ { id = "a", text = "A" } })
            local row = CreateFrame("Button")
            mock.scrollInit.view.initializer(row, tree.box.dataProvider.nodes[1])
            assert.is_nil(row.clickButtons)
            row:GetScript("OnClick")(row, "RightButton")
            assert.is_nil(tree:GetSelected())
        end)
    end)

    describe("Input placeholder", function()
        local function make()
            return Kit.Input(CreateFrame("Frame"), 100, nil, nil, { placeholder = "<group name>" })
        end

        it("shows a grey text while the box is empty", function()
            local input = make()
            assert.are.equal("<group name>", input.placeholder:GetText())
            assert.are.equal("GameFontDisable", input.placeholder.fontObject)
            assert.is_true(input.placeholder:IsShown())
        end)

        it("hides with text and shows again when the text is cleared", function()
            local input = make()
            input:SetText("abc")
            input:GetScript("OnTextChanged")(input)
            assert.is_false(input.placeholder:IsShown())
            input:SetText("")
            input:GetScript("OnTextChanged")(input)
            assert.is_true(input.placeholder:IsShown())
        end)

        it("hides on focus and shows again on focus loss while empty", function()
            local input = make()
            input:GetScript("OnEditFocusGained")(input)
            assert.is_false(input.placeholder:IsShown())
            input:GetScript("OnEditFocusLost")(input)
            assert.is_true(input.placeholder:IsShown())
            input:SetText("x")
            input:GetScript("OnEditFocusGained")(input)
            input:GetScript("OnEditFocusLost")(input)
            assert.is_false(input.placeholder:IsShown())
        end)

        it("keeps onFocusLost and sets nothing without the option", function()
            local got
            local input = Kit.Input(CreateFrame("Frame"), 100, nil, function(text)
                got = text
            end, { placeholder = "p" })
            input:SetText("q")
            input:GetScript("OnEditFocusLost")(input)
            assert.are.equal("q", got)
            assert.is_nil(Kit.Input(CreateFrame("Frame"), 100).placeholder)
        end)
    end)

    describe("QualityColor", function()
        it("gives r, g, b and the hex string from the client", function()
            local r, g, b, hex = Kit.QualityColor(4)
            assert.are.same({ 0.64, 0.21, 0.93, "ffa335ee" }, { r, g, b, hex })
        end)

        it("gives white for a missing quality or missing API", function()
            assert.are.same({ 1, 1, 1, "ffffffff" }, { Kit.QualityColor(nil) })
            assert.are.same({ 1, 1, 1, "ffffffff" }, { Kit.QualityColor(99) })
            _G.C_Item = nil
            assert.are.same({ 1, 1, 1, "ffffffff" }, { Kit.QualityColor(4) })
        end)
    end)end)
