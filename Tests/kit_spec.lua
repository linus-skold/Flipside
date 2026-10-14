local mock = require("Tests.wow_mock")

local FILES = { "Theme", "Window", "Widgets", "Tabs", "List", "Combat" }

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
