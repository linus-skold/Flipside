local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end }
    for _, name in ipairs({ "EventBus", "ItemString", "ScanKey", "BagItems", "SellingPlan", "Theme", "Widgets",
        "Window", "List", "Columns", "Tree", "AuctionTabs", "SellingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

-- These specs keep ScrollUtil: the game uses the ScrollBox path.
describe("SellingTab price box, warnings, post all and bag sync", function()
    local ns, bus, client, rules, tab, ui, bagItems, bagReads, warns, views, vendor, opExtra

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
        c.PostItem = function(bag, slot, duration, quantity, bid, buyout)
            c.posts[#c.posts + 1] = { kind = "item", bag = bag, slot = slot, duration = duration,
                quantity = quantity, bid = bid, buyout = buyout }
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

    local function click(button)
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

    local function type_(text)
        ui.details.priceInput:SetText(text)
        ui.details.priceInput.scripts.OnTextChanged(ui.details.priceInput)
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
            after = function() end,
            itemInfo = function(id) return "Item" .. id, 1 end,
            readBags = function()
                bagReads = bagReads + 1
                return bagItems
            end,
            maxStack = function(id) return id == 10 and 20 or 1 end,
            vendorPrice = function(id) return vendor[id] end,
            confirm = function() end,
            itemLink = function(id) return "|Hitem:" .. id .. "|h[Item" .. id .. "]|h", 1 end,
            warn = function(title, text, yesLabel, onYes)
                warns[#warns + 1] = { title = title, text = text, yesLabel = yesLabel, onYes = onYes }
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
        warns, bagReads, vendor, opExtra = {}, 0, {}, { vendorSkip = false }
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

    describe("the price parse function", function()
        local parse = function(text)
            return ns.SellingTab.ParsePrice(text)
        end

        it("reads gold, silver and copper", function()
            assert.are.equal(12000, parse("1g 20s"))
            assert.are.equal(12000, parse("120s"))
            assert.are.equal(12000, parse("12000"))
            assert.are.equal(10205, parse("1G2s5C"))
            assert.are.equal(10205, parse("  1g   2s  5c "))
            assert.are.equal(7, parse("7c"))
            assert.are.equal(5, parse("5"))
        end)

        it("refuses text that is not a price, with a reason", function()
            for _, text in ipairs({ "", "   ", "abc", "1.5g", "-5", "0", "0g", "1x", "g", "1g 1g", "5c 1g", "1g,20s",
                "1 g 20", "99999999999999999999g" }) do
                local price, why = parse(text)
                assert.is_nil(price, text)
                assert.is_string(why)
            end
            assert.is_nil((parse(nil)))
        end)

        it("writes a price as text that it reads back", function()
            assert.are.equal("1g 20s", ns.SellingTab.PriceText(12000))
            assert.are.equal("1s 19c", ns.SellingTab.PriceText(119))
            assert.are.equal("1g 5c", ns.SellingTab.PriceText(10005))
            assert.are.equal("20s", ns.SellingTab.PriceText(2000))
            for _, copper in ipairs({ 1, 99, 100, 10001, 123456789 }) do
                assert.are.equal(copper, parse(ns.SellingTab.PriceText(copper)))
            end
        end)
    end)

    describe("the price box", function()
        it("holds the suggested price and the user can change it", function()
            selectCloth()
            assert.are.equal("1s 19c", ui.details.priceInput.text)
            assert.is_true(ui.details.priceInput.enabled)
        end)

        it("posts an item at the typed price", function()
            selectCloth()
            pick("i10")
            type_("1g 20s")
            assert.are.equal("Buyout 240000c per auction", ui.details.price.text)
            click(ui.postNext)
            assert.are.equal(12000 * 20, client.posts[1].buyout)
            -- The box keeps the price for the next auction of the same item.
            click(ui.postNext)
            assert.are.equal(12000 * 20, client.posts[2].buyout)
            local list = ns.SellingPlan.Log:List()
            assert.are.equal(12000, list[#list].price)
        end)

        it("posts a commodity at the typed price for each item", function()
            selectCloth()
            pick("i11")
            assert.are.equal("1s 49c", ui.details.priceInput.text)
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

        it("shows the net of the typed price", function()
            selectCloth()
            pick("i10")
            local before = ui.details.net.text
            type_("1g 20s")
            assert.are_not.equal(before, ui.details.net.text)
        end)

        it("refuses an invalid price with a message and posts nothing", function()
            selectCloth()
            pick("i10")
            type_("12 apples")
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
            assert.are.equal("1s 49c", ui.details.priceInput.text)
            pick("i10")
            assert.are.equal("1s 19c", ui.details.priceInput.text)
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
            assert.are.equal("1s 49c", ui.details.priceInput.text)
            click(ui.postAll)
            assert.are.equal(149, client.posts[4].unitPrice)
        end)
    end)

    describe("the info pane", function()
        it("names the lowest price and explains it in a tooltip", function()
            selectCloth()
            pick("i10")
            assert.are.equal("Lowest on AH: 120c", ui.details.lowest.text)
            assert.are.equal("Lowest on AH", ui.headers.labels.lowest.text)
            local hit = ui.details.lowestHit
            hit.scripts.OnEnter(hit)
            assert.are.equal("Lowest on AH", mock.tooltip.title)
            assert.are.equal(ns.SellingTab.LOWEST_TIP, mock.tooltip.lines[1])
        end)

        it("says none when no other seller has an auction", function()
            client.rows[10] = {}
            pick("i10")
            fire("ITEM_RESULTS", 10)
            assert.are.equal("Lowest on AH: none", ui.details.lowest.text)
        end)

        it("shows no post time", function()
            selectCloth()
            pick("i10")
            assert.are.equal("3 x 20", ui.details.stack.text)
            for _, label in ipairs({ ui.details.stack, ui.details.price, ui.details.operation, ui.details.deposit }) do
                assert.is_nil(label.text:find(" h", 1, true))
            end
        end)

        it("shows a positive net in green with an up arrow", function()
            selectCloth()
            pick("i10")
            assert.are.equal("Net: " .. ns.SellingTab.ARROW_UP .. " 6183c", ui.details.net.text)
            assert.are.same({ 0.4, 1, 0.4 }, color(ui.details.net))
        end)

        it("shows a negative net in red with a down arrow", function()
            client.Deposit = function() return 100000 end
            selectCloth()
            pick("i10")
            assert.are.equal("Net: " .. ns.SellingTab.ARROW_DOWN .. " -293217c", ui.details.net.text)
            assert.are.same({ 1, 0.3, 0.3 }, color(ui.details.net))
        end)

        it("shows a net of zero in white with no arrow", function()
            local text, rgb = ns.SellingTab.NetStyle(0)
            assert.are.equal("Net: 0c", text)
            assert.are.same({ 1, 1, 1 }, rgb)
            local up, upColor = ns.SellingTab.NetStyle(5)
            assert.are.equal("Net: " .. ns.SellingTab.ARROW_UP .. " 5c", up)
            assert.are.same({ 0.4, 1, 0.4 }, upColor)
            local down, downColor = ns.SellingTab.NetStyle(-5)
            assert.are.equal("Net: " .. ns.SellingTab.ARROW_DOWN .. " -5c", down)
            assert.are.same({ 1, 0.3, 0.3 }, downColor)
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
            assert.are.equal("Post anyway", warns[1].yesLabel)
            assert.matches("Post 20 x |cff1eff00|Hitem:10|h%[Item10%]|h|r at 119c each", warns[1].text)
            assert.matches("Sells for more at a vendor: 4000c", warns[1].text)
            warns[1].onYes()
            assert.are.equal(1, #client.posts)
            click(ui.postNext)
            assert.are.equal(1, #warns)
            assert.are.equal(2, #client.posts)
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

        it("asks no vendor question in the Post all queue", function()
            vendor[10] = 200
            selectCloth()
            click(ui.postAll)
            assert.are.equal(0, #warns)
            assert.are.equal(1, #client.posts)
        end)

        it("does not ask in a dry run", function()
            vendor[10] = 200
            selectCloth()
            pick("i10")
            tab:SetDryRun(true)
            click(ui.postNext)
            assert.are.equal(0, #warns)
            assert.are.equal("dry run", ns.SellingPlan.Log:List()[1].decision)
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
            assert.are.equal("Post anyway", window.yesButton.text)
            assert.is_true(window.shown)
            click(window.noButton)
            assert.is_false(window.shown)
            assert.are.equal(0, #client.posts)
            click(ui.postNext)
            click(window.yesButton)
            assert.is_false(window.shown)
            assert.are.equal(1, #client.posts)
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
            assert.are.equal("4c", ui.details.priceInput.text)
            ui.details.priceInput:SetText("25c")
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
            ui.details.priceInput:SetText("")
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
            while ui.postAll.enabled and n < 50 do
                click(ui.postAll)
                n = n + 1
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
            remount({ duration = 48 })
            selectCloth()
            postAllClicks()
            assert.is_true(#client.posts > 0)
            for _, post in ipairs(client.posts) do
                assert.are.equal(48, post.duration)
            end
        end)

        it("follows the max stack size in a manual post", function()
            remount({ stackSize = 5 })
            client.rows[10] = { row(5, 1) }
            pick("i10")
            fire("ITEM_RESULTS", 10)
            ui.details.priceInput:SetText("25c")
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
            ui.details.priceInput:SetText("25c")
            click(ui.postNext)
            warns[1].onYes()
            assert.are.equal(8, client.posts[1].quantity)
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
            assert.are.equal("1s 19c", ui.details.priceInput.text)
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

        it("keeps an item in the list while a dry run runs", function()
            selectCloth()
            tab:SetDryRun(true)
            for _ = 1, 3 do
                click(ui.postNext)
            end
            assert.is_true(has(visibleIds(), "i10"))
            fire("BAG_UPDATE_DELAYED")
            assert.are.equal(1, bagReads)
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
            assert.are.equal("Linen Cloth x7", draw("i10").label.text)
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
