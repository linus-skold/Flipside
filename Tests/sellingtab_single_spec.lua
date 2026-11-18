local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules(flavour)
    local ns = { ReportError = function() end, Flavour = flavour }
    for _, name in ipairs({ "EventBus", "ItemString", "ScanKey", "BagItems", "SellingPlan", "BuyingPlan", "BuyFlow",
        "Theme", "Widgets", "MoneyInput", "Window", "List", "Columns", "Tree", "AuctionTabs", "BuyDialog",
        "SellingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

local FOREVER = { hasCommodityMarket = true }
local TBC = { hasCommodityMarket = false, multisell = true }

-- Item 20 is gear (max stack 1, three single items), 21 a stackable good (max stack 20), 22 a commodity (Forever).
describe("SellingTab single items", function()
    local ns, bus, client, tab, ui, bagItems, stackSizes, requested

    local function makeClient()
        local c = { ready = true, searches = {}, rows = {}, commodity = {}, posts = {} }
        c.CanLiveSearch = function() return true end
        c.CanPost = function() return true end
        c.IsReady = function() return c.ready end
        c.LiveSearch = function(itemID)
            c.searches[#c.searches + 1] = itemID
            return true
        end
        c.LiveRows = function(itemID) return c.rows[itemID] or {} end
        c.LiveResultEvents = function() return "COMMODITY_RESULTS", "ITEM_RESULTS" end
        c.ReadyEvent = function() return "READY" end
        c.PostedEvent = function() return "CREATED" end
        c.MultisellEvent = function() return "MULTI" end
        c.ItemIsCommodity = function(itemID) return c.commodity[itemID] end
        c.CanReadOwned = function() return false end
        c.Deposit = function(_, _, _, quantity, _, _, _, stacks) return quantity * (stacks or 1) * 10 end
        c.AvailablePostCount = function() return 1000 end
        c.IsSellItemValid = function() return true end
        c.RefreshOwned = function() end
        c.PostItem = function(bag, slot, duration, quantity, bid, buyout, itemID, _, stacks)
            c.posts[#c.posts + 1] = { kind = "item", bag = bag, slot = slot, duration = duration,
                quantity = quantity, bid = bid, buyout = buyout, itemID = itemID, stacks = stacks }
            return false
        end
        c.PostCommodity = function(bag, slot, duration, quantity, unitPrice)
            c.posts[#c.posts + 1] = { kind = "commodity", bag = bag, slot = slot, duration = duration,
                quantity = quantity, unitPrice = unitPrice }
            return false
        end
        c.ConfirmPostItem = function() end
        c.ConfirmPostCommodity = function() end
        return c
    end

    local groups = { [1] = { name = "Base", children = { 2 } }, [2] = { name = "Gear", children = {} } }

    local function makeRules()
        return {
            Children = function(_, id) return groups[id].children end,
            Name = function(_, id) return groups[id].name end,
            GroupOf = function() return 2 end,
            Walk = function(_, fn)
                fn(1)
                fn(2)
            end,
            EffectiveOperation = function(_, id)
                if id == 2 then
                    return 7
                end
            end,
            GetOperation = function()
                return { name = "Sell", settings = {
                    minPrice = "10", normalPrice = "100", maxPrice = "100000", undercut = 1, duration = 24,
                    vendorSkip = false,
                } }
            end,
            Path = function(_, id) return groups[id].name end,
            ItemsIn = function() return {} end,
        }
    end

    local function mount(flavour)
        mock.reset()
        local frameMethods = getmetatable(CreateFrame("Frame")).__index
        frameMethods.SetJustifyH = function() end
        ns = loadModules(flavour)
        bus = ns.EventBus.New({})
        client = makeClient()
        requested = {}
        stackSizes = { [20] = 1, [21] = 20, [22] = 20 }
        client.commodity[22] = true
        bagItems = {
            { key = "20", itemID = 20, name = "Silver Rod", count = 3, stacks = {
                { bag = 1, slot = 1, count = 1 }, { bag = 1, slot = 2, count = 1 },
                { bag = 1, slot = 3, count = 1 } } },
            { key = "21", itemID = 21, name = "Linen Cloth", count = 40, stacks = {
                { bag = 2, slot = 1, count = 20 }, { bag = 2, slot = 2, count = 20 } } },
            { key = "22", itemID = 22, name = "Bolt of Linen", count = 12, stacks = {
                { bag = 3, slot = 1, count = 12 } } },
        }
        ns.SellingPlan.Log:Clear()
        local core = ns.SellingTab.New({
            bus = bus, rules = makeRules(), formulaRun = { Evaluate = function(_, text) return tonumber(text) end },
            client = client, after = function() end, itemInfo = function(id) return "Item" .. id, 1 end,
            readBags = function() return bagItems end,
            maxStack = function(id) return stackSizes[id] end,
            requestItem = function(id) requested[#requested + 1] = id end,
            vendorPrice = function() return nil end, syncInterval = 0, time = function() return 0 end,
            warn = function() end,
        })
        core:Mount(CreateFrame("Frame", nil, UIParent), { Enter = function() end, Leave = function() end })
        core:Select()
        tab, ui = core, core.ui
    end

    -- A listing row at a price for one item.
    local function row(price, quantity)
        return { unitPrice = price, quantity = quantity, ownerItem = false, auctionID = price }
    end

    local function choose(itemID, rows)
        client.rows[itemID] = rows
        ui.tree:Select("i" .. itemID)
        bus:Emit(client.commodity[itemID] and "COMMODITY_RESULTS" or "ITEM_RESULTS", itemID)
    end

    after_each(function()
        mock.teardown()
    end)

    describe("on Forever", function()
        before_each(function()
            mount(FOREVER)
            client.commodity[20] = false
            client.commodity[21] = false
        end)

        it("prices from the price of one item: 40 items at 449 are 449 each, not 11", function()
            choose(20, { row(449, 40) })
            assert.are.equal(448, ui.details.priceInput:GetCopper())
        end)

        it("shows a price and a quantity, with no stack price and no stack size", function()
            choose(20, { row(449, 1) })
            local d = ui.details
            assert.are.equal("Price", d.priceLabel.text)
            assert.are.equal("Quantity:", d.qtyLabel.text)
            assert.is_false(d.stackInput:IsShown())
            assert.is_false(d.stackLabel:IsShown())
            assert.is_false(d.stacks:IsShown())
            assert.is_true(ui.details.priceInput:IsShown())
        end)

        it("posts one item for each auction at the price of the item", function()
            choose(20, { row(449, 1) })
            ui.postNext.scripts.OnClick(ui.postNext)
            local post = client.posts[1]
            assert.are.equal("item", post.kind)
            assert.are.equal(1, post.quantity)
            assert.are.equal(448, post.buyout)
        end)

        it("keeps a commodity as it was: a unit price", function()
            choose(22, { row(150, 5) })
            assert.are.equal("Unit Price", ui.details.priceLabel.text)
            assert.is_false(ui.details.stackInput:IsShown())
        end)

        it("treats an item with no commodity answer and a max stack above 1 as a commodity", function()
            client.commodity[21] = nil
            choose(21, { row(150, 5) })
            local entry
            for _, each in ipairs(tab.entries) do
                entry = each.key == "21" and each or entry
            end
            assert.is_true(entry.market.commodity)
            assert.are.equal("Unit Price", ui.details.priceLabel.text)
        end)

        it("shows the header Price in the level list for a single item and Unit price for a commodity", function()
            ui.levels.scripts.OnClick(ui.levels)
            choose(20, { row(449, 1) })
            assert.are.equal("Price", ui.levelHeader.labels.price.text)
            choose(22, { row(150, 5) })
            assert.are.equal("Unit price", ui.levelHeader.labels.price.text)
        end)
    end)

    describe("with item data that is not loaded", function()
        before_each(function()
            mount(FOREVER)
            stackSizes[20] = nil
        end)

        it("waits: no search, no guess of max stack 1, and a reason in the Info column", function()
            ui.tree:Select("i20")
            assert.are.same({}, client.searches)
            local entry
            for _, each in ipairs(tab.entries) do
                entry = each.key == "20" and each or entry
            end
            assert.are.equal("waiting", entry.status)
            assert.is_nil(entry.decision)
            assert.are.equal("item data is loading", ns.SellingTab.InfoText(entry))
            local asked = false
            for _, id in ipairs(requested) do
                asked = asked or id == 20
            end
            assert.is_true(asked)
        end)

        it("searches and decides when the data arrives", function()
            ui.tree:Select("i20")
            stackSizes[20] = 1
            client.commodity[20] = false
            client.rows[20] = { row(449, 1) }
            bus:Emit("ITEM_DATA_LOAD_RESULT", 20)
            assert.are.same({ 20 }, client.searches)
            bus:Emit("ITEM_RESULTS", 20)
            assert.are.equal(448, ui.details.priceInput:GetCopper())
        end)

        it("skips with a reason after three requests that bring no data", function()
            ui.tree:Select("i20")
            bus:Emit("ITEM_DATA_LOAD_RESULT", 20)
            bus:Emit("ITEM_DATA_LOAD_RESULT", 20)
            bus:Emit("ITEM_DATA_LOAD_RESULT", 20)
            local entry
            for _, each in ipairs(tab.entries) do
                entry = each.key == "20" and each or entry
            end
            assert.are.equal("skip", entry.status)
            assert.are.equal("item data is not available", entry.decision.reason)
            assert.are.same({}, client.searches)
        end)

        it("does not wait for a commodity: its max stack size is not needed", function()
            stackSizes[22] = nil
            choose(22, { row(150, 5) })
            assert.are.same({ 22 }, client.searches)
        end)
    end)

    describe("on TBC", function()
        before_each(function()
            mount(TBC)
            client.commodity[20] = nil
            client.commodity[21] = nil
        end)

        it("shows a price and the number of stacks for an item of max stack 1, with no stack size", function()
            choose(20, { row(449, 1) })
            local d = ui.details
            assert.are.equal("Price", d.priceLabel.text)
            assert.is_true(d.stacks:IsShown())
            assert.is_false(d.stackOf:IsShown())
            assert.is_false(d.qty:IsShown())
            assert.is_false(d.qtyLabel:IsShown())
            assert.is_false(d.stackInput:IsShown())
            assert.is_false(d.stackLabel:IsShown())
        end)

        it("posts stacks of 1 at the price of the item", function()
            choose(20, { row(449, 1) })
            ui.postNext.scripts.OnClick(ui.postNext)
            local post = client.posts[1]
            assert.are.equal(1, post.quantity)
            assert.are.equal(3, post.stacks)
            assert.are.equal(448, post.buyout)
        end)

        it("keeps a stackable item as it was: a unit price and a stack price", function()
            choose(21, { row(150, 20) })
            local d = ui.details
            assert.are.equal("Unit Price", d.priceLabel.text)
            assert.is_true(d.stackInput:IsShown())
            assert.is_true(d.stackLabel:IsShown())
            assert.is_true(d.stacks:IsShown())
            assert.is_true(d.stackOf:IsShown())
            assert.is_true(d.qty:IsShown())
            ui.postNext.scripts.OnClick(ui.postNext)
            local post = client.posts[1]
            assert.are.equal(20, post.quantity)
            assert.are.equal(149 * 20, post.buyout)
        end)

        it("shows the header Price in the level list for a single item", function()
            ui.levels.scripts.OnClick(ui.levels)
            choose(20, { row(449, 1) })
            assert.are.equal("Price", ui.levelHeader.labels.price.text)
            choose(21, { row(150, 20) })
            assert.are.equal("Unit price", ui.levelHeader.labels.price.text)
        end)
    end)
end)
