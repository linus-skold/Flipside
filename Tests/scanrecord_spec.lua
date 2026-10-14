describe("ScanRecord", function()
    local ScanRecord

    before_each(function()
        local ns = {}
        assert(loadfile("Services/ScanRecord.lua"))("Flipside", ns)
        ScanRecord = ns.ScanRecord
    end)

    local function snap(i)
        return { time = 1760000000 + i * 3600, min = 5000 + i, market = 5200 + i, qty = 40 + i, auctions = 6 }
    end

    local function latest(partial)
        return { time = 1760000000, min = 5000, market = 5200, qty = 40, auctions = 6, partial = partial }
    end

    local function today(n)
        local snaps = {}
        for i = 1, n do
            snaps[i] = snap(i)
        end
        return { day = 20376, snaps = snaps }
    end

    local function days(n)
        local list = {}
        for i = 1, n do
            list[i] = { day = 20300 + i, min = 4000 + i, market = 4100 + i, qty = 100 + i, scans = 3 }
        end
        return list
    end

    local function roundTrip(record)
        local back, err = ScanRecord.Decode(ScanRecord.Encode(record))
        assert.is_nil(err)
        assert.same(record, back)
    end

    describe("New", function()
        it("returns an empty valid record", function()
            local r = ScanRecord.New()
            assert.is_nil(r.latest)
            assert.is_nil(r.today)
            assert.same({}, r.days)
            assert.is_true(ScanRecord.Validate(r))
        end)
    end)

    describe("round trip", function()
        it("keeps an empty record", function()
            roundTrip(ScanRecord.New())
        end)

        it("keeps latest only, partial true and false", function()
            roundTrip({ latest = latest(true), days = {} })
            roundTrip({ latest = latest(false), days = {} })
        end)

        it("keeps today with 1 and 4 snaps", function()
            roundTrip({ today = today(1), days = {} })
            roundTrip({ today = today(4), days = {} })
        end)

        it("keeps 60 days of history", function()
            roundTrip({ days = days(60) })
        end)

        it("keeps all sections together", function()
            roundTrip({ latest = latest(true), today = today(3), days = days(10) })
        end)

        it("keeps large copper values", function()
            local l = latest(false)
            l.min, l.market = 9999999999, 9999999999
            roundTrip({ latest = l, days = { { day = 1, min = 9999999999, market = 9999999999, qty = 1, scans = 1 } } })
        end)

        it("keeps zero values", function()
            roundTrip({ latest = { time = 0, min = 0, market = 0, qty = 0, auctions = 0, partial = false }, days = {} })
        end)
    end)

    describe("Encode", function()
        it("writes the documented form", function()
            local r = { latest = latest(false), today = today(1), days = days(1) }
            assert.equals("1;1760000000,5000,5200,40,6,0;20376|1760003600,5001,5201,41,6;20301,4001,4101,101,3",
                ScanRecord.Encode(r))
        end)

        it("writes an empty record as version and empty fields", function()
            assert.equals("1;;;", ScanRecord.Encode(ScanRecord.New()))
        end)

        it("uses only digits and the separators , ; |", function()
            local text = ScanRecord.Encode({ latest = latest(true), today = today(4), days = days(5) })
            assert.is_nil(text:find("[^%d,;|]"))
        end)

        it("raises an error for an invalid record", function()
            assert.has_error(function() ScanRecord.Encode({ days = { { day = -1 } } }) end)
            assert.has_error(function() ScanRecord.Encode(nil) end)
        end)

        it("stays under 2000 characters with latest, 4 snaps and 60 days", function()
            local text = ScanRecord.Encode({ latest = latest(false), today = today(4), days = days(60) })
            print("encoded length: " .. #text)
            assert.is_true(#text < 2000)
        end)
    end)

    describe("Validate", function()
        local function bad(record)
            local ok, err = ScanRecord.Validate(record)
            assert.is_false(ok)
            assert.is_string(err)
        end

        it("accepts valid records", function()
            assert.is_true(ScanRecord.Validate({ latest = latest(true), today = today(4), days = days(3) }))
        end)

        it("rejects wrong types", function()
            bad(nil)
            bad("x")
            bad({})
            bad({ days = "x" })
            bad({ days = {}, latest = "x" })
            bad({ days = {}, today = "x" })
            bad({ days = {}, latest = { time = "1", min = 1, market = 1, qty = 1, auctions = 1, partial = false } })
            local l = latest(false)
            l.partial = 0
            bad({ days = {}, latest = l })
        end)

        it("rejects negative money", function()
            local l = latest(false)
            l.min = -1
            bad({ days = {}, latest = l })
        end)

        it("rejects non-integers", function()
            local l = latest(false)
            l.market = 1.5
            bad({ days = {}, latest = l })
            bad({ days = { { day = 1.5, min = 1, market = 1, qty = 1, scans = 1 } } })
            bad({ days = { { day = 1, min = 1, market = 1, qty = 1, scans = 0 / 0 } } })
            bad({ days = { { day = 1, min = 1, market = math.huge, qty = 1, scans = 1 } } })
        end)

        it("rejects unsorted and duplicate days", function()
            local d = days(3)
            d[1], d[2] = d[2], d[1]
            bad({ days = d })
            local dup = days(2)
            dup[2].day = dup[1].day
            bad({ days = dup })
        end)

        it("rejects more than 4 snaps", function()
            bad({ days = {}, today = today(5) })
        end)

        it("rejects empty snaps", function()
            bad({ days = {}, today = { day = 1, snaps = {} } })
            bad({ days = {}, today = { day = 1 } })
        end)
    end)

    describe("Decode failures", function()
        local function fails(text)
            local record, err = ScanRecord.Decode(text)
            assert.is_nil(record)
            assert.is_string(err)
        end

        it("rejects nil and non-string input", function()
            fails(nil)
            fails(5)
            fails({})
        end)

        it("rejects an empty string", function()
            fails("")
        end)

        it("rejects a wrong version", function()
            fails("2;;;")
            fails("0;;;")
            fails("x;;;")
        end)

        it("rejects missing or extra sections", function()
            fails("1")
            fails("1;;")
            fails("1;;;;")
        end)

        it("rejects non-numeric fields", function()
            fails("1;1,2,3,4,5,x;;")
            fails("1;1,2,3,4,-5,0;;")
            fails("1;1,2,3,4,5.5,0;;")
            fails("1;1,2,3,4,5,2;;")
            fails("1;;x|1,2,3,4,5;")
            fails("1;;;1,2,3,4,a")
            fails("1;;;1,2,3,4, 5")
        end)

        it("rejects numbers with too many digits", function()
            fails("1;;;1,2,3,4,1234567890123456")
        end)

        it("rejects wrong field counts", function()
            fails("1;1,2,3,4,5;;")
            fails("1;1,2,3,4,5,0,1;;")
            fails("1;;5|1,2,3,4;")
            fails("1;;5|1,2,3,4,5,6;")
            fails("1;;;1,2,3,4")
            fails("1;;;1,2,3,4,5,6")
            fails("1;;;1,2,3,4,5|")
        end)

        it("rejects today without snaps", function()
            fails("1;;5;")
            fails("1;;5|;")
        end)

        it("rejects too many snaps", function()
            local s = "1,2,3,4,5"
            fails("1;;5|" .. table.concat({ s, s, s, s, s }, "|") .. ";")
        end)

        it("rejects unsorted and duplicate days", function()
            fails("1;;;2,1,1,1,1|1,1,1,1,1")
            fails("1;;;1,1,1,1,1|1,1,1,1,1")
        end)
    end)
end)
