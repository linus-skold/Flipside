local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("EventBus")))("Flipside", ns)
assert(loadfile(manifest.path("SettingsDB")))("Flipside", ns)
assert(loadfile(manifest.path("LedgerRecord")))("Flipside", ns)
assert(loadfile(manifest.path("LedgerBuffer")))("Flipside", ns)
assert(loadfile(manifest.path("LedgerStore")))("Flipside", ns)
assert(loadfile(manifest.path("LedgerLoader")))("Flipside", ns)

local bus, db, buffer, loader, savedLedger
local combat, loadResult, loadCalls, loadedNames, failures, loadedEvents, later

local function rec(n)
    return { time = n, char = "Alice-Realm", type = "income", source = "quest", money = n }
end

local function Build(options)
    options = options or {}
    bus = ns.EventBus.New()
    db = ns.SettingsDB.New({}, {
        character = "Alice-Realm",
        schemaVersion = 1,
        defaults = { account = ns.LedgerRecord.Defaults() },
    })
    buffer = ns.LedgerBuffer.New(db, {
        onCap = function()
            loader:RequestFlush()
        end,
    })
    loader = ns.LedgerLoader.New({
        bus = bus,
        buffer = buffer,
        now = function()
            return 300 * 86400
        end,
        inCombat = function()
            return combat
        end,
        loadAddOn = function(name)
            loadCalls = loadCalls + 1
            loadedNames[#loadedNames + 1] = name
            return loadResult[1], loadResult[2]
        end,
        openStore = function()
            savedLedger = savedLedger or {}
            return ns.LedgerStore.New(savedLedger, { region = "EU", ruleset = "standard" })
        end,
        setting = function(key)
            return db:Get("account", key)
        end,
        after = options.deferred and function(_, fn)
            later[#later + 1] = fn
        end or nil,
    })
    bus:Subscribe(ns.LedgerLoader.EVENT_FAILED, "spec", function(_, reason)
        failures[#failures + 1] = reason
    end)
    bus:Subscribe(ns.LedgerLoader.EVENT_LOADED, "spec", function()
        loadedEvents = loadedEvents + 1
    end)
end

describe("LedgerLoader", function()
    before_each(function()
        combat, loadResult, loadCalls, loadedNames = false, { true }, 0, {}
        failures, loadedEvents, later, savedLedger = {}, 0, {}, nil
        Build()
    end)

    it("loads the addon and moves the buffer into the store", function()
        buffer:Add(rec(1))
        buffer:Add(rec(2))
        assert.is_true(loader:Ensure())
        assert.are.same({ "Flipside_Ledger" }, loadedNames)
        assert.are.equal(0, buffer:Count())
        assert.are.equal(2, #savedLedger.records.EU.standard["Alice-Realm"])
        assert.are.equal(1, loadedEvents)
        assert.is_not_nil(loader:Store())
    end)

    it("loads the addon only once", function()
        loader:Ensure()
        buffer:Add(rec(1))
        assert.is_true(loader:Ensure())
        assert.are.equal(1, loadCalls)
        assert.are.equal(1, #savedLedger.records.EU.standard["Alice-Realm"])
    end)

    it("runs the compaction after the load", function()
        savedLedger = { records = { EU = { standard = { ["Alice-Realm"] = { rec(10 * 86400) } } } } }
        loader:Ensure()
        assert.are.equal(300, savedLedger.lastCompact)
        assert.are.equal(1, #savedLedger.sums.EU.standard["Alice-Realm"])
    end)

    it("does not load in combat and queues the load", function()
        combat = true
        buffer:Add(rec(1))
        local ok, reason = loader:Ensure()
        assert.is_false(ok)
        assert.are.equal("combat", reason)
        assert.are.equal(0, loadCalls)
        assert.is_true(loader:IsPending())
        assert.are.equal(1, buffer:Count())
    end)

    it("runs the queued load at PLAYER_REGEN_ENABLED", function()
        loader:Attach()
        combat = true
        buffer:Add(rec(1))
        loader:Ensure()
        bus:Emit("PLAYER_REGEN_ENABLED")
        assert.are.equal(0, loadCalls)
        combat = false
        bus:Emit("PLAYER_REGEN_ENABLED")
        assert.are.equal(1, loadCalls)
        assert.are.equal(0, buffer:Count())
        assert.is_false(loader:IsPending())
    end)

    it("does nothing at PLAYER_REGEN_ENABLED without a queued load", function()
        loader:Attach()
        bus:Emit("PLAYER_REGEN_ENABLED")
        assert.are.equal(0, loadCalls)
    end)

    it("reports a failed load through the bus and keeps the buffer", function()
        loadResult = { false, "MISSING" }
        buffer:Add(rec(1))
        local ok, reason = loader:Ensure()
        assert.is_false(ok)
        assert.are.equal("MISSING", reason)
        assert.are.same({ "MISSING" }, failures)
        assert.are.equal(1, buffer:Count())
        assert.is_nil(loader:Store())
        assert.are.equal(0, loadedEvents)
    end)

    it("loads later when the addon becomes available", function()
        loadResult = { false, "DISABLED" }
        buffer:Add(rec(1))
        loader:Ensure()
        loadResult = { true }
        assert.is_true(loader:Ensure())
        assert.are.equal(0, buffer:Count())
    end)

    it("reports a load function that raises an error", function()
        local broken = ns.LedgerLoader.New({
            bus = bus, buffer = buffer, now = function() return 1 end, inCombat = function() return false end,
            loadAddOn = function() error("boom") end, openStore = function() end,
        })
        local ok, reason = broken:Ensure()
        assert.is_false(ok)
        assert.is_truthy(reason:find("boom"))
        assert.are.equal(1, #failures)
    end)

    it("keeps the buffer when the store is read-only", function()
        savedLedger = { _schema = 99 }
        buffer:Add(rec(1))
        local ok = loader:Ensure()
        assert.is_false(ok)
        assert.are.equal(1, buffer:Count())
        assert.are.equal(1, #failures)
    end)

    it("loads at login when the buffer is not empty, once", function()
        loader:Attach()
        buffer:Add(rec(1))
        bus:Emit("PLAYER_ENTERING_WORLD")
        assert.are.equal(1, loadCalls)
        buffer:Add(rec(2))
        bus:Emit("PLAYER_ENTERING_WORLD")
        assert.are.equal(1, loadCalls)
        assert.are.equal(1, buffer:Count())
    end)

    it("does not load at login when the buffer is empty", function()
        loader:Attach()
        bus:Emit("PLAYER_ENTERING_WORLD")
        assert.are.equal(0, loadCalls)
    end)

    describe("the buffer cap", function()
        it("forces the load at the cap", function()
            db:Set("account", "ledger.bufferCap", 3)
            for i = 1, 3 do
                buffer:Add(rec(i))
            end
            assert.are.equal(1, loadCalls)
            assert.are.equal(0, buffer:Count())
        end)

        it("waits for the end of combat at the cap", function()
            db:Set("account", "ledger.bufferCap", 2)
            combat = true
            buffer:Add(rec(1))
            buffer:Add(rec(2))
            assert.are.equal(0, loadCalls)
            assert.are.equal(2, buffer:Count())
            assert.is_true(loader:IsPending())
        end)

        it("defers the load with the after function and asks once", function()
            Build({ deferred = true })
            db:Set("account", "ledger.bufferCap", 2)
            buffer:Add(rec(1))
            buffer:Add(rec(2))
            buffer:Add(rec(3))
            assert.are.equal(0, loadCalls)
            assert.are.equal(1, #later)
            later[1]()
            assert.are.equal(1, loadCalls)
            assert.are.equal(0, buffer:Count())
        end)

        it("does not ask again after a failure in the session", function()
            loadResult = { false, "MISSING" }
            db:Set("account", "ledger.bufferCap", 2)
            buffer:Add(rec(1))
            buffer:Add(rec(2))
            buffer:Add(rec(3))
            buffer:Add(rec(4))
            assert.are.equal(1, loadCalls)
            assert.are.equal(1, #failures)
            assert.are.equal(4, buffer:Count())
        end)
    end)

    describe("the mailbox", function()
        it("holds the load at the cap while the mailbox is open and runs it after the close", function()
            Build({ deferred = true })
            loader:Attach()
            db:Set("account", "ledger.bufferCap", 2)
            bus:Emit("MAIL_SHOW")
            buffer:Add(rec(1))
            buffer:Add(rec(2))
            buffer:Add(rec(3))
            assert.are.equal(0, #later, "no timer while the mailbox is open")
            assert.are.equal(0, loadCalls)
            bus:Emit("MAIL_CLOSED")
            assert.are.equal(1, #later, "one timer after the close")
            later[1]()
            assert.are.equal(2, #later, "the close timer asks for the flush")
            later[2]()
            assert.are.equal(1, loadCalls)
            assert.are.equal(0, buffer:Count())
        end)

        it("does not load after the close if the buffer never reached the cap", function()
            Build({ deferred = true })
            loader:Attach()
            bus:Emit("MAIL_SHOW")
            buffer:Add(rec(1))
            bus:Emit("MAIL_CLOSED")
            assert.are.equal(1, #later, "the close timer")
            later[1]()
            assert.are.equal(1, #later, "the timer asks for no flush")
            assert.are.equal(0, loadCalls)
        end)

        it("holds a record that the close handler of another module adds in the close frame", function()
            Build({ deferred = true })
            loader:Attach()
            db:Set("account", "ledger.bufferCap", 2)
            bus:Emit("MAIL_SHOW")
            buffer:Add(rec(1))
            bus:Emit("MAIL_CLOSED")
            buffer:Add(rec(2))
            assert.are.equal(1, #later, "only the close timer, no flush request")
            assert.are.equal(0, loadCalls)
            later[1]()
            assert.are.equal(2, #later)
            later[2]()
            assert.are.equal(1, loadCalls)
        end)

        it("flushes at once near the hard limit, also while the mailbox is open", function()
            Build({ deferred = true })
            loader:Attach()
            db:Set("account", "ledger.bufferCap", 2)
            db:Set("account", "ledger.hardLimit", 6)
            bus:Emit("MAIL_SHOW")
            for i = 1, 3 do
                buffer:Add(rec(i))
            end
            assert.are.equal(0, #later, "held below hardLimit - cap")
            buffer:Add(rec(4))
            assert.are.equal(1, #later, "the flush is requested")
            later[1]()
            assert.are.equal(1, loadCalls)
            assert.are.equal(0, buffer:Count())
        end)

        it("flushes after the second close when the mailbox reopens before the close timer", function()
            Build({ deferred = true })
            loader:Attach()
            db:Set("account", "ledger.bufferCap", 2)
            bus:Emit("MAIL_SHOW")
            buffer:Add(rec(1))
            buffer:Add(rec(2))
            bus:Emit("MAIL_CLOSED")
            bus:Emit("MAIL_SHOW")
            later[1]()
            assert.are.equal(1, #later, "the first timer finds the mailbox open")
            bus:Emit("MAIL_CLOSED")
            assert.are.equal(2, #later)
            later[2]()
            assert.are.equal(3, #later, "the second timer asks for the flush")
            later[3]()
            assert.are.equal(1, loadCalls)
        end)

        it("ignores a stale close timer", function()
            Build({ deferred = true })
            loader:Attach()
            db:Set("account", "ledger.bufferCap", 2)
            bus:Emit("MAIL_SHOW")
            buffer:Add(rec(1))
            buffer:Add(rec(2))
            bus:Emit("MAIL_CLOSED")
            bus:Emit("MAIL_SHOW")
            bus:Emit("MAIL_CLOSED")
            later[1]()
            assert.are.equal(2, #later, "the old timer does nothing")
            assert.are.equal(0, loadCalls)
        end)

        it("waits again if the mailbox opens before the close timer ends", function()
            Build({ deferred = true })
            loader:Attach()
            db:Set("account", "ledger.bufferCap", 1)
            bus:Emit("MAIL_SHOW")
            buffer:Add(rec(1))
            bus:Emit("MAIL_CLOSED")
            bus:Emit("MAIL_SHOW")
            later[1]()
            assert.are.equal(1, #later)
            assert.are.equal(0, loadCalls)
        end)
    end)

    describe("the timing", function()
        it("reports a slow addon load and a slow store open", function()
            local now, lines = 0, {}
            local timed = ns.LedgerLoader.New({
                bus = bus, buffer = buffer, now = function() return 1 end, inCombat = function() return false end,
                clock = function() return now end,
                slow = function(label, ms)
                    lines[#lines + 1] = { label, ms }
                end,
                loadAddOn = function()
                    now = now + 40
                    return true
                end,
                openStore = function()
                    now = now + 30
                    return ns.LedgerStore.New({}, { region = "EU", ruleset = "standard" })
                end,
            })
            assert.is_true(timed:Ensure())
            assert.are.same({ { "ledger LoadAddOn", 40 }, { "ledger store open", 30 } }, lines)
        end)

        it("reports nothing for a fast load", function()
            local now, lines = 0, {}
            local timed = ns.LedgerLoader.New({
                bus = bus, buffer = buffer, now = function() return 1 end, inCombat = function() return false end,
                clock = function() return now end,
                slow = function(label)
                    lines[#lines + 1] = label
                end,
                loadAddOn = function()
                    now = now + 5
                    return true
                end,
                openStore = function()
                    return ns.LedgerStore.New({}, { region = "EU", ruleset = "standard" })
                end,
            })
            assert.is_true(timed:Ensure())
            assert.are.same({}, lines)
        end)

        it("has a readable owner name", function()
            assert.are.equal("Flipside.LedgerLoader", ns.EventBus.OwnerName(loader))
        end)
    end)

    it("needs its options", function()
        assert.has_error(function()
            ns.LedgerLoader.New({ bus = bus })
        end)
    end)
end)
