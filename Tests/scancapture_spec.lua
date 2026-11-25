local manifest = require("Tests.manifest")
describe("ScanCapture", function()
    local ns, store, capture, api, now, captured, reports, running
    local DAY = 86400

    local function gear(id, bonus)
        return "|cffffffff|Hitem:" .. id .. "::::::::::::1:" .. bonus .. "|h[Gear]|h|r"
    end

    before_each(function()
        ns = {}
        for _, name in ipairs({ "ScanClock", "ScanRecord", "ScanMarket", "ScanKey", "ScanBucket", "ScanStore",
            "ScanCapture" }) do
            assert(loadfile(manifest.path(name)))("Flipside", ns)
        end
        assert(loadfile(manifest.path("ItemString")))("Flipside", ns)
        store = ns.ScanStore.New({}, { region = "EU", ruleset = "standard", schemaVersion = 1 })
        now = 10 * DAY + 100
        captured, reports, running = {}, {}, false
        api = {
            commodityRows = {}, commodityIsFull = true,
            itemRows = {}, itemIsFull = true,
        }
        api.commodityNum = function() return #api.commodityRows end
        api.commodityInfo = function(_, i) return api.commodityRows[i] end
        api.commodityFull = function() return api.commodityIsFull end
        api.itemNum = function() return #api.itemRows end
        api.itemInfo = function(_, i) return api.itemRows[i] end
        api.itemFull = function() return api.itemIsFull end
        capture = ns.ScanCapture.New({
            store = store,
            serverTime = function() return now end,
            api = api,
            report = function(text) reports[#reports + 1] = text end,
            onCaptured = function(key, _, partial) captured[#captured + 1] = { key = key, partial = partial } end,
            isScanRunning = function() return running end,
        })
    end)

    local function commodityRows(prices)
        api.commodityRows = {}
        for i, p in ipairs(prices) do
            api.commodityRows[i] = { itemID = 2589, unitPrice = p, quantity = 10 }
        end
    end

    local function itemRow(link, buyout, quantity)
        table.insert(api.itemRows, { itemLink = link, buyoutAmount = buyout, quantity = quantity or 1 })
    end

    describe("legacy page", function()
        local function pageRow(id, count, buyout, link)
            return { itemID = id, count = count, buyout = buyout, link = link }
        end

        it("groups rows by key and converts the stack buyout to a unit price", function()
            capture:OnPageResults({
                pageRow(2589, 20, 2000, gear(2589, 0)), pageRow(2589, 10, 700, gear(2589, 0)),
                pageRow(5, 1, 900, gear(5, 77)),
            }, true)
            assert.are.equal(70, store:Get("2589#b0").latest.min)
            assert.are.equal(30, store:Get("2589#b0").latest.qty)
            assert.are.equal(900, store:Get("5#b77").latest.min)
        end)

        it("uses keyFor and skips a row without a key, a buyout, a count or a pet link", function()
            capture = ns.ScanCapture.New({
                store = store, serverTime = function() return now end, api = api,
                keyFor = function(id, link)
                    if id == 9 then return nil end
                    return tostring(id) .. (link and "L" or "")
                end,
            })
            capture:OnPageResults({
                pageRow(7, 2, 300), pageRow(9, 1, 100), pageRow(7, 1, 0), pageRow(7, 0, 100),
                pageRow(7, 1, 100, "|Hbattlepet:7|h[P]|h"),
            }, true)
            assert.are.equal(1, store:CountItems())
            assert.are.equal(150, store:Get("7").latest.min)
        end)

        it("skips a page of more than 50 rows and saves a page of exactly 50", function()
            local rows = {}
            for i = 1, 51 do
                rows[i] = pageRow(7, 1, 100, gear(7, 0))
            end
            capture:OnPageResults(rows, true)
            assert.is_nil(store:Get("7#b0"))
            rows[51] = nil
            capture:OnPageResults(rows, true)
            assert.are.equal(100, store:Get("7#b0").latest.min)
        end)

        it("saves a partial page as the lowest price only and does nothing during a scan", function()
            capture:OnPageResults({ pageRow(7, 1, 100, nil) }, false)
            assert.is_nil(store:Get("7"))
            capture = ns.ScanCapture.New({
                store = store, serverTime = function() return now end, api = api,
                keyFor = function(id) return tostring(id) end,
                isScanRunning = function() return running end,
            })
            running = true
            capture:OnPageResults({ pageRow(7, 1, 100) }, false)
            assert.is_nil(store:Get("7"))
            running = false
            capture:OnPageResults({ pageRow(7, 1, 100) }, false)
            assert.is_true(store:Get("7").latest.partial)
            assert.are.equal(100, store:Get("7").latest.market)
        end)
    end)

    describe("commodity", function()
        it("saves a complete result as latest and as the only snapshot", function()
            commodityRows({ 100, 110, 120 })
            capture:OnCommodityResults(2589)
            local r = store:Get("2589")
            assert.is_false(r.latest.partial)
            assert.are.equal(100, r.latest.min)
            assert.are.equal(30, r.latest.qty)
            assert.are.equal(3, r.latest.auctions)
            assert.are.equal(1, #r.today.snaps)
            assert.are.same({ { key = "2589", partial = false } }, captured)
        end)

        it("replaces the snapshots of today", function()
            commodityRows({ 100, 110 })
            capture:OnCommodityResults(2589)
            now = now + 50
            capture:OnCommodityResults(2589)
            commodityRows({ 90, 95 })
            now = now + 50
            capture:OnCommodityResults(2589)
            local r = store:Get("2589")
            assert.are.equal(1, #r.today.snaps)
            assert.are.equal(90, r.today.snaps[1].min)
        end)

        it("saves only the minimum for a partial result and keeps the old market value", function()
            commodityRows({ 100, 110, 120 })
            capture:OnCommodityResults(2589)
            local before = store:Get("2589").latest
            commodityRows({ 80 })
            api.commodityIsFull = false
            now = now + 60
            capture:OnCommodityResults(2589)
            local r = store:Get("2589")
            assert.is_true(r.latest.partial)
            assert.are.equal(80, r.latest.min)
            assert.are.equal(before.market, r.latest.market)
            assert.are.equal(before.qty, r.latest.qty)
            assert.are.equal(before.auctions, r.latest.auctions)
            assert.are.equal(1, #r.today.snaps)
            assert.are.equal(100, r.today.snaps[1].min)
        end)

        it("uses the minimum as market value for a partial result without an old record", function()
            commodityRows({ 80, 90 })
            api.commodityIsFull = false
            capture:OnCommodityResults(2589)
            local r = store:Get("2589")
            assert.are.equal(80, r.latest.min)
            assert.are.equal(80, r.latest.market)
            assert.are.equal(20, r.latest.qty)
            assert.are.equal(2, r.latest.auctions)
            assert.is_nil(r.today)
            assert.are.same({ { key = "2589", partial = true } }, captured)
        end)

        it("saves nothing for an empty result", function()
            capture:OnCommodityResults(2589)
            assert.is_nil(store:Get("2589"))
            assert.are.same({}, captured)
        end)
    end)

    describe("items", function()
        it("saves one record for each exact key", function()
            itemRow(gear(1001, 6001), 5000)
            itemRow(gear(1001, 6001), 6000)
            itemRow(gear(1001, 6002), 9000)
            capture:OnItemResults({ itemID = 1001 })
            assert.are.same({ "1001#b6001", "1001#b6002" }, store:Keys())
            local a, b = store:Get("1001#b6001"), store:Get("1001#b6002")
            assert.are.equal(5000, a.latest.min)
            assert.are.equal(2, a.latest.auctions)
            assert.are.equal(9000, b.latest.min)
            assert.is_false(a.latest.partial)
            assert.are.equal(2, #captured)
        end)

        it("takes the buyout of an item result as the price of one item, with no division", function()
            -- Forever prices an item auction for one item (ForeverBackend.LiveRows): 40 items at 449 each.
            itemRow(gear(1001, 6001), 449, 40)
            capture:OnItemResults({ itemID = 1001 })
            local r = store:Get("1001#b6001")
            assert.are.equal(449, r.latest.min)
            assert.are.equal(40, r.latest.qty)
        end)

        it("skips pets, rows without a link and rows without a buyout", function()
            itemRow("|cff0070dd|Hbattlepet:1234:1:3:0:0:0:0|h[Pet]|h|r", 5000)
            itemRow(nil, 5000)
            itemRow(gear(1001, 6001), nil)
            itemRow(gear(1001, 6001), 0)
            itemRow(gear(1001, 6001), 7000)
            capture:OnItemResults({ itemID = 1001 })
            assert.are.same({ "1001#b6001" }, store:Keys())
            assert.are.equal(1, store:Get("1001#b6001").latest.auctions)
        end)

        it("saves nothing when only pets are listed", function()
            itemRow("|cff0070dd|Hbattlepet:1234:1:3:0:0:0:0|h[Pet]|h|r", 5000)
            capture:OnItemResults({ itemID = 1 })
            assert.are.same({}, store:Keys())
        end)

        it("replaces the snapshots of today for a complete result", function()
            local r = ns.ScanRecord.New()
            ns.ScanBucket.Apply(r, { min = 1, market = 1, qty = 1, auctions = 1 }, now - 10, false)
            ns.ScanBucket.Apply(r, { min = 2, market = 2, qty = 1, auctions = 1 }, now - 5, false)
            store:Put("1001#b6001", r)
            itemRow(gear(1001, 6001), 5000)
            capture:OnItemResults({ itemID = 1001 })
            local got = store:Get("1001#b6001")
            assert.are.equal(1, #got.today.snaps)
            assert.are.equal(5000, got.today.snaps[1].min)
        end)

        it("keeps the snapshots of today for a partial result", function()
            local r = ns.ScanRecord.New()
            ns.ScanBucket.Apply(r, { min = 1, market = 40, qty = 9, auctions = 3 }, now - 10, false)
            ns.ScanBucket.Apply(r, { min = 2, market = 50, qty = 9, auctions = 3 }, now - 5, false)
            store:Put("1001#b6001", r)
            api.itemIsFull = false
            itemRow(gear(1001, 6001), 5000)
            capture:OnItemResults({ itemID = 1001 })
            local got = store:Get("1001#b6001")
            assert.are.equal(2, #got.today.snaps)
            assert.is_true(got.latest.partial)
            assert.are.equal(5000, got.latest.min)
            assert.are.equal(50, got.latest.market)
            assert.are.equal(9, got.latest.qty)
        end)
    end)

    describe("paging", function()
        local more, ready, timers

        before_each(function()
            more, ready, timers = {}, true, {}
            api.commodityMore = function(id) more[#more + 1] = id end
            api.itemMore = function(key) more[#more + 1] = key end
            api.isReady = function() return ready end
            capture = ns.ScanCapture.New({
                store = store, serverTime = function() return now end, api = api,
                report = function(text) reports[#reports + 1] = text end,
                after = function(seconds, fn) timers[#timers + 1] = { seconds = seconds, fn = fn } end,
                onCaptured = function(key, _, partial) captured[#captured + 1] = { key = key, partial = partial } end,
            })
            capture:BeginSearch(2589, { itemID = 2589 }) -- Flipside sent the search for item 2589
        end)

        local function runTimers()
            local list = timers
            timers = {}
            for _, t in ipairs(list) do
                t.fn()
            end
        end

        it("requests the next commodity page until the result is full", function()
            api.commodityIsFull = false
            commodityRows({ 100, 110 })
            capture:OnCommodityResults(2589)
            assert.are.same({ 2589 }, more)
            commodityRows({ 100, 110, 120, 130 })
            capture:OnCommodityResults(2589)
            assert.are.same({ 2589, 2589 }, more)
            assert.is_true(store:Get("2589").latest.partial)
            commodityRows({ 100, 110, 120, 130, 140 })
            api.commodityIsFull = true
            capture:OnCommodityResults(2589)
            assert.are.equal(2, #more)
            local r = store:Get("2589")
            assert.is_false(r.latest.partial)
            assert.are.equal(5, r.latest.auctions)
            assert.is_false(captured[#captured].partial)
        end)

        it("requests the next item page until the result is full", function()
            capture:BeginSearch(1001, { itemID = 1001 })
            api.itemIsFull = false
            itemRow(gear(1001, 6001), 5000)
            capture:OnItemResults({ itemID = 1001 })
            assert.are.same({ { itemID = 1001 } }, more)
            itemRow(gear(1001, 6001), 5100)
            capture:OnItemResults({ itemID = 1001 })
            assert.are.equal(2, #more)
            api.itemIsFull = true
            itemRow(gear(1001, 6001), 5200)
            capture:OnItemResults({ itemID = 1001 })
            assert.are.equal(2, #more)
            assert.is_false(store:Get("1001#b6001").latest.partial)
            assert.are.equal(3, store:Get("1001#b6001").latest.auctions)
        end)

        it("stops when a request gives no new row", function()
            api.commodityIsFull = false
            commodityRows({ 100, 110 })
            capture:OnCommodityResults(2589)
            capture:OnCommodityResults(2589)
            assert.are.equal(1, #more)
            assert.is_true(store:Get("2589").latest.partial)
        end)

        it("stops after the request cap", function()
            api.commodityIsFull = false
            for n = 1, 130 do
                api.commodityRows = {}
                for i = 1, n do
                    api.commodityRows[i] = { unitPrice = 100 + i, quantity = 1 }
                end
                capture:OnCommodityResults(2589)
            end
            assert.are.equal(100, #more)
        end)

        it("starts again for a new search, also with the same first page size", function()
            api.commodityIsFull = false
            commodityRows({ 100, 110, 120 })
            capture:OnCommodityResults(2589)
            assert.are.equal(1, #more)
            capture:OnCommodityResults(2589) -- a duplicate event: nothing changes
            assert.are.equal(1, #more)
            capture:BeginSearch(2589, { itemID = 2589 })
            capture:OnCommodityResults(2589) -- the new search has the same count
            assert.are.equal(2, #more)
        end)

        it("does not page a search that Flipside did not send", function()
            api.commodityIsFull = false
            commodityRows({ 100, 110 })
            capture:OnCommodityResults(3000)
            assert.are.equal(0, #more)
            assert.are.equal(100, store:Get("3000").latest.min) -- the rows are saved
        end)

        it("stops the paging of an item when a search for another item starts", function()
            api.commodityIsFull = false
            ready = false
            commodityRows({ 100, 110 })
            capture:OnCommodityResults(2589)
            assert.are.equal(1, #timers)
            capture:BeginSearch(3000, { itemID = 3000 })
            ready = true
            runTimers()
            assert.are.equal(0, #more)
            capture:OnCommodityResults(2589)
            assert.are.equal(0, #more)
            capture:OnCommodityResults(3000)
            assert.are.equal(1, #more)
        end)

        it("runs one request chain for each item, also with duplicate events", function()
            api.commodityIsFull = false
            ready = false
            commodityRows({ 100, 110 })
            capture:OnCommodityResults(2589)
            capture:OnCommodityResults(2589)
            assert.are.equal(1, #timers)
            ready = true
            runTimers()
            assert.are.equal(1, #more)
            capture:OnCommodityResults(2589) -- a duplicate while the request is open
            assert.are.equal(1, #more)
            commodityRows({ 100, 110, 120 })
            capture:OnCommodityResults(2589)
            assert.are.equal(2, #more)
        end)

        it("clears the link wait of a key when a new search for it starts", function()
            itemRow(gear(1001, 6001), 5000)
            itemRow(nil, 4000)
            capture:OnItemResults({ itemID = 1001 })
            for _ = 1, 4 do
                runTimers() -- 5 link tries used
            end
            capture:BeginSearch(1001, { itemID = 1001 })
            timers = {}
            capture:OnItemResults({ itemID = 1001 })
            for _ = 1, 4 do
                assert.are.equal(1, #timers) -- the link tries start again
                runTimers()
            end
        end)

        it("waits for the throttle gate before it requests the next page", function()
            api.commodityIsFull = false
            ready = false
            commodityRows({ 100, 110 })
            capture:OnCommodityResults(2589)
            assert.are.equal(0, #more)
            assert.are.equal(1, #timers)
            runTimers()
            assert.are.equal(0, #more)
            ready = true
            runTimers()
            assert.are.equal(1, #more)
        end)

        it("reports a failed request once and still saves the rows", function()
            api.commodityIsFull = false
            api.commodityMore = function() error("more") end
            commodityRows({ 100, 110 })
            capture:OnCommodityResults(2589)
            assert.are.equal(1, #reports)
            assert.are.equal(100, store:Get("2589").latest.min)
        end)

        it("does not page a legacy client with no next-page call", function()
            api.commodityMore, api.itemMore = nil, nil
            api.commodityIsFull = false
            commodityRows({ 100 })
            capture:OnCommodityResults(2589)
            assert.are.equal(0, #more)
            assert.are.equal(100, store:Get("2589").latest.min)
        end)
    end)

    describe("rows with no link", function()
        local timers

        before_each(function()
            timers = {}
            capture = ns.ScanCapture.New({
                store = store, serverTime = function() return now end, api = api,
                after = function(seconds, fn) timers[#timers + 1] = { seconds = seconds, fn = fn } end,
                onCaptured = function(key, _, partial) captured[#captured + 1] = { key = key, partial = partial } end,
            })
        end)

        local function runTimers()
            local list = timers
            timers = {}
            for _, t in ipairs(list) do
                t.fn()
            end
        end

        it("waits for the link and then saves the full result", function()
            itemRow(gear(1001, 6001), 5000)
            itemRow(nil, 4000)
            capture:OnItemResults({ itemID = 1001 })
            assert.are.equal(1, #timers)
            assert.are.same({}, store:Keys())
            api.itemRows[2].itemLink = gear(1001, 6001)
            runTimers()
            local r = store:Get("1001#b6001")
            assert.are.equal(4000, r.latest.min)
            assert.are.equal(2, r.latest.auctions)
            assert.is_false(r.latest.partial)
            assert.are.equal(0, #timers)
        end)

        it("saves the linked rows as partial when the link does not come", function()
            itemRow(gear(1001, 6001), 5000)
            itemRow(nil, 4000)
            capture:OnItemResults({ itemID = 1001 })
            for _ = 1, 10 do
                runTimers()
            end
            assert.are.equal(0, #timers)
            local r = store:Get("1001#b6001")
            assert.is_true(r.latest.partial)
            assert.are.equal(5000, r.latest.min)
        end)

        it("saves a partial result with no wait when the client has no timer", function()
            capture = ns.ScanCapture.New({ store = store, serverTime = function() return now end, api = api })
            itemRow(gear(1001, 6001), 5000)
            itemRow(nil, 4000)
            capture:OnItemResults({ itemID = 1001 })
            assert.is_true(store:Get("1001#b6001").latest.partial)
        end)

        it("does not count a row with no buyout as a row with no link", function()
            itemRow(gear(1001, 6001), 5000)
            itemRow(nil, 0)
            capture:OnItemResults({ itemID = 1001 })
            assert.are.equal(0, #timers)
            assert.is_false(store:Get("1001#b6001").latest.partial)
        end)
    end)

    describe("guards", function()
        it("saves nothing to a read-only store", function()
            store = ns.ScanStore.New({ _schema = 99 }, { region = "EU", ruleset = "standard", schemaVersion = 1 })
            capture = ns.ScanCapture.New({ store = store, serverTime = function() return now end, api = api })
            commodityRows({ 100 })
            capture:OnCommodityResults(2589)
            itemRow(gear(1001, 6001), 5000)
            capture:OnItemResults({ itemID = 1001 })
            assert.are.same({}, store:Keys())
        end)

        it("saves nothing while a full scan runs", function()
            running = true
            commodityRows({ 100 })
            capture:OnCommodityResults(2589)
            itemRow(gear(1001, 6001), 5000)
            capture:OnItemResults({ itemID = 1001 })
            assert.are.same({}, store:Keys())
            running = false
            capture:OnCommodityResults(2589)
            assert.is_not_nil(store:Get("2589"))
        end)

        it("saves nothing and reports once when a client call fails", function()
            api.commodityNum = function() error("boom") end
            capture:OnCommodityResults(2589)
            capture:OnCommodityResults(2589)
            assert.are.same({}, store:Keys())
            assert.are.equal(1, #reports)
            assert.is_truthy(reports[1]:find("boom", 1, true))
            api.itemFull = function() error("again") end
            itemRow(gear(1001, 6001), 5000)
            capture:OnItemResults({ itemID = 1001 })
            assert.are.same({}, store:Keys())
            assert.are.equal(1, #reports)
        end)

        it("saves nothing when a row call fails", function()
            commodityRows({ 100 })
            api.commodityInfo = function() error("row") end
            capture:OnCommodityResults(2589)
            assert.are.same({}, store:Keys())
            assert.are.equal(1, #reports)
        end)

        it("needs store, serverTime and api", function()
            assert.has_error(function() ns.ScanCapture.New({}) end)
        end)
    end)
end)
