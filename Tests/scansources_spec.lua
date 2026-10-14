local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("ScanClock")))("Flipside", ns)
assert(loadfile(manifest.path("ScanSources")))("Flipside", ns)
local S = ns.ScanSources

local DAY = 86400
local TODAY = 20000
local NOW = TODAY * DAY + 3600 * 6 -- 06:00 on day 20000

local function entry(day, market)
    return { day = day, min = market - 10, market = market, qty = 100, scans = 2 }
end

local function snap(time, market)
    return { time = time, min = market - 10, market = market, qty = 50, auctions = 5 }
end

local function record(days, latest, today)
    return { latest = latest, today = today, days = days or {} }
end

describe("ScanSources", function()
    it("lists the names and fields", function()
        assert.are.equal(9, #S.NAMES)
        assert.are.equal("scanMin", S.FIELD.ScanMin)
        assert.are.equal("scanMarket", S.FIELD.ScanMarket)
        for _, name in ipairs(S.NAMES) do
            assert.is_string(S.FIELD[name])
        end
    end)

    it("returns nil values for an empty record", function()
        local r = S.Compute(record(), NOW)
        assert.is_nil(r.scanMin)
        assert.is_nil(r.scanRecent)
        assert.is_nil(r.scanQty)
        assert.is_nil(r.scanAge)
        assert.is_nil(r.scanPartial)
        assert.is_nil(r.scanMarket)
        assert.is_nil(r.scanLow)
        assert.is_nil(r.scanHigh)
        assert.is_nil(r.scanHistorical)
        assert.are.equal(0, r.scanSamples)
        assert.are.equal(0, r.scanDays)
    end)

    it("reads the latest values", function()
        local latest = { time = NOW - 5400, min = 900, market = 1000, qty = 42, auctions = 7, partial = false }
        local r = S.Compute(record(nil, latest), NOW)
        assert.are.equal(900, r.scanMin)
        assert.are.equal(1000, r.scanRecent)
        assert.are.equal(42, r.scanQty)
        assert.are.equal(1.5, r.scanAge)
        assert.is_false(r.scanPartial)
        assert.is_nil(r.scanMarket)
    end)

    it("gives age 0 for a scan at now", function()
        local latest = { time = NOW, min = 1, market = 2, qty = 3, auctions = 1, partial = false }
        assert.are.equal(0, S.Compute(record(nil, latest), NOW).scanAge)
    end)

    it("passes the partial flag", function()
        local latest = { time = NOW, min = 1, market = 2, qty = 3, auctions = 1, partial = true }
        assert.is_true(S.Compute(record(nil, latest), NOW).scanPartial)
    end)

    it("uses the average of the snaps of today", function()
        local today = { day = TODAY, snaps = { snap(NOW - 100, 1000), snap(NOW, 2000) } }
        local r = S.Compute(record(nil, nil, today), NOW)
        assert.are.equal(1500, r.scanMarket)
        assert.are.equal(1, r.scanSamples)
        assert.is_nil(r.scanHistorical)
        assert.are.equal(0, r.scanDays)
    end)

    it("ignores snaps of an older day", function()
        local today = { day = TODAY - 1, snaps = { snap(NOW - DAY, 1000) } }
        local r = S.Compute(record(nil, nil, today), NOW)
        assert.is_nil(r.scanMarket)
        assert.are.equal(0, r.scanSamples)
    end)

    it("gives the flat price for 14 flat days", function()
        local days = {}
        for d = TODAY - 13, TODAY - 1 do
            days[#days + 1] = entry(d, 5000)
        end
        local today = { day = TODAY, snaps = { snap(NOW, 5000) } }
        local r = S.Compute(record(days, nil, today), NOW)
        assert.are.equal(5000, r.scanMarket)
        assert.are.equal(14, r.scanSamples)
    end)

    -- Hand calculation, halfLifeDays = 1: today 200 (weight 1), yesterday 100
    -- (weight 0.5). (200 * 1 + 100 * 0.5) / 1.5 = 166.67, rounded to 167.
    it("weights newer days more", function()
        local days = { entry(TODAY - 1, 100) }
        local today = { day = TODAY, snaps = { snap(NOW, 200) } }
        local r = S.Compute(record(days, nil, today), NOW, { halfLifeDays = 1 })
        assert.are.equal(167, r.scanMarket)
        local plain = S.Compute(record(days, nil, today), NOW)
        assert.is_true(plain.scanMarket > 150 and plain.scanMarket < 200)
    end)

    it("ignores days outside the window", function()
        local days = { entry(TODAY - 14, 9000), entry(TODAY - 2, 100), entry(TODAY - 1, 100) }
        local r = S.Compute(record(days), NOW)
        assert.are.equal(100, r.scanMarket)
        assert.are.equal(2, r.scanSamples)
        assert.are.equal(3, r.scanDays)
    end)

    it("includes the day at the window edge", function()
        local r = S.Compute(record({ entry(TODAY - 13, 700) }), NOW)
        assert.are.equal(700, r.scanMarket)
        assert.are.equal(1, r.scanSamples)
    end)

    -- Days 1 and 3 ago, halfLifeDays = 1: weights 0.5 and 0.125.
    -- (300 * 0.5 + 100 * 0.125) / 0.625 = 260. The gap day has no weight.
    it("skips a gap day", function()
        local days = { entry(TODAY - 3, 100), entry(TODAY - 1, 300) }
        local r = S.Compute(record(days), NOW, { halfLifeDays = 1 })
        assert.are.equal(260, r.scanMarket)
        assert.are.equal(2, r.scanSamples)
    end)

    it("averages history within the history window", function()
        local days = { entry(TODAY - 61, 9000), entry(TODAY - 60, 9000), entry(TODAY - 59, 100), entry(TODAY - 1, 300) }
        local today = { day = TODAY, snaps = { snap(NOW, 5000) } }
        local r = S.Compute(record(days, nil, today), NOW)
        assert.are.equal(200, r.scanHistorical)
        assert.are.equal(2, r.scanDays)
    end)

    it("rounds half up", function()
        local days = { entry(TODAY - 2, 100), entry(TODAY - 1, 101) }
        local r = S.Compute(record(days), NOW)
        assert.are.equal(101, r.scanHistorical) -- 100.5
        local today = { day = TODAY, snaps = { snap(NOW, 10), snap(NOW, 11) } }
        assert.are.equal(11, S.Compute(record(nil, nil, today), NOW).scanMarket) -- 10.5
    end)

    it("does not change the record", function()
        local days = { entry(TODAY - 3, 100), entry(TODAY - 1, 300) }
        local latest = { time = NOW - 60, min = 1, market = 2, qty = 3, auctions = 1, partial = true }
        local today = { day = TODAY, snaps = { snap(NOW, 200) } }
        local rec = record(days, latest, today)
        local function dump(t)
            local keys = {}
            for k in pairs(t) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            local out = {}
            for _, k in ipairs(keys) do
                local v = t[k] or t[tonumber(k)]
                out[#out + 1] = k .. "=" .. (type(v) == "table" and "{" .. dump(v) .. "}" or tostring(v))
            end
            return table.concat(out, ",")
        end
        local snapshot = dump(rec)
        S.Compute(rec, NOW)
        assert.are.equal(snapshot, dump(rec))
    end)

    it("honours option overrides", function()
        local days = { entry(TODAY - 5, 100), entry(TODAY - 1, 300) }
        local r = S.Compute(record(days), NOW, { windowDays = 3, historyDays = 3 })
        assert.are.equal(300, r.scanMarket)
        assert.are.equal(1, r.scanSamples)
        assert.are.equal(300, r.scanHistorical)
        assert.are.equal(1, r.scanDays)
    end)

    describe("scanLow and scanHigh", function()
        it("uses latest only for low", function()
            local latest = { time = NOW - 60, min = 900, market = 1000, qty = 1, auctions = 1, partial = false }
            local r = S.Compute(record(nil, latest), NOW)
            assert.are.equal(900, r.scanLow)
            assert.is_nil(r.scanHigh)
        end)

        it("counts a partial latest for low", function()
            local latest = { time = NOW - 60, min = 400, market = 1000, qty = 1, auctions = 1, partial = true }
            assert.are.equal(400, S.Compute(record(nil, latest), NOW).scanLow)
        end)

        it("ignores a latest outside the window", function()
            local latest = { time = (TODAY - 14) * DAY, min = 5, market = 9, qty = 1, auctions = 1, partial = false }
            local r = S.Compute(record(nil, latest), NOW)
            assert.is_nil(r.scanLow)
            local edge = { time = (TODAY - 13) * DAY, min = 5, market = 9, qty = 1, auctions = 1, partial = false }
            assert.are.equal(5, S.Compute(record(nil, edge), NOW).scanLow)
        end)

        it("uses the snaps of today", function()
            local today = { day = TODAY, snaps = { snap(NOW - 100, 1000), snap(NOW, 2000) } }
            local r = S.Compute(record(nil, nil, today), NOW)
            assert.are.equal(990, r.scanLow)
            assert.are.equal(1500, r.scanHigh)
        end)

        it("uses the lowest min and highest market over 14 days", function()
            local days = { entry(TODAY - 13, 800), entry(TODAY - 5, 300), entry(TODAY - 1, 600) }
            local today = { day = TODAY, snaps = { snap(NOW, 1000) } }
            local latest = { time = NOW, min = 700, market = 1, qty = 1, auctions = 1, partial = false }
            local r = S.Compute(record(days, latest, today), NOW)
            assert.are.equal(290, r.scanLow)
            assert.are.equal(1000, r.scanHigh)
        end)

        it("ignores days outside the window", function()
            local days = { entry(TODAY - 14, 1), entry(TODAY - 30, 99999), entry(TODAY - 2, 500) }
            local r = S.Compute(record(days), NOW)
            assert.are.equal(490, r.scanLow)
            assert.are.equal(500, r.scanHigh)
        end)

        it("is invalid with only old data", function()
            local r = S.Compute(record({ entry(TODAY - 20, 500) }), NOW)
            assert.is_nil(r.scanLow)
            assert.is_nil(r.scanHigh)
        end)
    end)
end)