local mock = require("Tests.wow_mock")

local KIT = { "Theme", "Window", "Widgets", "Tabs", "List", "Combat" }

local function load()
    local ns = {}
    for _, name in ipairs(KIT) do
        assert(loadfile("UI/Kit/" .. name .. ".lua"))("Flipside", ns)
    end
    assert(loadfile("Core/ItemString.lua"))("Flipside", ns)
    assert(loadfile("Core/SettingsDB.lua"))("Flipside", ns)
    assert(loadfile("Services/GroupTree.lua"))("Flipside", ns)
    assert(loadfile("Services/OperationSchema.lua"))("Flipside", ns)
    assert(loadfile("Services/RulesStore.lua"))("Flipside", ns)
    assert(loadfile("Services/ItemNameIndex.lua"))("Flipside", ns)
    assert(loadfile("UI/Pages/FormulaPage.lua"))("Flipside", ns)
    assert(loadfile("UI/Pages/OperationsPage.lua"))("Flipside", ns)
    return ns
end

-- Client methods that the mock lacks.
local function stubMethods()
    local probe = CreateFrame("Frame")
    getmetatable(probe).__index.SetJustifyH = function() end
end

describe("OperationsPage", function()
    local ns, rules, page, run, index, missing, later, saved, subscribed

    local function newRules(data)
        local db = ns.SettingsDB.New(data, { character = "Me", schemaVersion = 1 })
        return ns.RulesStore.New(db, {
            compile = function(text)
                return run:Compile(text)
            end,
        })
    end

    local function build()
        page = ns.OperationsPage.Build(CreateFrame("Frame", nil, UIParent), {
            rules = rules,
            formulaRun = run,
            itemNameIndex = index,
            subscribe = function(fn)
                subscribed = fn
            end,
        })
    end

    local function names(list)
        local out = {}
        for _, entry in ipairs(list) do
            out[#out + 1] = entry.name .. " (" .. ns.OperationSchema.TypeLabel(entry.type) .. ")"
        end
        return out
    end

    local function listTexts()
        local out = {}
        for index2, row in ipairs(page.list.rows) do
            if row:IsShown() and page.list.data[index2] then
                out[#out + 1] = row.nameText:GetText()
            end
        end
        return out
    end

    local function click(button)
        button.scripts.OnClick(button)
    end

    local function pickFilter(value)
        for _, item in ipairs(page.filter.menuItems) do
            if item.value == value then
                item.pick()
            end
        end
    end

    local function pickType(value)
        for _, item in ipairs(page.newType.menuItems) do
            if item.value == value then
                item.pick()
            end
        end
    end

    local function typeName(text)
        page.nameInput:SetText(text)
    end

    local function enter(widget, text)
        widget:SetText(text)
        widget.scripts.OnEnterPressed(widget)
    end

    before_each(function()
        mock.reset()
        stubMethods()
        _G.ScrollUtil = nil
        ns = load()
        saved = {}
        missing, later = {}, {}
        run = {
            Compile = function(_, text)
                if text:find("bad(", 1, true) then
                    return nil, { message = "unexpected symbol", pos = 4 }
                end
                return { names = { "scanmarket" }, later = later }
            end,
            Evaluate = function(self, text, item)
                local compiled, err = self:Compile(text)
                if not compiled then
                    return nil, { kind = "error", message = err.message, pos = err.pos }
                end
                if item == "1" then
                    return 500, { kind = "ok", missing = {}, later = later }
                end
                return nil, { kind = "invalid", missing = missing, later = later }
            end,
        }
        index = {
            Resolve = function(_, text)
                if text == "linen" then
                    return { kind = "name", matches = { { itemID = 1, name = "Linen", key = "1" } }, pendingCount = 0 }
                elseif text == "none" then
                    return { kind = "name", matches = {}, pendingCount = 2 }
                end
                return { kind = "error", message = "type at least 2 characters of the name" }
            end,
        }
        rules = newRules(saved)
        subscribed = nil
        build()
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("operation list", function()
        it("is empty at first with a hint in the header", function()
            assert.are.same({}, listTexts())
            assert.are.equal("No operation selected", page.header:GetText())
            assert.is_false(page.fieldList.frame:IsShown())
        end)

        it("lists operations with the type and filters by type", function()
            rules:CreateOperation("selling", "Sell")
            rules:CreateOperation("buying", "Buy")
            rules:CreateOperation("vendoring", "Vend")
            page.Refresh()
            assert.are.same({ "Buy (Buying)", "Sell (Selling)", "Vend (Vendoring)" }, listTexts())
            pickFilter("buying")
            assert.are.same({ "Buy (Buying)" }, listTexts())
            pickFilter("all")
            assert.are.equal(3, #page.list.data)
            assert.are.same({ "Buy (Buying)", "Sell (Selling)", "Vend (Vendoring)" }, names(page.list.data))
        end)

        it("selects an operation on click and shows its header", function()
            local id = rules:CreateOperation("selling", "Sell")
            page.Refresh()
            page.list.rows[1].scripts.OnClick()
            assert.are.equal("Sell (Selling)", page.header:GetText())
            assert.is_true(page.fieldList.frame:IsShown())
            assert.are.equal("GameFontHighlight", page.list.rows[1].nameText.fontObject)
            assert.is_table(rules:GetOperation(id))
        end)

        it("clears the selection when the filter hides the operation", function()
            local id = rules:CreateOperation("selling", "Sell")
            page.Select(id)
            pickFilter("buying")
            assert.are.equal("No operation selected", page.header:GetText())
        end)

        it("refreshes through the subscribe callback", function()
            assert.is_function(subscribed)
            rules:CreateOperation("selling", "Late")
            subscribed()
            assert.are.same({ "Late (Selling)" }, listTexts())
        end)
    end)

    describe("new", function()
        it("creates an operation of each type with its defaults", function()
            for _, opType in ipairs(ns.OperationSchema.TYPES) do
                pickType(opType)
                typeName("Op " .. opType)
                click(page.newButton)
                local list = rules:ListOperations(opType)
                assert.are.equal(1, #list)
                assert.are.equal("Op " .. opType .. " (" .. ns.OperationSchema.TypeLabel(opType) .. ")",
                    page.header:GetText())
                assert.are.equal("", page.nameInput:GetText())
                for _, field in ipairs(ns.OperationSchema.Fields(opType)) do
                    local part = page.FieldPart(field.key)
                    assert.is_table(part, field.key)
                    local value = field.default
                    if field.kind == "formula" then
                        assert.are.equal(value, part.input:GetText())
                    elseif field.kind == "money" or field.kind == "number" then
                        assert.are.equal(tostring(value), part.number:GetText())
                    elseif field.kind == "choice" then
                        assert.are.equal(value, part.choice:GetValue())
                    else
                        assert.are.equal(value, part.check:GetChecked())
                    end
                end
            end
        end)

        it("shows the fields in schema sequence", function()
            pickType("selling")
            typeName("Main")
            click(page.newButton)
            local keys = {}
            for _, row in ipairs(page.fieldList.rows) do
                if row:IsShown() then
                    keys[#keys + 1] = row.active.field.key
                end
            end
            local expected = {}
            for _, field in ipairs(ns.OperationSchema.Fields("selling")) do
                expected[#expected + 1] = field.key
            end
            assert.are.same(expected, keys)
        end)

        it("widens the filter to the new type", function()
            pickFilter("buying")
            pickType("selling")
            typeName("Main")
            click(page.newButton)
            assert.are.equal("selling", page.filter:GetValue())
            assert.are.same({ "Main (Selling)" }, listTexts())
        end)

        it("shows the store message for a duplicate name or an empty name", function()
            typeName("")
            click(page.newButton)
            assert.are.equal("Type a name first.", page.status:GetText())
            typeName("Main")
            click(page.newButton)
            typeName("main")
            click(page.newButton)
            assert.are.equal("an operation of this type has this name", page.status:GetText())
            assert.are.equal(1, #rules:ListOperations())
        end)
    end)

    describe("duplicate and rename", function()
        local id

        before_each(function()
            typeName("Main")
            click(page.newButton)
            id = rules:ListOperations()[1].id
        end)

        it("duplicates into an independent operation", function()
            typeName("Copy")
            click(page.duplicateButton)
            local list = rules:ListOperations()
            assert.are.equal(2, #list)
            local copyID = list[1].name == "Copy" and list[1].id or list[2].id
            assert.are_not.equal(id, copyID)
            assert.are.equal("Copy (Selling)", page.header:GetText())
            enter(page.FieldPart("postCap").number, "7")
            assert.are.equal(7, rules:GetOperation(copyID).settings.postCap)
            assert.are.equal(0, rules:GetOperation(id).settings.postCap)
        end)

        it("asks for a name before it duplicates", function()
            click(page.duplicateButton)
            assert.are.equal("Type a name first.", page.status:GetText())
            assert.are.equal(1, #rules:ListOperations())
        end)

        it("renames and keeps the selection", function()
            typeName("  Prime  ")
            click(page.renameButton)
            assert.are.equal("Prime", rules:GetOperation(id).name)
            assert.are.equal("Prime (Selling)", page.header:GetText())
            assert.are.same({ "Prime (Selling)" }, listTexts())
        end)

        it("refuses a rename to a name in use and shows the message", function()
            typeName("Other")
            click(page.newButton)
            page.Select(id)
            typeName("OTHER")
            click(page.renameButton)
            assert.are.equal("an operation of this type has this name", page.status:GetText())
            assert.are.equal("Main", rules:GetOperation(id).name)
        end)

        it("refuses a name of more than 40 characters", function()
            typeName(string.rep("x", 41))
            click(page.renameButton)
            assert.are.equal("name must have 1 to 40 characters", page.status:GetText())
        end)
    end)

    describe("delete", function()
        local id

        before_each(function()
            typeName("Main")
            click(page.newButton)
            id = rules:ListOperations()[1].id
        end)

        it("asks first and names the group count", function()
            rules:CreateGroup(1, "Herbs")
            rules:AttachOperation(1, "selling", id)
            rules:AttachOperation(2, "selling", id)
            click(page.deleteButton)
            assert.are.equal('Delete the operation "Main" (Selling)? It is used by 2 groups.', mock.popup.text)
            assert.is_table(rules:GetOperation(id))
        end)

        it("says that no group uses it", function()
            click(page.deleteButton)
            assert.are.equal('Delete the operation "Main" (Selling)? No group uses it.', mock.popup.text)
        end)

        it("uses the singular for one group", function()
            rules:AttachOperation(1, "selling", id)
            click(page.deleteButton)
            assert.is_truthy(mock.popup.text:find("1 group.", 1, true))
        end)

        it("deletes on accept and detaches it", function()
            rules:AttachOperation(1, "selling", id)
            click(page.deleteButton)
            mock.acceptPopup()
            assert.is_nil(rules:GetOperation(id))
            assert.are.same({}, rules:GroupsUsing(id))
            assert.are.equal("No operation selected", page.header:GetText())
            assert.are.same({}, listTexts())
        end)

        it("keeps the operation on cancel", function()
            click(page.deleteButton)
            mock.cancelPopup()
            assert.is_table(rules:GetOperation(id))
            assert.are.equal("Main (Selling)", page.header:GetText())
        end)

        it("does nothing without a selection", function()
            page.Select(nil)
            mock.popup = nil
            click(page.deleteButton)
            assert.is_nil(mock.popup)
        end)
    end)

    describe("fields", function()
        local id

        before_each(function()
            typeName("Main")
            click(page.newButton)
            id = rules:ListOperations()[1].id
        end)

        local function setting(key)
            return rules:GetOperation(id).settings[key]
        end

        it("gives each field a tooltip with its help", function()
            local part = page.FieldPart("minPrice")
            part.input.scripts.OnEnter(part.input)
            assert.are.equal("Minimum price", mock.tooltip.title)
            assert.are.same({ "Never post below this price." }, mock.tooltip.lines)
            assert.are.equal("Minimum price", part.label:GetText())
        end)

        it("saves a formula on Enter and on focus loss", function()
            local part = page.FieldPart("normalPrice")
            enter(part.input, "  2 * scanmarket ")
            assert.are.equal("2 * scanmarket", setting("normalPrice"))
            part.input:SetText("3 * scanmarket")
            part.input.scripts.OnEditFocusLost(part.input)
            assert.are.equal("3 * scanmarket", setting("normalPrice"))
            assert.are.equal("", part.message:GetText())
        end)

        it("refuses a bad formula with its position and keeps the old value", function()
            local part = page.FieldPart("normalPrice")
            enter(part.input, "bad(")
            assert.are.equal("unexpected symbol (at position 4)", part.message:GetText())
            assert.are.equal("scanmarket", setting("normalPrice"))
            assert.are.equal("scanmarket", part.input:GetText())
        end)

        it("refuses an empty formula", function()
            local part = page.FieldPart("maxPrice")
            enter(part.input, "   ")
            assert.are.equal("Enter a formula.", part.message:GetText())
            assert.are.equal("2 * scanmarket", part.input:GetText())
        end)

        it("clears the message after a good save", function()
            local part = page.FieldPart("normalPrice")
            enter(part.input, "bad(")
            enter(part.input, "scanmarket * 2")
            assert.are.equal("", part.message:GetText())
        end)

        it("saves a money field and shows its money text", function()
            local part = page.FieldPart("undercut")
            assert.are.equal("1c", part.moneyText:GetText())
            enter(part.number, "250")
            assert.are.equal(250, setting("undercut"))
            assert.are.equal("250c", part.moneyText:GetText())
        end)

        it("refuses a money value out of range with the range message", function()
            local part = page.FieldPart("undercut")
            enter(part.number, "2000000")
            assert.are.equal("Enter a number from 0 to 1000000.", part.message:GetText())
            assert.are.equal(1, setting("undercut"))
            assert.are.equal("1", part.number:GetText())
            assert.are.equal("1c", part.moneyText:GetText())
        end)

        it("saves a number field and refuses a number out of range", function()
            local part = page.FieldPart("maxDataAgeHours")
            enter(part.number, "100")
            assert.are.equal(100, setting("maxDataAgeHours"))
            enter(part.number, "0")
            assert.are.equal("Enter a number from 1 to 720.", part.message:GetText())
            assert.are.equal(100, setting("maxDataAgeHours"))
            assert.are.equal("100", part.number:GetText())
        end)

        it("refuses empty text in a number field", function()
            local part = page.FieldPart("minSamples")
            enter(part.number, "")
            assert.are.equal("Enter a whole number.", part.message:GetText())
            assert.are.equal(3, setting("minSamples"))
            assert.are.equal("3", part.number:GetText())
        end)

        it("saves a choice", function()
            local part = page.FieldPart("duration")
            assert.are.equal(3, #part.choice.menuItems)
            assert.are.equal("12 hours", part.choice.menuItems[1].text)
            part.choice.menuItems[3].pick()
            assert.are.equal(48, setting("duration"))
            assert.are.equal(48, part.choice:GetValue())
        end)

        it("keeps the old choice when the store refuses the value", function()
            local part = page.FieldPart("duration")
            local pick = part.choice.menuItems[1].pick
            rules._loadFailed = true
            pick()
            assert.are.equal("settings are read-only", part.message:GetText())
            assert.are.equal(24, setting("duration"))
            assert.are.equal(24, part.choice:GetValue())
        end)

        it("saves a bool", function()
            local part = page.FieldPart("cancelUndercut")
            assert.is_true(part.check:GetChecked())
            part.check:SetChecked(false)
            part.check.scripts.OnClick(part.check)
            assert.is_false(setting("cancelUndercut"))
        end)

        it("shows other fields for another type", function()
            pickType("vendoring")
            typeName("V")
            click(page.newButton)
            assert.is_table(page.FieldPart("sellToVendor"))
            assert.is_nil(page.FieldPart("minPrice"))
            assert.is_table(page.FieldPart("maxDataAgeHours"))
        end)

        it("keeps the message of another field", function()
            local one, two = page.FieldPart("normalPrice"), page.FieldPart("maxPrice")
            enter(one.input, "bad(")
            enter(two.input, "scanmarket")
            assert.are.equal("unexpected symbol (at position 4)", one.message:GetText())
            assert.are.equal("", two.message:GetText())
        end)
    end)

    describe("formula preview", function()
        local part

        before_each(function()
            typeName("Main")
            click(page.newButton)
            part = page.FieldPart("normalPrice")
        end)

        local function setExample(text)
            enter(page.exampleInput, text)
            part = page.FieldPart("normalPrice")
        end

        it("says formula ok without an example item", function()
            assert.are.equal("formula ok (sources: scanmarket)", part.preview:GetText())
        end)

        it("shows a compile error with position without an example item", function()
            rules._compile = nil
            rules:SetSetting(rules:ListOperations()[1].id, "normalPrice", "bad(")
            page.Refresh()
            part = page.FieldPart("normalPrice")
            assert.are.equal('error at 4: unexpected symbol - near "bad("', part.preview:GetText())
        end)

        it("shows the money value with an example item", function()
            setExample("1")
            assert.are.equal("500c", part.preview:GetText())
        end)

        it("shows missing and not available names", function()
            missing, later = { "scanmarket" }, { "crafting" }
            setExample("2")
            assert.are.equal("invalid: missing scanmarket - not available yet: crafting", part.preview:GetText())
        end)

        it("shows the later state change on refresh", function()
            missing, later = { "scanmarket" }, { "crafting" }
            setExample("2")
            missing, later = {}, {}
            subscribed()
            part = page.FieldPart("normalPrice")
            assert.are.equal("invalid", part.preview:GetText())
            assert.are.equal("2", page.exampleInput:GetText())
        end)

        it("accepts an item link", function()
            setExample("|cff0070dd|Hitem:2589::::::::|h[Linen]|h|r")
            assert.are.equal("", page.exampleStatus:GetText())
            assert.are.equal("invalid", part.preview:GetText())
        end)

        it("resolves an item name through the index", function()
            setExample("linen")
            assert.are.equal("500c", part.preview:GetText())
        end)

        it("reports an unknown name and a short name, then falls back to compile only", function()
            setExample("none")
            assert.are.equal('no item named "none" in the scan data - 2 item names are still loading',
                page.exampleStatus:GetText())
            assert.are.equal("formula ok (sources: scanmarket)", part.preview:GetText())
            setExample("x")
            assert.are.equal("type at least 2 characters of the name", page.exampleStatus:GetText())
        end)

        it("clears the example with an empty box", function()
            setExample("1")
            setExample("")
            assert.are.equal("formula ok (sources: scanmarket)", part.preview:GetText())
        end)

        it("updates the preview after a save", function()
            setExample("1")
            enter(part.input, "scanmarket * 3")
            assert.are.equal("500c", part.preview:GetText())
            assert.are.equal("scanmarket * 3", part.input:GetText())
        end)

        it("says that formulas are not available without a formula runner", function()
            run = nil
            build()
            page.Select(rules:ListOperations()[1].id)
            assert.are.equal("formulas are not available this session", page.FieldPart("normalPrice").preview:GetText())
        end)
    end)

    describe("formula editor", function()
        local part, dialog

        local function open(key)
            part = page.FieldPart(key or "normalPrice")
            click(part.expand)
            dialog = ns.Kit.EditorDialog("FlipsideFormulaEditor")
        end

        local function save(text)
            dialog.input.EditBox:SetText(text)
            click(dialog.saveButton)
        end

        before_each(function()
            typeName("Main")
            click(page.newButton)
        end)

        it("has an expand button on formula fields only", function()
            assert.is_table(page.FieldPart("normalPrice").expand)
            assert.is_nil(page.FieldPart("undercut").expand)
            assert.is_nil(page.FieldPart("duration").expand)
            assert.is_nil(page.FieldPart("cancelUndercut").expand)
        end)

        it("opens with the field label and the current formula", function()
            open()
            assert.is_true(dialog:IsShown())
            assert.are.equal("Normal price", dialog.title)
            assert.are.equal("scanmarket", dialog.input:GetText())
        end)

        it("saves the formula with line breaks as spaces and shows the preview", function()
            local id = rules:ListOperations()[1].id
            open()
            save("2 *\nscanmarket\r\n+ 1")
            assert.are.equal("2 * scanmarket + 1", rules:GetOperation(id).settings.normalPrice)
            part = page.FieldPart("normalPrice")
            assert.are.equal("2 * scanmarket + 1", part.input:GetText())
            assert.are.equal("formula ok (sources: scanmarket)", part.preview:GetText())
            assert.is_false(dialog:IsShown())
        end)

        it("shows the error next to the field and keeps the old value", function()
            local id = rules:ListOperations()[1].id
            open()
            save("bad(")
            assert.are.equal("unexpected symbol (at position 4)", part.message:GetText())
            assert.are.equal("scanmarket", rules:GetOperation(id).settings.normalPrice)
            assert.are.equal("scanmarket", part.input:GetText())
        end)

        it("changes nothing on Cancel", function()
            local id = rules:ListOperations()[1].id
            open()
            dialog.input.EditBox:SetText("other")
            click(dialog.cancelButton)
            assert.are.equal("scanmarket", rules:GetOperation(id).settings.normalPrice)
            assert.are.equal("", part.message:GetText())
            assert.is_false(dialog:IsShown())
        end)

        it("gives each row room for two preview lines", function()
            local row = page.fieldList.rows[1]
            assert.is_true(row.height >= 40 + 2 * 12 + 8)
        end)

        it("disables the expand button for a read-only store", function()
            local id = rules:ListOperations()[1].id
            rules._loadFailed = true
            page.Select(id)
            assert.is_false(page.FieldPart("normalPrice").expand.enabled)
        end)
    end)

    describe("footer", function()
        it("lists the group paths that use the operation", function()
            typeName("Main")
            click(page.newButton)
            local id = rules:ListOperations()[1].id
            assert.are.equal("Used by: no groups", page.footer:GetText())
            local herbs = rules:CreateGroup(1, "Herbs")
            local leaf = rules:CreateGroup(herbs, "Fine")
            rules:AttachOperation(herbs, "selling", id)
            rules:AttachOperation(leaf, "selling", id)
            page.Refresh()
            assert.are.equal("Used by: Base > Herbs, Base > Herbs > Fine", page.footer:GetText())
        end)
    end)

    describe("read-only", function()
        it("disables the controls and shows one line", function()
            local roData = { _schema = 9 }
            rules = newRules(roData)
            assert.is_true(rules:IsReadOnly())
            build()
            assert.is_true(page.readOnly:IsShown())
            assert.are.equal("Settings are read-only", page.readOnly:GetText())
            for _, button in ipairs({ page.newButton, page.duplicateButton, page.renameButton, page.deleteButton }) do
                assert.is_false(button.enabled)
            end
            assert.is_false(page.nameInput.enabled)
            typeName("Main")
            click(page.newButton)
            assert.are.equal("settings are read-only", page.status:GetText())
        end)

        it("shows an enabled page for a writable store", function()
            assert.is_false(page.readOnly:IsShown())
            assert.is_true(page.newButton.enabled)
        end)

        it("disables the field widgets of a read-only store", function()
            typeName("Main")
            click(page.newButton)
            local id = rules:ListOperations()[1].id
            rules._loadFailed = true
            page.Select(id)
            for _, key in ipairs({ "normalPrice", "undercut", "duration", "cancelUndercut", "minSamples" }) do
                local part = page.FieldPart(key)
                local widget = part.input or part.number or part.choice or part.check
                assert.is_false(widget.enabled, key)
            end
            assert.is_true(page.readOnly:IsShown())
        end)
    end)
end)
