local manifest = require("Tests.manifest")
describe("ScanStore", function()
    local ScanStore, ScanRecord

    before_each(function()
        local ns = {}
        assert(loadfile(manifest.path("ScanRecord")))("Flipside", ns)
        assert(loadfile(manifest.path("ScanStore")))("Flipside", ns)
        ScanStore = ns.ScanStore
        ScanRecord = ns.ScanRecord
    end)

    local function deepCopy(v)
        if type(v) ~= "table" then
            return v
        end
        local c = {}
        for k, x in pairs(v) do
            c[k] = deepCopy(x)
        end
        return c
    end

    local function record(min)
        local r = ScanRecord.New()
        r.latest = { time = 1760000000, min = min or 5000, market = 5200, qty = 40, auctions = 6, partial = false }
        return r
    end

    local function open(saved, extra)
        local warnings = {}
        local options = {
            region = "EU",
            ruleset = "standard",
            schemaVersion = 1,
            onWarning = function(m)
                warnings[#warnings + 1] = m
            end,
        }
        for k, v in pairs(extra or {}) do
            options[k] = v
        end
        return ScanStore.New(saved, options), warnings
    end

    describe("New", function()
        it("creates the structure in an empty table", function()
            local saved = {}
            local store = open(saved, { meta = { isStandard = true } })
            assert.same({
                _schema = 1,
                data = { EU = { standard = { meta = { isStandard = true }, items = {} } } },
            }, saved)
            assert.is_false(store:IsReadOnly())
            assert.equals(1, store:GetSchemaVersion())
            assert.equals("EU", store:GetRegion())
            assert.equals("standard", store:GetRuleset())
        end)

        it("rejects bad arguments", function()
            assert.has_error(function() ScanStore.New(nil, {}) end)
            assert.has_error(function() ScanStore.New({}, { ruleset = "standard", schemaVersion = 1 }) end)
            assert.has_error(function() ScanStore.New({}, { region = "EU", schemaVersion = 1 }) end)
            assert.has_error(function() ScanStore.New({}, { region = "EU", ruleset = "standard" }) end)
            assert.has_error(function()
                ScanStore.New({}, { region = "EU", ruleset = "standard", schemaVersion = 1.5 })
            end)
        end)

        it("keeps regions and rulesets separate", function()
            local saved = {}
            local eu = open(saved)
            eu:Put("1", record(1))
            eu:Flush()
            local us = open(saved, { region = "US" })
            local hc = open(saved, { ruleset = "hardcore" })
            assert.same({}, us:Keys())
            assert.same({}, hc:Keys())
            assert.same({ "1" }, open(saved):Keys())
            assert.is_table(saved.data.US.standard)
            assert.is_table(saved.data.EU.hardcore)
        end)

        it("keeps unknown top-level keys", function()
            local saved = { _schema = 1, extra = { a = 1 } }
            open(saved)
            assert.same({ a = 1 }, saved.extra)
        end)
    end)

    describe("records", function()
        it("returns nil for a missing key", function()
            local store = open({})
            assert.is_nil(store:Get("999"))
        end)

        it("returns the same table after Put and on a second Get", function()
            local store = open({})
            local r = record()
            assert.is_true(store:Put("1", r))
            assert.equals(r, store:Get("1"))
            local saved = {}
            local first = open(saved)
            first:Put("2", record())
            first:Flush()
            local second = open(saved)
            assert.equals(second:Get("2"), second:Get("2"))
        end)

        it("does not change the saved table before Flush", function()
            local saved = {}
            local store = open(saved)
            local before = deepCopy(saved)
            store:Put("1", record())
            store:Remove("2")
            assert.same(before, saved)
        end)

        it("raises an error for an invalid record", function()
            local store = open({})
            assert.has_error(function() store:Put("1", { days = "x" }) end)
            assert.has_error(function() store:Put("", record()) end)
            assert.same({}, store:Keys())
        end)

        it("writes encoded strings on Flush", function()
            local saved = {}
            local store = open(saved)
            local r = record(7)
            store:Put("2589#b1520", r)
            store:Put("12345", record(8))
            assert.equals(2, store:Flush())
            local text = saved.data.EU.standard.items["2589#b1520"]
            assert.equals(ScanRecord.Encode(r), text)
            assert.same(r, ScanRecord.Decode(text))
            assert.equals(0, store:Flush())
        end)

        it("removes keys on Flush", function()
            local saved = {}
            local store = open(saved)
            store:Put("1", record())
            store:Put("2", record())
            store:Flush()
            assert.is_true(store:Remove("1"))
            assert.is_nil(store:Get("1"))
            assert.is_string(saved.data.EU.standard.items["1"])
            store:Flush()
            assert.is_nil(saved.data.EU.standard.items["1"])
            assert.is_string(saved.data.EU.standard.items["2"])
        end)

        it("keeps a key that is removed and then put again", function()
            local saved = {}
            local store = open(saved)
            store:Put("1", record())
            store:Flush()
            store:Remove("1")
            store:Put("1", record(9))
            store:Flush()
            assert.equals(9, open(saved):Get("1").latest.min)
        end)

        it("lists sorted keys after Put and Remove", function()
            local saved = {}
            local store = open(saved)
            store:Put("b", record())
            store:Put("a", record())
            store:Flush()
            store:Put("c", record())
            store:Remove("b")
            assert.same({ "a", "c" }, store:Keys())
            assert.equals(2, store:CountItems())
        end)

        it("gives nil and one warning for a bad stored string", function()
            local saved = { _schema = 1, data = { EU = { standard = { items = { ["1"] = "junk" } } } } }
            local store, warnings = open(saved)
            assert.is_nil(store:Get("1"))
            assert.is_nil(store:Get("1"))
            assert.equals(1, #warnings)
            assert.equals("junk", saved.data.EU.standard.items["1"])
            assert.same({ "1" }, store:Keys())
        end)
    end)

    describe("schema", function()
        local function legacy()
            return { data = { EU = { standard = { items = {} } } }, extra = true }
        end

        it("migrates a copy and keeps the same table object", function()
            local saved = legacy()
            local seen
            local store, warnings = open(saved, {
                migrations = {
                    function(data)
                        seen = data
                        data.migrated = true
                    end,
                },
            })
            assert.is_false(store:IsReadOnly())
            assert.equals(0, #warnings)
            assert.not_equals(saved, seen)
            assert.is_true(saved.migrated)
            assert.is_true(saved.extra)
            assert.equals(1, saved._schema)
            assert.equals(1, store:GetSchemaVersion())
        end)

        it("goes read-only when a migration fails", function()
            local saved = legacy()
            local before = deepCopy(saved)
            local store, warnings = open(saved, {
                migrations = {
                    function(data)
                        data.half = true
                        error("boom")
                    end,
                },
            })
            assert.is_true(store:IsReadOnly())
            assert.equals(1, #warnings)
            assert.same(before, saved)
        end)

        it("goes read-only when a migration is missing", function()
            local saved = legacy()
            local before = deepCopy(saved)
            local store, warnings = open(saved)
            assert.is_true(store:IsReadOnly())
            assert.equals(1, #warnings)
            assert.same(before, saved)
        end)

        it("goes read-only for a newer schema", function()
            local saved = { _schema = 5, data = {} }
            local before = deepCopy(saved)
            local store, warnings = open(saved)
            assert.is_true(store:IsReadOnly())
            assert.equals(1, #warnings)
            assert.same(before, saved)
        end)
    end)

    describe("read-only", function()
        it("refuses Put, Remove and Flush", function()
            local saved = {
                _schema = 5,
                data = { EU = { standard = { items = { ["1"] = ScanRecord.Encode(record()) } } } },
            }
            local before = deepCopy(saved)
            local store, warnings = open(saved)
            assert.equals(1, #warnings)
            assert.is_false(store:Put("2", record()))
            assert.is_false(store:Remove("1"))
            assert.equals(0, store:Flush())
            assert.equals(2, #warnings)
            assert.is_table(store:Get("1"))
            assert.same({ "1" }, store:Keys())
            assert.same(before, saved)
        end)
    end)

    describe("GetVersion", function()
        it("starts at 0 and counts each successful Put and Remove", function()
            local store = open({})
            assert.equals(0, store:GetVersion())
            store:Put("1", record())
            assert.equals(1, store:GetVersion())
            store:Put("1", record(9))
            assert.equals(2, store:GetVersion())
            store:Remove("1")
            assert.equals(3, store:GetVersion())
        end)

        it("does not change on Get or Flush", function()
            local store = open({})
            store:Put("1", record())
            store:Get("1")
            store:Flush()
            assert.equals(1, store:GetVersion())
        end)

        it("does not change when a write is refused", function()
            local store = open({ _schema = 5 })
            store:Put("1", record())
            store:Remove("1")
            assert.equals(0, store:GetVersion())
        end)
    end)
end)