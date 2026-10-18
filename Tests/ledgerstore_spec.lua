local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("LedgerRecord")))("Flipside", ns)
assert(loadfile(manifest.path("LedgerStore")))("Flipside", ns)

local DAY = 86400
local warnings

local function Open(saved, region, ruleset)
    return ns.LedgerStore.New(saved or {}, {
        region = region or "EU",
        ruleset = ruleset or "standard",
        onWarning = function(message)
            warnings[#warnings + 1] = message
        end,
    })
end

local function rec(time, extra)
    local record = {
        time = time, char = "Alice-Realm", type = "sale", source = "ahSale", item = "25", qty = 1, money = 100,
    }
    for k, v in pairs(extra or {}) do
        record[k] = v
    end
    return record
end

describe("LedgerStore", function()
    before_each(function()
        warnings = {}
    end)

    it("needs a region and a ruleset", function()
        assert.has_error(function()
            ns.LedgerStore.New({}, { ruleset = "standard" })
        end)
        assert.has_error(function()
            ns.LedgerStore.New({}, { region = "EU" })
        end)
        assert.has_error(function()
            ns.LedgerStore.New("x", { region = "EU", ruleset = "standard" })
        end)
    end)

    describe("Move", function()
        it("stores records under region, ruleset and character", function()
            local saved = {}
            local store = Open(saved)
            local count = store:Move({ rec(10), rec(20, { char = "Bob-Realm" }), rec(30) })
            assert.are.equal(3, count)
            assert.are.equal(2, #saved.records.EU.standard["Alice-Realm"])
            assert.are.equal(1, #saved.records.EU.standard["Bob-Realm"])
        end)

        it("keeps other regions and rulesets apart", function()
            local saved = {}
            Open(saved, "EU", "standard"):Move({ rec(10) })
            Open(saved, "US", "standard"):Move({ rec(20) })
            Open(saved, "EU", "tbc-anniversary"):Move({ rec(30) })
            assert.are.equal(1, #saved.records.EU.standard["Alice-Realm"])
            assert.are.equal(1, #saved.records.US.standard["Alice-Realm"])
            assert.are.equal(1, #saved.records.EU["tbc-anniversary"]["Alice-Realm"])
            assert.are.equal(1, #Open(saved, "US", "standard"):Records())
        end)

        it("skips an invalid record", function()
            local store = Open()
            assert.are.equal(1, store:Move({ rec(10), { time = 1 } }))
        end)

        it("stamps the schema version", function()
            local saved = {}
            Open(saved)
            assert.are.equal(1, saved._schema)
        end)

        it("is read-only for a newer schema and warns", function()
            local saved = { _schema = 9 }
            local store = Open(saved)
            assert.is_true(store:IsReadOnly())
            assert.are.equal(1, #warnings)
            assert.is_false(store:Move({ rec(10) }))
            assert.is_nil(saved.records)
        end)
    end)

    describe("queries", function()
        local store
        before_each(function()
            store = Open()
            store:Move({
                rec(300),
                rec(100),
                rec(200, { char = "Bob-Realm", type = "purchase", source = "ahPurchase", money = 40 }),
                rec(400, { char = "Bob-Realm", source = "ahSale", money = 60, qty = 3 }),
            })
        end)

        it("lists the characters", function()
            assert.are.same({ "Alice-Realm", "Bob-Realm" }, store:Characters())
        end)

        it("returns the records of all characters, oldest first", function()
            local times = {}
            for _, r in ipairs(store:Records()) do
                times[#times + 1] = r.time
            end
            assert.are.same({ 100, 200, 300, 400 }, times)
        end)

        it("filters by character", function()
            assert.are.equal(2, #store:Records({ char = "Alice-Realm" }))
            assert.are.equal(0, #store:Records({ char = "Nobody-Realm" }))
        end)

        it("filters by an inclusive date range", function()
            assert.are.equal(2, #store:Records({ fromTime = 200, toTime = 300 }))
            assert.are.equal(3, #store:Records({ fromTime = 200 }))
            assert.are.equal(2, #store:Records({ toTime = 200 }))
        end)

        it("sums by source with the money in and out", function()
            local sums = store:SumsBySource()
            assert.are.same({ count = 3, qty = 5, moneyIn = 260, moneyOut = 0 }, sums.ahSale)
            assert.are.same({ count = 1, qty = 1, moneyIn = 0, moneyOut = 40 }, sums.ahPurchase)
        end)

        it("sums one character in a range", function()
            local sums = store:SumsBySource({ char = "Bob-Realm", fromTime = 300 })
            assert.are.same({ count = 1, qty = 3, moneyIn = 60, moneyOut = 0 }, sums.ahSale)
            assert.is_nil(sums.ahPurchase)
        end)

        it("leaves log records out of the sums", function()
            store:Move({ { time = 500, char = "Alice-Realm", type = "log", item = "25", qty = 1, money = 9 } })
            local sums = store:SumsBySource()
            assert.is_nil(sums.log)
            assert.are.equal(3, sums.ahSale.count)
        end)
    end)

    describe("Compact", function()
        local now = 300 * DAY + 5000

        it("turns records older than the retention days into daily sums", function()
            local saved = {}
            local store = Open(saved)
            local old = 100 * DAY
            store:Move({
                rec(old + 10, { money = 50, qty = 2 }),
                rec(old + 20, { money = 70, qty = 1 }),
                rec(old + 30, { item = "26", money = 5 }),
                rec(old + 40, { type = "purchase", source = "ahPurchase", money = 9 }),
                rec(old + 50, { type = "expired", source = "ahExpired", money = 0 }),
                rec(250 * DAY, { money = 1 }),
            })
            assert.are.equal(5, store:Compact(now))
            assert.are.equal(1, #saved.records.EU.standard["Alice-Realm"])
            local sums = saved.sums.EU.standard["Alice-Realm"]
            assert.are.equal(4, #sums)
            local found
            for _, s in ipairs(sums) do
                if s.source == "ahSale" and s.item == "25" then
                    found = s
                end
            end
            assert.are.same(
                { day = 100, source = "ahSale", item = "25", count = 2, qty = 3, moneyIn = 120, moneyOut = 0 }, found)
        end)

        it("compacts at the UTC day boundary", function()
            local saved = {}
            local store = Open(saved)
            -- Today is day 300 and the retention is 180 days, so day 119 is compacted and day 120 is kept.
            store:Move({ rec(120 * DAY - 1), rec(120 * DAY) })
            store:Compact(now)
            local kept = saved.records.EU.standard["Alice-Realm"]
            assert.are.equal(1, #kept)
            assert.are.equal(120 * DAY, kept[1].time)
            assert.are.equal(119, saved.sums.EU.standard["Alice-Realm"][1].day)
        end)

        it("uses the retention days option", function()
            local saved = {}
            local store = Open(saved)
            store:Move({ rec(290 * DAY) })
            assert.are.equal(0, store:Compact(now))
            assert.are.equal(1, store:Compact(now, { retentionDays = 5, force = true }))
        end)

        it("adds to a daily sum that exists", function()
            local saved = {}
            local store = Open(saved)
            store:Move({ rec(10 * DAY, { money = 10 }) })
            store:Compact(now)
            store:Move({ rec(10 * DAY + 5, { money = 20 }) })
            store:Compact(now, { force = true })
            local sums = saved.sums.EU.standard["Alice-Realm"]
            assert.are.equal(1, #sums)
            assert.are.equal(2, sums[1].count)
            assert.are.equal(30, sums[1].moneyIn)
        end)

        it("runs once for each day", function()
            local saved = {}
            local store = Open(saved)
            store:Move({ rec(10 * DAY) })
            assert.are.equal(1, store:Compact(now))
            store:Move({ rec(11 * DAY) })
            assert.are.equal(0, store:Compact(now + 100))
            assert.are.equal(1, store:Compact(now + DAY))
        end)

        it("deletes old log records with no sum", function()
            local saved = {}
            local store = Open(saved)
            local log = { char = "Alice-Realm", type = "log", item = "25", qty = 1 }
            store:Move({
                { time = now - 31 * DAY, char = log.char, type = "log", item = "25", qty = 1 },
                { time = now - 5 * DAY, char = log.char, type = "log", item = "25", qty = 1 },
            })
            assert.are.equal(1, store:Compact(now))
            assert.are.equal(1, #saved.records.EU.standard["Alice-Realm"])
            assert.are.equal(0, #saved.sums.EU.standard["Alice-Realm"])
        end)

        it("compacts every region and ruleset", function()
            local saved = {}
            Open(saved, "US"):Move({ rec(10 * DAY) })
            Open(saved, "EU"):Move({ rec(10 * DAY) })
            assert.are.equal(2, Open(saved, "EU"):Compact(now))
            assert.are.equal(1, #saved.sums.US.standard["Alice-Realm"])
        end)

        it("does nothing when read-only", function()
            local store = Open({ _schema = 9 })
            assert.are.equal(0, store:Compact(now))
        end)

        it("keeps the sums in the queries", function()
            local store = Open()
            store:Move({ rec(10 * DAY, { money = 50 }), rec(250 * DAY, { money = 7 }) })
            store:Compact(now)
            local sums = store:SumsBySource()
            assert.are.equal(2, sums.ahSale.count)
            assert.are.equal(57, sums.ahSale.moneyIn)
            local old = store:SumsBySource({ toTime = 20 * DAY })
            assert.are.equal(1, old.ahSale.count)
            assert.are.equal(0, #store:Records({ toTime = 20 * DAY }))
        end)
    end)
end)

describe("LedgerStore Revision", function()
    it("grows when records are moved in and when records are compacted", function()
        warnings = {}
        local store = Open()
        assert.are.equal(0, store:Revision())
        store:Move({ rec(10), rec(20) })
        assert.are.equal(2, store:Revision())
        store:Move({})
        assert.are.equal(2, store:Revision())
        store:Compact(10 + 400 * DAY, { force = true })
        assert.is_true(store:Revision() > 2)
    end)

    describe("editing a record", function()
        local store, saved, id

        before_each(function()
            saved = {}
            store = Open(saved)
            store:Move({ rec(1000), rec(2000, { money = 300, qty = 2 }) })
            id = store:Records()[1].id
        end)

        local function first()
            return store:Records()[1]
        end

        it("gives a new record a stable id and keeps it", function()
            assert.is_string(id)
            assert.are_not.equal(id, store:Records()[2].id)
            assert.are.equal(id, store:IdOf("Alice-Realm", first()))
        end)

        it("gives an old record with no id one when it is looked up, and keeps it", function()
            local old = rec(5, { char = "Old-Realm", item = "9", money = 4 })
            saved.records.EU.standard["Old-Realm"] = { old }
            local oldId = store:IdOf("Old-Realm", old)
            assert.is_string(oldId)
            assert.are.equal(oldId, old.id)
            assert.are.equal(oldId, store:IdOf("Old-Realm", old))
            assert.is_true(store:UpdateRecord("Old-Realm", oldId, { money = 8 }))
            assert.are.equal(8, old.money)
        end)

        it("finds no id for a record that is not stored under the character", function()
            assert.is_nil(store:IdOf("Bob-Realm", first()))
            assert.is_nil(store:IdOf("Alice-Realm", rec(1)))
        end)

        it("changes the fields and keeps the first values in orig", function()
            local ok = store:UpdateRecord("Alice-Realm", id, { money = 250, qty = 5, item = "30", note = "fix" })
            assert.is_true(ok)
            local record = first()
            assert.are.equal(250, record.money)
            assert.are.equal(5, record.qty)
            assert.are.equal("30", record.item)
            assert.are.equal("fix", record.note)
            assert.is_true(record.edited)
            assert.are.same({ source = "ahSale", type = "sale", item = "25", qty = 1, money = 100 }, record.orig)
            assert.are.equal(1000, record.time)
        end)

        it("keeps the first values over a second edit", function()
            store:UpdateRecord("Alice-Realm", id, { money = 250 })
            store:UpdateRecord("Alice-Realm", id, { money = 260, note = "x" })
            assert.are.equal(100, first().orig.money)
            assert.are.equal(260, first().money)
        end)

        it("does nothing when no value changes", function()
            local before = store:Revision()
            assert.is_true(store:UpdateRecord("Alice-Realm", id, { money = 100, item = "25" }))
            assert.is_nil(first().edited)
            assert.is_nil(first().orig)
            assert.are.equal(before, store:Revision())
        end)

        it("grows the revision on an edit and on a revert", function()
            local before = store:Revision()
            store:UpdateRecord("Alice-Realm", id, { money = 1 })
            assert.are.equal(before + 1, store:Revision())
            store:RevertRecord("Alice-Realm", id)
            assert.are.equal(before + 2, store:Revision())
        end)

        it("clears the item and the note with an empty text", function()
            store:UpdateRecord("Alice-Realm", id, { note = "a" })
            store:UpdateRecord("Alice-Realm", id, { note = "", item = "", qty = 0 })
            assert.is_nil(first().note)
            assert.are.equal("", first().item)
        end)

        it("drops a stored item name when the item changes", function()
            store:Move({ rec(3000, { item = "", itemName = "Old Name", qty = 1 }) })
            local named = store:Records()[3]
            assert.is_true(store:UpdateRecord("Alice-Realm", named.id, { item = "77" }))
            assert.is_nil(named.itemName)
            assert.are.equal("Old Name", named.orig.itemName)
        end)

        it("keeps the sums right when the amount changes", function()
            store:UpdateRecord("Alice-Realm", id, { money = 700 })
            local totals = store:SumsBySource()
            assert.are.same({ count = 2, qty = 3, moneyIn = 1000, moneyOut = 0 }, totals.ahSale)
        end)

        it("moves the money to the other source and type when the source changes", function()
            assert.is_true(store:UpdateRecord("Alice-Realm", id, { source = "vendorPurchase" }))
            assert.are.equal("expense", first().type)
            local totals = store:SumsBySource()
            assert.are.same({ count = 1, qty = 2, moneyIn = 300, moneyOut = 0 }, totals.ahSale)
            assert.are.same({ count = 1, qty = 1, moneyIn = 0, moneyOut = 100 }, totals.vendorPurchase)
        end)

        it("keeps the day, so a later compaction uses the edited values", function()
            store:UpdateRecord("Alice-Realm", id, { money = 700 })
            assert.are.equal(1000, first().time)
            store:Compact(1000 + 400 * DAY, { force = true })
            local sums = store:Sums()
            local total = 0
            for _, sum in ipairs(sums) do
                total = total + sum.moneyIn
            end
            assert.are.equal(1000, total)
        end)

        it("restores the first values on a revert", function()
            store:UpdateRecord("Alice-Realm", id,
                { source = "vendorPurchase", money = 5, note = "n", item = "", qty = 0 })
            assert.is_true(store:RevertRecord("Alice-Realm", id))
            local record = first()
            local expected = rec(1000)
            expected.id = id
            assert.are.same(expected, record)
        end)

        it("refuses a revert of a record that is not edited", function()
            local ok, message = store:RevertRecord("Alice-Realm", id)
            assert.is_false(ok)
            assert.is_string(message)
        end)

        it("refuses bad values and changes nothing", function()
            for _, changes in ipairs({
                { money = -1 }, { money = 1.5 }, { money = "5" }, { qty = -1 }, { qty = 1.5 },
                { source = "nothing" }, { source = 5 }, { item = 5 }, { note = 5 }, { qty = 1, item = "" },
                { time = 5 }, { type = "loot" }, { orig = {} },
            }) do
                local ok, message = store:UpdateRecord("Alice-Realm", id, changes)
                assert.is_false(ok)
                assert.is_string(message)
            end
            assert.are.equal(100, first().money)
            assert.is_nil(first().edited)
            assert.is_nil(first().orig)
        end)

        it("refuses an unknown record, a log record and a read-only store", function()
            assert.is_false((store:UpdateRecord("Alice-Realm", "nope", { money = 1 })))
            assert.is_false((store:UpdateRecord("Bob-Realm", id, { money = 1 })))
            store:Move({ { time = 9, char = "Alice-Realm", type = "log", item = "25", qty = 1 } })
            local log = store:Records()[1]
            assert.is_false((store:UpdateRecord("Alice-Realm", log.id, { note = "x" })))
            local data = { ["A-R"] = { rec(1, { id = "i" }) } }
            local locked = Open({ _schema = 9, records = { EU = { standard = data } } })
            assert.is_false((locked:UpdateRecord("A-R", "i", { money = 1 })))
            assert.is_false((locked:RevertRecord("A-R", "i")))
        end)
    end)
end)