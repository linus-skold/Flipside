local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("EventBus")))("Flipside", ns)
assert(loadfile(manifest.path("SettingsDB")))("Flipside", ns)
assert(loadfile(manifest.path("Scheduler")))("Flipside", ns)
assert(loadfile(manifest.path("LedgerRecord")))("Flipside", ns)
assert(loadfile(manifest.path("LedgerBuffer")))("Flipside", ns)
assert(loadfile(manifest.path("LedgerStore")))("Flipside", ns)
assert(loadfile(manifest.path("LedgerLoader")))("Flipside", ns)

local DAY = 86400
local NOW = 300 * DAY

local sched, buffer, loader, saved, started

local function rec(n, char)
    return { time = NOW - 1, char = char or "Alice-Realm", type = "income", source = "quest", money = n }
end

local function oldRec(n, char)
    return { time = DAY + n, char = char, type = "income", source = "quest", money = n, item = "item:1" }
end

-- Store content with the random ids removed, as plain data.
local function snapshot()
    local out = {}
    for char, list in pairs(saved.records.EU.standard) do
        local copy = {}
        for i, record in ipairs(list) do
            copy[i] = {}
            for name, value in pairs(record) do
                if name ~= "id" then
                    copy[i][name] = value
                end
            end
        end
        out[char] = copy
    end
    return { records = out, sums = saved.sums, lastCompact = saved.lastCompact }
end

local function seed()
    saved = { records = { EU = { standard = {} } } }
    for _, char in ipairs({ "A-Realm", "B-Realm", "C-Realm" }) do
        local list = {}
        for n = 1, 5 do
            list[#list + 1] = oldRec(n, char)
        end
        list[#list + 1] = rec(9, char)
        saved.records.EU.standard[char] = list
    end
end

local function build(options)
    started = 0
    local bus = ns.EventBus.New()
    local db = ns.SettingsDB.New({}, {
        character = "Alice-Realm",
        schemaVersion = 1,
        defaults = { account = ns.LedgerRecord.Defaults() },
    })
    db:Set("account", "ledger.bufferCap", 250)
    buffer = ns.LedgerBuffer.New(db, {
        onCap = function()
            loader:RequestFlush()
        end,
    })
    loader = ns.LedgerLoader.New({
        bus = bus,
        buffer = buffer,
        now = function()
            return NOW
        end,
        inCombat = function()
            return false
        end,
        loadAddOn = function()
            return true
        end,
        openStore = function()
            return ns.LedgerStore.New(saved, { region = "EU", ruleset = "standard" })
        end,
        setting = function(key)
            return db:Get("account", key)
        end,
        startJob = options.sliced and function(name, fn)
            started = started + 1
            return sched:Start(name, fn)
        end or nil,
    })
end

-- Ticks until the scheduler has no job. Returns the number of frames.
local function drain()
    local frames = 0
    while not sched:IsIdle() and frames < 100 do
        sched:Tick()
        frames = frames + 1
    end
    return frames
end

local function fill(count)
    for n = 1, count do
        buffer:Add(rec(n))
    end
end

describe("LedgerLoader sliced flush", function()
    before_each(function()
        sched = ns.Scheduler.New({
            clock = function()
                return 0
            end,
            unitsPerFrame = 150,
        })
        seed()
    end)

    it("gives the same store as the synchronous path, over many frames", function()
        build({ sliced = false })
        fill(240)
        assert.is_true(loader:Ensure())
        local expected = snapshot()

        seed()
        build({ sliced = true })
        fill(240)
        loader:RequestFlush()
        assert.are.equal(1, started)
        assert.are.equal(240, buffer:Count())
        assert.is_true(drain() > 1)
        assert.are.equal(0, buffer:Count())
        assert.are.same(expected, snapshot())
    end)
    it("loses and repeats no record when records arrive during the flush", function()
        build({ sliced = true })
        fill(240)
        loader:RequestFlush()
        sched:Tick()
        assert.is_true(buffer:Count() > 0)
        assert.is_true(buffer:Count() < 240)
        for n = 1001, 1010 do
            buffer:Add(rec(n))
        end
        drain()
        assert.are.equal(0, buffer:Count())
        local list = saved.records.EU.standard["Alice-Realm"]
        assert.are.equal(250, #list)
        local seen = {}
        for _, record in ipairs(list) do
            assert.is_nil(seen[record.money])
            seen[record.money] = true
        end
    end)

    it("leaves each record in exactly one place between frames", function()
        build({ sliced = true })
        fill(240)
        loader:RequestFlush()
        while not sched:IsIdle() do
            sched:Tick()
            local stored = saved.records.EU.standard["Alice-Realm"]
            assert.are.equal(240, buffer:Count() + (stored and #stored or 0))
        end
    end)

    it("does not start a second flush while one runs", function()
        build({ sliced = true })
        fill(240)
        loader:RequestFlush()
        sched:Tick()
        loader:RequestFlush()
        loader:RequestFlush()
        assert.are.equal(1, started)
        drain()
        assert.are.equal(1, started)
        assert.are.equal(240, #saved.records.EU.standard["Alice-Realm"])
    end)

    it("lets a synchronous Ensure take over a running flush", function()
        build({ sliced = true })
        fill(240)
        loader:RequestFlush()
        sched:Tick()
        assert.is_true(loader:Ensure())
        drain()
        assert.are.equal(0, buffer:Count())
        assert.are.equal(240, #saved.records.EU.standard["Alice-Realm"])
    end)

    it("falls back to the synchronous path without startJob", function()
        build({ sliced = false })
        fill(240)
        loader:RequestFlush()
        assert.are.equal(0, buffer:Count())
        assert.are.equal(0, started)
        assert.are.equal(240, #saved.records.EU.standard["Alice-Realm"])
    end)

    it("puts a chunk back when the store is read-only", function()
        saved._schema = 99
        build({ sliced = true })
        fill(240)
        loader:RequestFlush()
        drain()
        assert.are.equal(240, buffer:Count())
        assert.is_true(loader:IsPending() == false)
        loader:RequestFlush()
        assert.are.equal(1, started)
    end)
end)
