local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end, Flavour = { multisell = true } }
    for _, name in ipairs({ "EventBus", "ItemString", "ScanKey", "BagItems", "SellingPlan", "Theme", "Widgets",
        "MoneyInput", "Window", "List", "Columns", "Tree", "AuctionTabs", "SellingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

-- These specs keep ScrollUtil: the game uses the ScrollBox path.
describe("SellingTab multisell on TBC", function()
    local ns, bus, client, rules, tab, ui, bagItems, bagReads, warns, vendor, opExtra, confirms, autoAccept
    local delays = {}
    local timers = {}

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
        c.MultisellEvent = function() return "MULTI" end
        c.ItemIsCommodity = function(itemID) return c.commodity[itemID] end
        c.CanReadOwned = function() return false end
        c.deposits = {}
        c.Deposit = function(_, _, _, quantity, _, _, _, stacks)
            c.deposits[#c.deposits + 1] = { quantity = quantity, stacks = stacks }
            return quantity * (stacks or 1) * 10
        end
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

    local function entryOf(key)
        for _, entry in ipairs(tab.entries) do
            if entry.key == key then
                return entry
            end
        end
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
                else
                    timers[#timers + 1] = { seconds = seconds, fn = fn }
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
        getmetatable(CreateFrame("Frame")).__index.SetJustifyH = function() end
        mock.qualityColors[1] = { 1, 1, 1, "ff1eff00" }
        ns = loadModules()
        bus = ns.EventBus.New({})
        client = makeClient()
        client.commodity[10] = false
        client.commodity[11] = true
        timers = {}
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


    local function itemPosts()
        local list = {}
        for _, post in ipairs(client.posts) do
            if post.kind == "item" then
                list[#list + 1] = post
            end
        end
        return list
    end

    local function logCount(kind)
        local count = 0
        for _, item in ipairs(ns.SellingPlan.Log:List()) do
            if item.decision == kind then
                count = count + 1
            end
        end
        return count
    end

    -- Select the linen cloth with the count and the bag stacks of the test.
    local function selectLinen(count, stacks)
        bagItems[3].count, bagItems[3].stacks = count, stacks
        tab:RefreshBags()
        selectCloth()
        pick("i10")
    end

    local FULL = { { bag = 1, slot = 1, count = 20 }, { bag = 1, slot = 2, count = 20 },
        { bag = 1, slot = 3, count = 20 } }

    describe("the queue", function()
        it("makes one unit for all full stacks", function()
            selectLinen(60, FULL)
            local entry = entryOf("10")
            assert.are.equal(1, #entry.units)
            assert.are.equal(20, entry.units[1].quantity)
            assert.are.equal(3, entry.units[1].stacks)
        end)

        it("makes a second unit for the remainder", function()
            selectLinen(47, { { bag = 1, slot = 1, count = 20 }, { bag = 1, slot = 2, count = 20 },
                { bag = 1, slot = 3, count = 7 } })
            local entry = entryOf("10")
            assert.are.equal(2, #entry.units)
            assert.are.equal(20, entry.units[1].quantity)
            assert.are.equal(2, entry.units[1].stacks)
            assert.are.equal(7, entry.units[2].quantity)
            assert.are.equal(1, entry.units[2].stacks)
            local stacks = 0
            for _, unit in ipairs(entry.units) do
                stacks = stacks + unit.stacks
            end
            assert.are.equal(3, stacks)
        end)
    end)

    describe("one Post click", function()
        it("calls PostItem once with the stack size, the stack count and the price of one stack", function()
            selectLinen(60, FULL)
            click(ui.postNext)
            local posts = itemPosts()
            assert.are.equal(1, #posts)
            assert.are.equal(20, posts[1].quantity)
            assert.are.equal(3, posts[1].stacks)
            assert.are.equal(119 * 20, posts[1].buyout)
            assert.is_nil(posts[1].bid)
        end)

        it("asks for the deposit of all stacks", function()
            selectLinen(60, FULL)
            local found
            for _, call in ipairs(client.deposits) do
                if call.quantity == 20 and call.stacks == 3 then
                    found = true
                end
            end
            assert.is_true(found)
            assert.are.equal("Deposit: 600c", ui.details.deposit.text)
        end)

        it("shows the stack size and the stack count and keeps the post blocked until the end", function()
            selectLinen(60, FULL)
            assert.are.equal("3 x 20", ui.details.stack.text)
            assert.are.equal(20, ui.details.qty:GetNumber())
            assert.are.equal(3, ui.details.stacks:GetNumber())
            click(ui.postNext)
            assert.is_not_nil(tab.multi)
            assert.is_false(ui.postNext.enabled)
            assert.is_false(ui.postAll.enabled)
            assert.is_false(ui.skip.enabled)
            assert.are.equal("Posting 0 of 3 stacks", tab:ProgressText())
            local ok, why = tab:PostNext()
            assert.is_false(ok)
            assert.are.equal("posting", why)
            assert.is_false((tab:PostAll()))
            assert.is_false((tab:Skip()))
            assert.are.equal(1, #itemPosts())
        end)

        it("counts the updates and marks the entry done at the total", function()
            selectLinen(60, FULL)
            click(ui.postNext)
            fire("MULTI", "start", 0, 3)
            fire("MULTI", "update", 1, 3)
            assert.are.equal("Posting 1 of 3 stacks", tab:ProgressText())
            assert.are.equal("ready", entryOf("10").status)
            fire("MULTI", "update", 3, 3)
            assert.is_nil(tab.multi)
            assert.are.equal("done", entryOf("10").status)
            assert.are.equal(3, entryOf("10").posted)
            assert.are.equal(3, logCount("post"))
        end)

        it("unblocks Post after the end", function()
            selectLinen(60, FULL)
            click(ui.postNext)
            fire("MULTI", "update", 3, 3)
            assert.is_nil(tab.multi)
            assert.is_nil(tab.awaiting)
        end)

        it("posts the remainder with the next click as one smaller stack", function()
            selectLinen(47, { { bag = 1, slot = 1, count = 20 }, { bag = 1, slot = 2, count = 20 },
                { bag = 1, slot = 3, count = 7 } })
            click(ui.postNext)
            fire("MULTI", "update", 2, 2)
            assert.are.equal("ready", entryOf("10").status)
            click(ui.postNext)
            local posts = itemPosts()
            assert.are.equal(2, #posts)
            assert.are.equal(2, posts[1].stacks)
            assert.are.equal(7, posts[2].quantity)
            assert.is_nil(posts[2].stacks)
            assert.are.equal("done", entryOf("10").status)
            assert.are.equal(3, entryOf("10").posted)
        end)

        it("makes the Post all queue post the same units one click each", function()
            selectLinen(47, { { bag = 1, slot = 1, count = 20 }, { bag = 1, slot = 2, count = 20 },
                { bag = 1, slot = 3, count = 7 } })
            click(ui.postAll)
            assert.are.equal(1, #itemPosts())
            assert.is_not_nil(tab.multi)
            fire("MULTI", "update", 2, 2)
            click(ui.postAll)
            assert.are.equal(2, #itemPosts())
        end)
    end)

    describe("a failure", function()
        it("marks the entry failed with the created count for AUCTION_MULTISELL_FAILURE", function()
            selectLinen(60, FULL)
            local entry = entryOf("10")
            click(ui.postNext)
            fire("MULTI", "update", 2, 3)
            fire("MULTI", "failure", 2, 3, "the Auction House stopped the multi-stack post")
            assert.are.equal("failed", entry.status)
            assert.is_truthy(entry.note:find("2 of 3 stacks made", 1, true))
            assert.is_nil(tab.multi)
            assert.are.equal(2, entry.posted)
            assert.are.equal(2, logCount("post"))
            assert.are.equal(1, logCount("failed"))
        end)

        it("marks the entry failed with the text of an ERR_AUCTION_* UI error", function()
            selectLinen(60, FULL)
            local entry = entryOf("10")
            click(ui.postNext)
            fire("MULTI", "failure", 0, 3, "Auction House database error.")
            assert.are.equal("failed", entry.status)
            assert.is_truthy(entry.note:find("Auction House database error.", 1, true))
            assert.is_truthy(entry.note:find("0 of 3 stacks made", 1, true))
            assert.are.equal(0, logCount("post"))
        end)

        it("uses an event that comes while the PostItem call runs", function()
            selectLinen(60, FULL)
            local post = client.PostItem
            client.PostItem = function(...)
                local result = post(...)
                fire("MULTI", "update", 3, 3)
                return result
            end
            click(ui.postNext)
            assert.is_nil(tab.multi)
            assert.are.equal("done", entryOf("10").status)
        end)

        it("ends a post that gets no answer after the timeout", function()
            selectLinen(60, FULL)
            local entry = entryOf("10")
            click(ui.postNext)
            fire("MULTI", "update", 1, 3)
            local timer = timers[#timers]
            assert.is_true(timer.seconds > 15)
            timer.fn()
            assert.are.equal("failed", entry.status)
            assert.is_truthy(entry.note:find("no answer", 1, true))
            assert.is_truthy(entry.note:find("1 of 3 stacks made", 1, true))
        end)

        it("ignores a late timer after the post ended", function()
            selectLinen(60, FULL)
            click(ui.postNext)
            fire("MULTI", "update", 3, 3)
            timers[#timers].fn()
            assert.are.equal("done", entryOf("10").status)
        end)

        it("marks the entry failed when the call itself raises an error", function()
            selectLinen(60, FULL)
            local entry = entryOf("10")
            client.PostItem = function() error("the item did not go into the sale slot") end
            click(ui.postNext)
            assert.is_nil(tab.multi)
            assert.are.equal("failed", entry.status)
        end)
    end)

    describe("the stack controls", function()
        it("post the stack count the user types", function()
            selectLinen(60, FULL)
            tab:SetManualStacks(2)
            assert.are.equal("2 x 20", ui.details.stack.text)
            click(ui.postNext)
            assert.are.equal(2, itemPosts()[1].stacks)
        end)

        it("limit the stack count to what the bags hold", function()
            selectLinen(60, FULL)
            local ok, value = tab:SetManualStacks(9)
            assert.is_true(ok)
            assert.are.equal(3, value)
            value = select(2, tab:SetManualStacks(0))
            assert.are.equal(1, value)
        end)

        it("post a typed stack size with the same stack count", function()
            selectLinen(60, FULL)
            tab:SetManualQuantity(10)
            click(ui.postNext)
            local post = itemPosts()[1]
            assert.are.equal(10, post.quantity)
            assert.are.equal(3, post.stacks)
            assert.are.equal(119 * 10, post.buyout)
        end)

        it("limit the stack size to the item maximum stack", function()
            selectLinen(60, FULL)
            local ok, value = tab:SetManualQuantity(45)
            assert.is_true(ok)
            assert.are.equal(20, value)
        end)

        it("do nothing while a multisell runs", function()
            selectLinen(60, FULL)
            click(ui.postNext)
            assert.is_false((tab:SetManualStacks(1)))
            assert.is_false((tab:SetManualQuantity(5)))
        end)
    end)

    describe("a refreshed bag list", function()
        it("waits until the multisell ends", function()
            selectLinen(60, FULL)
            click(ui.postNext)
            local ok = tab:RefreshBags()
            assert.is_false(ok)
            assert.is_not_nil(tab.multi)
            assert.is_false(tab:SyncBags())
        end)

        it("keeps the remainder unit when the bags change after the first post", function()
            selectLinen(47, { { bag = 1, slot = 1, count = 20 }, { bag = 1, slot = 2, count = 20 },
                { bag = 1, slot = 3, count = 7 } })
            click(ui.postNext)
            bagItems[3].count = 7
            bagItems[3].stacks = { { bag = 1, slot = 3, count = 7 } }
            fire("MULTI", "update", 2, 2)
            tab:SyncBags()
            local entry = entryOf("10")
            assert.are.equal("ready", entry.status)
            assert.are.equal(1, #entry.units - entry.next + 1)
            assert.are.equal(7, entry.units[entry.next].quantity)
            click(ui.postNext)
            assert.are.equal(7, itemPosts()[2].quantity)
        end)
    end)
end)