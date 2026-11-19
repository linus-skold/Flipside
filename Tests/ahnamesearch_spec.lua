local manifest = require("Tests.manifest")
describe("AHNameSearch", function()
    local ns, bus, search, api, now, open, timers, sent, EVENT

    local function key(id, pet)
        return { itemID = id, battlePetSpeciesID = pet or 0 }
    end

    local function run(name, options)
        local got = {}
        search:Find(name, function(items, err)
            got.n = (got.n or 0) + 1
            got.items, got.err = items, err
        end, options)
        return got
    end

    before_each(function()
        ns = {}
        assert(loadfile(manifest.path("EventBus")))("Flipside", ns)
        assert(loadfile(manifest.path("AHNameSearch")))("Flipside", ns)
        EVENT = "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"
        bus = ns.EventBus.New()
        now, open, timers, sent = 100, true, {}, {}
        api = {
            rows = {}, names = {},
            sendBrowseQuery = function(q) sent[#sent + 1] = q end,
            getBrowseResults = function() return api.rows end,
            getItemKeyInfo = function(k) return { itemName = api.names[k.itemID] } end,
        }
        search = ns.AHNameSearch.New({
            bus = bus, api = api, clock = function() return now end,
            isAuctionHouseOpen = function() return open end,
            after = function(sec, fn) timers[#timers + 1] = { sec = sec, fn = fn } end,
        })
    end)

    it("answers at once when the Auction House is closed", function()
        open = false
        local got = run("Linen")
        assert.are.equal(1, got.n)
        assert.is_nil(got.items)
        assert.are.equal("open the Auction House to search it", got.err)
        assert.are.equal(0, #sent)
    end)

    it("sends the exact text and maps sorted results", function()
        api.rows = { { itemKey = key(2) }, { itemKey = key(1) } }
        api.names = { [1] = "Zeta Cloth", [2] = "Alpha Cloth" }
        local got = run("Cloth")
        assert.are.equal("Cloth", sent[1].searchString)
        assert.is_nil(got.n)
        bus:Emit(EVENT)
        assert.are.same({
            { itemID = 2, name = "Alpha Cloth", key = "2" },
            { itemID = 1, name = "Zeta Cloth", key = "1" },
        }, got.items)
        assert.is_false(search:IsBusy())
        assert.is_false(bus:HasSubscribers(EVENT))
    end)

    it("skips battle pets", function()
        api.rows = { { itemKey = key(0, 55) }, { itemKey = key(7) } }
        api.names = { [0] = "Pet", [7] = "Thing" }
        local got = run("T")
        bus:Emit(EVENT)
        assert.are.equal(1, #got.items)
        assert.are.equal(7, got.items[1].itemID)
    end)

    it("keeps only exact names with the exact option", function()
        api.rows = { { itemKey = key(1) }, { itemKey = key(2) } }
        api.names = { [1] = "Linen Cloth", [2] = "Linen Cloth Bolt" }
        local got = run("linen cloth", { exact = true })
        bus:Emit(EVENT)
        assert.are.equal(1, #got.items)
        assert.are.equal(1, got.items[1].itemID)
    end)

    describe("with settle", function()
        local seenLists

        local function runSettle(name, options)
            options = options or {}
            options.settle = 1
            seenLists = {}
            options.onItems = function(items)
                seenLists[#seenLists + 1] = #items
            end
            return run(name, options)
        end

        it("keeps two browse results and ends after a quiet time", function()
            api.rows = { { itemKey = key(1) }, { itemKey = key(2) } }
            api.names = { [1] = "Linen Cloth", [2] = "Bolt of Linen Cloth" }
            local got = runSettle("Linen Cloth")
            bus:Emit(EVENT)
            assert.is_nil(got.n)
            assert.are.same({ 2 }, seenLists)
            assert.are.equal(1, timers[#timers].sec)
            timers[#timers].fn()
            assert.are.equal(1, got.n)
            assert.are.equal(2, #got.items)
            assert.is_false(bus:HasSubscribers(EVENT))
        end)

        it("appends the items of a later event and ignores the earlier timer", function()
            api.rows = { { itemKey = key(1) } }
            api.names = { [1] = "Linen Cloth", [2] = "Bolt of Linen Cloth" }
            local got = runSettle("Linen Cloth")
            bus:Emit(EVENT)
            local firstTimer = timers[#timers]
            api.rows = { { itemKey = key(1) }, { itemKey = key(2) } }
            bus:Emit(EVENT)
            assert.are.same({ 1, 2 }, seenLists)
            firstTimer.fn()
            assert.is_nil(got.n)
            timers[#timers].fn()
            assert.are.equal(1, got.n)
            assert.are.same({ "Bolt of Linen Cloth", "Linen Cloth" }, { got.items[1].name, got.items[2].name })
        end)

        it("reads again on the added event", function()
            local ADDED = "AUCTION_HOUSE_BROWSE_RESULTS_ADDED"
            search = ns.AHNameSearch.New({
                bus = bus, api = api, clock = function() return now end, addedEvent = ADDED,
                isAuctionHouseOpen = function() return open end,
                after = function(sec, fn) timers[#timers + 1] = { sec = sec, fn = fn } end,
            })
            api.rows = { { itemKey = key(1) } }
            api.names = { [1] = "Linen Cloth", [2] = "Bolt of Linen Cloth" }
            runSettle("Linen")
            bus:Emit(EVENT)
            api.rows = { { itemKey = key(1) }, { itemKey = key(2) } }
            bus:Emit(ADDED, {})
            assert.are.same({ 1, 2 }, seenLists)
            timers[#timers].fn()
            assert.is_false(bus:HasSubscribers(ADDED))
        end)

        it("keeps only the exact name with the exact option", function()
            api.rows = { { itemKey = key(1) }, { itemKey = key(2) } }
            api.names = { [1] = "Linen Cloth", [2] = "Bolt of Linen Cloth" }
            local got = runSettle("linen cloth", { exact = true })
            bus:Emit(EVENT)
            timers[#timers].fn()
            assert.are.equal(1, #got.items)
            assert.are.equal(1, got.items[1].itemID)
        end)

        describe("a slow client", function()
            local INFO = "ITEM_KEY_ITEM_INFO_RECEIVED"
            local SILVER_BAR = 2842

            before_each(function()
                search = ns.AHNameSearch.New({
                    bus = bus, api = api, clock = function() return now end, infoEvent = INFO,
                    isAuctionHouseOpen = function() return open end,
                    after = function(sec, fn) timers[#timers + 1] = { sec = sec, fn = fn } end,
                })
            end)

            it("waits for the name of a commodity row (Silver Bar)", function()
                api.rows = { { itemKey = key(SILVER_BAR) } }
                local got = runSettle("Silver Bar")
                bus:Emit(EVENT)
                timers[#timers].fn()
                assert.is_nil(got.n)
                api.names[SILVER_BAR] = "Silver Bar"
                bus:Emit(INFO, SILVER_BAR)
                timers[#timers].fn()
                assert.are.equal(1, got.n)
                assert.are.same({ { itemID = SILVER_BAR, name = "Silver Bar", key = "2842" } }, got.items)
                assert.is_false(bus:HasSubscribers(INFO))
            end)

            it("reads again after a quiet time when the info event is lost", function()
                api.rows = { { itemKey = key(SILVER_BAR) } }
                local got = runSettle("Silver Bar")
                bus:Emit(EVENT)
                api.names[SILVER_BAR] = "Silver Bar"
                timers[#timers].fn()
                assert.is_nil(got.n)
                assert.are.same({ 0, 1 }, seenLists)
                now = now + 6
                timers[#timers].fn()
                assert.are.equal(1, #got.items)
            end)

            it("does not end on an empty first event", function()
                local got = runSettle("Silver Bar")
                bus:Emit(EVENT)
                timers[#timers].fn()
                assert.is_nil(got.n)
                api.rows = { { itemKey = key(SILVER_BAR) } }
                api.names[SILVER_BAR] = "Silver Bar"
                bus:Emit(EVENT)
                now = now + 6
                timers[#timers].fn()
                assert.are.equal(1, got.n)
                assert.are.equal(1, #got.items)
            end)

            it("ends with no items after the grace time", function()
                local got = runSettle("Nothing")
                bus:Emit(EVENT)
                now = now + 6
                timers[#timers].fn()
                assert.are.equal(1, got.n)
                assert.are.same({}, got.items)
            end)

            it("ends with the items found, not an error, at the timeout", function()
                api.rows = { { itemKey = key(SILVER_BAR) } }
                local got = runSettle("Silver Bar")
                bus:Emit(EVENT)
                timers[1].fn()
                assert.are.equal(1, got.n)
                assert.is_nil(got.err)
                assert.are.same({}, got.items)
            end)
        end)
    end)

    it("times out through after()", function()
        local got = run("X")
        assert.are.equal(10, timers[1].sec)
        timers[1].fn()
        assert.are.equal("no answer from the Auction House", got.err)
        bus:Emit(EVENT)
        assert.are.equal(1, got.n)
    end)

    it("ends a stale search by the clock when after() does not fire", function()
        local got = run("X")
        now = now + 11
        bus:Emit(EVENT)
        assert.are.equal("no answer from the Auction House", got.err)
        local again = run("Y")
        assert.is_nil(again.err)
        now = now + 11
        local third = run("Z")
        assert.are.equal("no answer from the Auction House", again.err)
        assert.is_nil(third.err)
    end)

    it("refuses a second search while one runs", function()
        local first = run("A")
        local second = run("B")
        assert.are.equal("a search is already running", second.err)
        assert.is_nil(first.n)
    end)

    it("reports a failing send", function()
        api.sendBrowseQuery = function() error("boom") end
        local got = run("A")
        assert.is_nil(got.items)
        assert.is_truthy(got.err:find("boom", 1, true))
        assert.is_false(search:IsBusy())
    end)

    it("survives a failing result read and name lookup", function()
        api.getBrowseResults = function() error("boom") end
        local got = run("A")
        bus:Emit(EVENT)
        assert.is_nil(got.items)
        assert.is_truthy(got.err)
        api.getBrowseResults = function() return { { itemKey = key(1) } } end
        api.getItemKeyInfo = function() error("boom") end
        local second = run("A")
        bus:Emit(EVENT)
        assert.are.same({}, second.items)
    end)
end)
