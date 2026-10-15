local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end }
    for _, name in ipairs({ "EventBus", "SettingsDB", "ItemString", "OperationSchema", "ItemNameIndex", "BuyingPlan",
        "SearchLists", "Theme", "Widgets", "Window", "List", "Tree", "Columns", "AuctionTabs", "BuyingTab" }) do
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
            assert.is_true(ui.itemInput:IsShown())
            assert.is_true(tab:SetSource("groups"))
            assert.is_false(ui.picker:IsShown())
        end)

        it("has no search lists source without the lists object", function()
            local plain = mount({ searchLists = false })
            assert.is_false(plain:SetSource("lists"))
            assert.is_false(plain.ui.listsButton:IsShown())
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
            assert.are.equal("no max", ui.tree.list.rows[4].parts.price.text)
            assert.are.equal("Search list: Recipe", tab.list[2].groupPath)
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
            local button = ui.tree.list.rows[2].parts.remove
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

        it("finds a name in the name index: one match, several matches, none", function()
            local matches = { { itemID = 1, name = "Linen Cloth", key = "1" } }
            local deps = { itemNameIndex = { Resolve = function() return { kind = "name", matches = matches } end } }
            assert.are.equal("Linen Cloth", parse("linen", deps).item.name)
            matches[2] = { itemID = 2, name = "Linen Bandage", key = "2" }
            local r = parse("linen", deps)
            assert.are.equal("choices", r.kind)
            assert.are.equal(2, #r.choices)
            matches[1], matches[2] = nil, nil
            r = parse("linen", deps)
            assert.are.equal("error", r.kind)
            assert.matches("no item named", r.message)
        end)

        it("asks the Auction House for a name that the index does not know", function()
            local found
            local deps = {
                itemNameIndex = { Resolve = function() return { kind = "name", matches = {} } end },
                isAuctionHouseOpen = function() return true end,
                ahNameSearch = { Find = function(_, query, callback, options)
                    found = { query = query, exact = options.exact }
                    callback({ { itemID = 9, name = "Rare Herb", key = "9" } })
                end },
            }
            local r = parse('"Rare Herb"', deps)
            assert.are.same({ query = "Rare Herb", exact = true }, found)
            assert.are.equal(9, r.item.itemID)
            deps.isAuctionHouseOpen = function() return false end
            assert.are.equal("error", parse("Rare Herb", deps).kind)
        end)

        it("gives an error for empty text, a short name and no name source", function()
            assert.are.equal("error", parse("   ").kind)
            local short = parse("a", { itemNameIndex = { Resolve = function()
                return { kind = "error", message = "type at least 3 characters of the name" }
            end } })
            assert.matches("at least", short.message)
            assert.matches("not available", parse("linen").message)
        end)

        it("adds the item to the selected list and clears the box", function()
            local id = lists:Create("A", {})
            tab:SelectList(id)
            ui.itemInput:SetText("2589")
            assert.is_true(tab:AddItem("2589"))
            assert.are.equal("2589", lists:Get(id).items[1].key)
            assert.are.equal("", ui.itemInput:GetText())
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

        it("shows a choice when several items match and adds the picked one", function()
            tab.deps.itemNameIndex = { Resolve = function()
                return { kind = "name", matches = {
                    { itemID = 1, name = "Linen Cloth", key = "1" }, { itemID = 2, name = "Linen Bandage", key = "2" },
                } }
            end }
            assert.is_true(tab:AddItem("linen"))
            assert.are.equal(2, #tab.choices)
            assert.matches("2 items match", ui.message.text)
            assert.are.same({}, lists:List())
            assert.is_true(tab:_AddResolved(tab.choices[2]))
            assert.are.equal("2", lists:Get(tab.listID).items[1].key)
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
            assert.matches("no max price set", ui.summary.text)
            local _, level, _, reason = tab:_NextBuy()
            assert.is_nil(reason)
            assert.are.equal(5000, level.unitPrice)
            assert.are.equal(3, #ui.rowsList.data)
            assert.are.equal("buy", ui.rowsList.data[1].state)
            assert.are.equal("buy", ui.rowsList.data[2].state)
            assert.are.equal("own", ui.rowsList.data[3].state)
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
