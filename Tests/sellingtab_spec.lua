local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end }
    for _, name in ipairs({ "EventBus", "ItemString", "SellingPlan", "Theme", "Widgets", "List",
        "AuctionTabs", "SellingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

describe("SellingTab", function()
    local ns, bus, client, rules, run, timers, tab, ui, confirms, bagItems

    -- A fake client: it records searches and post calls. Each post call is one protected call.
    local function makeClient()
        local c = {
            ready = true, searches = {}, rows = {}, commodity = {}, posts = {}, confirmed = {},
            needsConfirmation = false, postError = nil, valid = true, available = 1000, refreshed = 0,
            canPost = true,
        }
        c.CanLiveSearch = function()
            return true
        end
        c.CanPost = function()
            return c.canPost
        end
        c.IsReady = function()
            return c.ready
        end
        c.LiveSearch = function(itemID)
            c.searches[#c.searches + 1] = itemID
            return true
        end
        c.LiveRows = function(itemID)
            return c.rows[itemID] or {}
        end
        c.LiveResultEvents = function()
            return "COMMODITY_RESULTS", "ITEM_RESULTS"
        end
        c.ReadyEvent = function()
            return "READY"
        end
        c.PostedEvent = function()
            return "CREATED"
        end
        c.ItemIsCommodity = function(itemID)
            return c.commodity[itemID]
        end
        c.CanReadOwned = function()
            return false
        end
        c.Deposit = function(_, _, _, quantity)
            return quantity * 10
        end
        c.AvailablePostCount = function()
            return c.available
        end
        c.IsSellItemValid = function()
            return c.valid
        end
        c.RefreshOwned = function()
            c.refreshed = c.refreshed + 1
        end
        c.PostItem = function(bag, slot, duration, quantity, bid, buyout)
            if c.postError then
                error(c.postError, 0)
            end
            c.posts[#c.posts + 1] = { kind = "item", bag = bag, slot = slot, duration = duration,
                quantity = quantity, bid = bid, buyout = buyout }
            return c.needsConfirmation
        end
        c.PostCommodity = function(bag, slot, duration, quantity, unitPrice)
            if c.postError then
                error(c.postError, 0)
            end
            c.posts[#c.posts + 1] = { kind = "commodity", bag = bag, slot = slot, duration = duration,
                quantity = quantity, unitPrice = unitPrice }
            return c.needsConfirmation
        end
        c.ConfirmPostItem = function(...)
            c.confirmed[#c.confirmed + 1] = { kind = "item", ... }
        end
        c.ConfirmPostCommodity = function(...)
            c.confirmed[#c.confirmed + 1] = { kind = "commodity", ... }
        end
        return c
    end

    local function makeRules()
        return {
            Walk = function(_, fn)
                fn(1)
                fn(2)
            end,
            EffectiveOperation = function()
                return 7
            end,
            GetOperation = function()
                return { name = "Sell", settings = {
                    minPrice = "10", normalPrice = "100", maxPrice = "200", undercut = 1, duration = 24,
                } }
            end,
            Path = function()
                return "Herbs"
            end,
            ItemsIn = function()
                return { "10", "11", "12" }
            end,
        }
    end

    local function row(price, quantity, own)
        return { unitPrice = price, quantity = quantity, ownerItem = own or false, auctionID = price }
    end

    local function fire(event, ...)
        bus:Emit(event, ...)
    end

    local function click(button)
        button.scripts.OnClick(button)
    end

    local function mount(extra)
        local deps = {
            bus = bus, rules = rules, formulaRun = run, client = client,
            after = function(seconds, fn)
                timers[#timers + 1] = { seconds = seconds, fn = fn }
            end,
            itemInfo = function(id)
                return "Item" .. id, 1
            end,
            readBags = function()
                return bagItems
            end,
            maxStack = function(id)
                return id == 11 and 20 or 1
            end,
            confirm = function(name, text, onAccept)
                confirms[#confirms + 1] = { name = name, text = text, onAccept = onAccept }
            end,
        }
        for k, v in pairs(extra or {}) do
            deps[k] = v
        end
        local core = ns.SellingTab.New(deps)
        core:Mount(CreateFrame("Frame", nil, UIParent), { Enter = function() end, Leave = function() end })
        return core
    end

    -- Scan the bags and answer each search: 10 is a commodity, 11 an item, 12 sells below the minimum.
    local function scanAll()
        client.rows[10] = { row(150, 5) }
        client.rows[11] = { row(120, 1) }
        client.rows[12] = { row(10, 1) }
        assert.is_true(tab:ScanBags())
        fire("COMMODITY_RESULTS", 10)
        fire("ITEM_RESULTS", 11)
        fire("ITEM_RESULTS", 12)
    end

    before_each(function()
        mock.reset()
        _G.ScrollUtil = nil
        local frameMethods = getmetatable(CreateFrame("Frame")).__index
        frameMethods.SetJustifyH = function() end
        ns = loadModules()
        bus = ns.EventBus.New({})
        client = makeClient()
        client.commodity[10] = true
        client.commodity[11] = false
        client.commodity[12] = false
        timers, confirms = {}, {}
        rules = makeRules()
        run = {
            Evaluate = function(_, text)
                return tonumber(text), nil
            end,
        }
        bagItems = {
            { key = "10", itemID = 10, name = "Herb", count = 30, stacks = {
                { bag = 0, slot = 1, count = 20 }, { bag = 0, slot = 2, count = 10 } } },
            { key = "11", itemID = 11, name = "Sword", count = 60, stacks = {
                { bag = 1, slot = 1, count = 20 }, { bag = 1, slot = 2, count = 20 },
                { bag = 1, slot = 3, count = 20 } } },
            { key = "12", itemID = 12, name = "Cloth", count = 5, stacks = { { bag = 2, slot = 1, count = 5 } } },
        }
        ns.SellingPlan.Log:Clear()
        tab = mount()
        ui = tab.ui
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("scan bags", function()
        it("searches one item at a time and decides on each result", function()
            client.rows[10] = { row(150, 5) }
            assert.is_true(tab:ScanBags())
            assert.are.same({ 10 }, client.searches)
            assert.is_false(ui.scan.enabled)
            fire("COMMODITY_RESULTS", 10)
            assert.are.same({ 10, 11 }, client.searches)
            fire("ITEM_RESULTS", 11)
            fire("ITEM_RESULTS", 12)
            assert.is_nil(tab.queue)
            assert.is_true(ui.scan.enabled)
            assert.are.equal(3, #tab.entries)
            assert.are.equal("ready", tab.entries[1].status)
        end)

        it("does not search while the client is not ready and goes on at the ready event", function()
            client.ready = false
            tab:ScanBags()
            assert.are.same({}, client.searches)
            assert.are.equal(5, timers[#timers].seconds)
            client.ready = true
            fire("READY")
            assert.are.same({ 10 }, client.searches)
        end)

        it("logs no response after the timeout and goes on", function()
            tab:ScanBags()
            timers[1].fn()
            assert.are.equal("skip", tab.entries[1].status)
            assert.are.same({ 10, 11 }, client.searches)
            local list = ns.SellingPlan.Log:List()
            assert.are.equal("no response", list[#list].reason)
        end)

        it("skips an item without a price at once and makes no search for it", function()
            run.Evaluate = function(_, text, key)
                if key == "12" then
                    return nil, { kind = "none" }
                end
                return tonumber(text), nil
            end
            client.rows[10] = { row(150, 5) }
            tab:ScanBags()
            fire("COMMODITY_RESULTS", 10)
            fire("ITEM_RESULTS", 11)
            assert.are.same({ 10, 11 }, client.searches)
            assert.are.equal("no data", tab.entries[3].decision.reason)
        end)

        it("skips stale data with the reason", function()
            tab = mount({
                now = function()
                    return 1000000
                end,
                getRecord = function()
                    return { latest = { time = 1000000 - 100 * 3600 }, days = { { scans = 5 } } }
                end,
            })
            tab:ScanBags()
            assert.are.equal("skip", tab.entries[1].status)
            assert.matches("stale price", tab.entries[1].decision.reason)
            assert.are.same({}, client.searches)
        end)
    end)

    describe("the list", function()
        it("shows the decision, the deposit and the duration", function()
            scanAll()
            assert.are.equal("post 30 at 149c each | deposit 300c | 24 h", ns.SellingTab.Describe(tab.entries[1]))
            assert.are.equal("post 3 x 20 at 119c each | deposit 600c | 24 h", ns.SellingTab.Describe(tab.entries[2]))
            assert.are.equal("post 30 at 149c each | deposit 300c | 24 h", ui.list.rows[1].parts.sub.text)
            assert.are.equal("Herb", ui.list.rows[1].parts.name.text)
        end)

        it("shows a skipped item with the reason", function()
            scanAll()
            local entry = tab.entries[3]
            assert.are.equal("skip", entry.status)
            assert.are.equal("skip: below minimum", ui.list.rows[3].parts.sub.text)
            assert.are.equal("skip: below minimum", ns.SellingTab.Describe(entry))
            local list = ns.SellingPlan.Log:List()
            assert.are.equal("skip", list[#list].decision)
            assert.are.equal("below minimum", list[#list].reason)
        end)

        it("shows a question mark when the client gives no deposit", function()
            client.Deposit = function() end
            scanAll()
            assert.matches("deposit %?", ns.SellingTab.Describe(tab.entries[1]))
        end)

        it("splits a decision into units and takes the stacks in order", function()
            local candidate = { stacks = { { bag = 0, slot = 1, count = 45 }, { bag = 0, slot = 2, count = 20 } } }
            local units = ns.SellingTab.BuildUnits(candidate, { quantity = 20, auctions = 3 })
            assert.are.equal(3, #units)
            assert.are.same({ bag = 0, slot = 1, quantity = 20 }, units[1])
            assert.are.same({ bag = 0, slot = 1, quantity = 20 }, units[2])
            assert.are.same({ bag = 0, slot = 2, quantity = 20 }, units[3])
            local partial = ns.SellingTab.BuildUnits({ stacks = { { bag = 0, slot = 1, count = 7 } } },
                { quantity = 20, auctions = 1 })
            assert.are.same({ { bag = 0, slot = 1, quantity = 7 } }, partial)
        end)

        it("computes the age and the scan count of a record", function()
            local stats = ns.SellingTab.DataStats({
                latest = { time = 1000 }, days = { { scans = 2 }, { scans = 3 } }, today = { snaps = { {}, {} } },
            }, 1000 + 7200)
            assert.are.equal(2, stats.ageHours)
            assert.are.equal(7, stats.samples)
            assert.is_nil(ns.SellingTab.DataStats({ days = {} }, 5))
        end)
    end)

    describe("post next", function()
        it("posts a commodity as one listing with the unit price", function()
            scanAll()
            click(ui.postNext)
            assert.are.equal(1, #client.posts)
            local post = client.posts[1]
            assert.are.equal("commodity", post.kind)
            assert.are.same({ 0, 1, 24, 30, 149 },
                { post.bag, post.slot, post.duration, post.quantity, post.unitPrice })
            assert.are.equal("done", tab.entries[1].status)
            assert.are.equal(1, client.refreshed)
            local list = ns.SellingPlan.Log:List()
            assert.are.equal("post", list[#list].decision)
            assert.are.equal(149, list[#list].price)
            assert.are.equal(30, list[#list].quantity)
        end)

        it("posts each stack of an item with one click and labels the button", function()
            scanAll()
            tab.entries[1].status = "done"
            assert.are.equal("Post next", ui.postNext.text)
            click(ui.postNext)
            assert.are.equal("Post next stack (2 of 3)", ui.postNext.text)
            click(ui.postNext)
            assert.are.equal("Post next stack (3 of 3)", ui.postNext.text)
            click(ui.postNext)
            assert.are.equal(3, #client.posts)
            for index, post in ipairs(client.posts) do
                assert.are.equal("item", post.kind)
                assert.are.same({ 1, index, 24, 20, nil, 119 * 20 }, { post.bag, post.slot, post.duration,
                    post.quantity, post.bid, post.buyout })
            end
            assert.are.equal("done", tab.entries[2].status)
            assert.are.equal(1, client.refreshed)
            assert.are.equal("Post next", ui.postNext.text)
        end)

        it("caps the quantity by the available post count", function()
            scanAll()
            client.available = 12
            click(ui.postNext)
            assert.are.equal(12, client.posts[1].quantity)
        end)

        it("asks for a confirm when the server wants one and posts on the accept", function()
            scanAll()
            client.needsConfirmation = true
            click(ui.postNext)
            assert.are.equal(1, #client.posts)
            assert.are.equal(0, #client.confirmed)
            assert.are.equal(1, #confirms)
            assert.matches("Post 30 x Herb at 149c each", confirms[1].text)
            assert.are.equal("Confirm post", ui.postNext.text)
            confirms[1].onAccept()
            assert.are.equal(1, #client.confirmed)
            assert.are.equal("commodity", client.confirmed[1].kind)
            assert.are.same({ 0, 1, 24, 30, 149 }, { unpack(client.confirmed[1]) })
            assert.are.equal("done", tab.entries[1].status)
            assert.is_nil(tab.awaiting)
            assert.are.equal("Post next", ui.postNext.text)
        end)

        it("shows the confirm again on the next click and makes no second post", function()
            scanAll()
            client.needsConfirmation = true
            click(ui.postNext)
            click(ui.postNext)
            assert.are.equal(1, #client.posts)
            assert.are.equal(2, #confirms)
            confirms[2].onAccept()
            assert.are.equal(1, #client.confirmed)
        end)

        it("confirms an item post with the same buyout", function()
            scanAll()
            tab.entries[1].status = "done"
            client.needsConfirmation = true
            click(ui.postNext)
            confirms[1].onAccept()
            assert.are.equal("item", client.confirmed[1].kind)
            assert.are.same({ 1, 1, 24, 20, nil, 119 * 20 }, { client.confirmed[1][1], client.confirmed[1][2],
                client.confirmed[1][3], client.confirmed[1][4], client.confirmed[1][5], client.confirmed[1][6] })
            assert.are.equal(2, tab.entries[2].next)
        end)

        it("works with the real confirm pop-up", function()
            scanAll()
            tab.deps.confirm = ns.Kit.Confirm
            client.needsConfirmation = true
            click(ui.postNext)
            assert.are.equal("FLIPSIDE_CONFIRM_POST", mock.popup.which)
            mock.acceptPopup()
            assert.are.equal(1, #client.confirmed)
        end)

        it("fails the entry and goes on when the post call raises an error", function()
            scanAll()
            client.postError = "no auction house"
            click(ui.postNext)
            assert.are.equal("failed", tab.entries[1].status)
            assert.are.equal("failed: no auction house", ns.SellingTab.Describe(tab.entries[1]))
            assert.are.equal(tab.entries[2], tab:_Current())
            local list = ns.SellingPlan.Log:List()
            assert.are.equal("failed", list[#list].decision)
        end)

        it("fails when the item cannot be posted", function()
            scanAll()
            client.valid = false
            click(ui.postNext)
            assert.are.equal(0, #client.posts)
            assert.are.equal("failed", tab.entries[1].status)
            assert.are.equal("the item cannot be posted", tab.entries[1].note)
        end)

        it("fails when no item is left", function()
            scanAll()
            client.available = 0
            click(ui.postNext)
            assert.are.equal(0, #client.posts)
            assert.are.equal("no item left to post", tab.entries[1].note)
        end)

        it("has nothing to post before a scan", function()
            local ok, text = tab:PostNext()
            assert.is_false(ok)
            assert.are.equal("nothing to post", text)
            assert.is_false(ui.postNext.enabled)
        end)

        it("turns the post button off without the post capability", function()
            scanAll()
            assert.is_true(ui.postNext.enabled)
            client.canPost = false
            tab:_Update()
            assert.is_false(ui.postNext.enabled)
        end)
    end)

    describe("dry run", function()
        it("is off by default and logs only when on", function()
            assert.is_false(tab.dryRun)
            scanAll()
            ui.dryRun.checked = true
            ui.dryRun.scripts.OnClick(ui.dryRun)
            assert.is_true(tab.dryRun)
            click(ui.postNext)
            assert.are.equal(0, #client.posts)
            assert.are.equal(0, #confirms)
            assert.are.equal("done", tab.entries[1].status)
            local list = ns.SellingPlan.Log:List()
            assert.are.equal("dry run", list[#list].decision)
            assert.are.equal(149, list[#list].price)
        end)
    end)

    describe("skip", function()
        it("moves to the next item and logs the skip", function()
            scanAll()
            click(ui.skip)
            assert.are.equal("skipped", tab.entries[1].status)
            assert.are.equal(tab.entries[2], tab:_Current())
            local list = ns.SellingPlan.Log:List()
            assert.are.equal("skipped by user", list[#list].reason)
            assert.are.equal(0, #client.posts)
        end)

        it("drops an open confirm", function()
            scanAll()
            client.needsConfirmation = true
            click(ui.postNext)
            click(ui.skip)
            assert.is_nil(tab.awaiting)
            assert.are.equal("skipped", tab.entries[1].status)
        end)
    end)

    describe("log view", function()
        it("shows the log newest first", function()
            scanAll()
            click(ui.postNext)
            tab:ToggleLog()
            assert.is_true(ui.logList.frame:IsShown())
            assert.is_false(ui.list.frame:IsShown())
            assert.matches("Item10: post 30 at 149c", ui.logList.rows[1].parts.text)
            assert.matches("below minimum", ui.logList.rows[2].parts.text)
        end)
    end)

    describe("protected calls", function()
        it("makes no post call except from a click", function()
            scanAll()
            timers[#timers].fn()
            fire("READY")
            fire("CREATED", 5)
            tab:Skip()
            tab:ToggleLog()
            tab:SetDryRun(false)
            tab:Select()
            tab:Stop()
            assert.are.equal(0, #client.posts)
            assert.are.equal(0, #client.confirmed)
        end)

        it("keeps the post call sites in the post and confirm closures", function()
            local handle = assert(io.open(manifest.path("SellingTab"), "rb"))
            local source = handle:read("*a")
            handle:close()
            local count = 0
            for _ in source:gmatch("client%.Post%u") do
                count = count + 1
            end
            for _ in source:gmatch("client%.ConfirmPost%u") do
                count = count + 1
            end
            assert.are.equal(4, count)
            assert.is_not_nil(source:find('ui.postNext:SetScript("OnClick"', 1, true))
        end)
    end)

    describe("registry", function()
        it("registers the Selling tab for hosts with many tabs", function()
            local spec = ns.AuctionTabs.List()[1]
            assert.are.equal("selling", spec.id)
            assert.are.equal("Selling", spec.label)
        end)

        it("needs rules, formulas, bags, live search and the post capability", function()
            local spec = ns.AuctionTabs.List()[1]
            ns.AuctionClient = client
            local deps = { rules = rules, formulaRun = run, readBags = function() end }
            assert.is_true(spec.available(deps))
            client.canPost = false
            assert.is_false(spec.available(deps))
            client.canPost = true
            assert.is_false(spec.available({ rules = rules, formulaRun = run }))
        end)

        it("is in the Forever TOC after the Buying tab and not in the TBC TOC", function()
            local forever = manifest.files("Flipside.toc")
            assert.is_true(manifest.indexOf(forever, "BuyingTab") < manifest.indexOf(forever, "SellingTab"))
            assert.is_nil(manifest.indexOf(manifest.files("Flipside_TBC.toc"), "SellingTab"))
        end)
    end)

    it("removes its events on unmount", function()
        tab:Unmount()
        assert.is_false(bus:HasSubscribers("COMMODITY_RESULTS"))
        assert.is_false(bus:HasSubscribers("READY"))
        assert.is_false(bus:HasSubscribers("CREATED"))
    end)
end)
