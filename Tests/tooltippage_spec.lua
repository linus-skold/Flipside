local mock = require("Tests.wow_mock")

local KIT = { "Theme", "Window", "Widgets", "Tabs", "List", "Combat" }

local function load()
    local ns = {}
    for _, name in ipairs(KIT) do
        assert(loadfile("UI/Kit/" .. name .. ".lua"))("Flipside", ns)
    end
    assert(loadfile("Core/ItemString.lua"))("Flipside", ns)
    assert(loadfile("Core/SettingsDB.lua"))("Flipside", ns)
    assert(loadfile("Services/ItemNameIndex.lua"))("Flipside", ns)
    assert(loadfile("Services/TooltipConfig.lua"))("Flipside", ns)
    assert(loadfile("Services/TooltipLines.lua"))("Flipside", ns)
    assert(loadfile("UI/Pages/FormulaPage.lua"))("Flipside", ns)
    assert(loadfile("UI/Pages/TooltipPage.lua"))("Flipside", ns)
    return ns
end

-- Client methods that the mock lacks.
local function stubMethods()
    local probe = CreateFrame("Frame")
    getmetatable(probe).__index.SetJustifyH = function() end
end

describe("TooltipPage", function()
    local ns, tc, page, run, index, db, subscribed, extra

    local function newDB(data)
        return ns.SettingsDB.New(data, { character = "Me", schemaVersion = 1 })
    end

    local function build()
        local deps = {
            tooltipConfig = tc,
            formulaRun = run,
            itemNameIndex = index,
            subscribe = function(fn)
                subscribed = fn
            end,
        }
        for k, v in pairs(extra or {}) do
            deps[k] = v
        end
        page = ns.TooltipPage.Build(CreateFrame("Frame", nil, UIParent), deps)
    end

    local function labels()
        local out = {}
        for i, row in ipairs(page.list.rows) do
            if row:IsShown() and page.list.data[i] then
                out[#out + 1] = row.nameText:GetText()
            end
        end
        return out
    end

    local function click(widget)
        widget.scripts.OnClick(widget)
    end

    local function enter(widget, text)
        widget:SetText(text)
        widget.scripts.OnEnterPressed(widget)
    end

    local function selectLine(position)
        click(page.list.rows[position])
    end

    local function stored()
        return tc:Get()
    end

    before_each(function()
        mock.reset()
        stubMethods()
        _G.ScrollUtil = nil
        ns = load()
        extra = nil
        run = {
            Compile = function(_, text)
                if text:find("bad(", 1, true) then
                    return nil, { message = "unexpected symbol", pos = 4 }
                end
                return { names = { "scanmarket" }, later = {} }
            end,
            Evaluate = function(self, text, item)
                local compiled, err = self:Compile(text)
                if not compiled then
                    return nil, { kind = "error", message = err.message, pos = err.pos }
                end
                if item == "1" then
                    return 500, { kind = "ok", missing = {}, later = {} }
                end
                return nil, { kind = "invalid", missing = {}, later = {} }
            end,
        }
        index = {
            Resolve = function(_, text)
                if text == "linen" then
                    return { kind = "name", matches = { { itemID = 1, name = "Linen", key = "1" } }, pendingCount = 0 }
                end
                return { kind = "error", message = "type at least 2 characters of the name" }
            end,
        }
        db = newDB({})
        tc = ns.TooltipConfig.New(db, {
            compile = function(text)
                return run:Compile(text)
            end,
        })
        subscribed = nil
        build()
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("layout", function()
        it("puts the list on the inset background and sets the placeholders", function()
            assert.are.equal("InsetFrameTemplate", page.list.frame.template)
            assert.are.equal("<line label>", page.labelInput.placeholder:GetText())
            assert.are.equal("Item name, link or id", page.exampleInput.placeholder:GetText())
        end)

        it("shows the Alt hint", function()
            assert.are.equal("Hold Alt over an item to see the value of the whole stack.", page.hint:GetText())
        end)
    end)

    describe("line list", function()
        it("shows the default lines with formula and enabled box", function()
            assert.are.same({ "Market", "Min", "Max" }, labels())
            assert.are.equal("scanlow", page.list.rows[2].formulaText:GetText())
            assert.is_true(page.list.rows[1].enabledCheck:GetChecked())
        end)

        it("selects the first line", function()
            assert.are.equal("Market", page.header:GetText())
            assert.are.equal("scanmarket", page.formulaInput:GetText())
            assert.are.equal("Market", page.labelInput:GetText())
            assert.is_true(page.ageCheck:GetChecked())
            assert.is_true(page.samplesCheck:GetChecked())
        end)

        it("shows another line when it is clicked", function()
            selectLine(3)
            assert.are.equal("Max", page.labelInput:GetText())
            assert.is_false(page.ageCheck:GetChecked())
        end)

        it("redraws when the subscription fires", function()
            tc:AddLine("Extra", "scanmarket")
            subscribed()
            assert.are.same({ "Market", "Min", "Max", "Extra" }, labels())
        end)
    end)

    describe("add line", function()
        it("adds a line and selects it", function()
            click(page.addButton)
            assert.are.same({ "Market", "Min", "Max", "New line" }, labels())
            assert.are.equal("New line", page.header:GetText())
            assert.are.equal("", page.status:GetText())
        end)

        it("shows the limit message at 12 lines", function()
            for _ = 4, 12 do
                click(page.addButton)
            end
            assert.are.equal(12, #stored().lines)
            click(page.addButton)
            assert.are.equal(12, #stored().lines)
            assert.are.equal("a tooltip can have 12 lines at most", page.status:GetText())
        end)
    end)

    describe("edit", function()
        it("saves a new label", function()
            enter(page.labelInput, "  Average ")
            assert.are.equal("Average", stored().lines[1].label)
            assert.are.same({ "Average", "Min", "Max" }, labels())
            assert.are.equal("", page.labelMessage:GetText())
        end)

        it("saves the label on focus loss", function()
            page.labelInput:SetText("Lost")
            page.labelInput.scripts.OnEditFocusLost(page.labelInput)
            assert.are.equal("Lost", stored().lines[1].label)
        end)

        it("refuses a label that is too long and keeps the old one", function()
            enter(page.labelInput, string.rep("x", 31))
            assert.are.equal("label must have 1 to 30 characters", page.labelMessage:GetText())
            assert.are.equal("Market", stored().lines[1].label)
            assert.are.equal("Market", page.labelInput:GetText())
        end)

        it("saves a good formula", function()
            enter(page.formulaInput, "scanmarket * 2")
            assert.are.equal("scanmarket * 2", stored().lines[1].formula)
            assert.are.equal("scanmarket * 2", page.list.rows[1].formulaText:GetText())
            assert.are.equal("", page.formulaMessage:GetText())
        end)

        it("shows a bad formula error with the position and keeps the old formula", function()
            enter(page.formulaInput, "bad(")
            assert.are.equal("unexpected symbol (at position 4)", page.formulaMessage:GetText())
            assert.are.equal("scanmarket", stored().lines[1].formula)
            assert.are.equal("scanmarket", page.formulaInput:GetText())
        end)

        it("toggles the enabled box of a row", function()
            local row = page.list.rows[2]
            row.enabledCheck:SetChecked(false)
            click(row.enabledCheck)
            assert.is_false(stored().lines[2].enabled)
            assert.is_false(page.list.rows[2].enabledCheck:GetChecked())
        end)

        it("toggles age and days", function()
            page.ageCheck:SetChecked(false)
            click(page.ageCheck)
            assert.is_false(stored().lines[1].showAge)
            page.samplesCheck:SetChecked(false)
            click(page.samplesCheck)
            assert.is_false(stored().lines[1].showSamples)
            page.samplesCheck:SetChecked(true)
            click(page.samplesCheck)
            assert.is_true(stored().lines[1].showSamples)
        end)
    end)

    describe("order and removal", function()
        it("moves a line up and down", function()
            selectLine(2)
            click(page.upButton)
            assert.are.same({ "Min", "Market", "Max" }, labels())
            click(page.downButton)
            click(page.downButton)
            assert.are.same({ "Market", "Max", "Min" }, labels())
            assert.are.equal("Min", page.header:GetText())
        end)

        it("removes a line after the confirm", function()
            click(page.list.rows[2].removeButton)
            assert.is_truthy(mock.popup.text:find("Min", 1, true))
            assert.are.equal(3, #stored().lines)
            mock.acceptPopup()
            assert.are.same({ "Market", "Max" }, labels())
        end)

        it("keeps the line when the confirm is cancelled", function()
            click(page.list.rows[2].removeButton)
            mock.cancelPopup()
            assert.are.equal(3, #stored().lines)
        end)

        it("selects another line when the selected line goes", function()
            click(page.list.rows[1].removeButton)
            mock.acceptPopup()
            assert.are.equal("Min", page.header:GetText())
        end)

        it("resets to the defaults after the confirm", function()
            enter(page.labelInput, "Changed")
            click(page.addButton)
            click(page.resetButton)
            assert.are.equal(4, #stored().lines)
            mock.acceptPopup()
            assert.are.same({ "Market", "Min", "Max" }, labels())
        end)
    end)

    describe("global flags", function()
        it("shows and saves the flags", function()
            assert.is_true(page.group:GetChecked())
            page.group:SetChecked(false)
            click(page.group)
            page.operation:SetChecked(false)
            click(page.operation)
            page.counts:SetChecked(false)
            click(page.counts)
            local data = stored()
            assert.is_false(data.showGroup)
            assert.is_false(data.showOperation)
            assert.is_false(data.showCounts)
        end)
    end)

    describe("preview", function()
        it("shows the formula status without an example", function()
            assert.are.equal("formula ok (sources: scanmarket)", page.preview:GetText())
        end)

        it("shows the error of a formula that does not compile", function()
            tc = ns.TooltipConfig.New(newDB({}))
            tc:AddLine("Broken", "bad(")
            build()
            selectLine(4)
            assert.are.equal("error at 4: unexpected symbol - near \"bad(\"", page.preview:GetText())
        end)

        it("shows the row of the line for an item id", function()
            enter(page.exampleInput, "1")
            assert.are.equal("Market  5s", page.preview:GetText())
        end)

        it("shows invalid price for an item without data", function()
            enter(page.exampleInput, "2")
            assert.are.equal("Market  invalid price", page.preview:GetText())
        end)

        it("shows only the selected line, also when it is disabled", function()
            tc:UpdateLine(2, { enabled = false })
            subscribed()
            selectLine(2)
            enter(page.exampleInput, "1")
            assert.are.equal("Min  5s", page.preview:GetText())
        end)

        it("resolves an item name", function()
            enter(page.exampleInput, "linen")
            assert.are.equal("", page.exampleStatus:GetText())
            assert.are.equal("Market  5s", page.preview:GetText())
        end)

        it("shows the name message", function()
            enter(page.exampleInput, "x")
            assert.are.equal("type at least 2 characters of the name", page.exampleStatus:GetText())
        end)

        it("uses buildPreview when it is given", function()
            local seen
            extra = {
                buildPreview = function(input, config)
                    seen = { input = input, lines = #config.lines }
                    return { { left = "Custom", right = "9g" } }
                end,
            }
            build()
            enter(page.exampleInput, "1")
            assert.are.same({ input = "1", lines = 1 }, seen)
            assert.are.equal("Custom  9g", page.preview:GetText())
        end)

        it("says that formulas are missing without a formula runner", function()
            run = nil
            build()
            assert.are.equal("formulas are not available this session", page.preview:GetText())
        end)
    end)

    describe("formula editor", function()
        local dialog

        local function open()
            click(page.expandButton)
            dialog = ns.Kit.EditorDialog("FlipsideFormulaEditor")
        end

        it("opens with the label and the formula", function()
            open()
            assert.is_true(dialog:IsShown())
            assert.are.equal("Market", dialog.title)
            assert.are.equal("scanmarket", dialog.input:GetText())
        end)

        it("saves the formula with line breaks as spaces", function()
            open()
            dialog.input.EditBox:SetText("2 *\nscanmarket")
            click(dialog.saveButton)
            assert.are.equal("2 * scanmarket", stored().lines[1].formula)
            assert.are.equal("2 * scanmarket", page.formulaInput:GetText())
        end)

        it("shows the error of a bad formula from the editor", function()
            open()
            dialog.input.EditBox:SetText("bad(")
            click(dialog.saveButton)
            assert.are.equal("unexpected symbol (at position 4)", page.formulaMessage:GetText())
            assert.are.equal("scanmarket", stored().lines[1].formula)
        end)
    end)

    describe("read-only settings", function()
        before_each(function()
            db = newDB({})
            db.IsReadOnly = function()
                return true
            end
            tc = ns.TooltipConfig.New(db)
            build()
        end)

        it("shows the message and disables the controls", function()
            assert.is_true(page.readOnly:IsShown())
            assert.are.equal("Settings are read-only", page.readOnly:GetText())
            for _, widget in ipairs({ page.addButton, page.upButton, page.downButton, page.resetButton,
                page.labelInput, page.formulaInput, page.expandButton, page.ageCheck, page.samplesCheck,
                page.group, page.operation, page.counts, page.list.rows[1].enabledCheck,
                page.list.rows[1].removeButton }) do
                assert.is_false(widget.enabled)
            end
        end)

        it("hides the message when the settings can change", function()
            tc = ns.TooltipConfig.New(newDB({}))
            build()
            assert.is_false(page.readOnly:IsShown())
            assert.is_true(page.addButton.enabled)
        end)

        it("shows the refusal text when a change is tried", function()
            click(page.addButton)
            assert.are.equal("settings are read-only", page.status:GetText())
        end)
    end)
end)
