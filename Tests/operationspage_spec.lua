local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local KIT = { "Theme", "Window", "Widgets", "Prompt", "Tabs", "List", "Combat" }

local function load()
    local ns = {}
    for _, name in ipairs(KIT) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    assert(loadfile(manifest.path("ItemString")))("Flipside", ns)
    assert(loadfile(manifest.path("SettingsDB")))("Flipside", ns)
    assert(loadfile(manifest.path("GroupTree")))("Flipside", ns)
    assert(loadfile(manifest.path("TooltipLines")))("Flipside", ns)
    assert(loadfile(manifest.path("OperationSchema")))("Flipside", ns)
    assert(loadfile(manifest.path("RulesStore")))("Flipside", ns)
    assert(loadfile(manifest.path("ItemNameIndex")))("Flipside", ns)
    assert(loadfile(manifest.path("FormulaPage")))("Flipside", ns)
    assert(loadfile(manifest.path("RulesExport")))("Flipside", ns)
    assert(loadfile(manifest.path("RulesImport")))("Flipside", ns)
    assert(loadfile(manifest.path("OperationsPage")))("Flipside", ns)
    return ns
end

-- Client methods that the mock lacks.
local function stubMethods()
    local probe = CreateFrame("Frame")
    getmetatable(probe).__index.SetJustifyH = function() end
end

