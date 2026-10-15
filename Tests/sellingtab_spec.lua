local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end }
    for _, name in ipairs({ "EventBus", "ItemString", "ScanKey", "BagItems", "SellingPlan", "Theme", "Widgets",
        "MoneyInput", "List", "Columns", "Tree", "AuctionTabs", "SellingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

describe("SellingTab", function()
    local ns, bus, client, rules, run, timers, tab, ui, confirms, bagItems, bagReads, groups, itemGroup, now

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

    -- Groups: 2 Cloth (with 3 Bolts and 5 Empty), 6 Misc. Cloth and Bolts have a selling operation; Misc has none.
    local function makeRules()
        return {
            Children = function(_, id)
                return groups[id].children
            end,
            Name = function(_, id)
                return groups[id].name
            end,
            GroupOf = function(_, key)
                return itemGroup[key] or 1
            end,
            Walk = function(_, fn)
                for _, id in ipairs({ 1, 2, 3, 5, 6 }) do
                    fn(id)
                end
            end,
            EffectiveOperation = function(_, id)
                if id == 2 or id == 3 or id == 5 then
                    return 7
                end
            end,
            GetOperation = function()
                return { name = "Sell", settings = {
                    minPrice = "10", normalPrice = "100", maxPrice = "200", undercut = 1, duration = 24,
                    vendorSkip = false,
                } }
            end,
            Path = function(_, id)
                return groups[id].name
            end,
            ItemsIn = function(_, id)
                local list = {}
                for key, group in pairs(itemGroup) do
                    if group == id then
                        list[#list + 1] = key
                    end
                end
                table.sort(list)
                return list
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
                bagReads = bagReads + 1
                return bagItems
            end,
            maxStack = function(id)
                return id == 10 and 20 or 1
            end,
            vendorPrice = function(id)
                return id == 10 and 5 or nil
            end,
            confirm = function(name, text, onAccept)
                confirms[#confirms + 1] = { name = name, text = text, onAccept = onAccept }
            end,
            syncInterval = 0,
            time = function()
                return now
            end,
        }
        for k, v in pairs(extra or {}) do
            deps[k] = v
        end
        local core = ns.SellingTab.New(deps)
        core:Mount(CreateFrame("Frame", nil, UIParent), { Enter = function() end, Leave = function() end })
        core:Select()
        return core
    end

    local function entryOf(key)
        for _, entry in ipairs(tab.entries) do
            if entry.key == key then
                return entry
            end
        end
    end

    -- Select a tree row by id, as a click on the row does.
    local function pick(id)
        ui.tree:Select(id)
    end

    local function idsOf(nodes)
        local ids = {}
        for _, node in ipairs(nodes) do
            ids[#ids + 1] = node.id
        end
        return ids
    end

    -- Select the group Cloth and answer both searches: 10 is an item with 3 stacks, 11 a commodity.
    local function selectCloth()
        client.rows[10] = { row(120, 1) }
        client.rows[11] = { row(150, 5) }
        pick("g2")
        fire("ITEM_RESULTS", 10)
        fire("COMMODITY_RESULTS", 11)
    end

    before_each(function()
        mock.reset()
        _G.ScrollUtil = nil
        local frameMethods = getmetatable(CreateFrame("Frame")).__index
        frameMethods.SetJustifyH = function() end
        ns = loadModules()
        bus = ns.EventBus.New({})
        client = makeClient()
        client.commodity[10] = false
        client.commodity[11] = true
        timers, confirms, bagReads, now = {}, {}, 0, 0
        groups = {
            [1] = { name = "Base", children = { 2, 6 } },
            [2] = { name = "Cloth", children = { 3, 5 } },
            [3] = { name = "Bolts", children = {} },
            [5] = { name = "Empty", children = {} },
            [6] = { name = "Misc", children = {} },
        }
        itemGroup = { ["10"] = 2, ["11"] = 3, ["13"] = 6 }
        rules = makeRules()
        run = {
            Evaluate = function(_, text)
                return tonumber(text), nil
            end,
        }
        bagItems = {
            { key = "11", itemID = 11, name = "Bolt of Linen", count = 12, stacks = {
                { bag = 0, slot = 4, count = 12 } } },
            { key = "13", itemID = 13, name = "Widget", count = 2, stacks = { { bag = 2, slot = 1, count = 2 } } },
            { key = "12", itemID = 12, name = "Copper Ore", count = 8, stacks = { { bag = 2, slot = 2, count = 8 } } },
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

    describe("the tree", function()
        it("has the top-level groups as the roots and ends with the no-group node, with no Base node", function()
            local roots = tab.nodes
            assert.are.same({ "g2", "g6", "none" }, idsOf(roots))
            assert.are.equal("[Cloth]", roots[1].text)
            assert.are.same({ "i10", "g3" }, idsOf(roots[1].children))
            assert.are.same({ "i11" }, idsOf(roots[1].children[2].children))
            assert.are.equal("[No group]", roots[3].text)
            assert.are.same({ "i12" }, idsOf(roots[3].children))
        end)

        it("shows many top-level groups", function()
            groups[1].children = { 2, 6, 7 }
            groups[7] = { name = "Herbs", children = {} }
            itemGroup["12"] = 7
            tab:RefreshBags()
            assert.are.same({ "g2", "g6", "g7" }, idsOf(tab.nodes))
        end)

        it("hides a group with no bag item", function()
            for _, node in ipairs(tab.nodes[1].children) do
                assert.are_not.equal("g5", node.id)
            end
            groups[2].children = { 5 }
            itemGroup = { ["13"] = 6 }
            tab:RefreshBags()
            assert.are.same({ "g6", "none" }, idsOf(tab.nodes))
        end)

        it("has no no-group node when every item is in a group", function()
            itemGroup["12"] = 6
            tab:RefreshBags()
            assert.are.same({ "g2", "g6" }, idsOf(tab.nodes))
        end)

        it("shows no node when the bags hold no item", function()
            bagItems = {}
            tab:RefreshBags()
            assert.are.same({}, tab.nodes)
        end)

        it("hides bound items", function()
            local function link(id)
                return "|cff1eff00|Hitem:" .. id .. "::::::::::::|h[x]|h|r"
            end
            local bags = {
                [0] = {
                    { hyperlink = link(10), itemID = 10, stackCount = 20, itemName = "Linen Cloth" },
                    { hyperlink = link(12), itemID = 12, stackCount = 1, itemName = "Soulbound", isBound = true },
                },
            }
            local resolver = ns.ScanKey.New({ clientIsCommodity = function() return nil end })
            tab.deps.readBags = function()
                return (ns.BagItems.Read({
                    numSlots = function(bag)
                        return bags[bag] and #bags[bag] or 0
                    end,
                    itemInfo = function(bag, slot)
                        return bags[bag][slot]
                    end,
                }, resolver, { bagIDs = { 0 }, stacks = true }))
            end
            itemGroup = {}
            tab:RefreshBags()
            assert.are.equal(1, #tab.entries)
            assert.are.equal("Linen Cloth", tab.entries[1].item.name)
            assert.are.same({ "none" }, idsOf(tab.nodes))
            assert.are.same({ "i10" }, idsOf(tab.nodes[1].children))
        end)

        it("shows the rows of the expanded groups with the name, the count and the columns", function()
            local rows = ui.tree.list.rows
            assert.are.equal("[Cloth]", rows[1].label.text)
            assert.are.equal("Linen Cloth x60", rows[2].label.text)
            local cells = rows[2].sellParts.cells
            assert.are.equal("~100c", cells.price.text)
            assert.are.equal("Sell", cells.operation.text)
            assert.are.equal("-", cells.lowest.text)
            assert.are.equal("-", cells.net.text)
            assert.are.equal("not searched yet", cells.info.text)
            assert.are.equal("[Bolts]", rows[3].label.text)
            assert.are.equal("Bolt of Linen x12", rows[4].label.text)
            assert.are.equal("[Misc]", rows[5].label.text)
            assert.are.equal("no operation", rows[6].sellParts.cells.info.text)
            assert.are.equal("-", rows[6].sellParts.cells.operation.text)
            assert.are.equal("[No group]", rows[7].label.text)
            assert.are.equal("Copper Ore x8", rows[8].label.text)
        end)

        it("has the header columns Item, Your price, Operation, Lowest on AH, Net and Info", function()
            local titles = {}
            for _, column in ipairs(ns.SellingTab.COLUMNS) do
                titles[#titles + 1] = ui.headers.labels[column.key].text
            end
            assert.are.same({ "Item", "Your price", "Operation", "Lowest on AH", "Net", "Info" }, titles)
        end)

        it("collapses and expands a group", function()
            ui.tree:SetCollapsed("g2", true)
            assert.are.equal("[Misc]", ui.tree.list.rows[2].label.text)
            ui.tree:SetCollapsed("g2", false)
            assert.are.equal("Linen Cloth x60", ui.tree.list.rows[2].label.text)
        end)

        it("greys the expected price until the live result and shows the columns after it", function()
            local cells = ui.tree.list.rows[2].sellParts.cells
            assert.are.same({ 0.5, 0.5, 0.5 }, { cells.price.color[1], cells.price.color[2], cells.price.color[3] })
            selectCloth()
            cells = ui.tree.list.rows[2].sellParts.cells
            assert.are.equal("119c", cells.price.text)
            assert.are.equal("120c", cells.lowest.text)
            assert.are.equal("6183c", cells.net.text)
            assert.are.equal("1c under lowest", cells.info.text)
            assert.are.same({ 1, 1, 1 }, { cells.price.color[1], cells.price.color[2], cells.price.color[3] })
            local bolts = ui.tree.list.rows[4].sellParts.cells
            assert.are.equal("149c", bolts.price.text)
            assert.are.equal("150c", bolts.lowest.text)
            assert.are.equal("1579c", bolts.net.text)
        end)

        it("has no Refresh bags, Log or Dry run control", function()
            assert.is_nil(ui.refresh)
            assert.is_nil(ui.logButton)
            assert.is_nil(ui.logList)
            assert.is_nil(ui.dryRun)
            assert.is_nil(tab.ToggleLog)
            assert.is_nil(tab.SetDryRun)
        end)

        it("reads the bags when the tab opens and again on each tab select", function()
            assert.are.equal(1, bagReads)
            tab:Select()
            assert.are.equal(2, bagReads)
        end)
    end)

    describe("profit and the details pane", function()
        local function color(label)
            return { label.color[1], label.color[2], label.color[3] }
        end

        it("shows the net of each row: price x quantity - cut - deposit", function()
            selectCloth()
            local rows = ui.tree.list.rows
            -- 119c x 60 = 7140c; cut 5% = 357c; deposit 3 x 200c = 600c.
            assert.are.equal("6183c", rows[2].sellParts.cells.net.text)
            -- 149c x 12 = 1788c; cut 89c; deposit 120c.
            assert.are.equal("1579c", rows[4].sellParts.cells.net.text)
        end)

        it("shows the details of the next post, with no lowest and no vs vendor line", function()
            selectCloth()
            local d = ui.details
            assert.are.equal("Linen Cloth", d.name.text)
            assert.are.equal("Operation: Sell", d.operation.text)
            assert.are.equal("Buyout 2380c per auction", d.price.text)
            assert.are.equal("3 x 20", d.stack.text)
            assert.are.equal("Deposit: 600c", d.deposit.text)
            assert.are.equal("Net: " .. ns.SellingTab.ARROW_UP .. " 6183c", d.net.text)
            assert.is_nil(d.lowest)
            assert.is_nil(d.vs)
            assert.is_nil(d.lowestHit)
        end)

        it("counts only the auctions that are left", function()
            selectCloth()
            click(ui.postNext)
            assert.are.equal("Net: " .. ns.SellingTab.ARROW_UP .. " 4122c", ui.details.net.text)
            assert.are.equal("2 x 20", ui.details.stack.text)
            assert.are.equal("4122c", ui.tree.list.rows[2].sellParts.cells.net.text)
        end)

        it("moves the details to the next item when one is done", function()
            selectCloth()
            for _ = 1, 3 do
                click(ui.postNext)
            end
            assert.are.equal("Bolt of Linen", ui.details.name.text)
            assert.are.equal("Buyout 1788c per auction", ui.details.price.text)
            assert.are.equal("1 x 12", ui.details.stack.text)
        end)

        it("shows a negative net in red, in the row and the pane", function()
            client.Deposit = function()
                return 100000
            end
            selectCloth()
            local cells = ui.tree.list.rows[2].sellParts.cells
            assert.is_true(cells.net.text:sub(1, 1) == "-")
            assert.are.same({ 1, 0.3, 0.3 }, color(cells.net))
            assert.are.same({ 1, 0.3, 0.3 }, color(ui.details.net))
        end)

        it("shows no profit for a skipped or waiting row, and clears the pane", function()
            assert.are.equal("-", ui.tree.list.rows[2].sellParts.cells.net.text)
            assert.are.equal("Pick a group or an item", ui.details.name.text)
            client.rows[10] = { row(5, 1) }
            pick("i10")
            fire("ITEM_RESULTS", 10)
            assert.are.equal("-", ui.tree.list.rows[2].sellParts.cells.net.text)
            -- One selected item that the rule skips shows in the pane; Post asks first.
            assert.are.equal("Linen Cloth", ui.details.name.text)
            assert.matches("The rule skips this item: below minimum", ui.details.warn.text)
            assert.matches("^Net:", ui.details.net.text)
            pick("g2")
            assert.are.equal("Nothing to post", ui.details.name.text)
        end)

        it("gives the vendor price with the client call when the dependency is not set", function()
            local seen, savedItem = nil, _G.C_Item
            local fresh = ns.SellingTab.New({ bus = bus, rules = rules, formulaRun = run, client = client,
                after = function() end })
            _G.C_Item = { GetItemInfo = function(id)
                seen = id
                return "n", "l", 1, 1, 1, "t", "s", 1, "e", 1, 77
            end }
            assert.are.equal(77, fresh.deps.vendorPrice(10))
            assert.are.equal(10, seen)
            _G.C_Item = { GetItemInfo = function()
                return "n", "l", 1, 1, 1, "t", "s", 1, "e", 1, 0
            end }
            assert.is_nil(fresh.deps.vendorPrice(10))
            _G.C_Item = savedItem
        end)
    end)

    describe("info texts", function()
        local function entry(fields)
            fields.candidate = fields.candidate or { settings = {} }
            return fields
        end

        it("says why in short words", function()
            local function info(status, decision, candidate)
                return ns.SellingTab.InfoText(entry({ status = status, decision = decision, candidate = candidate }))
            end
            local post = function(reason, extra)
                local d = { action = "post", reason = reason, price = 99, competitor = 100 }
                for k, v in pairs(extra or {}) do
                    d[k] = v
                end
                return d
            end
            assert.are.equal("1c under lowest", info("ready", post("undercut")))
            assert.are.equal("no competitor, normal price", info("ready", post("normal price", { competitor = nil })))
            assert.are.equal("capped at max price", info("ready", post("above max, at max")))
            assert.are.equal("raised to min price", info("ready", post("below min, at min")))
            assert.are.equal("below min price, skipped",
                info("skip", { action = "skip", reason = "below minimum" }))
            assert.are.equal("no competitor, no market value",
                info("skip", { action = "skip", reason = "no price: no competitor and no market value" }))
            assert.are.equal("you are already lowest", info("skip", { action = "skip", reason = "already lowest" }))
            assert.are.equal("no operation", info("noop"))
            assert.are.equal("searching", info("searching"))
            assert.are.equal("posted", info("done"))
            assert.are.equal("no data for min price", info("waiting", nil, { reason = "no data for min price" }))
        end)

        it("names the vendor price when the Default floor skips or raises", function()
            ns.OperationSchema = { VENDOR_FLOOR = "first(vendorsell, 1)" }
            local candidate = { settings = { minPrice = "first(vendorsell, 1)" } }
            local skip = entry({ status = "skip", candidate = candidate,
                decision = { action = "skip", reason = "below minimum" } })
            assert.are.equal("below vendor price, skipped", ns.SellingTab.InfoText(skip))
            local raise = entry({ status = "ready", candidate = candidate,
                decision = { action = "post", reason = "below min, at min", price = 5 } })
            assert.are.equal("raised to vendor price", ns.SellingTab.InfoText(raise))
        end)
    end)
    describe("selection", function()
        it("selects a group and its subgroups", function()
            pick("g2")
            local keys = {}
            for _, entry in ipairs(tab.selection) do
                keys[#keys + 1] = entry.key
            end
            assert.are.same({ "10", "11" }, keys)
        end)

        it("selects only the subgroup, or only one item", function()
            pick("g3")
            assert.are.equal(1, #tab.selection)
            assert.are.equal("11", tab.selection[1].key)
            pick("i10")
            assert.are.equal(1, #tab.selection)
            assert.are.equal("10", tab.selection[1].key)
        end)

        it("selects through a click on the row", function()
            local rowFrame = ui.tree.list.rows[1]
            rowFrame.scripts.OnClick(rowFrame, "LeftButton")
            assert.are.equal(2, #tab.selection)
        end)

        it("selects the items of no group through the no-group node", function()
            pick("none")
            assert.are.equal(1, #tab.selection)
            assert.are.equal("12", tab.selection[1].key)
            pick("g6")
            assert.are.equal(1, #tab.selection)
            assert.are.equal("13", tab.selection[1].key)
        end)
        it("searches the items of the selection one at a time and decides on each result", function()
            client.rows[10] = { row(120, 1) }
            client.rows[11] = { row(150, 5) }
            pick("g2")
            assert.are.same({ 10 }, client.searches)
            assert.are.equal("searching", tab.selection[1].status)
            fire("ITEM_RESULTS", 10)
            assert.are.same({ 10, 11 }, client.searches)
            fire("COMMODITY_RESULTS", 11)
            assert.is_nil(tab.queue)
            assert.are.equal("ready", entryOf("10").status)
            assert.are.equal("ready", entryOf("11").status)
        end)

        it("searches only the items it has no result for", function()
            selectCloth()
            pick("g3")
            pick("g2")
            assert.are.same({ 10, 11 }, client.searches)
        end)

        it("makes no search for items without an operation", function()
            pick("i12")
            pick("g6")
            assert.are.same({}, client.searches)
            assert.are.equal("noop", entryOf("12").status)
            assert.are.equal("no operation", ns.SellingTab.Describe(entryOf("13")))
        end)

        it("does not search while the client is not ready and goes on at the ready event", function()
            client.ready = false
            pick("g2")
            assert.are.same({}, client.searches)
            assert.are.equal(5, timers[#timers].seconds)
            client.ready = true
            fire("READY")
            assert.are.same({ 10 }, client.searches)
        end)

        it("logs no response after the timeout and goes on", function()
            pick("g2")
            timers[1].fn()
            assert.are.equal("skip", entryOf("10").status)
            assert.are.same({ 10, 11 }, client.searches)
            local list = ns.SellingPlan.Log:List()
            assert.are.equal("no response", list[#list].reason)
        end)

        it("shows a skip reason and logs it", function()
            client.rows[10] = { row(10, 1) }
            pick("i10")
            fire("ITEM_RESULTS", 10)
            assert.are.equal("skip: below minimum", ns.SellingTab.Describe(entryOf("10")))
            local list = ns.SellingPlan.Log:List()
            assert.are.equal("below minimum", list[#list].reason)
        end)

        it("skips stale data with the reason and makes no search", function()
            tab = mount({
                now = function()
                    return 1000000
                end,
                getRecord = function()
                    return { latest = { time = 1000000 - 100 * 3600 }, days = { { scans = 5 } } }
                end,
            })
            ui = tab.ui
            ui.tree:Select("i10")
            assert.matches("stale price", entryOf("10").decision.reason)
            assert.are.same({}, client.searches)
        end)
    end)

    describe("units and data", function()
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

    describe("the post queue of a group", function()
        it("posts one auction for each click and counts them in the button", function()
            selectCloth()
            assert.are.equal("Posting 1 of 4", ui.progress.text)
            click(ui.postNext)
            assert.are.equal("Posting 2 of 4", ui.progress.text)
            click(ui.postNext)
            click(ui.postNext)
            assert.are.equal("Posting 4 of 4", ui.progress.text)
            assert.are.equal(3, #client.posts)
            click(ui.postNext)
            assert.are.equal(4, #client.posts)
            for index = 1, 3 do
                local post = client.posts[index]
                assert.are.equal("item", post.kind)
                assert.are.same({ 1, index, 24, 20, nil, 119 * 20 },
                    { post.bag, post.slot, post.duration, post.quantity, post.bid, post.buyout })
            end
            local last = client.posts[4]
            assert.are.equal("commodity", last.kind)
            assert.are.same({ 0, 4, 24, 12, 149 },
                { last.bag, last.slot, last.duration, last.quantity, last.unitPrice })
        end)

        it("says all posted at the end and reads the bags again", function()
            selectCloth()
            for _ = 1, 4 do
                click(ui.postNext)
            end
            assert.are.equal("all posted", ui.message.text)
            assert.are.equal(2, bagReads)
            assert.are.equal("Post", ui.postNext.text)
            assert.is_false(ui.postNext.enabled)
            assert.are.equal(2, client.refreshed)
            assert.are.equal(0, #tab.selection)
            local list = ns.SellingPlan.Log:List()
            assert.are.equal("post", list[#list].decision)
        end)

        it("has no deposit, queue net or vendor text next to the buttons", function()
            selectCloth()
            assert.is_nil(ui.deposit)
            assert.is_nil(ui.net)
            assert.is_nil(ui.vs)
        end)

        it("puts Post, Post all and Skip above the list", function()
            local function y(frame)
                return frame.points[1][5]
            end
            assert.are.equal("TOPLEFT", ui.postNext.points[1][1])
            assert.is_true(y(ui.postNext) > y(ui.details.frame))
            assert.is_true(y(ui.details.frame) > y(ui.tree.frame))
            assert.are.equal(ui.postNext, ui.postAll.points[1][2])
            assert.are.equal(ui.postAll, ui.skip.points[1][2])
            -- The list reaches the bottom of the panel: no bar below it.
            assert.are.equal(0, ui.tree.frame.points[2][5])
        end)

        it("posts only the selected item", function()
            selectCloth()
            pick("i10")
            assert.are.equal("Posting 1 of 3", ui.progress.text)
            click(ui.postNext)
            click(ui.postNext)
            click(ui.postNext)
            assert.are.equal(3, #client.posts)
            for _, post in ipairs(client.posts) do
                assert.are.equal("item", post.kind)
            end
        end)

        it("posts the subgroup only", function()
            selectCloth()
            pick("g3")
            click(ui.postNext)
            assert.are.equal("commodity", client.posts[1].kind)
            assert.are.equal("all posted", ui.message.text)
        end)

        it("caps the quantity by the available post count", function()
            selectCloth()
            client.available = 12
            click(ui.postNext)
            assert.are.equal(12, client.posts[1].quantity)
        end)

        it("never posts an item without an operation", function()
            pick("i12")
            assert.is_false(ui.postNext.enabled)
            local ok, text = tab:PostNext()
            assert.is_false(ok)
            assert.are.equal("nothing to post", text)
            pick("g6")
            tab:PostNext()
            assert.are.equal(0, #client.posts)
            assert.are.equal("Post", ui.postNext.text)
        end)

        it("posts the items with an operation of a mixed selection and not the others", function()
            itemGroup["12"] = 3
            tab:RefreshBags()
            ui = tab.ui
            client.rows[12] = { row(150, 5) }
            selectCloth()
            tab.deps.client.commodity[12] = true
            assert.are.equal("noop", entryOf("13").status)
            for _ = 1, 4 do
                click(ui.postNext)
            end
            for _, post in ipairs(client.posts) do
                assert.are_not.equal(2, post.bag)
            end
        end)

        it("has nothing to post before a selection", function()
            local ok, text = tab:PostNext()
            assert.is_false(ok)
            assert.are.equal("nothing to post", text)
            assert.is_false(ui.postNext.enabled)
        end)

        it("turns the post button off without the post capability", function()
            selectCloth()
            assert.is_true(ui.postNext.enabled)
            client.canPost = false
            tab:_Update()
            assert.is_false(ui.postNext.enabled)
        end)
    end)

    describe("confirm and failure", function()
        it("asks for a confirm when the server wants one and posts on the accept", function()
            selectCloth()
            pick("g3")
            local bolt = entryOf("11")
            client.needsConfirmation = true
            click(ui.postNext)
            assert.are.equal(1, #client.posts)
            assert.are.equal(0, #client.confirmed)
            assert.are.equal(1, #confirms)
            assert.matches("Post 12 x Bolt of Linen at 149c each", confirms[1].text)
            assert.are.equal("Confirm post", ui.postNext.text)
            assert.are.equal("Posting 1 of 1", ui.progress.text)
            confirms[1].onAccept()
            assert.are.equal("commodity", client.confirmed[1].kind)
            assert.are.same({ 0, 4, 24, 12, 149 }, { unpack(client.confirmed[1]) })
            assert.are.equal("done", bolt.status)
            assert.is_nil(tab.awaiting)
        end)

        it("shows the confirm again on the next click and makes no second post", function()
            selectCloth()
            client.needsConfirmation = true
            click(ui.postNext)
            click(ui.postNext)
            assert.are.equal(1, #client.posts)
            assert.are.equal(2, #confirms)
            confirms[2].onAccept()
            assert.are.equal(1, #client.confirmed)
            assert.are.equal("item", client.confirmed[1].kind)
            assert.are.same({ 1, 1, 24, 20, nil, 119 * 20 }, { client.confirmed[1][1], client.confirmed[1][2],
                client.confirmed[1][3], client.confirmed[1][4], client.confirmed[1][5], client.confirmed[1][6] })
        end)

        it("does not change the selection while a confirm is open", function()
            selectCloth()
            client.needsConfirmation = true
            click(ui.postNext)
            pick("g6")
            assert.are.equal("g2", ui.tree.selected)
            assert.are.equal(2, #tab.selection)
        end)

        it("works with the real confirm pop-up", function()
            selectCloth()
            tab.deps.confirm = ns.Kit.Confirm
            client.needsConfirmation = true
            click(ui.postNext)
            assert.are.equal("FLIPSIDE_CONFIRM_POST", mock.popup.which)
            mock.acceptPopup()
            assert.are.equal(1, #client.confirmed)
        end)

        it("fails the entry and goes on when the post call raises an error", function()
            selectCloth()
            client.postError = "no auction house"
            click(ui.postNext)
            assert.are.equal("failed", entryOf("10").status)
            assert.are.equal("failed: no auction house", ns.SellingTab.Describe(entryOf("10")))
            assert.are.equal(entryOf("11"), tab:_Current())
            assert.are.equal("Posting 1 of 1", ui.progress.text)
            local list = ns.SellingPlan.Log:List()
            assert.are.equal("failed", list[#list].decision)
        end)

        it("fails when the item cannot be posted", function()
            selectCloth()
            client.valid = false
            click(ui.postNext)
            assert.are.equal(0, #client.posts)
            assert.are.equal("the item cannot be posted", entryOf("10").note)
        end)

        it("fails when no item is left", function()
            selectCloth()
            client.available = 0
            click(ui.postNext)
            assert.are.equal("no item left to post", entryOf("10").note)
        end)
    end)

    describe("skip", function()
        it("moves to the next auction and logs the skip", function()
            selectCloth()
            click(ui.skip)
            assert.are.equal(0, #client.posts)
            assert.are.equal("Posting 2 of 4", ui.progress.text)
            assert.are.equal(2, entryOf("10").next)
            local list = ns.SellingPlan.Log:List()
            assert.are.equal("skipped by user", list[#list].reason)
        end)

        it("ends the queue when every auction is skipped", function()
            selectCloth()
            local linen = entryOf("10")
            for _ = 1, 4 do
                click(ui.skip)
            end
            assert.are.equal("nothing left to post", ui.message.text)
            assert.are.equal("skipped", linen.status)
            assert.are.equal(0, #client.posts)
            assert.are.equal(2, bagReads)
        end)

        it("drops an open confirm", function()
            selectCloth()
            client.needsConfirmation = true
            click(ui.postNext)
            click(ui.skip)
            assert.is_nil(tab.awaiting)
            assert.are.equal(2, entryOf("10").next)
        end)
    end)

    describe("automatic bag reads", function()
        it("reads the bags again on a bag event and drops an item that left the bags", function()
            local reads = bagReads
            bagItems = { bagItems[1], bagItems[2], bagItems[4] }
            fire("BAG_UPDATE_DELAYED")
            assert.are.equal(reads + 1, bagReads)
            assert.is_nil(entryOf("12"))
            assert.are.same({ "g2", "g6" }, idsOf(tab.nodes))
        end)

        it("shows a new bag item at once", function()
            bagItems[#bagItems + 1] = { key = "14", itemID = 14, name = "Thread", count = 5, stacks = {
                { bag = 3, slot = 1, count = 5 } } }
            fire("BAG_UPDATE_DELAYED")
            assert.is_not_nil(entryOf("14"))
            assert.are.same({ "i12", "i14" }, idsOf(tab.nodes[3].children))
        end)

        it("reads the bags on the post event too", function()
            local reads = bagReads
            fire("CREATED")
            assert.are.equal(reads + 1, bagReads)
        end)

        it("keeps the search results of the items", function()
            selectCloth()
            fire("BAG_UPDATE_DELAYED")
            assert.are.equal("ready", entryOf("10").status)
            assert.are.equal("ready", entryOf("11").status)
        end)

        describe("with a time limit", function()
            before_each(function()
                tab:Unmount()
                tab = mount({ syncInterval = 5 })
                ui = tab.ui
                bagReads = 0
            end)

            it("reads at once the first time and makes the later events wait for the end of the interval", function()
                fire("BAG_UPDATE_DELAYED")
                assert.are.equal(1, bagReads)
                now = 1
                fire("BAG_UPDATE_DELAYED")
                fire("CREATED")
                fire("BAG_UPDATE_DELAYED")
                assert.are.equal(1, bagReads)
                local wait = timers[#timers]
                assert.are.equal(4, wait.seconds)
                now = 5
                wait.fn()
                assert.are.equal(2, bagReads)
            end)

            it("reads at once again after the interval", function()
                fire("BAG_UPDATE_DELAYED")
                now = 6
                fire("BAG_UPDATE_DELAYED")
                assert.are.equal(2, bagReads)
            end)
        end)

        it("waits for an open server confirm and reads the bags after it", function()
            selectCloth()
            client.needsConfirmation = true
            click(ui.postNext)
            local reads = bagReads
            fire("BAG_UPDATE_DELAYED")
            assert.are.equal(reads, bagReads)
            confirms[1].onAccept()
            assert.are.equal(reads + 1, bagReads)
        end)
    end)

    describe("rules changes", function()
        it("builds the tree again and moves an item to its new group", function()
            assert.are.same({ "i11" }, idsOf(tab.nodes[1].children[2].children))
            itemGroup["10"] = 6
            fire("Flipside.RulesChanged")
            assert.are.same({ "g2", "g6", "none" }, idsOf(tab.nodes))
            assert.are.same({ "g3" }, idsOf(tab.nodes[1].children))
            assert.are.same({ "i13", "i10" }, idsOf(tab.nodes[2].children))
            assert.are.equal(6, entryOf("10").groupID)
            assert.are.equal("Linen Cloth x60", ui.tree.list.rows[6].label.text)
        end)

        it("hides a group when its last item leaves, and shows an item that has no group again", function()
            itemGroup["10"] = 6
            itemGroup["11"] = 6
            itemGroup["12"] = 6
            fire("Flipside.RulesChanged")
            assert.are.same({ "g6" }, idsOf(tab.nodes))
            itemGroup = {}
            fire("Flipside.RulesChanged")
            assert.are.same({ "none" }, idsOf(tab.nodes))
            assert.are.same({ "i11", "i13", "i12", "i10" }, idsOf(tab.nodes[1].children))
        end)

        it("reads the operation, the min price and the max price of each item again", function()
            assert.are.equal("Sell", entryOf("10").candidate.operationName)
            assert.are.equal(10, entryOf("10").candidate.minPrice)
            rules.GetOperation = function()
                return { name = "Dearer", settings = {
                    minPrice = "50", normalPrice = "100", maxPrice = "300", undercut = 1, duration = 24,
                    vendorSkip = false,
                } }
            end
            fire("Flipside.RulesChanged")
            local candidate = entryOf("10").candidate
            assert.are.equal("Dearer", candidate.operationName)
            assert.are.equal(50, candidate.minPrice)
            assert.are.equal(300, candidate.maxPrice)
        end)

        it("gives an item an operation when a rule change gives its group one", function()
            assert.are.equal("noop", entryOf("12").status)
            rules.EffectiveOperation = function()
                return 7
            end
            fire("Flipside.RulesChanged")
            assert.are.equal("waiting", entryOf("12").status)
            assert.are.equal("Sell", entryOf("12").candidate.operationName)
        end)

        it("keeps the selected node and searches its items again", function()
            selectCloth()
            assert.are.equal("ready", entryOf("10").status)
            rules.GetOperation = function()
                return { name = "Dearer", settings = {
                    minPrice = "50", normalPrice = "100", maxPrice = "300", undercut = 1, duration = 24,
                    vendorSkip = false,
                } }
            end
            fire("Flipside.RulesChanged")
            assert.are.equal("g2", tab.selectedId)
            assert.are.equal("g2", ui.tree.selected)
            assert.are.equal(2, #tab.selection)
            assert.are.equal("searching", entryOf("10").status)
            assert.are.same({ 10, 11, 10 }, client.searches)
        end)

        it("takes the selection again from the new tree", function()
            pick("g6")
            assert.are.equal(1, #tab.selection)
            itemGroup["10"] = 6
            fire("Flipside.RulesChanged")
            local keys = {}
            for _, entry in ipairs(tab.selection) do
                keys[#keys + 1] = entry.key
            end
            assert.are.same({ "13", "10" }, keys)
            assert.are.equal("g6", tab.selectedId)
        end)

        it("makes no post", function()
            itemGroup["10"] = 6
            fire("Flipside.RulesChanged")
            assert.are.equal(0, #client.posts)
        end)

        it("waits while the tab is hidden and reads when it shows", function()
            tab:Deselect()
            local reads = bagReads
            itemGroup["10"] = 6
            fire("Flipside.RulesChanged")
            assert.are.equal(reads, bagReads)
            tab:Select()
            assert.are.equal(reads + 1, bagReads)
            assert.are.same({ "i13", "i10" }, idsOf(tab.nodes[2].children))
            tab:Select()
            assert.are.equal(reads + 2, bagReads)
        end)

        it("shows the new bag contents when the tab is selected again", function()
            tab:Deselect()
            bagItems[#bagItems + 1] = {
                key = "99", itemID = 99, name = "Fresh", count = 1,
                stacks = { { bag = 0, slot = 9, count = 1 } },
            }
            tab:Select()
            assert.is_not_nil(entryOf("99"))
            local found = false
            for _, group in ipairs(tab.nodes) do
                for _, child in ipairs(group.children or {}) do
                    found = found or child.id == "i99"
                end
            end
            assert.is_true(found)
        end)

        it("keeps an open post when the tab is selected again", function()
            selectCloth()
            client.needsConfirmation = true
            click(ui.postNext)
            local open = tab.awaiting
            assert.is_not_nil(open)
            tab:Deselect()
            tab:Select()
            assert.are.equal(open, tab.awaiting)
        end)

        it("waits for an open server confirm", function()
            selectCloth()
            client.needsConfirmation = true
            click(ui.postNext)
            local reads = bagReads
            itemGroup["10"] = 6
            fire("Flipside.RulesChanged")
            assert.are.equal(reads, bagReads)
            confirms[1].onAccept()
            assert.is_true(bagReads > reads)
            assert.are.equal(6, entryOf("10").groupID)
        end)
    end)

    describe("Post all", function()
        local function searchAll()
            client.rows[10] = { row(120, 1) }
            client.rows[11] = { row(150, 5) }
            pick("g2")
            fire("ITEM_RESULTS", 10)
            fire("COMMODITY_RESULTS", 11)
        end

        it("is off with nothing selected, and makes no confirm and no post", function()
            assert.are.equal(0, #tab.selection)
            assert.is_false(ui.postAll.enabled)
            local ok, why = tab:PostAll()
            assert.is_false(ok)
            assert.are.equal("select a group first", why)
            click(ui.postAll)
            assert.are.equal(0, #confirms)
            assert.are.equal(0, #client.posts)
        end)

        it("posts the selected group and its subgroups, each item by its own rules", function()
            searchAll()
            click(ui.postAll)
            confirms[1].onAccept()
            for _ = 1, 3 do
                click(ui.postAll)
            end
            assert.are.equal(4, #client.posts)
            assert.are.same({ "item", "item", "item", "commodity" },
                { client.posts[1].kind, client.posts[2].kind, client.posts[3].kind, client.posts[4].kind })
            assert.are.equal(119 * 20, client.posts[1].buyout)
            assert.are.equal(149, client.posts[4].unitPrice)
        end)

        it("posts only the items of the selected subgroup", function()
            searchAll()
            pick("g3")
            click(ui.postAll)
            confirms[1].onAccept()
            assert.are.equal(1, #client.posts)
            assert.are.equal("commodity", client.posts[1].kind)
            pick("g6")
            assert.is_false(ui.postAll.enabled)
        end)

        it("posts the items of the no-group node", function()
            rules.EffectiveOperation = function()
                return 7
            end
            tab:RefreshBags()
            ui = tab.ui
            client.commodity[12] = true
            client.rows[12] = { row(150, 5) }
            pick("none")
            fire("COMMODITY_RESULTS", 12)
            assert.are.equal("ready", entryOf("12").status)
            assert.is_true(ui.postAll.enabled)
            click(ui.postAll)
            confirms[1].onAccept()
            assert.are.equal(1, #client.posts)
            assert.are.same({ 2, 2 }, { client.posts[1].bag, client.posts[1].slot })
        end)

        it("is off again when the selection ends", function()
            searchAll()
            assert.is_true(ui.postAll.enabled)
            tab:RefreshBags()
            assert.is_false(ui.postAll.enabled)
        end)

        it("confirms with the total deposit before the first post and then asks no more", function()
            searchAll()
            click(ui.postAll)
            assert.are.equal(1, #confirms)
            assert.are.equal("FLIPSIDE_CONFIRM_POST_ALL", confirms[1].name)
            -- 3 auctions of 20 at 10c each unit = 600c, and 12 units = 120c.
            assert.matches("Post 4 auctions%? Total deposit: 720c", confirms[1].text)
            assert.are.equal(0, #client.posts)
            confirms[1].onAccept()
            assert.are.equal(1, #client.posts)
            click(ui.postAll)
            assert.are.equal(1, #confirms)
            assert.are.equal(2, #client.posts)
        end)

        it("makes no post when the user cancels the confirm, and asks again on the next click", function()
            searchAll()
            click(ui.postAll)
            assert.are.equal(0, #client.posts)
            click(ui.postAll)
            assert.are.equal(2, #confirms)
            assert.are.equal(0, #client.posts)
        end)

        it("asks again for a new selection", function()
            searchAll()
            click(ui.postAll)
            confirms[1].onAccept()
            pick("g3")
            click(ui.postAll)
            assert.are.equal(2, #confirms)
            assert.matches("Post 1 auctions%? Total deposit: 120c", confirms[2].text)
        end)

        it("makes the post call only in the accept of the confirm", function()
            searchAll()
            tab:PostAll()
            assert.are.equal(0, #client.posts)
            confirms[1].onAccept()
            assert.are.equal(1, #client.posts)
        end)
    end)

    describe("the item link in a row", function()
        local LINK = "|cff1eff00|Hitem:10::::|h[Linen Cloth]|h|r"
        local inserted

        before_each(function()
            inserted = nil
            _G.ChatEdit_InsertLink = function(link)
                inserted = link
                return true
            end
            _G.IsModifiedClick = function(name)
                return name == "CHATLINK" and _G.shiftDown == true
            end
            _G.shiftDown = false
        end)

        after_each(function()
            _G.ChatEdit_InsertLink, _G.IsModifiedClick, _G.shiftDown = nil, nil, nil
        end)

        it("shows the name as the item link in the quality colour", function()
            bagItems[4].link = LINK
            tab:RefreshBags()
            assert.are.equal(LINK .. " x60", ui.tree.list.rows[2].label.text)
        end)

        it("draws the link when the item data loads, with no bag read", function()
            local loaded = false
            tab = mount({ itemLink = function()
                if loaded then
                    return LINK, 1
                end
            end })
            ui = tab.ui
            assert.are.equal("Linen Cloth x60", ui.tree.list.rows[2].label.text)
            local reads = bagReads
            loaded = true
            fire("ITEM_DATA_LOAD_RESULT", 10, true)
            assert.are.equal(LINK .. " x60", ui.tree.list.rows[2].label.text)
            assert.are.equal(reads, bagReads)
        end)

        it("colours a link that has no colour with the quality colour", function()
            mock.qualityColors[1] = { 1, 1, 1, "ff1eff00" }
            tab = mount({ itemLink = function(id)
                return "|Hitem:" .. id .. "::::|h[Linen Cloth]|h", 1
            end })
            ui = tab.ui
            assert.are.equal("|cff1eff00|Hitem:10::::|h[Linen Cloth]|h|r x60", ui.tree.list.rows[2].label.text)
        end)

        it("shows the item tooltip on hover and hides it on leave", function()
            bagItems[4].link = LINK
            tab:RefreshBags()
            local rowFrame = ui.tree.list.rows[2]
            rowFrame.scripts.OnEnter(rowFrame)
            assert.are.equal("item:10::::", mock.tooltip.hyperlink)
            assert.is_true(mock.tooltip.shown)
            rowFrame.scripts.OnLeave(rowFrame)
            assert.is_false(mock.tooltip.shown)
        end)

        it("puts the link in the chat box on a shift-click and does not select the row", function()
            bagItems[4].link = LINK
            tab:RefreshBags()
            local rowFrame = ui.tree.list.rows[2]
            _G.shiftDown = true
            rowFrame.scripts.OnClick(rowFrame, "LeftButton")
            assert.are.equal(LINK, inserted)
            assert.are.equal(0, #tab.selection)
        end)

        it("selects the row on a plain click", function()
            bagItems[4].link = LINK
            tab:RefreshBags()
            local rowFrame = ui.tree.list.rows[2]
            rowFrame.scripts.OnClick(rowFrame, "LeftButton")
            assert.is_nil(inserted)
            assert.are.equal(1, #tab.selection)
        end)

        it("gives a group row no tooltip", function()
            bagItems[4].link = LINK
            tab:RefreshBags()
            local rowFrame = ui.tree.list.rows[1]
            assert.is_nil(rowFrame.scripts.OnEnter)
        end)
    end)

    describe("protected calls", function()
        it("makes no post call except from a click", function()
            selectCloth()
            timers[#timers].fn()
            fire("READY")
            fire("CREATED", 5)
            pick("g6")
            pick("g2")
            tab:Select()
            tab:Stop()
            tab:RefreshBags()
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
        assert.is_false(bus:HasSubscribers("Flipside.RulesChanged"))
    end)
end)
