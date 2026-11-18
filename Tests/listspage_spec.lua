local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local LINK = "|cff1eff00|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r"

local function loadModules()
    local ns = { ReportError = function() end }
    for _, name in ipairs({ "EventBus", "SettingsDB", "ItemString", "OperationSchema", "SearchLists", "CraftListMargin",
        "Theme", "Widgets", "Window", "Prompt", "List", "ListsPage" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

describe("ListsPage", function()
    local ns, bus, db, store, deps, content, page, scan

    local function click(widget)
        widget.scripts.OnClick(widget)
    end

    local function submit(box, text)
        box.input:SetText(text)
        box.input.scripts.OnTextChanged(box.input)
        box.okButton.scripts.OnClick(box.okButton)
    end

    local function build()
        page = ns.ListsPage.Build(content, deps)
        return page
    end

    before_each(function()
        mock.reset()
        _G.ScrollUtil = nil
        local methods = getmetatable(CreateFrame("Frame")).__index
        methods.HasFocus = function(self)
            return self.focused == true
        end
        methods.Insert = function(self, text)
            self.text = (self.text or "") .. text
        end
        ns = loadModules()
        -- The scan record of the mock is the value table that ScanSources.Compute would give.
        ns.ScanSources = {
            Compute = function(record)
                return record
            end,
        }
        bus = ns.EventBus.New({})
        db = ns.SettingsDB.New({}, { character = "Alice-Realm", schemaVersion = 1 })
        store = ns.SearchLists.New(db, { bus = bus })
        scan = {}
        content = CreateFrame("Frame", nil, UIParent)
        deps = {
            searchLists = store, bus = bus,
            getRecord = function(key)
                return scan[key]
            end,
            now = function()
                return 1000
            end,
        }
    end)

    after_each(function()
        _G.ChatEdit_InsertLink, _G.ChatFrameUtil = nil, nil
        mock.teardown()
    end)

    describe("the lists", function()
        it("shows every list with its kind and count, and selects the first", function()
            store:Create("Pants", { { itemID = 100 } }, "craft")
            store:Create("Herbs", { { itemID = 1 }, { itemID = 2 } })
            build()
            assert.are.equal(2, #page.lists.data)
            assert.are.equal("Herbs (2)", page.lists.data[1].text)
            assert.are.equal("search", page.lists.data[1].tag)
            assert.are.equal("Pants (1)", page.lists.data[2].text)
            assert.are.equal("craft", page.lists.data[2].tag)
            assert.are.equal("craft", page.lists.rows[2].tag:GetText())
            assert.are.equal(page.lists.data[1].id, page.selected)
            assert.are.equal("Herbs (search list)", page.title:GetText())
        end)

        it("needs no Auction House, and shows an empty state with no list", function()
            build()
            assert.are.equal("Pick a list, or click New.", page.title:GetText())
            assert.is_false(page.rename:IsEnabled())
            assert.is_false(page.delete:IsEnabled())
            assert.is_false(page.addItem:IsEnabled())
            assert.is_true(page.new:IsEnabled())
            local ok, err = page.AddItem("2589")
            assert.is_false(ok)
            assert.are.equal("pick a list first", err)
        end)

        it("selects the list that a click picks", function()
            local first = store:Create("Herbs", { { itemID = 1 } })
            local second = store:Create("Pants", { { itemID = 100, count = 4 } }, "craft")
            build()
            assert.are.equal(first, page.selected)
            click(page.lists.rows[2])
            assert.are.equal(second, page.selected)
            assert.are.equal("4× item 100", page.items.data[1].text)
            assert.is_true(page.results.frame:IsShown())
            assert.is_false(page.Select(999))
            assert.are.equal(second, page.selected)
        end)

        it("makes a search list and a craft list with the New prompt", function()
            build()
            click(page.new)
            local box = ns.Kit.Prompt("FlipsideListsNewPrompt")
            assert.is_true(box:IsShown())
            submit(box, "Herbs")
            assert.is_false(box:IsShown())
            assert.are.equal("search", store:Get(page.selected).kind)
            assert.is_false(page.results.frame:IsShown())
            assert.is_false(page.addResult:IsShown())
            click(page.new)
            box.choiceValue = "craft"
            submit(box, "Shirts")
            assert.are.equal("craft", store:Get(page.selected).kind)
            assert.are.equal("Shirts (craft list)", page.title:GetText())
            assert.is_true(page.results.frame:IsShown())
            assert.is_true(page.addResult:IsShown())
            assert.are.equal(2, #page.lists.data)
        end)

        it("keeps the New prompt open with the error for a name in use", function()
            store:Create("Herbs", {})
            build()
            click(page.new)
            local box = ns.Kit.Prompt("FlipsideListsNewPrompt")
            submit(box, "herbs")
            assert.is_true(box:IsShown())
            assert.is_not.equal("", box.error:GetText())
            assert.are.equal(1, #store:List())
        end)

        it("renames the selected list with a prompt that starts with the old name", function()
            local id = store:Create("Herbs", {})
            build()
            click(page.rename)
            local box = ns.Kit.Prompt("FlipsideListsRenamePrompt")
            assert.are.equal("Herbs", box.input:GetText())
            submit(box, "Flowers")
            assert.is_false(box:IsShown())
            assert.are.equal("Flowers", store:Get(id).name)
            assert.are.equal("Flowers (0)", page.lists.data[1].text)
            assert.are.equal("Flowers (search list)", page.title:GetText())
        end)

        it("keeps the Rename prompt open with the error for a name in use", function()
            store:Create("Herbs", {})
            local id = store:Create("Pants", {})
            build()
            page.Select(id)
            click(page.rename)
            local box = ns.Kit.Prompt("FlipsideListsRenamePrompt")
            submit(box, "HERBS")
            assert.is_true(box:IsShown())
            assert.are.equal("Pants", store:Get(id).name)
        end)

        it("asks before it deletes a list, and deletes after the accept", function()
            local id = store:Create("Herbs", {})
            store:Create("Pants", {}, "craft")
            build()
            click(page.delete)
            assert.are.equal("FLIPSIDE_DELETE_SEARCH_LIST", mock.popup.which)
            assert.matches("Herbs", mock.popup.text)
            assert.is_not_nil(store:Get(id))
            mock.cancelPopup()
            assert.is_not_nil(store:Get(id))
            click(page.delete)
            mock.acceptPopup()
            assert.is_nil(store:Get(id))
            assert.are.equal(1, #page.lists.data)
            assert.are.equal("Pants", store:Get(page.selected).name)
        end)

        it("deletes and renames the list that the pop-up named, also after the selection changed", function()
            local first = store:Create("Herbs", {})
            local second = store:Create("Pants", {})
            build()
            click(page.delete)
            page.Select(second)
            mock.acceptPopup()
            assert.is_nil(store:Get(first))
            assert.is_not_nil(store:Get(second))
            assert.are.equal(second, page.selected)
            local third = store:Create("Shirts", {})
            page.Select(second)
            click(page.rename)
            local box = ns.Kit.Prompt("FlipsideListsRenamePrompt")
            page.Select(third)
            submit(box, "Trousers")
            assert.are.equal("Trousers", store:Get(second).name)
            assert.are.equal("Shirts", store:Get(third).name)
        end)

        it("draws again when a list changes somewhere else", function()
            local id = store:Create("Herbs", {})
            build()
            store:AddItem(id, { itemID = 5 })
            assert.are.equal(1, #page.items.data)
            assert.are.equal("Herbs (1)", page.lists.data[1].text)
            store:Rename(id, "Flowers")
            assert.are.equal("Flowers (1)", page.lists.data[1].text)
            local other = store:Create("Another", {})
            assert.are.equal(2, #page.lists.data)
            assert.are.equal(id, page.selected)
            store:Delete(id)
            assert.are.equal(other, page.selected)
            assert.are.equal(1, #page.lists.data)
        end)
    end)

    describe("items", function()
        local id

        before_each(function()
            id = store:Create("Herbs", { { itemID = 1, name = "Herb", count = 3 }, { itemID = 2 } })
            build()
        end)

        it("shows the items with their counts", function()
            assert.are.equal("3× Herb", page.items.data[1].text)
            assert.are.equal("item 2", page.items.data[2].text)
            assert.are.equal("3× Herb", page.items.rows[1].text:GetText())
        end)

        it("adds an item by ID, and selects it", function()
            assert.is_true(page.AddItem(" 2589 "))
            local item = store:Get(id).items[3]
            assert.are.equal(2589, item.itemID)
            assert.are.equal("2589", item.key)
            assert.are.equal(3, page.itemSel)
            assert.are.equal(3, #page.items.data)
            assert.are.equal("", page.addInput:GetText())
        end)

        it("adds an item by link, with the name from the link", function()
            page.addInput:SetText(LINK)
            click(page.addItem)
            local item = store:Get(id).items[3]
            assert.are.equal(2589, item.itemID)
            assert.are.equal("Linen Cloth", item.name)
            assert.are.equal("Linen Cloth", page.items.data[3].text)
        end)

        it("adds an item by link with the key from keyFor, and by key", function()
            deps.keyFor = function()
                return "2589#b1"
            end
            assert.is_true(page.AddItem(LINK))
            assert.are.equal("2589#b1", store:Get(id).items[3].key)
            assert.is_true(page.AddItem("25320#s-44"))
            assert.are.equal(25320, store:Get(id).items[4].itemID)
            assert.are.equal("25320#s-44", store:Get(id).items[4].key)
        end)

        it("adds with Enter in the box", function()
            page.addInput:SetText("2589")
            page.addInput.scripts.OnEnterPressed(page.addInput)
            assert.are.equal(3, #store:Get(id).items)
        end)

        it("refuses an item that is in the list, an empty box and a name with no name index", function()
            local ok, err = page.AddItem("1")
            assert.is_false(ok)
            assert.are.equal("The item is in the list.", err)
            assert.are.equal(err, page.status:GetText())
            ok, err = page.AddItem("  ")
            assert.is_false(ok)
            assert.are.equal("enter an item link, ID or key", err)
            ok, err = page.AddItem("Linen")
            assert.is_false(ok)
            assert.are.equal("type an item link, ID or key", err)
            assert.are.equal(2, #store:Get(id).items)
        end)

        it("adds an item by name through the name index", function()
            local matches = { { itemID = 2447, name = "Peacebloom", key = "2447" } }
            deps.itemNameIndex = {
                Find = function(_, text)
                    assert.are.equal("Peacebloom", text)
                    return matches
                end,
            }
            assert.is_true(page.AddItem("Peacebloom"))
            assert.are.equal(2447, store:Get(id).items[3].itemID)
            assert.are.equal("Peacebloom", store:Get(id).items[3].name)
        end)

        it("picks the one exact name, and refuses a name with several matches or none", function()
            local matches = {}
            deps.itemNameIndex = {
                Find = function()
                    return matches
                end,
            }
            matches = {
                { itemID = 7, name = "Linen Cloth", key = "7" }, { itemID = 8, name = "Linen Cloth Bolt", key = "8" },
            }
            assert.is_true(page.AddItem("linen cloth"))
            assert.are.equal(7, store:Get(id).items[3].itemID)
            matches = {
                { itemID = 9, name = "Silk Cloth", key = "9" }, { itemID = 10, name = "Silk Cloth Bolt", key = "10" },
            }
            local ok, err = page.AddItem("Silk")
            assert.is_false(ok)
            assert.matches("2 items match", err)
            matches = {}
            ok, err = page.AddItem("Nothing")
            assert.is_false(ok)
            assert.matches("no item named Nothing", err)
            assert.are.equal(3, #store:Get(id).items)
        end)

        it("edits the count of the selected item", function()
            assert.is_false(page.countSet:IsEnabled())
            click(page.items.rows[2])
            assert.are.equal(2, page.itemSel)
            assert.is_true(page.countSet:IsEnabled())
            assert.is_true(page.itemRemove:IsEnabled())
            page.countInput:SetText("12")
            click(page.countSet)
            assert.are.equal(12, store:Get(id).items[2].count)
            assert.are.equal("12× item 2", page.items.data[2].text)
            assert.are.equal("12", page.countInput:GetText())
            page.countInput:SetText("5")
            page.countInput.scripts.OnEnterPressed(page.countInput)
            assert.are.equal(5, store:Get(id).items[2].count)
            page.countInput:SetText("")
            click(page.countSet)
            assert.is_nil(store:Get(id).items[2].count)
            assert.are.equal("item 2", page.items.data[2].text)
        end)

        it("refuses a count that is not a whole number above 0", function()
            click(page.items.rows[1])
            for _, text in ipairs({ "0", "x", "1.5", "-2" }) do
                page.countInput:SetText(text)
                click(page.countSet)
                assert.are.equal(3, store:Get(id).items[1].count)
                assert.are.equal("the count must be a whole number above 0", page.status:GetText())
            end
            local ok = page.SetCount(nil, "3")
            assert.is_false(ok)
        end)

        it("selects with a click, clears with a second click, and removes the selected item", function()
            click(page.items.rows[1])
            assert.are.equal(1, page.itemSel)
            click(page.items.rows[1])
            assert.is_nil(page.itemSel)
            assert.is_false(page.itemRemove:IsEnabled())
            click(page.items.rows[1])
            click(page.itemRemove)
            assert.are.equal(1, #store:Get(id).items)
            assert.are.equal(2, store:Get(id).items[1].itemID)
            assert.is_nil(page.itemSel)
            assert.are.equal(1, #page.items.data)
        end)

        it("takes a shift-clicked link while the add box has focus", function()
            local hooked = {}
            _G.ChatEdit_InsertLink = function() end
            _G.ChatFrameUtil = { InsertLink = function() end }
            _G.hooksecurefunc = function(first, second, third)
                if type(first) == "string" then
                    hooked[first] = second
                else
                    hooked[second] = third
                end
            end
            build()
            assert.is_function(hooked.ChatEdit_InsertLink)
            assert.is_function(hooked.InsertLink)
            hooked.InsertLink(LINK)
            assert.is_nil(page.addInput:GetText())
            page.addInput.focused = true
            hooked.InsertLink(LINK)
            assert.are.equal(LINK, page.addInput:GetText())
            page.addInput:SetText("")
            hooked.ChatEdit_InsertLink(LINK)
            assert.are.equal(LINK, page.addInput:GetText())
            hooked.ChatEdit_InsertLink(nil)
            click(page.addItem)
            assert.are.equal(2589, store:Get(id).items[3].itemID)
        end)
    end)

    describe("the results of a craft list", function()
        local id

        before_each(function()
            id = store:Create("Pants", { { itemID = 100, count = 4 }, { itemID = 200 } }, "craft")
            store:AddResult(id, { itemID = 300, name = "Dust", min = 1, max = 2 })
            build()
        end)

        it("shows the results with their amounts", function()
            assert.are.equal(1, #page.results.data)
            assert.are.equal("1-2× Dust", page.results.data[1].text)
            assert.are.equal("1-2× Dust", page.results.rows[1].text:GetText())
            assert.are.equal("Materials (count for one craft)", page.itemsLabel:GetText())
        end)

        it("adds a result with the amount 1, or with the amount in the box", function()
            page.addInput:SetText("25320#s-44")
            click(page.addResult)
            local results = store:Get(id).results
            assert.are.equal(2, #results)
            assert.are.equal(25320, results[2].itemID)
            assert.are.equal(1, results[2].min)
            assert.are.equal(1, results[2].max)
            assert.are.equal(2, page.resultSel)
            assert.are.equal("", page.addInput:GetText())
            page.addInput:SetText("400")
            page.amountInput:SetText("2-3")
            click(page.addResult)
            assert.are.equal(2, store:Get(id).results[3].min)
            assert.are.equal(3, store:Get(id).results[3].max)
            assert.are.equal(3, #page.results.data)
        end)

        it("refuses a result that is not valid", function()
            local ok, err = page.AddResult("300", "1")
            assert.is_false(ok)
            assert.are.equal("The item is a result of the list.", err)
            ok, err = page.AddResult("999", "3-2")
            assert.is_false(ok)
            assert.are.equal(err, page.status:GetText())
            ok, err = page.AddResult("999", "abc")
            assert.is_false(ok)
            assert.are.equal("enter an amount such as 2 or 1-2", err)
            ok = page.AddResult("Linen", "1")
            assert.is_false(ok)
            assert.are.equal(1, #store:Get(id).results)
        end)

        it("edits the amount made of the selected result", function()
            assert.is_false(page.resultSet:IsEnabled())
            click(page.results.rows[1])
            assert.are.equal(1, page.resultSel)
            assert.is_true(page.resultSet:IsEnabled())
            assert.are.equal("1-2", page.resultInput:GetText())
            page.resultInput:SetText("4-2")
            click(page.resultSet)
            assert.are.equal(2, store:Get(id).results[1].max)
            assert.is_not.equal("", page.status:GetText())
            page.resultInput:SetText("3-5")
            click(page.resultSet)
            assert.are.equal(3, store:Get(id).results[1].min)
            assert.are.equal(5, store:Get(id).results[1].max)
            assert.are.equal("3-5× Dust", page.results.data[1].text)
            page.resultInput:SetText("2")
            page.resultInput.scripts.OnEnterPressed(page.resultInput)
            assert.are.same({ 2, 2 }, { store:Get(id).results[1].min, store:Get(id).results[1].max })
        end)

        it("removes the selected result and turns the buttons off", function()
            click(page.results.rows[1])
            click(page.resultRemove)
            assert.same({}, store:Get(id).results)
            assert.is_nil(page.resultSel)
            assert.is_false(page.resultSet:IsEnabled())
            assert.is_false(page.resultRemove:IsEnabled())
            assert.are.equal(0, #page.results.data)
        end)

        it("has no results area for a search list, and refuses a result for it", function()
            local plain = store:Create("Herbs", {})
            page.Select(plain)
            assert.is_false(page.results.frame:IsShown())
            assert.is_false(page.addResult:IsShown())
            assert.is_false(page.margin.frame:IsShown())
            assert.are.equal("Items (count to buy)", page.itemsLabel:GetText())
            local ok, err = page.AddResult("300", "1")
            assert.is_false(ok)
            assert.are.equal("The list is not a craft list.", err)
            assert.are.same({}, page.margin.data)
        end)

        it("reads a yield text", function()
            assert.are.same({ 2, 2 }, { ns.ListsPage.ParseYield(" 2 ") })
            assert.are.same({ 1, 3 }, { ns.ListsPage.ParseYield("1 - 3") })
            assert.is_nil((ns.ListsPage.ParseYield("a")))
            assert.is_nil((ns.ListsPage.ParseYield("-1")))
            assert.is_nil((ns.ListsPage.ParseYield("")))
        end)
    end)

    describe("the margin breakdown", function()
        local id

        local function right(index)
            return page.margin.data[index].right
        end

        -- The text of a row of the table: the label and the three cells.
        local function grid(slot)
            local row = page.tableRows[slot]
            return { row.label:GetText(), row[1]:GetText(), row[2]:GetText(), row[3]:GetText() }
        end

        local function cost()
            return page.tableCost.text:GetText()
        end

        before_each(function()
            id = store:Create("Pants", { { itemID = 100, count = 4 }, { itemID = 200 } }, "craft")
            store:AddResult(id, { itemID = 300, name = "Dust", min = 1, max = 2 })
            -- Item 100 and 200 are materials, item 300 is the result.
            scan["100"], scan["200"], scan["300"] = { scanMarket = 300 }, { scanMarket = 50 }, { scanMarket = 1000 }
            build()
        end)

        it("has one row for each material and each result, and marks the scan prices as estimates", function()
            local rows = page.margin.data
            assert.are.equal(5, #rows)
            assert.are.same({ kind = "head", left = "Materials for 1 craft", right = "" }, rows[1])
            assert.are.same({ kind = "item", left = "4× item 100", right = "1200c (est.)" }, rows[2])
            assert.are.same({ kind = "item", left = "1× item 200", right = "50c (est.)" }, rows[3])
            assert.are.same({ kind = "head", left = "Results (value after the 5% cut)", right = "" }, rows[4])
            assert.are.same({ kind = "item", left = "1-2× Dust", right = "avg 1425c" }, rows[5])
        end)

        it("shows the cost once and the table with the columns Min, Avg and Max", function()
            assert.are.equal("Cost", page.tableCost.label:GetText())
            assert.are.equal("1250c (est.)", cost())
            assert.are.same({ "", "Min", "Avg", "Max" }, grid(1))
            assert.are.same({ "Value", "950c", "1425c", "1900c" }, grid(2))
            assert.are.same({ "Profit", "-300c", "175c", "650c" }, grid(3))
            assert.are.same({ "", "(-24%)", "(14%)", "(52%)" }, grid(4))
            assert.are.same({ "", "", "", "" }, grid(5))
            assert.are.equal("GameFontRed", page.tableRows[3][1].fontObject)
            assert.are.equal("GameFontGreen", page.tableRows[3][2].fontObject)
            assert.are.equal("GameFontGreen", page.tableRows[3][3].fontObject)
        end)

        it("draws the rows in the list", function()
            assert.are.equal("4× item 100", page.margin.rows[2].left:GetText())
            assert.are.equal("1200c (est.)", page.margin.rows[2].right:GetText())
        end)

        it("uses the live price of this session when there is one, and no estimate mark for it", function()
            deps.livePrice = function(key, needed)
                if key == "100" and needed == 4 then
                    return 1100
                end
            end
            page.Refresh()
            assert.are.equal("1100c", right(2))
            assert.are.equal("50c (est.)", right(3))
            assert.are.equal("1150c (est.)", cost())
            deps.livePrice = function(key)
                return key == "200" and 50 or (key == "100" and 1100 or nil)
            end
            page.Refresh()
            assert.are.equal("50c", right(3))
            assert.are.equal("1150c", cost())
        end)

        it("scales the rows with the number of crafts, and refuses a bad number", function()
            page.craftsInput:SetText("2")
            page.craftsInput.scripts.OnEnterPressed(page.craftsInput)
            assert.are.equal(2, page.crafts)
            assert.are.equal("Materials for 2 crafts", page.margin.data[1].left)
            assert.are.equal("8× item 100", page.margin.data[2].left)
            assert.are.equal("2400c (est.)", right(2))
            assert.are.equal("2× item 200", page.margin.data[3].left)
            assert.are.equal("2500c (est.)", cost())
            assert.are.same({ "Profit", "-600c", "350c", "1300c" }, grid(3))
            page.craftsInput:SetText("0")
            page.craftsInput.scripts.OnEnterPressed(page.craftsInput)
            assert.are.equal(2, page.crafts)
            assert.are.equal("crafts must be a whole number above 0", page.status:GetText())
            assert.are.equal("2", page.craftsInput:GetText())
        end)

        it("uses ScanMin for a result with no market value, and says that a price is missing", function()
            scan["300"] = { scanMin = 800 }
            page.Refresh()
            assert.are.equal("760c", grid(2)[2])
            scan["300"] = {}
            page.Refresh()
            assert.are.equal("no price", right(5))
            assert.are.same({ "Value", "?", "?", "?" }, grid(2))
            assert.are.same({ "Profit", "?", "?", "?" }, grid(3))
            assert.are.same({ "", "", "", "" }, grid(4))
            scan["300"] = { scanMarket = 1000 }
            scan["100"] = nil
            page.Refresh()
            assert.are.equal("no price", right(2))
            assert.are.equal("? (50c priced) (est.)", cost())
            assert.are.same({ "Profit", "?", "?", "?" }, grid(3))
        end)

        it("asks for a result when the list has none, and shows only the cost", function()
            store:RemoveResult(id, 1)
            local rows = page.margin.data
            assert.are.equal(5, #rows)
            assert.are.same({ kind = "item", left = "Add a result to see the margin", right = "" }, rows[5])
            assert.are.equal("1250c (est.)", cost())
            assert.are.same({ "", "", "", "" }, grid(1))
        end)

        it("saves the result mode with the check box, and adds the Yield row to the table", function()
            scan["400"] = { scanMarket = 100 }
            store:AddResult(id, { itemID = 400, name = "Cheap", min = 2, max = 3 })
            assert.is_false(page.oneOfCheck:GetChecked())
            assert.are.equal("Results (amount made for each craft)", page.resultsLabel:GetText())
            assert.are.equal("Results (value after the 5% cut)", page.margin.data[4].left)
            assert.are.same({ "Value", "1140c", "1662c", "2185c" }, grid(2))
            page.oneOfCheck:SetChecked(true)
            click(page.oneOfCheck)
            assert.are.equal("oneOf", store:Get(id).resultMode)
            assert.are.equal("One of these results", page.resultsLabel:GetText())
            assert.are.equal("One of these results (value after the 5% cut)", page.margin.data[4].left)
            assert.are.equal("1250c (est.)", cost())
            assert.are.same({ "", "Min", "Avg", "Max" }, grid(1))
            assert.are.same({ "Yield", "2× Cheap", "mean", "2× Dust" }, grid(2))
            assert.are.same({ "Value", "190c", "831c", "1900c" }, grid(3))
            assert.are.same({ "Profit", "-1060c", "-419c", "650c" }, grid(4))
            assert.are.same({ "", "(-85%)", "(-34%)", "(52%)" }, grid(5))
            page.oneOfCheck:SetChecked(false)
            click(page.oneOfCheck)
            assert.are.equal("all", store:Get(id).resultMode)
            assert.are.same({ "Value", "1140c", "1662c", "2185c" }, grid(2))
            assert.is_false(page.oneOfCheck:GetChecked())
        end)

        it("shows the check box for a craft list only, and refuses the mode for a search list", function()
            assert.is_true(page.oneOfCheck:IsShown())
            local plain = store:Create("Herbs", {})
            page.Select(plain)
            assert.is_false(page.oneOfCheck:IsShown())
            local ok, err = page.SetResultMode("oneOf")
            assert.is_false(ok)
            assert.are.equal("The list is not a craft list.", err)
            assert.are.equal("all", store:Get(plain).resultMode)
        end)

        it("follows a change of the list", function()
            store:SetResult(id, 1, 2, 4)
            assert.are.equal("2850c", grid(2)[3])
            store:SetCount(id, 1, 8)
            assert.are.equal("8× item 100", page.margin.data[2].left)
        end)
    end)

    describe("with the Buying tab", function()
        local client, tab

        local function row(price, quantity)
            return { unitPrice = price, quantity = quantity, ownerItem = false, auctionID = price }
        end

        before_each(function()
            for _, name in ipairs({ "ItemNameIndex", "BuyingPlan", "Tree", "Tabs", "Columns", "AuctionTabs",
                "BuyingTab" }) do
                assert(loadfile(manifest.path(name)))("Flipside", ns)
            end
            client = { rows = {} }
            client.CanLiveSearch = function() return true end
            client.IsReady = function() return true end
            client.LiveSearch = function() return true end
            client.LiveRows = function(itemID) return client.rows[itemID] or {} end
            client.LiveResultEvents = function() return "COMMODITY_RESULTS", "ITEM_RESULTS" end
            client.ReadyEvent = function() return "READY" end
            client.CloseEvent = function() return "CLOSE" end
            client.BuyEvents = function() return nil end
            client.CanBuy = function() return true end
            local rules = {
                Walk = function(_, fn) fn(1) end,
                Children = function() return {} end,
                Name = function() return "Base" end,
                ItemsIn = function() return {} end,
                Path = function() return { "Base" } end,
                GroupOf = function() return nil end,
                EffectiveOperation = function() return 8 end,
                GetOperation = function()
                    return { name = "Default", settings = { maxPrice = "", showAboveMax = false } }
                end,
            }
            tab = ns.BuyingTab.New({
                bus = bus, rules = rules,
                formulaRun = { Evaluate = function(_, text) return tonumber(text), nil end },
                client = client, searchLists = store, isAuctionHouseOpen = function() return true end,
                after = function() end, itemInfo = function(itemID) return "item " .. itemID, 1 end,
            })
            tab:Mount(CreateFrame("Frame", nil, UIParent), { Enter = function() end, Leave = function() end })
        end)

        it("shows an item that the Buying tab adds, and a rename of the page in the tab", function()
            local id = store:Create("Pants", { { itemID = 100, count = 4 } }, "craft")
            build()
            tab:SelectList(id)
            assert.is_true(tab:AddItem("2589"))
            assert.are.equal(2, #page.items.data)
            assert.are.equal("Pants (2)", page.lists.data[1].text)
            assert.is_true(page.Rename("Shirts"))
            assert.are.equal("Search list: Shirts", tab.list[1].groupPath)
            assert.is_true(page.Delete())
            assert.is_nil(tab.listID)
            assert.are.same({}, tab.list)
            -- With another list left, the tab shows the first list.
            local first = store:Create("Herbs", { { itemID = 1 } })
            local second = store:Create("Pants2", { { itemID = 2 } })
            tab:SelectList(second)
            page.Delete(second)
            assert.are.equal(first, tab.listID)
            assert.are.equal(1, #tab.list)
        end)

        it("uses the live prices of a search in the Buying tab", function()
            local id = store:Create("Pants", { { itemID = 100, count = 4 } }, "craft")
            store:AddResult(id, { itemID = 300, name = "Dust", min = 1, max = 2 })
            scan["300"] = { scanMarket = 1000 }
            build()
            assert.are.equal("no price", page.margin.data[2].right)
            tab:SelectList(id)
            client.rows[100] = { row(300, 9) }
            tab:Select_("100")
            tab:Search()
            bus:Emit("COMMODITY_RESULTS", 100)
            page.Refresh()
            assert.are.equal("1200c", page.margin.data[2].right)
            assert.are.equal("1200c", page.tableCost.text:GetText())
        end)

        it("opens from the Edit lists button of the tab with the shown list", function()
            local opened = {}
            tab.deps.openLists = function(id)
                opened[#opened + 1] = id
            end
            local id = store:Create("Herbs", {})
            tab:SelectList(id)
            tab:EditLists()
            assert.are.same({ id }, opened)
        end)
    end)
end)