describe("OperationsPage", function()
    local ns, rules, page, run, index, missing, later, saved, subscribed, customSources

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
            customSources = customSources,
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

    local function fill(window, text)
        window.input:SetText(text)
        window.input.scripts.OnTextChanged(window.input)
    end

    local function pickChoice(window, value)
        for _, item in ipairs(window.choice.menuItems) do
            if item.value == value then
                item.pick()
            end
        end
    end

    local function newWindow()
        return ns.Kit.Prompt("FlipsideNewOperationPrompt")
    end

    -- Click New, choose the type, type the name and press OK. Returns the window.
    local function create(opType, name)
        click(page.newButton)
        local window = newWindow()
        pickChoice(window, opType)
        fill(window, name)
        click(window.okButton)
        return window
    end

    local function rightClick(index)
        local row = page.list.rows[index]
        row.scripts.OnClick(row, "RightButton")
    end

    local function menuClick(text)
        for _, item in ipairs(mock.menu.items) do
            if item.text == text then
                item.onClick()
                return
            end
        end
        error("no menu entry " .. text)
    end

    local function menuItem(text)
        for _, item in ipairs(mock.menu.items) do
            if item.text == text then
                return item
            end
        end
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
        subscribed, customSources = nil, nil
        build()
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("layout", function()
        it("puts both lists on the inset background", function()
            assert.are.equal("InsetFrameTemplate", page.list.frame.template)
            assert.are.equal("InsetFrameTemplate", page.fieldList.frame.template)
        end)

        it("sets the placeholders", function()
            assert.are.equal("Item name, link or id", page.exampleInput.placeholder:GetText())
        end)
    end)

    describe("operation list", function()        it("is empty at first with a hint in the header", function()
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
                local window = create(opType, "Op " .. opType)
                local list = rules:ListOperations(opType)
                assert.are.equal(1, #list)
                assert.are.equal("Op " .. opType .. " (" .. ns.OperationSchema.TypeLabel(opType) .. ")",
                    page.header:GetText())
                assert.is_false(window:IsShown())
                for _, field in ipairs(ns.OperationSchema.Fields(opType)) do
                    local part = page.FieldPart(field.key)
                    assert.is_table(part, field.key)
                    local value = field.default
                    if field.kind == "formula" or field.kind == "text" then
                        assert.are.equal(value, part.input:GetText())
                    elseif field.kind == "money" or field.kind == "number" then
                        assert.are.equal(tostring(value), part.number:GetText())
                    elseif field.kind == "choice" then
                        assert.are.equal(value, part.choice:GetValue())
                    elseif field.kind == "classes" then
                        -- The spec has no client item class API, so the field has a label and no control.
                        assert.is_nil(part.classes, field.key)
                        assert.are.equal("", value)
                    else
                        assert.are.equal(value, part.check:GetChecked())
                    end
                end
            end
        end)

        it("opens a window that asks for the type first and then the name", function()
            click(page.newButton)
            local window = newWindow()
            assert.is_true(window:IsShown())
            assert.are.equal("New operation", window.title)
            assert.are.equal("Type", window.choiceLabel:GetText())
            assert.are.equal("Name", window.label:GetText())
            assert.is_true(window.choice:IsShown())
            local types = {}
            for _, item in ipairs(window.choice.menuItems) do
                types[#types + 1] = item.value
            end
            assert.are.same(ns.OperationSchema.TYPES, types)
            local choiceY, inputY = window.choice.points[1][5], window.input.points[1][5]
            assert.is_true(choiceY > inputY)
            assert.is_false(window.okButton.enabled)
            assert.are.same({}, rules:ListOperations())
        end)

        it("starts with the type of the list filter", function()
            pickFilter("buying")
            click(page.newButton)
            assert.are.equal("buying", newWindow().choice:GetValue())
        end)

        it("has no name box, no type drop-down and no Duplicate, Rename or Delete button", function()
            assert.is_nil(page.nameInput)
            assert.is_nil(page.newType)
            assert.is_nil(page.duplicateButton)
            assert.is_nil(page.renameButton)
            assert.is_nil(page.deleteButton)
        end)

        it("shows the fields in schema sequence", function()
            create("selling", "Main")
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
            create("selling", "Main")
            assert.are.equal("selling", page.filter:GetValue())
            assert.are.same({ "Main (Selling)" }, listTexts())
        end)

        it("refuses an empty name", function()
            local window = create("selling", "  ")
            assert.is_true(window:IsShown())
            assert.is_false(window.okButton.enabled)
            assert.are.same({}, rules:ListOperations())
        end)

        it("shows the store message in the window for a duplicate name and keeps it open", function()
            create("selling", "Main")
            local window = create("selling", "main")
            assert.is_true(window:IsShown())
            assert.are.equal("an operation of this type has this name", window.error:GetText())
            assert.are.equal(1, #rules:ListOperations())
            fill(window, "Other")
            assert.are.equal("", window.error:GetText())
            click(window.okButton)
            assert.are.equal(2, #rules:ListOperations())
        end)

        it("allows the same name for another type", function()
            create("selling", "Main")
            create("buying", "Main")
            assert.are.equal(2, #rules:ListOperations())
        end)
    end)

    describe("context menu", function()
        local id

        before_each(function()
            create("selling", "Main")
            id = rules:ListOperations()[1].id
        end)

        it("opens on a right click, selects the row and lists Rename, Duplicate and Delete", function()
            page.Select(nil)
            rightClick(1)
            assert.are.equal(id, rules:ListOperations()[1].id)
            assert.are.equal("Main (Selling)", page.header:GetText())
            assert.are.equal(page.list.rows[1], mock.menu.owner)
            assert.are.equal("Main", mock.menu.title)
            assert.are.equal("Rename", mock.menu.items[1].text)
            assert.are.equal("Duplicate", mock.menu.items[2].text)
            assert.are.equal("Delete", mock.menu.items[3].text)
            assert.is_true(menuItem("Rename").enabled)
        end)

        it("does not open on a left click", function()
            mock.menu = nil
            page.list.rows[1].scripts.OnClick(page.list.rows[1], "LeftButton")
            assert.is_nil(mock.menu)
        end)

        it("disables the entries in a read-only store", function()
            rules._loadFailed = true
            rightClick(1)
            assert.is_false(menuItem("Rename").enabled)
            assert.is_false(menuItem("Duplicate").enabled)
            assert.is_false(menuItem("Delete").enabled)
        end)

        it("renames in a window with the current name and keeps the selection", function()
            rightClick(1)
            menuClick("Rename")
            local window = ns.Kit.Prompt("FlipsideRenameOperationPrompt")
            assert.is_true(window:IsShown())
            assert.are.equal("Main", window.input:GetText())
            fill(window, "  Prime  ")
            click(window.okButton)
            assert.are.equal("Prime", rules:GetOperation(id).name)
            assert.are.equal("Prime (Selling)", page.header:GetText())
            assert.are.same({ "Prime (Selling)" }, listTexts())
            assert.is_false(window:IsShown())
        end)

        it("refuses a rename to a name in use and shows the message in the window", function()
            create("selling", "Other")
            page.Select(id)
            rightClick(1)
            menuClick("Rename")
            local window = ns.Kit.Prompt("FlipsideRenameOperationPrompt")
            fill(window, "OTHER")
            click(window.okButton)
            assert.are.equal("an operation of this type has this name", window.error:GetText())
            assert.is_true(window:IsShown())
            assert.are.equal("Main", rules:GetOperation(id).name)
        end)

        it("refuses an empty name and a name of more than 40 characters", function()
            rightClick(1)
            menuClick("Rename")
            local window = ns.Kit.Prompt("FlipsideRenameOperationPrompt")
            fill(window, "")
            assert.is_false(window.okButton.enabled)
            fill(window, string.rep("x", 41))
            click(window.okButton)
            assert.are.equal("name must have 1 to 40 characters", window.error:GetText())
            assert.are.equal("Main", rules:GetOperation(id).name)
        end)

        it("duplicates into an independent operation after it asks for the name", function()
            rightClick(1)
            menuClick("Duplicate")
            local window = ns.Kit.Prompt("FlipsideCopyOperationPrompt")
            assert.is_true(window:IsShown())
            fill(window, "Copy")
            click(window.okButton)
            local list = rules:ListOperations()
            assert.are.equal(2, #list)
            local copyID = list[1].name == "Copy" and list[1].id or list[2].id
            assert.are_not.equal(id, copyID)
            assert.are.equal("Copy (Selling)", page.header:GetText())
            enter(page.FieldPart("postCap").number, "7")
            assert.are.equal(7, rules:GetOperation(copyID).settings.postCap)
            assert.are.equal(0, rules:GetOperation(id).settings.postCap)
        end)

        it("refuses a duplicate name for the copy", function()
            rightClick(1)
            menuClick("Duplicate")
            local window = ns.Kit.Prompt("FlipsideCopyOperationPrompt")
            fill(window, "main")
            click(window.okButton)
            assert.are.equal("an operation of this type has this name", window.error:GetText())
            assert.are.equal(1, #rules:ListOperations())
        end)

        it("asks first and names the group count", function()
            rules:CreateGroup(1, "Herbs")
            rules:AttachOperation(1, "selling", id)
            rules:AttachOperation(2, "selling", id)
            rightClick(1)
            menuClick("Delete")
            assert.are.equal('Delete the operation "Main" (Selling)? It is used by 2 groups.', mock.popup.text)
            assert.is_table(rules:GetOperation(id))
        end)

        it("says that no group uses it", function()
            rightClick(1)
            menuClick("Delete")
            assert.are.equal('Delete the operation "Main" (Selling)? No group uses it.', mock.popup.text)
        end)

        it("uses the singular for one group", function()
            rules:AttachOperation(1, "selling", id)
            rightClick(1)
            menuClick("Delete")
            assert.is_truthy(mock.popup.text:find("1 group.", 1, true))
        end)

        it("deletes on accept and detaches it", function()
            rules:AttachOperation(1, "selling", id)
            rightClick(1)
            menuClick("Delete")
            mock.acceptPopup()
            assert.is_nil(rules:GetOperation(id))
            assert.are.same({}, rules:GroupsUsing(id))
            assert.are.equal("No operation selected", page.header:GetText())
            assert.are.same({}, listTexts())
        end)

        it("keeps the operation on cancel", function()
            rightClick(1)
            menuClick("Delete")
            mock.cancelPopup()
            assert.is_table(rules:GetOperation(id))
            assert.are.equal("Main (Selling)", page.header:GetText())
        end)
    end)

    describe("import", function()
        it("has an Import button in the toolbar next to New", function()
            assert.is_table(page.importButton)
            assert.are.equal("Import", page.importButton:GetText())
            assert.are.equal("New", page.newButton:GetText())
        end)

        it("is off without custom sources", function()
            assert.is_false(page.importButton.enabled)
        end)

        it("opens the import dialog below Base and shows a parse error", function()
            customSources = {}
            build()
            assert.is_true(page.importButton.enabled)
            click(page.importButton)
            assert.is_true(page.importDialog:IsShown())
            assert.are.equal("Import below Base", page.importDialog.title)
            page.importDialog.input.EditBox:SetText("bogus")
            click(page.importDialog.saveButton)
            assert.is_truthy(page.status:GetText():find("not a Flipside rules export", 1, true))
            assert.is_nil(mock.popup)
        end)
    end)
    describe("fields", function()
        local id

        before_each(function()
            create("selling", "Main")
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
            assert.are.equal("2s 50c", part.moneyText:GetText())
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
            assert.are.equal("2 hours", part.choice.menuItems[1].text)
            part.choice.menuItems[2].pick()
            assert.are.equal(8, setting("duration"))
            assert.are.equal(8, part.choice:GetValue())
        end)

        it("saves the rule limits of a selling operation", function()
            for key, value in pairs({ stackSize = 5, keepInBags = 7, postCap = 9 }) do
                local part = page.FieldPart(key)
                assert.is_table(part, key)
                enter(part.number, tostring(value))
                assert.are.equal(value, setting(key))
            end
            local part = page.FieldPart("stackSize")
            enter(part.number, "1001")
            assert.are.equal("Enter a number from 0 to 1000.", part.message:GetText())
            assert.are.equal(5, setting("stackSize"))
            assert.are.equal("Max stack size", part.label:GetText())
        end)

        it("shows and saves the vendor skip box, on by default", function()
            local part = page.FieldPart("vendorSkip")
            assert.are.equal("Skip if vendor pays more", part.label:GetText())
            assert.is_true(part.check:GetChecked())
            part.check:SetChecked(false)
            part.check.scripts.OnClick(part.check)
            assert.is_false(setting("vendorSkip"))
        end)

        it("shows the max price formula of a buying operation and lets it be empty", function()
            create("buying", "B")
            local buyID
            for _, op in ipairs(rules:ListOperations()) do
                if op.type == "buying" then
                    buyID = op.id
                end
            end
            local part = page.FieldPart("maxPrice")
            assert.is_table(part)
            assert.are.equal("scanmarket", part.input:GetText())
            enter(part.input, "1.5 * scanmarket")
            assert.are.equal("1.5 * scanmarket", rules:GetOperation(buyID).settings.maxPrice)
            enter(part.input, "")
            assert.are.equal("", part.message:GetText())
            assert.are.equal("", rules:GetOperation(buyID).settings.maxPrice)
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
            create("vendoring", "V")
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
            create("selling", "Main")
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
            assert.are.equal("5s", part.preview:GetText())
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
            assert.are.equal("5s", part.preview:GetText())
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
            assert.are.equal("5s", part.preview:GetText())
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
            create("selling", "Main")
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
            create("selling", "Main")
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
            assert.is_false(page.newButton.enabled)
            assert.is_false(page.importButton.enabled)
            local window = create("selling", "Main")
            assert.are.equal("settings are read-only", window.error:GetText())
        end)

        it("shows an enabled page for a writable store", function()
            assert.is_false(page.readOnly:IsShown())
            assert.is_true(page.newButton.enabled)
        end)

        it("disables the field widgets of a read-only store", function()
            create("selling", "Main")
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
