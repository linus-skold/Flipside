describe("ScanBucket", function()
    local SB, SR, Clock
    local DAY = 86400

    before_each(function()
        local ns = {}
        assert(loadfile("Services/ScanClock.lua"))("Flipside", ns)
        assert(loadfile("Services/ScanRecord.lua"))("Flipside", ns)
        assert(loadfile("Services/ScanBucket.lua"))("Flipside", ns)
        SB, SR, Clock = ns.ScanBucket, ns.ScanRecord, ns.ScanClock
    end)

    local function Snap(min, market, qty)
        return { min = min, market = market, qty = qty or 10, auctions = 2 }
    end

    local function Valid(record)
        assert.is_true(SR.Validate(record))
        local back = assert(SR.Decode(SR.Encode(record)))
        assert.are.same(record, back)
    end

    local function Rec()
        return SR.New()
    end

    describe("RollUp", function()
        it("rolls one snapshot into a day", function()
            local r = Rec()
            SB.Apply(r, Snap(100, 200, 5), 10 * DAY + 5, false)
            assert.is_true(SB.RollUp(r, 11))
            assert.is_nil(r.today)
            assert.are.same({ { day = 10, min = 100, market = 200, qty = 5, scans = 1 } }, r.days)
            Valid(r)
        end)

        it("averages four snapshots and rounds half up", function()
            local r = Rec()
            local mins = { 1, 2, 2, 2 }
            for i, m in ipairs(mins) do
                SB.Apply(r, Snap(m, 10, 3), 10 * DAY + i, false)
            end
            SB.RollUp(r, 11)
            assert.are.equal(2, r.days[1].min)
            assert.are.equal(4, r.days[1].scans)
            r = Rec()
            SB.Apply(r, Snap(1, 1, 1), 10 * DAY + 1, false)
            SB.Apply(r, Snap(2, 2, 2), 10 * DAY + 2, false)
            SB.RollUp(r, 11)
            assert.are.equal(2, r.days[1].min)
            assert.are.equal(2, r.days[1].qty)
            Valid(r)
        end)

        it("is a no-op the second time and on the same day", function()
            local r = Rec()
            SB.Apply(r, Snap(100, 200), 10 * DAY, false)
            assert.is_false(SB.RollUp(r, 10))
            assert.is_true(SB.RollUp(r, 11))
            assert.is_false(SB.RollUp(r, 11))
            assert.are.equal(1, #r.days)
        end)

        it("replaces an existing record of that day and keeps order", function()
            local r = Rec()
            r.days = { { day = 8, min = 1, market = 1, qty = 1, scans = 1 },
                { day = 10, min = 9, market = 9, qty = 9, scans = 9 },
                { day = 12, min = 1, market = 1, qty = 1, scans = 1 } }
            r.today = { day = 10, snaps = { { time = 1, min = 50, market = 60, qty = 7, auctions = 1 } } }
            SB.RollUp(r, 13)
            assert.are.equal(3, #r.days)
            assert.are.same({ day = 10, min = 50, market = 60, qty = 7, scans = 1 }, r.days[2])
            Valid(r)
        end)

        it("inserts an earlier day in order", function()
            local r = Rec()
            r.days = { { day = 12, min = 1, market = 1, qty = 1, scans = 1 } }
            r.today = { day = 10, snaps = { { time = 1, min = 5, market = 5, qty = 5, auctions = 1 } } }
            SB.RollUp(r, 13)
            assert.are.equal(10, r.days[1].day)
            assert.are.equal(12, r.days[2].day)
        end)
    end)

    describe("Apply", function()
        it("partial scan changes only latest", function()
            local r = Rec()
            SB.Apply(r, Snap(100, 200), 10 * DAY, false)
            SB.Apply(r, Snap(50, 60), 10 * DAY + 100, true)
            assert.is_true(r.latest.partial)
            assert.are.equal(50, r.latest.min)
            assert.are.equal(10 * DAY + 100, r.latest.time)
            assert.are.equal(1, #r.today.snaps)
            Valid(r)
        end)

        it("partial scan on an empty record makes no today", function()
            local r = Rec()
            SB.Apply(r, Snap(50, 60), 10 * DAY, true)
            assert.is_nil(r.today)
            Valid(r)
        end)

        it("complete scan replaces latest and adds a snapshot", function()
            local r = Rec()
            SB.Apply(r, Snap(100, 200), 10 * DAY + 1.5, false)
            SB.Apply(r, Snap(110, 210), 10 * DAY + 50, false)
            assert.is_false(r.latest.partial)
            assert.are.equal(110, r.latest.min)
            assert.are.equal(10 * DAY + 50, r.latest.time)
            assert.are.equal(2, #r.today.snaps)
            assert.are.equal(10, r.today.day)
            assert.are.equal(10 * DAY + 1, r.today.snaps[1].time)
            Valid(r)
        end)

        it("drops the oldest snapshot after the fourth", function()
            local r = Rec()
            for i = 1, Clock.MAX_SNAPSHOTS_PER_DAY + 1 do
                SB.Apply(r, Snap(i, i), 10 * DAY + i, false)
            end
            assert.are.equal(4, #r.today.snaps)
            assert.are.equal(2, r.today.snaps[1].min)
            assert.are.equal(5, r.today.snaps[4].min)
            Valid(r)
        end)

        it("rolls up first on a new day", function()
            local r = Rec()
            SB.Apply(r, Snap(100, 200), 10 * DAY, false)
            SB.Apply(r, Snap(300, 400), 11 * DAY, false)
            assert.are.equal(1, #r.days)
            assert.are.equal(10, r.days[1].day)
            assert.are.equal(11, r.today.day)
            assert.are.equal(1, #r.today.snaps)
            Valid(r)
        end)

        it("raises an error for an invalid snap", function()
            local r = Rec()
            assert.has_error(function() SB.Apply(r, nil, 10 * DAY, false) end)
            assert.has_error(function() SB.Apply(r, { min = 1, market = 1, qty = 1 }, 10 * DAY, false) end)
            assert.has_error(function() SB.Apply(r, Snap(-1, 1), 10 * DAY, false) end)
            assert.has_error(function() SB.Apply(r, Snap(1.5, 1), 10 * DAY, false) end)
            assert.is_nil(r.latest)
        end)
    end)

    describe("Prune", function()
        local function WithDays()
            local r = Rec()
            for d = 1, 5 do
                r.days[d] = { day = 100 + d, min = 1, market = 1, qty = 1, scans = 1 }
            end
            return r
        end

        it("removes the boundary day and keeps the next", function()
            local r = WithDays()
            assert.are.equal(3, SB.Prune(r, 163, 60))
            assert.are.equal(104, r.days[1].day)
            assert.are.equal(2, #r.days)
            Valid(r)
        end)

        it("uses the default retention", function()
            local r = WithDays()
            assert.are.equal(0, SB.Prune(r, 100 + Clock.RETENTION_DAYS_DEFAULT))
            assert.are.equal(1, SB.Prune(r, 101 + Clock.RETENTION_DAYS_DEFAULT))
        end)

        it("accepts a custom retention and rejects a bad one", function()
            local r = WithDays()
            assert.are.equal(4, SB.Prune(r, 106, 2))
            assert.has_error(function() SB.Prune(r, 106, 0) end)
            assert.has_error(function() SB.Prune(r, 106, 1.5) end)
        end)
    end)

    describe("IsEmpty and MarkUnseen", function()
        it("reports empty records", function()
            local r = Rec()
            assert.is_true(SB.IsEmpty(r))
            SB.Apply(r, Snap(1, 1), 10 * DAY, true)
            assert.is_false(SB.IsEmpty(r))
            local r2 = Rec()
            r2.days[1] = { day = 1, min = 1, market = 1, qty = 1, scans = 1 }
            assert.is_false(SB.IsEmpty(r2))
        end)

        it("MarkUnseen rolls up and keeps latest", function()
            local r = Rec()
            SB.Apply(r, Snap(100, 200), 10 * DAY, false)
            local latest = r.latest
            assert.is_nil(SB.MarkUnseen(r, 11 * DAY))
            assert.are.equal(latest, r.latest)
            assert.is_nil(r.today)
            assert.are.equal(1, #r.days)
            Valid(r)
        end)

        it("MarkUnseen on the same day changes nothing", function()
            local r = Rec()
            SB.Apply(r, Snap(100, 200), 10 * DAY, false)
            SB.MarkUnseen(r, 10 * DAY + 5)
            assert.are.equal(1, #r.today.snaps)
            assert.are.equal(0, #r.days)
        end)
    end)
end)
