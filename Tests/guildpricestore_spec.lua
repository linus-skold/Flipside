local manifest = require("Tests.manifest")

describe("GuildPriceStore", function()
    local ns, Store, saved, now

    before_each(function()
        ns = {}
        assert(loadfile(manifest.path("ScanClock")))("Flipside", ns)
        assert(loadfile(manifest.path("ScanRecord")))("Flipside", ns)
        assert(loadfile(manifest.path("GuildPriceStore")))("Flipside", ns)
        Store = ns.GuildPriceStore
        saved = {}
        now = 1760000000
    end)

    local function open(extra)
        local options = { scope = "EU._.standard", now = function()
            return now
        end }
        for k, v in pairs(extra or {}) do
            options[k] = v
        end
        return Store.New(saved, options)
    end

    local function entry(key, market, time)
        return { key = key, min = market - 100, market = market, qty = 5, time = time or now }
    end

    describe("merge", function()
        it("stores entries and reads them back", function()
            local store = open()
            assert.are.same({ 2, 0 }, { store:Merge({ entry("1", 500), entry("2", 600) }) })
            assert.are.equal(2, store:Count())
            assert.are.same({ min = 400, market = 500, qty = 5, time = now }, store:Get("1"))
            assert.is_nil(store:Get("3"))
        end)

        it("keeps the newest entry of an item", function()
            local store = open()
            store:Merge({ entry("1", 500, now - 100) })
            assert.are.same({ 0, 1 }, { store:Merge({ entry("1", 999, now - 200) }) })
            assert.are.equal(500, store:Get("1").market)
            assert.are.same({ 0, 1 }, { store:Merge({ entry("1", 999, now - 100) }) })
            assert.are.same({ 1, 0 }, { store:Merge({ entry("1", 700, now - 50) }) })
            assert.are.equal(700, store:Get("1").market)
            assert.are.equal(1, store:Count())
        end)

        it("skips invalid entries and times far in the future", function()
            local store = open()
            local bad = {
                { key = "", min = 1, market = 1, qty = 1, time = now },
                { key = "1", min = 0, market = 5, qty = 1, time = now },
                { key = "1", min = 1, market = 0, qty = 1, time = now },
                { key = "1", min = 1.5, market = 5, qty = 1, time = now },
                { key = "1", min = 1, market = 5, qty = -1, time = now },
                entry("1", 500, now + 3 * 86400),
            }
            assert.are.same({ 0, 6 }, { store:Merge(bad) })
            assert.are.equal(0, store:Count())
        end)

        it("saves in the given table, and a new store reads it", function()
            open():Merge({ entry("1", 500) })
            assert.is_table(saved["EU._.standard"].items)
            assert.are.equal(500, open():Get("1").market)
            assert.are.equal(1, open():Count())
        end)

        it("keeps scopes apart", function()
            open():Merge({ entry("1", 500) })
            local other = Store.New(saved, { scope = "EU._.hardcore" })
            assert.is_nil(other:Get("1"))
        end)

        it("removes the oldest items above the limit", function()
            local store = open({ maxItems = 2 })
            store:Merge({ entry("1", 500, now - 30), entry("2", 600, now - 10), entry("3", 700, now - 20) })
            assert.are.equal(2, store:Count())
            assert.is_nil(store:Get("1"))
            assert.is_table(store:Get("2"))
            assert.is_table(store:Get("3"))
        end)

        it("changes the version only when something changed", function()
            local store = open()
            local v0 = store:Version()
            store:Merge({ entry("1", 500) })
            local v1 = store:Version()
            assert.is_true(v1 > v0)
            store:Merge({ entry("1", 500) })
            assert.are.equal(v1, store:Version())
        end)

        it("reports the newest time", function()
            local store = open()
            assert.are.equal(0, store:Newest())
            store:Merge({ entry("1", 500, now - 100), entry("2", 600, now - 5) })
            assert.are.equal(now - 5, store:Newest())
        end)

        it("ignores a broken saved entry", function()
            saved["EU._.standard"] = { items = { ["1"] = "junk" } }
            local store = open()
            assert.is_nil(store:Get("1"))
            assert.is_nil(store:Record("1"))
        end)
    end)

    describe("record", function()
        it("makes a valid scan record that the scan sources can read", function()
            local store = open()
            store:Merge({ entry("1", 500) })
            local record = store:Record("1")
            assert.is_true(ns.ScanRecord.Validate(record))
            assert.is_true(record.latest.partial)
            assert.are.equal(ns.ScanClock.DayOf(now), record.days[1].day)
        end)
    end)

    describe("reader", function()
        local localData, enabled, reader, store

        before_each(function()
            localData = {}
            enabled = true
            store = open()
            store:Merge({ entry("1", 500), entry("2", 600) })
            reader = Store.NewReader({
                localStore = {
                    Get = function(_, key)
                        return localData[key]
                    end,
                    GetVersion = function()
                        return 7
                    end,
                },
                guildStore = store,
                isEnabled = function()
                    return enabled
                end,
            })
        end)

        it("fills a gap from the shared data", function()
            local record = reader:Get("1")
            assert.are.equal(500, record.latest.market)
            assert.is_true(reader:IsGuild("1"))
            assert.is_nil(reader:Get("9"))
            assert.is_false(reader:IsGuild("9"))
        end)

        it("lets a newer local record win", function()
            localData["1"] = { latest = { market = 111, time = now + 1 } }
            assert.are.equal(111, reader:Get("1").latest.market)
            assert.is_false(reader:IsGuild("1"))
            assert.are.equal(600, reader:Get("2").latest.market)
        end)

        it("lets a newer shared record beat an older local record", function()
            localData["1"] = { latest = { market = 111, time = now - 1 } }
            assert.are.equal(500, reader:Get("1").latest.market)
            assert.is_true(reader:IsGuild("1"))
        end)

        it("keeps the local record on equal times", function()
            localData["1"] = { latest = { market = 111, time = now } }
            assert.are.equal(111, reader:Get("1").latest.market)
            assert.is_false(reader:IsGuild("1"))
        end)

        it("uses the local record when there is no shared record", function()
            localData["9"] = { latest = { market = 111, time = now } }
            assert.are.equal(111, reader:Get("9").latest.market)
            assert.is_false(reader:IsGuild("9"))
        end)

        it("gives the local record when sharing is off, even if the shared one is newer", function()
            localData["1"] = { latest = { market = 111, time = now - 1000 } }
            enabled = false
            assert.are.equal(111, reader:Get("1").latest.market)
        end)

        it("lists the keys of the store", function()
            local keys = store:Keys()
            table.sort(keys)
            assert.same({ "1", "2" }, keys)
        end)

        it("gives no shared data when sharing is off", function()
            enabled = false
            assert.is_nil(reader:Get("1"))
            assert.is_false(reader:IsGuild("1"))
        end)

        it("changes the version with the shared data and the setting", function()
            local a = reader:GetVersion()
            store:Merge({ entry("3", 700) })
            local b = reader:GetVersion()
            enabled = false
            local c = reader:GetVersion()
            assert.is_true(a ~= b and b ~= c and a ~= c)
        end)
    end)
end)
