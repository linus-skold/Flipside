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
        assert(loadfile("Core/EventBus.lua"))("Flipside", ns)
        assert(loadfile("Services/AHNameSearch.lua"))("Flipside", ns)
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
