local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local KIT = { "Theme", "Window", "Widgets", "Tabs", "List", "Combat" }
local DOC_FILES = { "FormulaFunctions", "FormulaSources" }

local function load()
    local ns = {}
    for _, name in ipairs(KIT) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    for _, name in ipairs(DOC_FILES) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    assert(loadfile(manifest.path("FormulaPage")))("Flipside", ns)
    return ns
end

-- Client methods that the mock lacks.
local function stubMethods()
    local probe = CreateFrame("Frame")
    local methods = getmetatable(probe).__index
    methods.SetJustifyH = function() end
    methods.HasFocus = function(self)
        return self.focused
    end
end

describe("FormulaPage", function()
    local ns, Page, content, run, sources, page, calls

    local function source(name, status)
        return { name = name, status = status }
    end

    before_each(function()
        mock.reset()
        stubMethods()
        _G.ScrollUtil = nil
        ns = load()
        Page = ns.FormulaPage
        calls = { compile = {}, evaluate = {} }
        run = {
            Compile = function(_, text)
                table.insert(calls.compile, text)
                if text == "bad" then
                    return nil, { message = "unexpected symbol", pos = 3 }
                end
                return { names = { "scanmin" }, later = {} }
            end,
            Evaluate = function(_, text, item)
                table.insert(calls.evaluate, { text, item })
                if item == "1" then
                    return 500, { kind = "ok", missing = {}, later = {} }
                elseif item == "2" then
                    return nil, { kind = "invalid", missing = { "scanmin" }, later = { "avgsell" } }
                end
                return nil, { kind = "error", message = "not an item" }
            end,
        }
        sources = {
            List = function()
                return { source("avgsell", "later"), source("scanmin", "available") }
            end,
        }
        content = CreateFrame("Frame", nil, UIParent)
        page = Page.Build(content, { formulaRun = run, formulaSources = sources })
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("Describe", function()
        it("says valid", function()
            assert.are.same({ "valid" }, Page.Describe(5, { kind = "ok", missing = {}, later = {} }))
        end)

        it("lists missing and later names", function()
            local info = { kind = "invalid", missing = { "a", "b" }, later = { "c" } }
            assert.are.same({ "invalid: missing a, b", "not available yet: c" }, Page.Describe(nil, info))
        end)

        it("says invalid when nothing is named", function()
            assert.are.same({ "invalid" }, Page.Describe(nil, { kind = "invalid", missing = {}, later = {} }))
        end)

        it("gives the position, message and nearby text of an error", function()
            local lines = Page.Describe(nil, nil, { message = "bad", pos = 12 }, "min(scanmin, 1 +")
            assert.are.same({ "error at 12: bad", 'near "...anmin, 1 +"' }, lines)
        end)

        it("reads an error from the info table", function()
            local lines = Page.Describe(nil, { kind = "error", message = "oops", pos = 1 }, nil, "x")
            assert.are.same({ "error at 1: oops", 'near "x"' }, lines)
        end)

        it("gives an error without position", function()
            assert.are.same({ "not an item" }, Page.Describe(nil, { kind = "error", message = "not an item" }))
        end)

        it("describes a compile only result", function()
            local info = { kind = "compiled", names = { "a", "b" }, later = { "c" } }
            assert.are.same({ "formula ok (sources: a, b)", "not available yet: c" }, Page.Describe(nil, info))
            assert.are.same({ "formula ok (sources: none)" }, Page.Describe(nil, { kind = "compiled", names = {} }))
        end)
    end)

    describe("reference list", function()
        local function find(name, list)
            for _, row in ipairs((list or page.list).rows) do
                if row.nameText:GetText() == name then
                    return row
                end
            end
        end

        local function hover(row)
            mock.tooltip.lines = {}
            row.scripts.OnEnter(row)
        end

        it("has the three sections in order", function()
            local rows = page.list.rows
            assert.are.equal("Functions", rows[1].nameText:GetText())
            assert.are.equal("avg", rows[2].nameText:GetText())
            assert.are.equal("Sources", rows[11].nameText:GetText())
            assert.are.equal("avgsell", rows[12].nameText:GetText())
            assert.are.equal("scanmin", rows[13].nameText:GetText())
            assert.are.equal("Syntax", rows[14].nameText:GetText())
            assert.are.equal("invalid", rows[15].nameText:GetText())
            assert.are.equal("10g 5s 2c", rows[16].nameText:GetText())
            assert.are.equal("150%", rows[17].nameText:GetText())
            assert.are.equal(17, #rows)
        end)

        it("shows the status of each source", function()
            assert.are.equal("not available yet", find("avgsell").statusText:GetText())
            assert.are.equal("available", find("scanmin").statusText:GetText())
        end)

        it("shows the first sentence as description", function()
            local doc = ns.FormulaFunctions.DOCS.check
            assert.are.equal("Gives b only if a is valid and above 0.", find("check").descText:GetText())
            assert.is_truthy(doc.text:find(find("check").descText:GetText(), 1, true))
        end)

        it("shows the full text and example in the tooltip", function()
            hover(find("max"))
            assert.are.equal("max(a, b, ...)", mock.tooltip.title)
            assert.are.equal(ns.FormulaFunctions.DOCS.max.text, mock.tooltip.lines[1])
            assert.are.equal("Example: max(scanmin, 1.5 * vendorsell)", mock.tooltip.lines[2])
            assert.is_true(mock.tooltip.shown)
            local row = find("max")
            row.scripts.OnLeave(row)
            assert.is_false(mock.tooltip.shown)
        end)

        it("shows the text of a source in the tooltip", function()
            hover(find("scanmin"))
            assert.are.equal("scanmin", mock.tooltip.title)
            assert.are.equal(ns.FormulaSources.DOCS.scanmin.text, mock.tooltip.lines[1])
        end)

        it("inserts name( for a function", function()
            page.formulaInput:SetText("")
            find("min").scripts.OnClick()
            assert.are.equal("min(", page.formulaInput:GetText())
        end)

        it("appends the name when a source row is clicked", function()
            page.formulaInput:SetText("")
            find("scanmin").scripts.OnClick()
            assert.are.equal("scanmin", page.formulaInput:GetText())
            find("avgsell").scripts.OnClick()
            assert.are.equal("scanmin avgsell", page.formulaInput:GetText())
        end)

        it("does not add a space after a bracket", function()
            page.formulaInput:SetText("min(")
            find("scanmin").scripts.OnClick()
            assert.are.equal("min(scanmin", page.formulaInput:GetText())
        end)

        it("inserts syntax words", function()
            page.formulaInput:SetText("")
            find("invalid").scripts.OnClick()
            assert.are.equal("invalid", page.formulaInput:GetText())
        end)

        it("header rows do nothing on click", function()
            assert.is_nil(find("Functions").scripts.OnClick)
        end)
    end)

    describe("custom sources", function()
        local custom, page2, store

        before_each(function()
            store = { { name = "mymin", text = "min(scanmin, 1)" } }
            custom = {
                List = function()
                    return store
                end,
                Set = function() return true end,
            }
            page2 = Page.Build(CreateFrame("Frame", nil, UIParent), {
                formulaRun = run, formulaSources = sources, customSources = custom,
            })
        end)

        it("puts the reference list and the custom list on the inset background", function()
            assert.are.equal("InsetFrameTemplate", page2.list.frame.template)
            assert.are.equal("InsetFrameTemplate", page2.customList.frame.template)
        end)

        it("lists a custom source with its formula as description", function()            local found
            for _, row in ipairs(page2.list.rows) do
                if row.nameText:GetText() == "mymin" then
                    found = row
                end
            end
            assert.is_truthy(found)
            assert.are.equal("custom", found.statusText:GetText())
            assert.are.equal("min(scanmin, 1)", found.descText:GetText())
        end)

        it("copies the formula into the custom formula box", function()
            page2.formulaInput:SetText("  max(scanmin, 5) ")
            page2.customFrom.scripts.OnClick(page2.customFrom)
            assert.are.equal("max(scanmin, 5)", page2.customText:GetText())
        end)

        it("has a clear heading and button", function()
            assert.are.equal("Save current formula as...", page2.customFrom:GetText())
        end)
    end)
    describe("Check", function()
        local function check(formula, item)
            page.formulaInput:SetText(formula)
            page.itemInput:SetText(item)
            page.checkButton.scripts.OnClick(page.checkButton)
        end

        it("shows the value and valid", function()
            check("scanmin", " 1 ")
            assert.are.same({ { "scanmin", "1" } }, calls.evaluate)
            assert.are.equal("500c", page.money:GetText())
            assert.are.equal("valid", page.status:GetText())
        end)

        it("shows missing and later names", function()
            check("scanmin", "2")
            assert.are.equal("-", page.money:GetText())
            assert.are.equal("invalid: missing scanmin\nnot available yet: avgsell", page.status:GetText())
        end)

        it("shows a compile error with position", function()
            run.Evaluate = function(_, text)
                local _, err = run:Compile(text)
                return nil, { kind = "error", message = err.message, pos = err.pos }
            end
            check("bad", "1")
            assert.are.equal('error at 3: unexpected symbol\nnear "bad"', page.status:GetText())
        end)

        it("only compiles when the item box is empty", function()
            check("scanmin", "")
            assert.are.same({ "scanmin" }, calls.compile)
            assert.are.same({}, calls.evaluate)
            assert.are.equal("formula ok (sources: scanmin)", page.status:GetText())
            check("bad", "")
            assert.are.equal('error at 3: unexpected symbol\nnear "bad"', page.status:GetText())
        end)

        it("rejects text that is not an item", function()
            check("scanmin", "sword")
            assert.are.same({}, calls.evaluate)
            assert.are.equal("not an item: sword", page.status:GetText())
        end)

        it("accepts an item link", function()
            check("scanmin", "|cff0070dd|Hitem:2589::::::::|h[Linen]|h|r")
            assert.are.equal(1, #calls.evaluate)
        end)

        it("asks for a formula", function()
            check("  ", "1")
            assert.are.equal("enter a formula", page.status:GetText())
        end)

        it("runs on Enter in either input", function()
            page.formulaInput:SetText("scanmin")
            page.itemInput:SetText("1")
            page.formulaInput.scripts.OnEnterPressed(page.formulaInput)
            assert.are.equal(1, #calls.evaluate)
            page.itemInput.scripts.OnEnterPressed(page.itemInput)
            assert.are.equal(2, #calls.evaluate)
        end)
    end)

    describe("item names", function()
        local pending, matches, index

        local function build()
            index = {
                Resolve = function(_, text)
                    if text == "item:5" then
                        return { kind = "item", input = text }
                    end
                    if #text < 2 then
                        return { kind = "error", message = "type at least 2 characters of the name" }
                    end
                    return { kind = "name", matches = matches, pendingCount = pending }
                end,
            }
            page = Page.Build(CreateFrame("Frame", nil, UIParent),
                { formulaRun = run, formulaSources = sources, itemNameIndex = index })
        end

        local function check(formula, item)
            page.formulaInput:SetText(formula)
            page.itemInput:SetText(item)
            page.checkButton.scripts.OnClick(page.checkButton)
        end

        local function shown()
            local out = {}
            for _, button in ipairs(page.choices) do
                if button:IsShown() then
                    table.insert(out, button)
                end
            end
            return out
        end

        before_each(function()
            pending = 0
            matches = {}
            assert(loadfile(manifest.path("ItemString")))("Flipside", ns)
            assert(loadfile(manifest.path("ItemNameIndex")))("Flipside", ns)
            build()
        end)

        it("evaluates one match by its key", function()
            matches = { { itemID = 1, name = "Linen", key = "1" } }
            check("scanmin", "linen")
            assert.are.same({ { "scanmin", "1" } }, calls.evaluate)
            assert.are.equal("valid", page.status:GetText())
        end)

        it("passes an item string for a variant key", function()
            matches = { { itemID = 1, name = "Sword", key = "1#s-34" } }
            check("scanmin", "sword")
            assert.are.equal("1#s-34", ns.ItemString.ToExactKey(calls.evaluate[1][2]))
        end)

        it("says when no item has the name, with the pending line", function()
            pending = 3
            check("scanmin", "nothing")
            assert.are.same({}, calls.evaluate)
            assert.are.equal('no item named "nothing" in the scan data\n3 item names are still loading',
                page.status:GetText())
        end)

        it("reports a short name", function()
            check("scanmin", "x")
            assert.are.equal("type at least 2 characters of the name", page.status:GetText())
        end)

        it("accepts an item string through the index", function()
            check("scanmin", "item:5")
            assert.are.same({ { "scanmin", "item:5" } }, calls.evaluate)
        end)

        it("lists several matches and evaluates the clicked one", function()
            matches = {
                { itemID = 1, name = "Linen", key = "1" },
                { itemID = 2, name = "Linen Cloth", key = "2" },
            }
            pending = 2
            check("scanmin", "linen")
            assert.are.same({}, calls.evaluate)
            local buttons = shown()
            assert.are.equal(2, #buttons)
            assert.are.equal("Linen Cloth (2)", buttons[2]:GetText())
            assert.are.equal("2 items match, pick one\n2 item names are still loading", page.status:GetText())
            assert.is_false(page.list.frame:IsShown())
            buttons[2].scripts.OnClick()
            assert.are.same({ { "scanmin", "2" } }, calls.evaluate)
            assert.are.equal(0, #shown())
            assert.is_true(page.list.frame:IsShown())
            assert.are.equal("invalid: missing scanmin\nnot available yet: avgsell", page.status:GetText())
        end)

        it("hides the choices on the next check", function()
            matches = {
                { itemID = 1, name = "Linen", key = "1" },
                { itemID = 2, name = "Linen Cloth", key = "2" },
            }
            check("scanmin", "linen")
            check("scanmin", "1")
            assert.are.equal(0, #shown())
        end)
    end)

    it("shows the help line", function()
        assert.are.equal(
            "Money: 10g 5s 2c. Functions: min max avg first check ifgt iflt ifeq round. "
                .. "Missing prices are invalid, never 0.",
            page.help:GetText()
        )
    end)

    it("fills the item box on an item link while it has focus", function()
        local hooked
        _G.hooksecurefunc = function(_, fn)
            hooked = fn
        end
        _G.ChatEdit_InsertLink = function() end
        local p = Page.Build(CreateFrame("Frame", nil, UIParent), { formulaRun = run, formulaSources = sources })
        _G.hooksecurefunc, _G.ChatEdit_InsertLink = nil, nil
        hooked("|Hitem:1|h")
        assert.is_nil(p.itemInput:GetText())
        p.itemInput.focused = true
        hooked("|Hitem:1|h")
        assert.are.equal("|Hitem:1|h", p.itemInput:GetText())
    end)
end)
