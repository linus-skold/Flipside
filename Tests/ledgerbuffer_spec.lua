local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("SettingsDB")))("Flipside", ns)
assert(loadfile(manifest.path("LedgerRecord")))("Flipside", ns)
assert(loadfile(manifest.path("LedgerBuffer")))("Flipside", ns)

local warnings, capCalls

local function Open(settings, saved)
    local defaults = { account = ns.LedgerRecord.Defaults() }
    for k, v in pairs(settings or {}) do
        defaults.account[k] = v
    end
    local db = ns.SettingsDB.New(saved or {}, { character = "Alice-Realm", schemaVersion = 1, defaults = defaults })
    local buffer = ns.LedgerBuffer.New(db, {
        warn = function(message)
            warnings[#warnings + 1] = message
        end,
        onCap = function()
            capCalls = capCalls + 1
        end,
    })
    return buffer, db
end

local function rec(n)
    return { time = n, char = "Alice-Realm", type = "income", source = "quest", money = n }
end

describe("LedgerBuffer", function()
    before_each(function()
        warnings, capCalls = {}, 0
    end)

    it("appends records in order and counts them", function()
        local buffer = Open()
        assert.is_true(buffer:Add(rec(1)))
        assert.is_true(buffer:Add(rec(2)))
        assert.are.equal(2, buffer:Count())
    end)

    it("stores the buffer in the account scope of the main DB", function()
        local saved = {}
        local buffer = Open(nil, saved)
        buffer:Add(rec(1))
        assert.are.equal(1, #saved["a/ledger.buffer"])
        assert.are.equal(1, saved["a/ledger.buffer"][1].time)
    end)

    it("rejects an invalid record", function()
        local buffer = Open()
        local ok, message = buffer:Add({ time = 1 })
        assert.is_false(ok)
        assert.is_truthy(message)
        assert.are.equal(0, buffer:Count())
    end)

    it("copies the record", function()
        local buffer = Open()
        local record = rec(1)
        buffer:Add(record)
        record.money = 99
        assert.are.equal(1, buffer:Drain()[1].money)
    end)

    it("calls onCap at the cap and not before", function()
        local buffer = Open({ ["ledger.bufferCap"] = 3 })
        buffer:Add(rec(1))
        buffer:Add(rec(2))
        assert.are.equal(0, capCalls)
        buffer:Add(rec(3))
        assert.are.equal(1, capCalls)
    end)

    it("uses the default cap of 500", function()
        local buffer = Open()
        assert.are.equal(500, buffer:Cap())
        assert.are.equal(2000, buffer:HardLimit())
        for i = 1, 499 do
            buffer:Add(rec(i))
        end
        assert.are.equal(0, capCalls)
        buffer:Add(rec(500))
        assert.are.equal(1, capCalls)
    end)

    it("falls back to the default for a bad setting", function()
        local buffer = Open({ ["ledger.bufferCap"] = "x", ["ledger.hardLimit"] = 0 })
        assert.are.equal(500, buffer:Cap())
        assert.are.equal(2000, buffer:HardLimit())
    end)

    it("drops the oldest record above the hard limit, counts the drops and warns once", function()
        local buffer = Open({ ["ledger.bufferCap"] = 2, ["ledger.hardLimit"] = 3 })
        for i = 1, 6 do
            assert.is_true(buffer:Add(rec(i)))
        end
        assert.are.equal(3, buffer:Count())
        assert.are.equal(3, buffer:Dropped())
        assert.are.equal(1, #warnings)
        local list = buffer:Drain()
        assert.are.equal(4, list[1].time)
        assert.are.equal(6, list[3].time)
    end)

    it("never lets the hard limit be below the cap", function()
        local buffer = Open({ ["ledger.bufferCap"] = 5, ["ledger.hardLimit"] = 2 })
        assert.are.equal(5, buffer:HardLimit())
    end)

    it("drains all records and clears the buffer", function()
        local saved = {}
        local buffer = Open(nil, saved)
        buffer:Add(rec(1))
        buffer:Add(rec(2))
        local list = buffer:Drain()
        assert.are.equal(2, #list)
        assert.are.equal(0, buffer:Count())
        assert.are.same({}, saved["a/ledger.buffer"])
        assert.are.same({}, buffer:Drain())
    end)

    it("restores records in front of newer ones", function()
        local buffer = Open()
        buffer:Add(rec(1))
        buffer:Add(rec(2))
        local list = buffer:Drain()
        buffer:Add(rec(3))
        buffer:Restore(list)
        local again = buffer:Drain()
        assert.are.same({ 1, 2, 3 }, { again[1].time, again[2].time, again[3].time })
    end)

    it("keeps the records of an earlier session", function()
        local saved = {}
        Open(nil, saved):Add(rec(1))
        local buffer = Open(nil, saved)
        assert.are.equal(1, buffer:Count())
    end)

    it("fails to add when the settings are read-only", function()
        local buffer, db = Open()
        db._readOnly = true
        local ok, message = buffer:Add(rec(1))
        assert.is_false(ok)
        assert.is_truthy(message)
    end)
end)
