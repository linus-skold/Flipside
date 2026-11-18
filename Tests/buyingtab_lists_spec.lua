local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end }
    for _, name in ipairs({ "EventBus", "SettingsDB", "ItemString", "OperationSchema", "ItemNameIndex", "BuyingPlan",
        "SearchLists", "Theme", "Widgets", "Window", "Prompt", "List", "Tree", "Tabs", "Columns", "AuctionTabs",
        "BuyingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

describe("BuyingTab search lists", function()
    local ns, bus, client, rules, lists, tab, ui, ahOpen, nameIndex, ahSearch, db, timers

    local function makeClient()
        local c = { ready = true, searches = {}, rows = {} }
        c.CanLiveSearch = function() return true end
        c.IsReady = function() return c.ready end
        c.LiveSearch = function(itemID)
            c.searches[#c.searches + 1] = itemID
            return true
        end
        c.LiveRows = function(itemID) return c.rows[itemID] or {} end
        c.LiveResultEvents = function() return "COMMODITY_RESULTS", "ITEM_RESULTS" end
        c.ReadyEvent = function() return "READY" end
        c.CloseEvent = function() return "CLOSE" end
        c.BuyEvents = function() return nil end
        c.CanBuy = function() return true end
        return c
    end

    -- Rules: item "100" is in group 2 with a buying operation (max 500). Base has the Default (no max).
    local function makeRules()
        local ops = {
            [7] = { name = "Cheap", settings = { maxPrice = "500", showAboveMax = false } },
            [8] = { name = "Default", settings = { maxPrice = "", showAboveMax = false } },
        }
        return {
            Walk = function(_, fn) fn(1) end,
            Children = function(_, id) return id == 1 and { 2 } or {} end,
            Name = function() return "Herbs" end,
            ItemsIn = function() return {} end,
            Path = function() return { "Base", "Herbs" } end,
            GroupOf = function(_, key) return key == "100" and 2 or nil end,
            EffectiveOperation = function(_, group)
                return group == 2 and 7 or 8
            end,
            GetOperation = function(_, id) return ops[id] end,
        }
    end

    local function row(price, quantity, own)
        return { unitPrice = price, quantity = quantity, ownerItem = own or false, auctionID = price }
    end

    local function mount(extra)
        local deps = {
            bus = bus, rules = rules, formulaRun = {
                Evaluate = function(_, text) return tonumber(text), nil end,
            },
            client = client, searchLists = lists, itemNameIndex = nameIndex, ahNameSearch = ahSearch,
            isAuctionHouseOpen = function() return ahOpen end,
            after = function(seconds, fn) timers[#timers + 1] = { seconds = seconds, fn = fn } end,
            itemInfo = function(id) return "item " .. id, 1 end,
        }
        for k, v in pairs(extra or {}) do
            deps[k] = v
        end
        local core = ns.BuyingTab.New(deps)
        core:Mount(CreateFrame("Frame", nil, UIParent), { Enter = function() end, Leave = function() end })
        return core
    end

    before_each(function()
        mock.reset()
        _G.ScrollUtil = nil
        getmetatable(CreateFrame("Frame")).__index.SetJustifyH = function() end
        ns = loadModules()
        bus = ns.EventBus.New({})
        db = ns.SettingsDB.New({}, { character = "Alice-Realm", schemaVersion = 1 })
        ahOpen = true
        timers = {}
        client = makeClient()
        rules = makeRules()
        nameIndex = nil
        ahSearch = nil
        lists = ns.SearchLists.New(db, { bus = bus, isAuctionHouseOpen = function() return ahOpen end })
        ns.BuyingPlan.Log:Clear()
        tab = mount()
        ui = tab.ui
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("the list source", function()
        it("starts on the groups and shows the search list controls only for lists", function()
            assert.are.equal("groups", tab.source)
            assert.is_false(ui.picker:IsShown())
            assert.is_true(tab:SetSource("lists"))
            assert.is_true(ui.picker:IsShown())
            assert.is_true(ui.rename:IsShown())
            assert.is_nil(ui.nameInput)
            assert.is_nil(ui.itemInput)
            assert.is_true(tab:SetSource("groups"))
            assert.is_false(ui.picker:IsShown())
        end)

        it("has no search lists source without the lists object", function()
            local plain = mount({ searchLists = false })
            assert.is_false(plain:SetSource("lists"))
            assert.is_false(plain.ui.sourceTabs.buttons[2]:IsShown())
        end)

        it("shows the items of the selected list with the operation of the group, or the Default", function()
            local id = lists:Create("Recipe", { { itemID = 100, name = "Peacebloom" }, { itemID = 200 } })
            assert.is_true(tab:SelectList(id))
            assert.are.equal("lists", tab.source)
            assert.are.equal(2, #tab.list)
            assert.are.equal(500, tab.list[1].maxPrice)
            assert.are.equal("Cheap", tab.list[1].operationName)
            assert.is_true(tab.list[2].noMax)
            assert.are.equal("Default", tab.list[2].operationName)
            assert.are.equal("Peacebloom", tab:_ItemName(tab.list[1]))
            assert.are.equal("-", ui.tree.list.rows[2].parts.price.text)
            assert.are.equal("Search list: Recipe", tab.list[2].groupPath)
        end)

        it("shows the list as a flat list of items, with no group nodes", function()
            local id = lists:Create("Recipe", { { itemID = 100 }, { itemID = 200 } })
            assert.is_true(tab:SelectList(id))
            assert.are.equal(2, #tab.nodes)
            for _, node in ipairs(tab.nodes) do
                assert.are.equal("item", node.kind)
            end
            assert.are.equal("Cheap", tab.nodes[1].entry.operationName)
        end)

        it("shows the market price of a list item, and the total only on the selected commodity", function()
            local id = lists:Create("Recipe", { { itemID = 200 }, { itemID = 300 } })
            tab._ScanInfo = function()
                return { market = 250 }
            end
            tab:SelectList(id)
            tab:SetAmount("4")
            assert.are.equal("250c", ui.tree.list.rows[1].parts.price.text)
            assert.are.equal("250c", ui.tree.list.rows[2].parts.price.text)
            client.rows[200] = { row(300, 9) }
            tab:Select_("200")
            tab:Search()
            bus:Emit("COMMODITY_RESULTS", 200)
            tab:SetAmount("4")
            assert.are.equal("1000c", ui.tree.list.rows[1].parts.price.text)
            assert.are.equal("250c", ui.tree.list.rows[2].parts.price.text)
        end)

        it("picks the first list when the source changes and no list is selected", function()
            local id = lists:Create("A", { { itemID = 1 } })
            tab:SetSource("lists")
            assert.are.equal(id, tab.listID)
            assert.are.equal(1, #tab.list)
        end)

        it("refreshes on a change event of the lists", function()
            local id = lists:Create("A", {})
            tab:SelectList(id)
            lists:AddItem(id, { itemID = 5 })
            assert.are.equal(1, #tab.list)
        end)
    end)

    describe("list management", function()
        it("makes, renames and deletes a list", function()
            assert.is_true(tab:NewList("Herbs"))
            assert.are.equal("Herbs", lists:Get(tab.listID).name)
            assert.is_true(tab:RenameList("Flowers"))
            assert.are.equal("Flowers", lists:Get(tab.listID).name)
            local ok, err = tab:NewList("flowers")
            assert.is_false(ok)
            assert.is_string(err)
            assert.are.equal(err, ui.message.text)
            local id = tab.listID
            assert.is_true(tab:DeleteList())
            assert.is_nil(lists:Get(id))
            assert.is_nil(tab.listID)
            assert.are.equal("lists", tab.source)
            assert.are.same({}, tab.list)
        end)

        it("removes an item with the remove button of its row", function()
            local id = lists:Create("A", { { itemID = 1 }, { itemID = 2 } })
            tab:SelectList(id)
            -- The list is flat: the first row is the first item.
            local button = ui.tree.list.rows[1].parts.remove
            assert.is_true(button:IsShown())
            button.scripts.OnClick(button)
            assert.are.equal(1, #tab.list)
            assert.are.equal(2, tab.list[1].itemID)
            assert.are.equal(1, #lists:Get(id).items)
        end)
    end)

    describe("item box", function()
        local function parse(text, deps)
            local result
            ns.BuyingTab.ParseInput(text, deps or {}, function(r)
                result = r
            end)
            return result
        end

        it("reads an item ID", function()
            local r = parse(" 2589 ")
            assert.are.equal("item", r.kind)
            assert.are.equal(2589, r.item.itemID)
            assert.are.equal("2589", r.item.key)
        end)

        it("reads a Flipside key", function()
            local r = parse("25320#s-44")
            assert.are.equal("item", r.kind)
            assert.are.equal(25320, r.item.itemID)
            assert.are.equal("25320#s-44", r.item.key)
        end)

        it("reads an item link with the name and the key from keyFor", function()
            local link = "|cff1eff00|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r"
            local r = parse(link)
            assert.are.equal(2589, r.item.itemID)
            assert.are.equal("Linen Cloth", r.item.name)
            assert.are.equal("2589", r.item.key)
            r = parse(link, { keyFor = function() return "2589#b1" end })
            assert.are.equal("2589#b1", r.item.key)
        end)

        it("gives an error for empty text and for a name", function()
            assert.are.equal("error", parse("   ").kind)
            assert.matches("not an item ID", parse("linen").message)
        end)

        it("adds the item to the selected list and clears the box", function()
            local id = lists:Create("A", {})
            tab:SelectList(id)
            ui.searchInput:SetText("2589")
            assert.is_true(tab:AddItem("2589"))
            assert.are.equal("2589", lists:Get(id).items[1].key)
            assert.are.equal("", ui.searchInput:GetText())
            assert.are.equal("2589", tab.selectedKey)
            local ok, err = tab:AddItem("2589")
            assert.is_false(ok)
            assert.matches("in the list", err)
        end)

        it("makes the list Quick search when no list is selected, and reuses it", function()
            assert.is_true(tab:AddItem("2589"))
            assert.is_true(tab:AddItem("2592"))
            local all = lists:List()
            assert.are.equal(1, #all)
            assert.are.equal("Quick search", all[1].name)
            assert.are.equal(2, all[1].count)
            assert.are.equal("lists", tab.source)
        end)

        it("reports an error text for bad input", function()
            local ok, err = tab:AddItem("")
            assert.is_false(ok)
            assert.are.equal(err, ui.message.text)
            assert.are.same({}, lists:List())
        end)

        it("adds the selected result of a name search to the selected list", function()
            local id = lists:Create("A", {})
            tab:SelectList(id)
            tab.deps.ahNameSearch = { Find = function(_, _, callback)
                callback({
                    { itemID = 7, key = "7", name = "Rare Herb" },
                    { itemID = 8, key = "8", name = "Rare Root" },
                })
            end }
            assert.is_true(tab:SearchName("Rare"))
            assert.is_true(ui.addToList:IsShown())
            assert.is_false(ui.addToList.enabled)
            tab:Select_("8")
            assert.is_true(ui.addToList.enabled)
            ui.addToList.scripts.OnClick(ui.addToList)
            assert.are.equal("8", lists:Get(id).items[1].key)
            assert.is_nil(tab.searchResults)
            assert.is_false(ui.addToList:IsShown())
        end)

        it("has no Add to list button without a list or without a search", function()
            assert.is_false(ui.addToList:IsShown())
            local ok = tab:AddSelectedToList()
            assert.is_false(ok)
        end)
    end)

    describe("the one input of the search row", function()
        local LINK = "|cff1eff00|Hitem:2592::::::::60:::::|h[Wool Cloth]|h|r"

        local function enter(text)
            ui.searchInput:SetText(text)
            ui.searchInput.scripts.OnEnterPressed(ui.searchInput)
        end

        before_each(function()
            local names = {}
            ahSearch = { Find = function(_, query)
                names[#names + 1] = query
            end }
            tab.deps.ahNameSearch = ahSearch
            tab.names = names
        end)

        it("has no placeholder text", function()
            assert.is_nil(ui.searchInput.placeholder)
        end)

        it("adds an item ID, a key or a link to the current list on Enter and starts no name search", function()
            local id = lists:Create("A", {})
            tab:SelectList(id)
            enter("2589")
            enter("25320#s-44")
            enter(LINK)
            local items = lists:Get(id).items
            assert.are.equal("2589", items[1].key)
            assert.are.equal("25320#s-44", items[2].key)
            assert.are.equal(2592, items[3].itemID)
            assert.are.same({}, tab.names)
        end)

        it("runs the name search on Enter for other text", function()
            local id = lists:Create("A", {})
            tab:SelectList(id)
            enter("Linen Cloth")
            assert.are.same({ "Linen Cloth" }, tab.names)
            assert.are.same({}, lists:Get(id).items)
        end)

        it("tells an item reference from a name", function()
            assert.is_true(ns.BuyingTab.IsItemRef(" 2589 "))
            assert.is_true(ns.BuyingTab.IsItemRef("25320#s-44"))
            assert.is_true(ns.BuyingTab.IsItemRef(LINK))
            assert.is_false(ns.BuyingTab.IsItemRef("Linen Cloth"))
            assert.is_false(ns.BuyingTab.IsItemRef(""))
        end)
    end)

    describe("the name prompts", function()
        local function submit(box, text)
            box.input:SetText(text)
            box.input.scripts.OnTextChanged(box.input)
            box.okButton.scripts.OnClick(box.okButton)
        end

        it("asks for the name of a new list", function()
            ui.newList.scripts.OnClick(ui.newList)
            local box = ns.Kit.Prompt("FlipsideBuyingNewListPrompt")
            assert.is_true(box:IsShown())
            submit(box, "Herbs")
            assert.are.equal("Herbs", lists:Get(tab.listID).name)
            assert.is_false(box:IsShown())
        end)

        it("keeps the new list prompt open with the error for a name in use", function()
            lists:Create("Herbs", {})
            ui.newList.scripts.OnClick(ui.newList)
            local box = ns.Kit.Prompt("FlipsideBuyingNewListPrompt")
            submit(box, "herbs")
            assert.is_true(box:IsShown())
            assert.is_not.equal("", box.error:GetText())
        end)

        it("asks for the new name of the selected list, with the old name as start text", function()
            local id = lists:Create("Herbs", {})
            tab:SelectList(id)
            ui.rename.scripts.OnClick(ui.rename)
            local box = ns.Kit.Prompt("FlipsideBuyingRenameListPrompt")
            assert.are.equal("Herbs", box.input:GetText())
            submit(box, "Flowers")
            assert.are.equal("Flowers", lists:Get(id).name)
        end)
    end)

    describe("search of a list", function()
        it("searches each item of the list and shows the levels", function()
            local id = lists:Create("Recipe", { { itemID = 100 }, { itemID = 200 } })
            tab:SelectList(id)
            client.rows[100] = { row(300, 2), row(900, 1) }
            client.rows[200] = { row(5000, 1), row(8000, 3), row(9000, 1, true) }
            assert.is_true(tab:SearchAll())
            assert.are.same({ 100 }, client.searches)
            bus:Emit("COMMODITY_RESULTS", 100)
            assert.are.same({ 100, 200 }, client.searches)
            bus:Emit("COMMODITY_RESULTS", 200)
            assert.is_nil(tab.queue)
            -- Item 100 has the max price 500 of its group.
            assert.are.equal(2, tab.results["100"].result.quantity)
            -- Item 200 uses the Default: no max price, every row of another seller is buyable.
            assert.are.equal(4, tab.results["200"].result.quantity)
            tab:Select_("200")
            assert.are.equal("", ui.summary.text)
            local _, level, _, reason = tab:_NextBuy()
            assert.is_nil(reason)
            assert.are.equal(5000, level.unitPrice)
            assert.are.equal(3, #ui.rowsList.data)
            assert.are.equal("buy", ui.rowsList.data[1].state)
            assert.are.equal("buy", ui.rowsList.data[2].state)
            assert.are.equal("own", ui.rowsList.data[3].state)
        end)
    end)

    describe("an unsaved list and the counts of items", function()
        local started, confirmed

        local function dialog(name)
            for _, frame in ipairs(mock.frames) do
                if frame.name == name then
                    return frame
                end
            end
        end

        local function emitTemp()
            bus:Emit("Flipside.SearchListTemp", "Recipe: Potion", {
                { itemID = 100, name = "Peacebloom", count = 4 }, { itemID = 200, count = 2 }, { itemID = 300 },
            }, false)
        end

        local function submit(box, text)
            box.input:SetText(text)
            box.input.scripts.OnTextChanged(box.input)
            box.okButton.scripts.OnClick(box.okButton)
        end

        before_each(function()
            started, confirmed = {}, {}
            -- A new bus, a new list object and a client that can buy. The tab of the outer before_each is not used.
            bus = ns.EventBus.New({})
            lists = ns.SearchLists.New(db, { bus = bus, isAuctionHouseOpen = function() return ahOpen end })
            client = makeClient()
            client.BuyEvents = function()
                return { priceUpdated = "QUOTE", priceUnavailable = "NOQUOTE", commoditySucceeded = "BOUGHT",
                    commodityFailed = "NOTBOUGHT", itemCompleted = "ITEMBOUGHT", itemError = "ITEMERR" }
            end
            client.StartCommodityPurchase = function(itemID, quantity)
                started[#started + 1] = { itemID, quantity }
            end
            client.ConfirmCommodityPurchase = function(itemID, quantity)
                confirmed[#confirmed + 1] = { itemID, quantity }
            end
            client.CancelCommodityPurchase = function() end
            client.QuoteSecondsLeft = function() return 30 end
            tab = mount()
            ui = tab.ui
        end)

        it("shows the list with the counts and stores nothing", function()
            emitTemp()
            assert.are.equal("lists", tab.source)
            assert.are.equal(3, #tab.list)
            assert.are.same({}, lists:List())
            assert.are.equal("4× Peacebloom", tab.nodes[1].text)
            assert.are.equal("2× item 200", tab.nodes[2].text)
            assert.are.equal("item 300", tab.nodes[3].text)
        end)

        it("ignores the list while the Auction House is closed", function()
            ahOpen = false
            emitTemp()
            assert.is_nil(tab.temp)
            assert.are.equal("groups", tab.source)
        end)

        it("shows Save in place of Rename and Delete for an unsaved list only", function()
            emitTemp()
            assert.is_true(ui.save:IsShown())
            assert.is_false(ui.rename:IsShown())
            assert.is_false(ui.delete:IsShown())
            local id = lists:Create("Own", {})
            tab:SelectList(id)
            assert.is_false(ui.save:IsShown())
            assert.is_true(ui.rename:IsShown())
        end)

        it("saves the list with the counts through a prompt that starts with the default name", function()
            emitTemp()
            ui.save.scripts.OnClick(ui.save)
            local box = ns.Kit.Prompt("FlipsideBuyingSaveListPrompt")
            assert.is_true(box:IsShown())
            assert.are.equal("Recipe: Potion", box.input:GetText())
            submit(box, "Potion reagents")
            assert.is_false(box:IsShown())
            local saved = lists:Get(tab.listID)
            assert.are.equal("Potion reagents", saved.name)
            assert.are.equal(4, saved.items[1].count)
            assert.are.equal(2, saved.items[2].count)
            assert.is_nil(saved.items[3].count)
            assert.is_nil(tab.temp)
            assert.is_false(ui.save:IsShown())
        end)

        it("keeps the prompt open with the error for a name in use", function()
            lists:Create("Taken", {})
            emitTemp()
            ui.save.scripts.OnClick(ui.save)
            local box = ns.Kit.Prompt("FlipsideBuyingSaveListPrompt")
            submit(box, "taken")
            assert.is_true(box:IsShown())
            assert.is_not.equal("", box.error:GetText())
            assert.is_not_nil(tab.temp)
            assert.are.equal(1, #lists:List())
        end)

        it("starts the amount box with the count of the selected item", function()
            emitTemp()
            tab:Select_("100")
            assert.are.equal(4, tab.amount)
            tab:Select_("300")
            assert.are.equal(1, tab.amount)
        end)

        it("starts the amount box with the count of an item of a saved list, and not for an old list", function()
            local id = lists:Create("Saved", { { itemID = 100, count = 6 }, { itemID = 200 } })
            tab:SelectList(id)
            tab:Select_("100")
            assert.are.equal(6, tab.amount)
            tab:Select_("200")
            assert.are.equal(1, tab.amount)
            assert.are.equal("item 200", tab.nodes[2].text)
        end)

        it("buys the count after the normal confirmation", function()
            emitTemp()
            client.rows[100] = { row(300, 9) }
            tab:Select_("100")
            tab:Search()
            bus:Emit("COMMODITY_RESULTS", 100)
            assert.are.equal("4", ui.amount:GetText())
            ui.buyNext.scripts.OnClick(ui.buyNext)
            assert.are.same({ { 100, 4 } }, started)
            bus:Emit("QUOTE", 300, 1200)
            local confirm = dialog("FlipsideBuyConfirm")
            assert.is_true(confirm:IsShown())
            assert.matches("Buy 4 x", confirm.text.text)
            assert.are.same({}, confirmed)
            confirm.yesButton.scripts.OnClick(confirm.yesButton)
            assert.are.same({ { 100, 4 } }, confirmed)
        end)

        it("stores the typed amount as the count of the selected item of a saved list on Enter", function()
            local id = lists:Create("Saved", { { itemID = 100 } })
            tab:SelectList(id)
            tab:Select_("100")
            ui.amount:SetText("6")
            ui.amount.scripts.OnTextChanged(ui.amount)
            assert.is_nil(lists:Get(id).items[1].count)
            ui.amount.scripts.OnEnterPressed(ui.amount)
            assert.are.equal(6, lists:Get(id).items[1].count)
            assert.are.equal("6× item 100", tab.nodes[1].text)
            ui.amount:SetText("")
            ui.amount.scripts.OnTextChanged(ui.amount)
            ui.amount.scripts.OnEnterPressed(ui.amount)
            assert.is_nil(lists:Get(id).items[1].count)
        end)

        it("keeps the typed amount on the item of an unsaved list until Save", function()
            emitTemp()
            tab:Select_("300")
            ui.amount:SetText("9")
            ui.amount.scripts.OnTextChanged(ui.amount)
            ui.amount.scripts.OnEnterPressed(ui.amount)
            assert.are.equal(9, tab.temp.items[3].count)
            assert.are.same({}, lists:List())
        end)

        it("does not change the list on Enter during a name search", function()
            local id = lists:Create("Saved", { { itemID = 100 } })
            tab:SelectList(id)
            tab.deps.ahNameSearch = { Find = function(_, _, callback)
                callback({ { itemID = 7, key = "7", name = "Rare Herb" } })
            end }
            assert.is_true(tab:SearchName("Rare"))
            tab:Select_("7")
            ui.amount:SetText("6")
            ui.amount.scripts.OnTextChanged(ui.amount)
            ui.amount.scripts.OnEnterPressed(ui.amount)
            assert.is_nil(lists:Get(id).items[1].count)
        end)

        it("does not add an item twice to an unsaved list", function()
            emitTemp()
            local ok, err = tab:_AddResolved({ itemID = 100, key = "100", name = "Peacebloom" })
            assert.is_false(ok)
            assert.matches("in the list", err)
            assert.are.equal(3, #tab.temp.items)
            assert.is_true(tab:_AddResolved({ itemID = 400, key = "400" }))
            assert.are.equal(4, #tab.temp.items)
        end)

        it("does not store a count when the user typed nothing", function()
            local id = lists:Create("Saved", { { itemID = 100 } })
            tab:SelectList(id)
            tab:Select_("100")
            ui.amount.scripts.OnEnterPressed(ui.amount)
            assert.is_nil(lists:Get(id).items[1].count)
        end)
    end)

    describe("Flipside.SearchListOpen", function()
        local id
        before_each(function()
            id = lists:Create("Recipe", { { itemID = 100 }, { itemID = 200 } })
        end)

        it("selects the list and starts the search when the AH is open and autoSearch is true", function()
            bus:Emit("Flipside.SearchListOpen", id, true)
            assert.are.equal("lists", tab.source)
            assert.are.equal(id, tab.listID)
            assert.are.same({ 100 }, client.searches)
        end)

        it("selects the list and starts no search with autoSearch false", function()
            bus:Emit("Flipside.SearchListOpen", id, false)
            assert.are.equal(id, tab.listID)
            assert.are.same({}, client.searches)
        end)

        it("ignores a list that does not exist", function()
            bus:Emit("Flipside.SearchListOpen", 99, true)
            assert.are.equal("groups", tab.source)
            assert.are.same({}, client.searches)
        end)

        it("waits while the AH is closed and shows the list the next time the tab opens", function()
            ahOpen = false
            bus:Emit("Flipside.SearchListOpen", id, true)
            assert.are.equal("groups", tab.source)
            assert.are.same({}, client.searches)
            assert.same({ id = id, autoSearch = true }, lists:Requested())
            ahOpen = true
            tab:Select()
            assert.are.equal("lists", tab.source)
            assert.are.equal(id, tab.listID)
            assert.are.same({ 100 }, client.searches)
            assert.is_nil(lists:Requested())
        end)

        it("shows the list without a search when the closed request has autoSearch false", function()
            ahOpen = false
            bus:Emit("Flipside.SearchListOpen", id, false)
            ahOpen = true
            tab:Select()
            assert.are.equal(id, tab.listID)
            assert.are.same({}, client.searches)
        end)

        it("does not apply an old request a second time", function()
            ahOpen = false
            bus:Emit("Flipside.SearchListOpen", id, false)
            ahOpen = true
            tab:Select()
            tab:SetSource("groups")
            tab:Select()
            assert.are.equal("groups", tab.source)
        end)

        it("is not heard after Unmount", function()
            tab:Unmount()
            bus:Emit("Flipside.SearchListOpen", id, true)
            assert.are.same({}, client.searches)
        end)
    end)
end)
