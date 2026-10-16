local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end }
    for _, name in ipairs({ "EventBus", "ItemString", "ScanKey", "BagItems", "SellingPlan", "Theme", "Widgets",
        "MoneyInput", "Window", "List", "Columns", "Tree", "AuctionTabs", "SellingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

-- These specs keep ScrollUtil: the game uses the ScrollBox path.
describe("SellingTab price box, warnings, post all and bag sync", function()
    local ns, bus, client, rules, tab, ui, bagItems, bagReads, warns, views, vendor, opExtra, confirms, autoAccept
    local delays = {}

    local function makeClient()
        local c = { ready = true, searches = {}, rows = {}, commodity = {}, posts = {}, confirmed = {} }
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
        c.ItemIsCommodity = function(itemID) return c.commodity[itemID] end
        c.CanReadOwned = function() return false end
        c.Deposit = function(_, _, _, quantity) return quantity * 10 end
        c.AvailablePostCount = function() return 1000 end
        c.IsSellItemValid = function() return true end
        c.RefreshOwned = function() end
        c.PostItem = function(bag, slot, duration, quantity, bid, buyout, itemID)
            c.posts[#c.posts + 1] = { kind = "item", bag = bag, slot = slot, duration = duration,
                quantity = quantity, bid = bid, buyout = buyout, itemID = itemID }
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

    -- Groups: 2 Cloth (with 3 Bolts), 6 Misc. Cloth and Bolts have a selling operation; Misc has none.
    local groups = {
        [1] = { name = "Base", children = { 2, 6 } },
        [2] = { name = "Cloth", children = { 3 } },
        [3] = { name = "Bolts", children = {} },
        [6] = { name = "Misc", children = {} },
    }
    local itemGroup = { ["10"] = 2, ["11"] = 3, ["13"] = 6 }

    local function makeRules()
        return {
            Children = function(_, id) return groups[id].children end,
            Name = function(_, id) return groups[id].name end,
            GroupOf = function(_, key) return itemGroup[key] or 1 end,
            Walk = function(_, fn)
                for _, id in ipairs({ 1, 2, 3, 6 }) do
                    fn(id)
                end
            end,
            EffectiveOperation = function(_, id)
                if id == 2 or id == 3 then
                    return 7
                end
            end,
            GetOperation = function()
                local settings = {
                    minPrice = "10", normalPrice = "100", maxPrice = "200", undercut = 1, duration = 24,
                }
                for k, v in pairs(opExtra) do
                    settings[k] = v
                end
                return { name = "Sell", settings = settings }
            end,
            Path = function(_, id) return groups[id].name end,
            ItemsIn = function() return {} end,
        }
    end

    local function row(price, quantity)
        return { unitPrice = price, quantity = quantity, ownerItem = false, auctionID = price }
    end

    local function fire(event, ...)
        bus:Emit(event, ...)
    end

    -- Run the Post all delay timers, as the game does after the delay. Other timers stay off.
    local function flushDelays()
        local list = delays
        delays = {}
        for _, fn in ipairs(list) do
            fn()
        end
    end

    local function click(button)
        if button == ui.postAll then
            flushDelays()
        end
        button.scripts.OnClick(button)
    end

    local function pick(id)
        ui.tree:Select(id)
    end

    local function visibleIds()
        local ids = {}
        for _, treeNode in ipairs(ui.tree.box.dataProvider:GetVisible()) do
            ids[#ids + 1] = treeNode:GetData().id
        end
        return ids
    end

    local function has(ids, id)
        for _, value in ipairs(ids) do
            if value == id then
                return true
            end
        end
        return false
    end

    -- Draw the row of a visible tree node, as the ScrollBox does.
    local function draw(id)
        for _, treeNode in ipairs(ui.tree.box.dataProvider:GetVisible()) do
            if treeNode:GetData().id == id then
                local frame = CreateFrame("Button")
                views[ui.tree.box].initializer(frame, treeNode)
                return frame
            end
        end
        error("no visible node " .. id)
    end

    local function entryOf(key)
        for _, entry in ipairs(tab.entries) do
            if entry.key == key then
                return entry
            end
        end
    end

    local function color(label)
        return { label.color[1], label.color[2], label.color[3] }
    end

    -- Fill the gold, silver and copper boxes as the user does, from a text like "1g 20s 5c".
    local function type_(text)
        local money = ui.details.priceInput
        money.gold:SetText(text:match("(%d+)g") or "")
        money.silver:SetText(text:match("(%d+)s") or "")
        money.copper:SetText(text:match("(%d+)c") or "")
        money.gold.scripts.OnTextChanged(money.gold)
    end

    local function selectCloth()
        client.rows[10] = { row(120, 1) }
        client.rows[11] = { row(150, 5) }
        pick("g2")
        fire("ITEM_RESULTS", 10)
        fire("COMMODITY_RESULTS", 11)
    end

    local function mount(extra)
        local deps = {
            bus = bus, rules = rules, formulaRun = { Evaluate = function(_, text) return tonumber(text), nil end },
            client = client,
            after = function(seconds, fn)
                if seconds == ns.SellingTab.POST_DELAY then
                    delays[#delays + 1] = fn
                end
            end,
            itemInfo = function(id) return "Item" .. id, 1 end,
            readBags = function()
                bagReads = bagReads + 1
                return bagItems
            end,
            syncInterval = 0,
            maxStack = function(id) return id == 10 and 20 or 1 end,
            vendorPrice = function(id) return vendor[id] end,
            -- The Post all confirm accepts at once; the server confirm of a post stays open.
            confirm = function(name, text, onAccept)
                confirms[#confirms + 1] = { name = name, text = text, onAccept = onAccept }
                if name == "FLIPSIDE_CONFIRM_POST_ALL" and autoAccept then
                    onAccept()
                end
            end,
            itemLink = function(id) return "|Hitem:" .. id .. "|h[Item" .. id .. "]|h", 1 end,
            warn = function(title, text, onPost, onSkip, onCancel, options)
                warns[#warns + 1] = { title = title, text = text, onYes = onPost, onSkip = onSkip, onCancel = onCancel,
                    options = options }
            end,
        }
        for k, v in pairs(extra or {}) do
            deps[k] = v
        end
        if deps.realWarn then
            deps.warn = nil
        end
        local core = ns.SellingTab.New(deps)
        core:Mount(CreateFrame("Frame", nil, UIParent), { Enter = function() end, Leave = function() end })
        core:Select()
        return core
    end

    before_each(function()
        mock.reset()
        views = {}
        local init = _G.ScrollUtil.InitScrollBoxListWithScrollBar
        _G.ScrollUtil.InitScrollBoxListWithScrollBar = function(box, bar, view)
            views[box] = view
            init(box, bar, view)
        end
        getmetatable(CreateFrame("Frame")).__index.SetJustifyH = function() end
        mock.qualityColors[1] = { 1, 1, 1, "ff1eff00" }
        ns = loadModules()
        bus = ns.EventBus.New({})
        client = makeClient()
        client.commodity[10] = false
        client.commodity[11] = true
        warns, bagReads, vendor, opExtra = {}, 0, {}, { vendorSkip = false, maxPrice = "100000000" }
        confirms, autoAccept = {}, true
        rules = makeRules()
        bagItems = {
            { key = "11", itemID = 11, name = "Bolt of Linen", count = 12, stacks = {
                { bag = 0, slot = 4, count = 12 } } },
            { key = "13", itemID = 13, name = "Widget", count = 2, stacks = { { bag = 2, slot = 1, count = 2 } } },
            { key = "10", itemID = 10, name = "Linen Cloth", count = 60, stacks = {
                { bag = 1, slot = 1, count = 20 }, { bag = 1, slot = 2, count = 20 },
                { bag = 1, slot = 3, count = 20 } } },
        }
        ns.SellingPlan.Log:Clear()
        tab = mount()
        ui = tab.ui
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("the price check", function()
        it("accepts a price from 1 copper up to the limit", function()
            assert.are.equal(1, ns.SellingTab.CheckPrice(1))
            assert.are.equal(12000, ns.SellingTab.CheckPrice(12000))
            assert.are.equal(100000000000, ns.SellingTab.CheckPrice(100000000000))
        end)

        it("refuses 0, a price that is too large and a value that is not a number, with a reason", function()
            for _, value in ipairs({ 0, -5, 100000000001 }) do
                local price, why = ns.SellingTab.CheckPrice(value)
                assert.is_nil(price, value)
                assert.is_string(why)
            end
            assert.is_nil((ns.SellingTab.CheckPrice(nil)))
        end)
    end)
    describe("the price box", function()
        it("holds the suggested price and the user can change it", function()
            selectCloth()
            assert.are.equal(119, ui.details.priceInput:GetCopper())
            assert.is_true(ui.details.priceInput.gold.enabled)
        end)

        it("posts an item at the typed price", function()
            selectCloth()
            pick("i10")
            type_("1g 20s")
            assert.are.equal("240000c", ui.details.total.text)
            assert.are.equal(240000, ui.details.stackInput:GetCopper())
            click(ui.postNext)
            assert.are.equal(12000 * 20, client.posts[1].buyout)
            -- The box keeps the price for the next auction of the same item.
            click(ui.postNext)
            assert.are.equal(12000 * 20, client.posts[2].buyout)
            local list = ns.SellingPlan.Log:List()
            assert.are.equal(12000, list[#list].price)
        end)

        it("gives the planned item ID to the post call", function()
            selectCloth()
            pick("i10")
            click(ui.postNext)
            assert.are.equal(10, client.posts[1].itemID)
        end)

        it("posts a commodity at the typed price for each item", function()
            selectCloth()
            pick("i11")
            assert.are.equal(149, ui.details.priceInput:GetCopper())
            type_("50s")
            click(ui.postNext)
            assert.are.equal("commodity", client.posts[1].kind)
            assert.are.equal(5000, client.posts[1].unitPrice)
        end)

        it("posts at the suggested price when the user types nothing", function()
            selectCloth()
            pick("i10")
            click(ui.postNext)
            assert.are.equal(119 * 20, client.posts[1].buyout)
        end)

        it("shows the total price of the typed price", function()
            selectCloth()
            pick("i10")
            local before = ui.details.total.text
            type_("1g 20s")
            assert.are_not.equal(before, ui.details.total.text)
        end)

        it("refuses an invalid price with a message and posts nothing", function()
            selectCloth()
            pick("i10")
            type_("")
            assert.matches("^Invalid price", ui.details.warn.text)
            assert.are.same({ 1, 0.3, 0.3 }, color(ui.details.warn))
            local ok, why = tab:PostNext()
            assert.is_false(ok)
            assert.matches("^invalid price", why)
            assert.matches("^invalid price", ui.message.text)
            click(ui.postNext)
            click(ui.postAll)
            assert.are.equal(0, #client.posts)
            type_("")
            click(ui.postNext)
            assert.are.equal(0, #client.posts)
        end)

        it("goes back to the suggested price when another item shows", function()
            selectCloth()
            pick("i10")
            type_("1g")
            pick("i11")
            assert.are.equal(149, ui.details.priceInput:GetCopper())
            pick("i10")
            assert.are.equal(119, ui.details.priceInput:GetCopper())
        end)

        it("uses the typed price only for the item that shows", function()
            selectCloth()
            pick("g2")
            type_("1g")
            for _ = 1, 3 do
                click(ui.postAll)
            end
            assert.are.equal(10000 * 20, client.posts[1].buyout)
            -- The next entry is the commodity: its own suggested price.
            assert.are.equal(149, ui.details.priceInput:GetCopper())
            click(ui.postAll)
            assert.are.equal(149, client.posts[4].unitPrice)
        end)
    end)

    describe("the info pane", function()
        it("keeps the lowest price in the list and not in the pane", function()
            selectCloth()
            pick("i10")
            assert.are.equal("Lowest on AH", ui.headers.labels.lowest.text)
            assert.are.equal("120c", draw("i10").sellParts.cells.lowest.text)
            assert.is_nil(ui.details.lowest)
            assert.is_nil(ui.details.vs)
        end)

        it("says none in the list when no other seller has an auction", function()
            client.rows[10] = {}
            pick("i10")
            fire("ITEM_RESULTS", 10)
            assert.are.equal("none", draw("i10").sellParts.cells.lowest.text)
        end)

        it("shows no post time", function()
            selectCloth()
            pick("i10")
            for _, label in ipairs({ ui.details.operation, ui.details.deposit, ui.details.total }) do
                assert.is_nil(label.text:find(" h", 1, true))
            end
        end)

        it("shows the deposit and the total price of the next post, and no net", function()
            selectCloth()
            pick("i10")
            assert.are.equal("200c", ui.details.deposit.text)
            assert.are.equal("2380c", ui.details.total.text)
            assert.is_nil(ui.details.net)
        end)

        it("shows the total price of a commodity as the price of one item times the quantity", function()
            selectCloth()
            pick("i11")
            local quantity = ui.details.qty:GetNumber()
            assert.are.equal(tostring(149 * quantity) .. "c", ui.details.total.text)
        end)

        it("shows the stack size row for an item and hides the stack price for a commodity", function()
            selectCloth()
            pick("i10")
            assert.is_false(ui.details.stacks:IsShown())
            assert.are.equal("Stack size:", ui.details.qtyLabel.text)
            assert.is_true(ui.details.qtyLabel:IsShown())
            assert.is_true(ui.details.stackInput:IsShown())
            pick("i11")
            assert.are.equal("Quantity:", ui.details.qtyLabel.text)
            assert.is_false(ui.details.stackInput:IsShown())
            assert.is_false(ui.details.stackLabel:IsShown())
            assert.is_true(ui.details.priceInput:IsShown())
            assert.is_true(ui.details.qty:IsShown())
        end)
    end)

    describe("the vendor warning", function()
        it("shows a line when the vendor pays more than the net", function()
            vendor[10] = 200
            selectCloth()
            pick("i10")
            assert.are.equal("Sells for more at a vendor: 4000c (net on the AH: 2061c)", ui.details.warn.text)
            assert.are.same({ 1, 0.6, 0.2 }, color(ui.details.warn))
        end)

        it("shows no line when the AH pays more", function()
            vendor[10] = 5
            selectCloth()
            pick("i10")
            assert.are.equal("", ui.details.warn.text)
            pick("i11")
            assert.are.equal("", ui.details.warn.text)
        end)

        it("follows the typed price", function()
            vendor[10] = 200
            selectCloth()
            pick("i10")
            type_("50s")
            assert.are.equal("", ui.details.warn.text)
            type_("1c")
            assert.matches("^Sells for more at a vendor", ui.details.warn.text)
        end)

        it("asks first on Post and posts after the accept, once for each item", function()
            vendor[10] = 200
            selectCloth()
            pick("i10")
            click(ui.postNext)
            assert.are.equal(0, #client.posts)
            assert.are.equal(1, #warns)
            assert.are.equal("Check the price", warns[1].title)
            assert.matches("Post 20 x |cff1eff00|Hitem:10|h%[Item10%]|h|r at 119c each", warns[1].text)
            assert.matches("Sells for more at a vendor: 4000c", warns[1].text)
            warns[1].onYes()
            assert.are.equal(1, #client.posts)
            click(ui.postNext)
            assert.are.equal(1, #warns)
            assert.are.equal(2, #client.posts)
        end)

        it("lists the net, the price, the deposit and the AH cut in the box", function()
            vendor[10] = 200
            selectCloth()
            pick("i10")
            click(ui.postNext)
            assert.matches("Net on the AH: 2061c %(price 2380c, Deposit: 200c, AH cut 119c%)", warns[1].text)
        end)

        it("shows an unknown deposit in the box as unknown, not as 0", function()
            vendor[10] = 200
            client.Deposit = function() return nil end
            tab = mount()
            ui = tab.ui
            selectCloth()
            pick("i10")
            click(ui.postNext)
            assert.matches("Net on the AH %(before deposit%): 2261c %(price 2380c, Deposit: unknown, AH cut 119c%)",
                warns[1].text)
        end)

        it("posts nothing when the user cancels", function()
            vendor[10] = 200
            selectCloth()
            pick("i10")
            click(ui.postNext)
            assert.are.equal(0, #client.posts)
            click(ui.postNext)
            assert.are.equal(2, #warns)
            assert.are.equal(0, #client.posts)
        end)

        it("asks the same question in the Post all queue", function()
            vendor[10] = 200
            selectCloth()
            click(ui.postAll)
            assert.are.equal(1, #warns)
            assert.are.equal(0, #client.posts)
            assert.matches("Sells for more at a vendor", warns[1].text)
        end)

        it("uses a square Kit window with the item link in the quality colour", function()
            local seen, window
            local create = ns.Kit.CreateWindow
            ns.Kit.CreateWindow = function(name, options)
                seen = options
                window = create(name, options)
                return window
            end
            vendor[10] = 200
            tab = mount({ realWarn = true })
            ui = tab.ui
            selectCloth()
            pick("i10")
            click(ui.postNext)
            assert.is_true(seen.square)
            assert.are.equal(0, #client.posts)
            assert.matches("|cff1eff00|Hitem:10|h%[Item10%]|h|r", window.text.text)
            assert.matches("Sells for more at a vendor", window.text.text)
            assert.are.equal("Post", window.yesButton.text)
            assert.are.equal("Skip", window.skipButton.text)
            assert.are.equal("Cancel", window.noButton.text)
            assert.is_true(window.shown)
            click(window.noButton)
            assert.is_false(window.shown)
            assert.are.equal(0, #client.posts)
            click(ui.postNext)
            click(window.yesButton)
            assert.is_false(window.shown)
            assert.are.equal(1, #client.posts)
        end)

        it("skips the item with the Skip button of the real box and makes no post", function()
            local window
            local create = ns.Kit.CreateWindow
            ns.Kit.CreateWindow = function(name, options)
                window = create(name, options)
                return window
            end
            vendor[10] = 200
            tab = mount({ realWarn = true })
            ui = tab.ui
            selectCloth()
            pick("i10")
            click(ui.postNext)
            assert.is_true(window.shown)
            click(window.skipButton)
            assert.is_false(window.shown)
            assert.are.equal(0, #client.posts)
            assert.are.equal("skipped", entryOf("10").status)
            assert.are.equal("i11", tab.selectedId)
        end)
    end)
    describe("the price warning box (Post, Skip, Cancel)", function()
        it("opens when the price is below the minimum price, and Cancel makes no post", function()
            selectCloth()
            pick("i10")
            type_("5c")
            click(ui.postNext)
            assert.are.equal(1, #warns)
            assert.matches("The price is below the minimum price: 10c", warns[1].text)
            assert.are.equal(0, #client.posts)
            warns[1].onCancel()
            assert.are.equal(0, #client.posts)
            assert.are.equal("ready", entryOf("10").status)
            assert.are.equal("i10", tab.selectedId)
        end)

        it("opens when the price is above the maximum price", function()
            opExtra = { vendorSkip = false, maxPrice = "200" }
            tab = mount()
            ui = tab.ui
            selectCloth()
            pick("i10")
            type_("5g")
            click(ui.postNext)
            assert.matches("The price is above the maximum price: 200c", warns[1].text)
        end)

        it("opens when the price is below the vendor price", function()
            vendor[10] = 200
            selectCloth()
            pick("i10")
            click(ui.postNext)
            assert.matches("Sells for more at a vendor", warns[1].text)
        end)

        it("opens for an item that the rule skips, so that Post works on any item with a result", function()
            client.rows[10] = { row(5, 1) }
            pick("i10")
            fire("ITEM_RESULTS", 10)
            type_("25c")
            click(ui.postNext)
            assert.matches("The rule skips this item", warns[1].text)
            assert.is_nil(warns[1].text:match("below the minimum price"))
        end)

        it("does not open for a price inside the limits", function()
            selectCloth()
            pick("i10")
            click(ui.postNext)
            assert.are.equal(0, #warns)
            assert.are.equal(1, #client.posts)
        end)

        it("posts with the Post button, once, and asks no more for the same item", function()
            selectCloth()
            pick("i10")
            type_("5c")
            click(ui.postNext)
            warns[1].onYes()
            assert.are.equal(1, #client.posts)
            assert.are.equal(5 * 20, client.posts[1].buyout)
            click(ui.postNext)
            assert.are.equal(1, #warns)
            assert.are.equal(2, #client.posts)
        end)

        it("skips the whole item with the Skip button and moves the selection to the next item", function()
            selectCloth()
            pick("i10")
            type_("5c")
            click(ui.postNext)
            warns[1].onSkip()
            assert.are.equal(0, #client.posts)
            assert.are.equal("skipped", entryOf("10").status)
            assert.are.equal("i11", tab.selectedId)
            assert.are.equal("i11", ui.tree.selected)
            assert.are.equal(1, #tab.selection)
            assert.are.equal("11", tab.selection[1].key)
            assert.are.equal("Bolt of Linen", ui.details.name.text)
            local list = ns.SellingPlan.Log:List()
            assert.are.equal("skipped by user", list[#list].reason)
        end)

        it("moves the selection to the next item after the last post of an item", function()
            selectCloth()
            pick("i10")
            click(ui.postNext)
            click(ui.postNext)
            assert.are.equal("i10", tab.selectedId)
            click(ui.postNext)
            assert.are.equal("i11", tab.selectedId)
            assert.are.equal("i11", ui.tree.selected)
            click(ui.postNext)
            assert.are.equal(4, #client.posts)
        end)

        it("starts the search of the next item when the selection moves to it", function()
            client.rows[10] = { row(120, 1) }
            pick("i10")
            fire("ITEM_RESULTS", 10)
            for _ = 1, 3 do
                click(ui.postNext)
            end
            assert.are.equal("i11", tab.selectedId)
            assert.are.same({ 10, 11 }, client.searches)
        end)

        it("moves on after the Skip button too", function()
            selectCloth()
            pick("i10")
            for _ = 1, 3 do
                click(ui.skip)
            end
            assert.are.equal("i11", tab.selectedId)
            assert.are.equal(0, #client.posts)
        end)

        it("keeps the group selection when a post ends an item of the group", function()
            selectCloth()
            for _ = 1, 3 do
                click(ui.postNext)
            end
            assert.are.equal("g2", tab.selectedId)
        end)

        it("makes the post call only in a click", function()
            selectCloth()
            pick("i10")
            type_("5c")
            tab:PostNext()
            assert.are.equal(0, #client.posts)
            warns[1].onSkip()
            warns[1].onCancel()
            assert.are.equal(0, #client.posts)
        end)
    end)

    describe("Post all with the warning box and the deposit confirm", function()
        local function warnBoth()
            vendor[10] = 200
            vendor[11] = 1000
            selectCloth()
        end

        it("shows the box for each warned item, then goes on", function()
            warnBoth()
            click(ui.postAll)
            assert.are.equal(1, #confirms)
            assert.are.equal(1, #warns)
            assert.are.equal(0, #client.posts)
            warns[1].onYes()
            assert.are.equal(1, #client.posts)
            click(ui.postAll)
            click(ui.postAll)
            assert.are.equal(1, #warns)
            assert.are.equal(3, #client.posts)
            click(ui.postAll)
            assert.are.equal(2, #warns)
            assert.are.equal(3, #client.posts)
            assert.matches("Item11", warns[2].text)
            warns[2].onYes()
            assert.are.equal(4, #client.posts)
            assert.are.equal("commodity", client.posts[4].kind)
        end)

        it("skips the warned item with Skip and goes on with the next one", function()
            warnBoth()
            click(ui.postAll)
            warns[1].onSkip()
            assert.are.equal("skipped", entryOf("10").status)
            assert.are.equal(0, #client.posts)
            click(ui.postAll)
            assert.are.equal(2, #warns)
            warns[2].onYes()
            assert.are.equal(1, #client.posts)
            assert.are.equal("commodity", client.posts[1].kind)
        end)

        it("stops the run with Cancel and asks for the deposit confirm again", function()
            warnBoth()
            click(ui.postAll)
            warns[1].onCancel()
            assert.are.equal(0, #client.posts)
            assert.is_nil(tab.allRun)
            assert.are.equal("stopped", ui.message.text)
            click(ui.postAll)
            assert.are.equal(2, #confirms)
            assert.are.equal(2, #warns)
        end)

        it("confirms the total deposit before the first post", function()
            selectCloth()
            autoAccept = false
            click(ui.postAll)
            assert.are.equal("FLIPSIDE_CONFIRM_POST_ALL", confirms[1].name)
            assert.matches("Post 4 auctions%? Total deposit: 720c", confirms[1].text)
            assert.are.equal(0, #client.posts)
            confirms[1].onAccept()
            assert.are.equal(1, #client.posts)
        end)

        it("makes the post inside the accept of the confirm, and no post if the user cancels it", function()
            selectCloth()
            autoAccept = false
            tab:PostAll()
            assert.are.equal(0, #client.posts)
            assert.are.equal(1, #confirms)
        end)

    end)

    describe("Post all delay", function()
        it("turns the button off after a post and on after the delay", function()
            selectCloth()
            click(ui.postAll)
            assert.are.equal(1, #client.posts)
            assert.is_false(ui.postAll.enabled)
            assert.are.equal("Post all (1/4)", ui.postAll.text)
            assert.are.equal(1, #delays)
            flushDelays()
            assert.is_true(ui.postAll.enabled)
        end)

        it("makes no post from the timer and refuses a click while locked", function()
            selectCloth()
            click(ui.postAll)
            local ok = tab:PostAll()
            assert.is_false(ok)
            assert.are.equal(1, #client.posts)
            flushDelays()
            assert.are.equal(1, #client.posts)
        end)

        it("keeps the button off while the throttle is not ready", function()
            selectCloth()
            click(ui.postAll)
            client.ready = false
            flushDelays()
            assert.is_false(ui.postAll.enabled)
            assert.are.equal(1, #delays)
            local ok = tab:PostAll()
            assert.is_false(ok)
            assert.are.equal(1, #client.posts)
            client.ready = true
            flushDelays()
            assert.is_true(ui.postAll.enabled)
            assert.are.equal(1, #client.posts)
        end)

        it("makes no first post while the throttle is not ready", function()
            selectCloth()
            client.ready = false
            click(ui.postAll)
            assert.are.equal(0, #client.posts)
        end)

        it("cancels the pending timer on Stop", function()
            selectCloth()
            click(ui.postAll)
            assert.is_true(ui.stop.shown)
            tab:Stop()
            assert.is_false(ui.stop.shown)
            flushDelays()
            assert.are.equal(0, #delays)
            assert.are.equal(1, #client.posts)
            assert.is_false(tab.locked)
        end)
    end)
    describe("the list columns", function()
        it("lines up the cells with the header at every depth of the tree", function()
            selectCloth()
            local headerX = ui.headers.labels.price.points[1][4] - ui.tree.contentInsets.left
            for id, depth in pairs({ i13 = 2, i10 = 2, i11 = 3 }) do
                local drawn = draw(id)
                local cell = drawn.sellParts.cells.price
                assert.are.equal(headerX, cell.points[1][4] + (depth - 1) * 14, id)
                local info = drawn.sellParts.cells.info
                assert.are.equal(info.points[1][4] + (depth - 1) * 14,
                    ui.headers.labels.info.points[1][4] - ui.tree.contentInsets.left, id)
            end
        end)

        it("right-aligns the number columns and the header of each", function()
            for _, column in ipairs(ns.SellingTab.COLUMNS) do
                local expected = column.number and "RIGHT" or "LEFT"
                assert.are.equal(expected, ns.Kit.ColumnJustify(column), column.key)
            end
            assert.is_true(ns.SellingTab.COLUMNS[2].number)
            assert.is_true(ns.SellingTab.COLUMNS[4].number)
            assert.is_true(ns.SellingTab.COLUMNS[5].number)
        end)
    end)

    describe("a post of an item that the rule skips", function()
        local function skipLinen()
            client.rows[10] = { row(5, 1) }
            pick("i10")
            fire("ITEM_RESULTS", 10)
        end

        it("lets the user post one item after a warning", function()
            skipLinen()
            assert.are.equal("skip", entryOf("10").status)
            assert.is_true(ui.postNext.enabled)
            assert.are.equal(4, ui.details.priceInput:GetCopper())
            type_("25c")
            click(ui.postNext)
            assert.are.equal(0, #client.posts)
            assert.are.equal(1, #warns)
            assert.matches("The rule skips this item: below minimum", warns[1].text)
            assert.matches("Post 20 x ", warns[1].text)
            assert.matches("at 25c each", warns[1].text)
            warns[1].onYes()
            assert.are.equal(1, #client.posts)
            assert.are.same({ "item", 1, 1, 24, 20, 500 }, { client.posts[1].kind, client.posts[1].bag,
                client.posts[1].slot, client.posts[1].duration, client.posts[1].quantity, client.posts[1].buyout })
            local list = ns.SellingPlan.Log:List()
            assert.are.equal("post", list[#list].decision)
            assert.are.equal("manual post", list[#list].reason)
        end)

        it("needs a price when the rule has none", function()
            skipLinen()
            type_("")
            click(ui.postNext)
            assert.are.equal(0, #warns)
            assert.matches("^invalid price", ui.message.text)
        end)

        it("is not part of a group post", function()
            skipLinen()
            pick("g2")
            assert.is_false(ui.postAll.enabled)
            local ok, why = tab:PostAll()
            assert.is_false(ok)
            assert.are.equal("nothing to post", why)
            assert.are.equal(0, #client.posts)
        end)

        it("is not offered for an item with no operation", function()
            pick("i13")
            assert.is_false(ui.postNext.enabled)
        end)
    end)

    describe("the Post button of the real warning box", function()
        local box, seen

        local function warnDialog()
            for _, frame in ipairs(mock.frames) do
                if frame.name == "FlipsideSellWarning" then
                    return frame
                end
            end
        end

        -- Mount with the real box. Each post call notes if the box is still open and if the click handler runs.
        local function mountReal()
            seen = {}
            local inClick = false
            for _, name in ipairs({ "PostItem", "PostCommodity" }) do
                local inner = client[name]
                client[name] = function(...)
                    seen[#seen + 1] = { name = name, inClick = inClick, shown = box and box:IsShown() }
                    return inner(...)
                end
            end
            tab = mount({ realWarn = true })
            ui = tab.ui
            box = nil
            local function press(button)
                inClick = true
                click(button)
                inClick = false
            end
            return press
        end

        it("posts an item that the rule skips inside the click", function()
            local press = mountReal()
            client.rows[10] = { row(5, 1) }
            pick("i10")
            fire("ITEM_RESULTS", 10)
            type_("25c")
            click(ui.postNext)
            box = warnDialog()
            assert.is_true(box:IsShown())
            assert.matches("The rule skips this item", box.text.text)
            assert.are.equal(0, #client.posts)
            press(box.yesButton)
            assert.are.equal(1, #client.posts)
            assert.are.same({ { name = "PostItem", inClick = true, shown = true } }, seen)
            assert.is_false(box:IsShown())
        end)

        it("posts a vendor-price warning of a commodity inside the click", function()
            local press = mountReal()
            vendor[11] = 4000
            client.rows[11] = { row(150, 5) }
            pick("i11")
            fire("COMMODITY_RESULTS", 11)
            type_("119c")
            click(ui.postNext)
            box = warnDialog()
            assert.is_true(box:IsShown())
            assert.matches("Sells for more at a vendor", box.text.text)
            assert.are.equal(0, #client.posts)
            press(box.yesButton)
            assert.are.equal(1, #client.posts)
            assert.are.equal("commodity", client.posts[1].kind)
            assert.are.same({ { name = "PostCommodity", inClick = true, shown = true } }, seen)
            assert.is_false(box:IsShown())
        end)

        it("posts a vendor-price warning of an item inside the click", function()
            local press = mountReal()
            vendor[10] = 4000
            client.rows[10] = { row(150, 5) }
            pick("i10")
            fire("ITEM_RESULTS", 10)
            type_("119c")
            click(ui.postNext)
            box = warnDialog()
            assert.matches("Sells for more at a vendor", box.text.text)
            press(box.yesButton)
            assert.are.same({ { name = "PostItem", inClick = true, shown = true } }, seen)
            assert.is_false(box:IsShown())
        end)
    end)

    describe("the deposit check at post time", function()
        local realDeposit, held

        -- A TBC-like client: no deposit while planning, the real deposit when the item is in the sale slot.
        local function mountTbc(vendorPrice, vendorSkip)
            opExtra.vendorSkip = vendorSkip
            vendor[10] = vendorPrice
            realDeposit, held = 400, 0
            client.Deposit = function() return nil end
            client.PostItem = function(bag, slot, duration, quantity, bid, buyout, itemID, guard)
                if guard and guard(realDeposit) == false then
                    held = held + 1
                    return "held", realDeposit
                end
                client.posts[#client.posts + 1] = { kind = "item", bag = bag, slot = slot, duration = duration,
                    quantity = quantity, bid = bid, buyout = buyout, itemID = itemID, guarded = guard ~= nil }
                return false
            end
            tab = mount()
            ui = tab.ui
            selectCloth()
            pick("i10")
        end

        it("holds the post and asks when the vendor pays more than the net with the real deposit", function()
            mountTbc(100, true)
            click(ui.postNext)
            assert.are.equal(1, held)
            assert.are.equal(0, #client.posts)
            assert.are.equal(1, #warns)
            assert.matches("Net: 1861c\nVendor: 2000c", warns[1].text)
            assert.matches("nets less than selling it to a vendor", warns[1].text)
            assert.are.equal("Post anyway", warns[1].options.post)
            assert.are.equal("Cancel", warns[1].options.cancel)
            assert.is_false(warns[1].options.skip)
        end)

        it("shows the price, the deposit and the AH cut in the vendor box", function()
            mountTbc(100, true)
            click(ui.postNext)
            assert.matches("Price: 2380c\nDeposit: 400c\nAH cut %(5%%%): 119c\nNet: 1861c", warns[1].text)
        end)

        it("shows an unknown deposit as unknown and the net before deposit", function()
            mountTbc(100, true)
            tab:_AskVendor(entryOf("10"), false, {
                vendor = 2000, net = 2261, profit = { gross = 2380, cut = 119, deposit = 0 },
            })
            local text = warns[1].text
            assert.matches("Deposit: unknown\nAH cut %(5%%%): 119c\nNet %(before deposit%): 2261c", text)
            assert.is_nil(text:find("Deposit: 0", 1, true))
        end)

        it("posts once with the same arguments after Post anyway", function()
            mountTbc(100, true)
            click(ui.postNext)
            warns[1].onYes()
            assert.are.equal(1, #client.posts)
            assert.are.equal(1, held)
            local post = client.posts[1]
            assert.are.same({ 1, 1, 24, 20, 2380 }, { post.bag, post.slot, post.duration, post.quantity, post.buyout })
            assert.is_false(post.guarded)
            assert.are.equal(1, #warns)
        end)

        it("posts nothing and skips the item after Cancel", function()
            mountTbc(100, true)
            click(ui.postNext)
            warns[1].onCancel()
            assert.are.equal(0, #client.posts)
            assert.are.equal("skipped", entryOf("10").status)
        end)

        it("posts at once when the vendor does not pay more", function()
            mountTbc(50, true)
            click(ui.postNext)
            assert.are.equal(0, #warns)
            assert.are.equal(1, #client.posts)
            assert.is_true(client.posts[1].guarded)
        end)

        it("makes no check when the operation has the vendor rule off", function()
            mountTbc(100, false)
            click(ui.postNext)
            assert.are.equal(0, #warns)
            assert.are.equal(1, #client.posts)
            assert.is_false(client.posts[1].guarded)
        end)

        it("makes no check when the vendor price is unknown", function()
            mountTbc(nil, true)
            click(ui.postNext)
            assert.are.equal(0, #warns)
            assert.are.equal(1, #client.posts)
            assert.is_false(client.posts[1].guarded)
        end)

        it("posts when the client gives no deposit", function()
            mountTbc(100, true)
            realDeposit = nil
            click(ui.postNext)
            assert.are.equal(0, #warns)
            assert.are.equal(1, #client.posts)
        end)

        it("makes the same check on a click of Post all", function()
            mountTbc(100, true)
            click(ui.postAll)
            assert.are.equal(0, #client.posts)
            assert.are.equal(1, #warns)
            assert.matches("Vendor: 2000c", warns[1].text)
        end)
    end)

    describe("Post all", function()
        it("posts the queue in tree order, one auction for each click", function()
            selectCloth()
            assert.are.equal("Post all (0/4)", ui.postAll.text)
            click(ui.postAll)
            assert.are.equal("Post all (1/4)", ui.postAll.text)
            click(ui.postAll)
            click(ui.postAll)
            assert.are.equal("Post all (3/4)", ui.postAll.text)
            click(ui.postAll)
            assert.are.equal(4, #client.posts)
            assert.are.same({ "item", "item", "item", "commodity" },
                { client.posts[1].kind, client.posts[2].kind, client.posts[3].kind, client.posts[4].kind })
            assert.are.same({ 1, 2, 3 }, { client.posts[1].slot, client.posts[2].slot, client.posts[3].slot })
            assert.are.equal("Post all", ui.postAll.text)
            assert.is_false(ui.postAll.enabled)
        end)

        it("makes one protected post for each click", function()
            selectCloth()
            tab:PostAll()
            assert.are.equal(1, #client.posts)
        end)

        it("leaves out the items that the plan skips", function()
            client.rows[10] = { row(5, 1) }
            client.rows[11] = { row(150, 5) }
            pick("g2")
            fire("ITEM_RESULTS", 10)
            fire("COMMODITY_RESULTS", 11)
            assert.are.equal("skip", entryOf("10").status)
            assert.are.equal("Post all (0/1)", ui.postAll.text)
            click(ui.postAll)
            assert.are.equal(1, #client.posts)
            assert.are.equal("commodity", client.posts[1].kind)
            assert.are.equal(0, #warns)
        end)

        it("is off with no post left, and with the post capability off", function()
            assert.is_false(ui.postAll.enabled)
            selectCloth()
            assert.is_true(ui.postAll.enabled)
            client.CanPost = function() return false end
            tab:_Update()
            assert.is_false(ui.postAll.enabled)
            assert.is_false(ui.postNext.enabled)
        end)
    end)

    describe("the rule limits", function()
        local function remount(extra)
            opExtra = extra
            tab = mount()
            ui = tab.ui
        end

        local function postAllClicks()
            local n = 0
            flushDelays()
            while ui.postAll.enabled and n < 50 do
                click(ui.postAll)
                n = n + 1
                flushDelays()
            end
            return n
        end

        it("splits an item by the max stack size", function()
            remount({ stackSize = 8 })
            selectCloth()
            local entry = entryOf("10")
            -- A unit comes from one slot: two units of 8 fit in each stack of 20.
            assert.are.equal(6, #entry.units)
            assert.are.equal(8, entry.units[1].quantity)
        end)

        it("posts nothing of the kept quantity with Post all", function()
            remount({ keepInBags = 30 })
            selectCloth()
            assert.are.equal("keep in bags reached", entryOf("11").decision.reason)
            postAllClicks()
            local units = 0
            for _, post in ipairs(client.posts) do
                units = units + post.quantity
            end
            -- 30 of 60 linen are free: one stack of 20 (a second needs 20, only 10 are left); 12 bolts are kept.
            assert.are.equal(20, units)
        end)

        it("stops Post all at the post quantity", function()
            remount({ postCap = 2 })
            selectCloth()
            assert.are.equal(2, #entryOf("10").units)
            local n = postAllClicks()
            assert.are.equal(n, #client.posts)
            local items = 0
            for _, post in ipairs(client.posts) do
                if post.kind == "item" then
                    items = items + 1
                end
            end
            assert.are.equal(2, items)
        end)

        it("caps a commodity by the post quantity in units", function()
            remount({ postCap = 5 })
            selectCloth()
            postAllClicks()
            local commodity
            for _, post in ipairs(client.posts) do
                if post.kind == "commodity" then
                    commodity = post
                end
            end
            assert.are.equal(5, commodity.quantity)
        end)

        it("passes the post duration of the rule to the post call", function()
            remount({ duration = 8 })
            selectCloth()
            postAllClicks()
            assert.is_true(#client.posts > 0)
            for _, post in ipairs(client.posts) do
                assert.are.equal(8, post.duration)
            end
        end)

        it("follows the max stack size in a manual post", function()
            remount({ stackSize = 5 })
            client.rows[10] = { row(5, 1) }
            pick("i10")
            fire("ITEM_RESULTS", 10)
            type_("25c")
            click(ui.postNext)
            warns[1].onYes()
            assert.are.equal(5, client.posts[1].quantity)
        end)

        it("never offers a manual post of the kept quantity", function()
            remount({ keepInBags = 60 })
            client.rows[10] = { row(120, 1) }
            pick("i10")
            fire("ITEM_RESULTS", 10)
            assert.are.equal("skip", entryOf("10").status)
            assert.is_false(ui.postNext.enabled)
        end)

        it("keeps the kept quantity out of a manual commodity post", function()
            remount({ keepInBags = 4, belowMin = "skip", minPrice = "1000" })
            client.rows[11] = { row(150, 5) }
            pick("i11")
            fire("COMMODITY_RESULTS", 11)
            assert.are.equal("skip", entryOf("11").status)
            type_("25c")
            click(ui.postNext)
            warns[1].onYes()
            assert.are.equal(8, client.posts[1].quantity)
        end)
    end)

    describe("the kept sale slot (TBC)", function()
        local slotItem, holds, releases, holdFails

        before_each(function()
            slotItem, holds, releases, holdFails = nil, {}, 0, false
            client.HoldSlot = function(bag, slot, quantity, itemID, stacks)
                holds[#holds + 1] = { bag = bag, slot = slot, quantity = quantity, itemID = itemID, stacks = stacks }
                if holdFails then
                    return false, "the cursor holds an item"
                end
                slotItem = itemID
                return true
            end
            client.ReleaseSlot = function()
                releases = releases + 1
                slotItem = nil
                return true
            end
            -- The legacy client gives a deposit only for the item in the sale slot and with the real prices.
            client.Deposit = function(_, _, hours, quantity, _, start)
                if not slotItem or type(start) ~= "number" then
                    return nil
                end
                return quantity * 2 + hours + math.floor(start / quantity / 100)
            end
        end)

        it("shows unknown, not 0, when the client has no kept slot and gives no deposit", function()
            client.HoldSlot, client.ReleaseSlot = nil, nil
            client.Deposit = function() return nil end
            selectCloth()
            pick("i10")
            assert.are.equal("unknown", ui.details.deposit.text)
        end)

        it("puts the item in the sale slot on the select click and keeps it there", function()
            selectCloth()
            pick("i10")
            assert.are.same({ bag = 1, slot = 1, quantity = 20, itemID = 10 }, holds[#holds])
            assert.are.equal(10, slotItem)
            assert.are.equal(0, releases)
            assert.are.equal(0, #client.posts)
            -- 3 auctions of 20 items at 119 each: 20 x 2 + 24 + 1 for each auction.
            assert.are.equal("65c", ui.details.deposit.text)
            assert.are.equal(195, entryOf("10").deposit)
        end)

        it("fills the slot with the one item that the pane shows when a group is selected", function()
            selectCloth()
            assert.are.equal(1, #holds)
            assert.are.same({ bag = 1, slot = 1, quantity = 1, itemID = 10 }, holds[1])
            assert.are.equal("65c", ui.details.deposit.text)
        end)

        it("fills the slot before the decision and reads the deposit when the decision event arrives", function()
            client.rows[10] = { row(120, 1) }
            pick("g2")
            assert.are.equal(1, #holds)
            assert.are.same({ bag = 1, slot = 1, quantity = 1, itemID = 10 }, holds[1])
            fire("ITEM_RESULTS", 10)
            assert.are.equal(1, #holds)
            assert.are.equal(0, releases)
            assert.are.equal("65c", ui.details.deposit.text)
        end)

        it("reads again when the price, the stack size or the duration changes, with no new fill", function()
            selectCloth()
            pick("i10")
            local fills = #holds
            type_("1g 20s")
            assert.are.equal((20 * 2 + 24 + 120) .. "c", ui.details.deposit.text)
            type_("119c")
            assert.are.equal("65c", ui.details.deposit.text)
            -- The stack price box sets the unit price: 24g for 20 items is 1g 20s each.
            ui.details.stackInput.gold:SetText("24")
            ui.details.stackInput.silver:SetText("")
            ui.details.stackInput.copper:SetText("")
            ui.details.stackInput.gold.scripts.OnTextChanged(ui.details.stackInput.gold)
            assert.are.equal(12000, ui.details.priceInput:GetCopper())
            assert.are.equal((20 * 2 + 24 + 120) .. "c", ui.details.deposit.text)
            type_("119c")
            assert.is_true(tab:SetManualQuantity(5))
            assert.are.equal((5 * 2 + 24 + 1) .. "c", ui.details.deposit.text)
            assert.is_true(tab:SetManualQuantity(nil))
            assert.is_true(tab:SetManualDuration(8))
            assert.are.equal((20 * 2 + 8 + 1) .. "c", ui.details.deposit.text)
            assert.are.equal(fills, #holds)
            assert.are.equal(0, releases)
        end)

        it("keeps the deposit unknown when the slot cannot fill", function()
            holdFails = true
            selectCloth()
            pick("i10")
            assert.are.equal("unknown", ui.details.deposit.text)
            assert.is_nil(slotItem)
        end)

        it("keeps the deposit unknown when the fill raises an error", function()
            client.HoldSlot = function() error("boom", 0) end
            selectCloth()
            pick("i10")
            assert.are.equal("unknown", ui.details.deposit.text)
        end)

        it("fills the slot with the new item in the click that selects another item", function()
            client.commodity[11] = false
            selectCloth()
            pick("i10")
            pick("i11")
            assert.are.equal(0, holds[#holds].bag)
            assert.are.equal(4, holds[#holds].slot)
            assert.are.equal(11, holds[#holds].itemID)
            assert.are.equal(11, slotItem)
        end)

        it("releases the slot when the new selection has no item to hold", function()
            selectCloth()
            pick("i10")
            pick("g6")
            assert.are.equal(1, releases)
            assert.is_nil(slotItem)
        end)

        it("releases the slot when the tab is left, once", function()
            selectCloth()
            pick("i10")
            tab:Deselect()
            assert.are.equal(1, releases)
            assert.is_nil(slotItem)
            tab:Deselect()
            assert.are.equal(1, releases)
        end)

        it("releases the slot when the AH closes", function()
            client.CloseEvent = function() return "AH_CLOSED" end
            tab = mount()
            ui = tab.ui
            selectCloth()
            pick("i10")
            fire("AH_CLOSED")
            assert.are.equal(1, releases)
            assert.is_nil(slotItem)
        end)

        it("releases the slot when the user skips the item", function()
            selectCloth()
            pick("i10")
            tab:SkipItem(entryOf("10"))
            assert.are.equal(1, releases)
            assert.is_nil(slotItem)
        end)

        it("stops the reads without a release when the item leaves the plan, and releases on the leave", function()
            selectCloth()
            pick("i10")
            tab:RefreshBags()
            assert.are.equal(0, releases)
            assert.is_nil(tab.held.entry)
            tab:Deselect()
            assert.are.equal(1, releases)
        end)

        it("posts with the kept slot: no new fill, no release, and the post owns the slot", function()
            selectCloth()
            pick("i10")
            local fills, seen = #holds, nil
            local post = client.PostItem
            client.PostItem = function(...)
                seen = slotItem
                return post(...)
            end
            click(ui.postNext)
            assert.are.equal(10, seen)
            assert.are.equal(1, #client.posts)
            assert.are.equal(fills, #holds)
            assert.are.equal(0, releases)
            tab:Deselect()
            assert.are.equal(0, releases)
        end)

        it("keeps the Forever deposit as it is", function()
            client.HoldSlot, client.ReleaseSlot = nil, nil
            client.Deposit = function(_, _, _, quantity) return quantity * 10 end
            selectCloth()
            pick("i10")
            assert.are.equal("200c", ui.details.deposit.text)
            assert.are.equal("2380c", ui.details.total.text)
        end)

        it("formats the deposit as unknown, never 0, and the total price of a post", function()
            assert.are.equal("unknown", ns.SellingTab.DepositValue(nil))
            assert.are.equal("0c", ns.SellingTab.DepositValue(0))
            assert.are.equal("Deposit: unknown", ns.SellingTab.DepositText(nil))
            assert.are.equal("Deposit: 0c", ns.SellingTab.DepositText(0))
            assert.are.equal(2380, ns.SellingTab.TotalPrice(119, { quantity = 20 }))
            assert.are.equal(7140, ns.SellingTab.TotalPrice(119, { quantity = 20, stacks = 3 }))
        end)
    end)

    describe("the quantity and the duration of a manual post", function()
        before_each(function()
            -- The deposit grows with the hours and the quantity.
            client.Deposit = function(_, _, hours, quantity) return quantity * hours end
        end)

        it("limits a quantity from 1 to the available count", function()
            assert.are.equal(5, ns.SellingTab.ClampQuantity(5, 12))
            assert.are.equal(12, ns.SellingTab.ClampQuantity(99, 12))
            assert.are.equal(1, ns.SellingTab.ClampQuantity(0, 12))
            assert.are.equal(1, ns.SellingTab.ClampQuantity(-4, 12))
            assert.are.equal(3, ns.SellingTab.ClampQuantity(3.7, 12))
            assert.are.equal(1, ns.SellingTab.ClampQuantity(5, 0))
            assert.is_nil(ns.SellingTab.ClampQuantity(nil, 12))
            assert.is_nil(ns.SellingTab.ClampQuantity("x", 12))
        end)

        it("takes the available count from the bags minus the keep quantity", function()
            assert.are.equal(56, ns.SellingTab.MaxQuantity({ count = 60, settings = { keepInBags = 4 } }))
            assert.are.equal(60, ns.SellingTab.MaxQuantity({ count = 60 }))
            assert.are.equal(1, ns.SellingTab.MaxQuantity({ count = 3, settings = { keepInBags = 9 } }))
        end)

        it("accepts only the durations 2, 8 and 24", function()
            for _, hours in ipairs({ 2, 8, 24 }) do
                assert.is_true(ns.SellingTab.IsDuration(hours))
            end
            for _, hours in ipairs({ 1, 12, 48 }) do
                assert.is_false(ns.SellingTab.IsDuration(hours))
            end
        end)

        it("shows the calculated quantity and the duration of the rule", function()
            selectCloth()
            pick("i10")
            assert.are.equal(20, ui.details.qty.GetNumber())
            assert.are.equal(24, ui.details.duration.GetValue())
        end)

        it("updates the deposit and the total price when the quantity changes", function()
            selectCloth()
            pick("i10")
            local deposit, total = ui.details.deposit.text, ui.details.total.text
            assert.is_true(tab:SetManualQuantity(5))
            assert.are_not.equal(deposit, ui.details.deposit.text)
            assert.are_not.equal(total, ui.details.total.text)
            assert.are.equal("120c", ui.details.deposit.text)
            assert.are.equal("595c", ui.details.total.text)
        end)

        it("updates the deposit when the duration changes", function()
            selectCloth()
            pick("i10")
            local deposit = ui.details.deposit.text
            tab:SetManualDuration(2)
            assert.are_not.equal(deposit, ui.details.deposit.text)
            assert.are.equal((20 * 2) .. "c", ui.details.deposit.text)
        end)

        it("posts the chosen quantity and duration and logs them", function()
            selectCloth()
            pick("i10")
            tab:SetManualQuantity(5)
            tab:SetManualDuration(8)
            click(ui.postNext)
            assert.are.equal(5, client.posts[1].quantity)
            assert.are.equal(8, client.posts[1].duration)
            assert.are.equal(119 * 5, client.posts[1].buyout)
            local list = ns.SellingPlan.Log:List()
            assert.are.equal(5, list[#list].quantity)
            assert.are.equal(8, list[#list].duration)
            -- The next post goes back to the calculated values.
            assert.are.equal(20, ui.details.qty.GetNumber())
            assert.are.equal(24, ui.details.duration.GetValue())
            click(ui.postNext)
            assert.are.equal(20, client.posts[2].quantity)
            assert.are.equal(24, client.posts[2].duration)
        end)

        it("limits a commodity quantity to the count minus the keep quantity", function()
            opExtra = { keepInBags = 4 }
            tab = mount()
            ui = tab.ui
            selectCloth()
            pick("i11")
            tab:SetManualQuantity(500)
            assert.are.equal(8, entryOf("11").manualQty)
            click(ui.postNext)
            assert.are.equal(8, client.posts[1].quantity)
        end)

        it("clears the quantity when the value is empty", function()
            selectCloth()
            pick("i10")
            tab:SetManualQuantity(5)
            tab:SetManualQuantity(nil)
            assert.is_nil(entryOf("10").manualQty)
        end)

        it("ignores a duration that is not offered", function()
            selectCloth()
            pick("i10")
            tab:SetManualDuration(12)
            assert.is_nil(entryOf("10").manualHours)
        end)

        it("keeps Post all on the operation settings", function()
            selectCloth()
            pick("i10")
            tab:SetManualQuantity(5)
            tab:SetManualDuration(2)
            pick("g2")
            click(ui.postAll)
            assert.are.equal(24, client.posts[1].duration)
            assert.are_not.equal(5, client.posts[1].quantity)
        end)

        it("uses the chosen quantity and duration for a skipped item", function()
            client.rows[10] = { row(5, 1) }
            pick("i10")
            fire("ITEM_RESULTS", 10)
            assert.are.equal("skip", entryOf("10").status)
            assert.are.equal(20, ui.details.qty.GetNumber())
            tab:SetManualQuantity(7)
            tab:SetManualDuration(2)
            assert.matches("^%d+c$", ui.details.deposit.text)
            type_("25c")
            click(ui.postNext)
            warns[1].onYes()
            assert.are.equal(7, client.posts[1].quantity)
            assert.are.equal(2, client.posts[1].duration)
        end)

        it("changes the quantity through the box", function()
            selectCloth()
            pick("i10")
            ui.details.qty:SetText("6")
            ui.details.qty.scripts.OnEnterPressed(ui.details.qty)
            assert.are.equal(6, entryOf("10").manualQty)
        end)
    end)
    describe("the vendor skip rule", function()
        local function remount(extra)
            opExtra = extra
            tab = mount()
            ui = tab.ui
        end

        it("skips an item whose vendor price is higher than the net, by default", function()
            remount({})
            vendor[10] = 200
            selectCloth()
            local entry = entryOf("10")
            assert.are.equal("skip", entry.status)
            assert.are.equal("vendor pays more than the AH", entry.decision.reason)
            assert.are.equal("vendor pays more, skipped", ns.SellingTab.InfoText(entry))
            local last
            for _, item in ipairs(ns.SellingPlan.Log:List()) do
                if item.key == "10" then
                    last = item
                end
            end
            assert.are.equal("skip", last.decision)
            assert.are.equal("vendor pays more than the AH", last.reason)
        end)

        it("keeps the item in the queue when the AH pays more", function()
            remount({})
            vendor[10] = 5
            selectCloth()
            assert.are.equal("ready", entryOf("10").status)
        end)

        it("posts the item when the rule is off", function()
            remount({ vendorSkip = false })
            vendor[10] = 200
            selectCloth()
            assert.are.equal("ready", entryOf("10").status)
        end)

        it("leaves the skipped item out of Post all", function()
            remount({})
            vendor[10] = 200
            selectCloth()
            assert.are.equal("Post all (0/1)", ui.postAll.text)
            click(ui.postAll)
            assert.are.equal("commodity", client.posts[1].kind)
            assert.are.equal(0, #warns)
        end)

        it("still asks first on a manual post of the skipped item", function()
            remount({})
            vendor[10] = 200
            selectCloth()
            pick("i10")
            assert.is_true(ui.postNext.enabled)
            assert.are.equal(119, ui.details.priceInput:GetCopper())
            click(ui.postNext)
            assert.are.equal(0, #client.posts)
            assert.matches("The rule skips this item: vendor pays more, skipped", warns[1].text)
            assert.matches("Sells for more at a vendor", warns[1].text)
            warns[1].onYes()
            assert.are.equal(1, #client.posts)
        end)
    end)
    describe("the sample fallback", function()
        local function remount(samples)
            tab = mount({
                getRecord = function() return { latest = { time = 0 }, days = { { scans = samples } } } end,
                now = function() return 3600 end,
            })
            ui = tab.ui
        end

        it("posts at the cheapest listing when the scan has too few samples", function()
            remount(1)
            selectCloth()
            local entry = entryOf("10")
            assert.are.equal("ready", entry.status)
            assert.are.equal(119, entry.decision.price)
            assert.are.equal("few samples, using the cheapest listing", entry.decision.reason)
            assert.are.equal("few samples, using the cheapest listing", ns.SellingTab.InfoText(entry))
        end)

        it("skips with the old reason when no listing exists", function()
            remount(1)
            client.rows[10] = {}
            pick("i10")
            fire("ITEM_RESULTS", 10)
            assert.are.equal("skip", entryOf("10").status)
            assert.are.equal("too few samples: 1 of 3", entryOf("10").decision.reason)
        end)

        it("posts as before with enough samples", function()
            remount(3)
            selectCloth()
            assert.are.equal("undercut", entryOf("10").decision.reason)
        end)
    end)
    describe("the bag sync after a post", function()
        it("drops an item from the list after its last post", function()
            selectCloth()
            assert.is_true(has(visibleIds(), "i10"))
            for _ = 1, 3 do
                click(ui.postNext)
            end
            local ids = visibleIds()
            assert.is_false(has(ids, "i10"))
            assert.is_true(has(ids, "i11"))
            -- The queue keeps its count.
            assert.are.equal("Posting 4 of 4", ui.progress.text)
        end)

        it("shows the rest of a stack that is only partly posted", function()
            bagItems[3].count = 47
            bagItems[3].stacks = { { bag = 1, slot = 1, count = 20 }, { bag = 1, slot = 2, count = 20 },
                { bag = 1, slot = 3, count = 7 } }
            tab:RefreshBags()
            selectCloth()
            click(ui.postNext)
            click(ui.postNext)
            assert.are.equal(2, #client.posts)
            assert.is_false(has(visibleIds(), "i10"))
            -- The bags change: 40 items are on the AH, 7 stay.
            bagItems[3] = { key = "10", itemID = 10, name = "Linen Cloth", count = 7, stacks = {
                { bag = 1, slot = 3, count = 7 } } }
            fire("BAG_UPDATE_DELAYED")
            assert.is_true(has(visibleIds(), "i10"))
            assert.are.equal("|cff1eff00|Hitem:10|h[Item10]|h|r x7", draw("i10").label.text)
            assert.are.equal("searching", entryOf("10").status)
            assert.are.equal(10, client.searches[#client.searches])
            fire("ITEM_RESULTS", 10)
            assert.are.equal("ready", entryOf("10").status)
            click(ui.postNext)
            local last = client.posts[3]
            assert.are.same({ "item", 1, 3, 7 }, { last.kind, last.bag, last.slot, last.quantity })
        end)

        it("drops an item that the bags no longer hold", function()
            selectCloth()
            click(ui.postNext)
            local kept = {}
            for _, item in ipairs(bagItems) do
                if item.key ~= "10" then
                    kept[#kept + 1] = item
                end
            end
            bagItems = kept
            fire("CREATED")
            assert.is_nil(entryOf("10"))
            assert.is_false(has(visibleIds(), "i10"))
            assert.is_true(has(visibleIds(), "i11"))
            assert.are.equal(entryOf("11"), tab:_Current())
        end)

        it("takes the units that are left from the new stacks", function()
            selectCloth()
            pick("i10")
            click(ui.postNext)
            -- The bag packs the two stacks that are left into the first slots.
            bagItems[3] = { key = "10", itemID = 10, name = "Linen Cloth", count = 40, stacks = {
                { bag = 1, slot = 1, count = 20 }, { bag = 1, slot = 2, count = 20 } } }
            fire("BAG_UPDATE_DELAYED")
            assert.are.equal("ready", entryOf("10").status)
            click(ui.postNext)
            assert.are.same({ 1, 1 }, { client.posts[2].bag, client.posts[2].slot })
            click(ui.postNext)
            assert.are.same({ 1, 2 }, { client.posts[3].bag, client.posts[3].slot })
            -- The last post reads the bags at once: the item stays until the bag event, then it goes.
            bagItems = { bagItems[1], bagItems[2] }
            fire("BAG_UPDATE_DELAYED")
            assert.is_false(has(visibleIds(), "i10"))
        end)

        it("makes no post on a bag or post event", function()
            selectCloth()
            fire("BAG_UPDATE_DELAYED")
            fire("CREATED")
            assert.are.equal(0, #client.posts)
        end)

        it("reads the bags on the post event too", function()
            selectCloth()
            local reads = bagReads
            fire("CREATED")
            assert.are.equal(reads + 1, bagReads)
        end)

        it("waits for the server confirm before it reads the bags", function()
            selectCloth()
            client.PostItem = function()
                return true
            end
            click(ui.postNext)
            assert.is_not_nil(tab.awaiting)
            local reads = bagReads
            fire("BAG_UPDATE_DELAYED")
            assert.are.equal(reads, bagReads)
        end)
    end)
end)
