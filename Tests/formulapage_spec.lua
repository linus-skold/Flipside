local mock = require("Tests.wow_mock")

local KIT = { "Theme", "Window", "Widgets", "Tabs", "List", "Combat" }

local function load()
    local ns = {}
    for _, name in ipairs(KIT) do
        assert(loadfile("UI/Kit/" .. name .. ".lua"))("Flipside", ns)
    end
    assert(loadfile("UI/Pages/FormulaPage.lua"))("Flipside", ns)
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

    describe("sources list", function()
        it("has a row for each source with its status", function()
            local rows = page.list.rows
            assert.are.equal(2, #rows)
            assert.are.equal("avgsell", rows[1].nameText:GetText())
            assert.are.equal("not available yet", rows[1].statusText:GetText())
            assert.are.equal("scanmin", rows[2].nameText:GetText())
            assert.are.equal("available", rows[2].statusText:GetText())
        end)

        it("appends the name when a row is clicked", function()
            page.formulaInput:SetText("")
            page.list.rows[2].scripts.OnClick()
            assert.are.equal("scanmin", page.formulaInput:GetText())
            page.list.rows[1].scripts.OnClick()
            assert.are.equal("scanmin avgsell", page.formulaInput:GetText())
        end)

        it("does not add a space after a bracket", function()
            page.formulaInput:SetText("min(")
            page.list.rows[2].scripts.OnClick()
            assert.are.equal("min(scanmin", page.formulaInput:GetText())
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
