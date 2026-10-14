local mock = require("Tests.wow_mock")

local FILES = { "Theme", "Window", "Widgets", "Tabs", "List", "Tree", "Combat" }

local function loadKit()
    local ns = {}
    for _, name in ipairs(FILES) do
        assert(loadfile("UI/Kit/" .. name .. ".lua"))("Flipside", ns)
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
            local file = assert(io.open("UI/Kit/" .. name .. ".lua", "rb"))
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
end)
