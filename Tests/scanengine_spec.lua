local FILES = {
    "Core/EventBus.lua", "Core/Scheduler.lua", "Core/ItemInfoCache.lua", "Core/SettingsDB.lua",
    "Core/ItemString.lua", "Services/ScanClock.lua", "Services/ScanKey.lua", "Services/ScanCooldown.lua",
    "Services/ScanRecord.lua", "Services/ScanMarket.lua", "Services/ScanItemLoad.lua",
    "Services/ScanBucket.lua", "Services/ScanStore.lua", "Services/ScanRows.lua", "Services/ScanEngine.lua",
}

local DAY = 86400
local FIRST_DAY = 100
local REPLICATE = "REPLICATE_ITEM_LIST_UPDATE"
local CLOSED = "AUCTION_HOUSE_CLOSED"

local function gearRow(i, price)
    local id = 1000 + i
    return {
        item = id, count = 1, buyout = price or (5000 + i * 10),
        link = "|cffffffff|Hitem:" .. id .. "::::::::::::1:" .. (6000 + i) .. "|h[G]|h|r",
    }
end

local function commodityRow(id, count, buyout)
    return {
        item = id, count = count or 5, buyout = buyout or 5000,
        link = "|cffffffff|Hitem:" .. id .. "::::::::70:::::|h[C]|h|r",
    }
end

local function bigRows()
    local rows = {}
    for i = 1, 500 do
        rows[#rows + 1] = gearRow(i)
    end
    for id = 2001, 2020 do
        for _ = 1, 100 do
            rows[#rows + 1] = commodityRow(id)
        end
    end
    return rows
end

-- Builds the engine and its fake world. A tick is one frame: 16 ms and 1 s pass.
local function MakeWorld(options)
    options = options or {}
    local ns = {}
    for _, file in ipairs(FILES) do
        assert(loadfile(file))("Flipside", ns)
    end
    local w = {
        ns = ns, ms = 0, sec = 0, tick = 0, server = FIRST_DAY * DAY + 1000, rows = options.rows or {},
        known = {}, requested = {}, requestCount = {}, neverLoad = {}, stack = {},
        stackOnLoad = {}, errors = {}, reports = {}, finished = {},
        putTicks = {}, ahOpen = true, apiCost = options.apiCost or 0.001,
    }
    w.saved = options.saved or {}
    w.saved.scan = w.saved.scan or {}
    w.saved.settings = w.saved.settings or {}
    w.bus = ns.EventBus.New()
    w.sched = ns.Scheduler.New({
        clock = function() return w.ms end,
        onError = function(_, message) w.errors[#w.errors + 1] = message end,
    })
    w.settings = ns.SettingsDB.New(w.saved.settings or {}, { character = "Alice-Realm", schemaVersion = 1 })
    w.store = ns.ScanStore.New(w.saved.scan or {}, { region = "us", ruleset = "standard", schemaVersion = 1 })
    w.cooldown = ns.ScanCooldown.New(w.settings, { clock = function() return w.server end })
    w.cache = ns.ItemInfoCache.New({
        getInfo = function(id)
            if w.known[id] then
                return { name = "Item" .. id }
            end
        end,
        requestLoad = function(id)
            w.requested[id] = true
            w.requestCount[id] = (w.requestCount[id] or 0) + 1
        end,
    })

    local realPut = w.store.Put
    w.store.Put = function(self, key, record)
        w.putTicks[#w.putTicks + 1] = w.tick
        return realPut(self, key, record)
    end

    local function loaded(row)
        return not row.late or w.known[row.item]
    end
    w.api = {
        replicateItems = function()
            w.fireAt = w.tick + (options.eventDelay or 1)
            if options.syncEvent then
                w.fireAt = nil
                w.bus:Emit(REPLICATE)
            end
            if options.callError then
                error(options.callError)
            end
            if options.noEvent then
                w.fireAt = nil
            end
        end,
        getNum = function() return #w.rows end,
        getInfo = function(index)
            w.ms = w.ms + w.apiCost
            if w.onInfo then
                w.onInfo(index)
            end
            local r = w.rows[index + 1]
            return "n", 1, r.count, 1, true, 1, 0, 0, 0, r.buyout, 0, false, "", "", "", 0, r.item, loaded(r)
        end,
        getLink = function(index)
            local r = w.rows[index + 1]
            if loaded(r) then
                return r.link
            end
        end,
        getPetInfo = function(index)
            if w.rows[index + 1].pet then
                return "pet"
            end
        end,
        clientIsCommodity = function(id) return id >= 2000 end,
    }
    if options.unknownStack then
        w.api.clientIsCommodity = nil
        w.api.maxStack = function(id) return w.stack[id] end
    end
    if options.noReplicate then
        w.api.replicateItems = nil
    end

    w.engine = ns.ScanEngine.New({
        bus = w.bus,
        startJob = function(name, fn) return w.sched:Start(name, fn) end,
        store = w.store,
        cooldown = w.cooldown,
        cache = w.cache,
        api = w.api,
        serverTime = function() return w.server end,
        seconds = function() return w.sec end,
        ms = function() return w.ms end,
        isAuctionHouseOpen = function() return w.ahOpen end,
        report = function(message) w.reports[#w.reports + 1] = message end,
        onFinished = function(summary) w.finished[#w.finished + 1] = summary end,
    })
    return w
end

local function Tick(w)
    w.ms = w.ms + 16
    w.sec = w.sec + 1
    w.tick = w.tick + 1
    if w.fireAt and w.tick >= w.fireAt then
        w.fireAt = nil
        w.bus:Emit(REPLICATE)
    end
    for id in pairs(w.requested) do
        if not w.neverLoad[id] then
            w.requested[id] = nil
            w.known[id] = true
            w.stack[id] = w.stackOnLoad[id]
            w.cache:OnLoadResult(id, true)
        end
    end
    w.sched:Tick()
end

local function Pump(w, limit)
    for _ = 1, limit or 300 do
        if not w.engine:IsRunning() then
            return
        end
        Tick(w)
    end
    error("scan did not finish")
end

local function Run(w, limit)
    assert.is_true(w.engine:Start())
    Pump(w, limit)
    assert.are.same({}, w.errors)
    return w.finished[#w.finished]
end

local function SavedItems(w)
    return w.saved.scan.data.us.standard.items
end

local function CountKeys(map)
    local n = 0
    for _ in pairs(map) do
        n = n + 1
    end
    return n
end

local function Joined(w)
    return table.concat(w.reports, "\n")
end

describe("ScanEngine.CanStart", function()
    it("returns true when all is ready", function()
        assert.is_true(MakeWorld().engine:CanStart())
    end)

    it("returns the reason for each block", function()
        local w = MakeWorld()
        w.ahOpen = false
        assert.are.same({ false, "ah-closed" }, { w.engine:CanStart() })

        w = MakeWorld()
        w.cooldown:MarkAttempt()
        w.server = w.server + 100
        local ok, reason, left = w.engine:CanStart()
        assert.is_false(ok)
        assert.are.equal("cooldown", reason)
        assert.are.equal(800, left)

        w = MakeWorld({ saved = { scan = { _schema = 99 } } })
        assert.are.same({ false, "read-only" }, { w.engine:CanStart() })

        w = MakeWorld({ noReplicate = true })
        assert.are.same({ false, "api-missing" }, { w.engine:CanStart() })

        w = MakeWorld({ rows = { gearRow(1) } })
        assert.is_true(w.engine:Start())
        assert.are.same({ false, "running" }, { w.engine:CanStart() })
    end)

    it("reports the cooldown and does not start", function()
        local w = MakeWorld()
        w.cooldown:MarkAttempt()
        w.server = w.server + 100
        assert.is_false(w.engine:Start())
        assert.is_false(w.engine:IsRunning())
        assert.is_truthy(Joined(w):find("cooldown, 13 min 20 s left", 1, true))
        assert.are.equal(0, w.sched:GetQueueLength())
    end)
end)

describe("ScanEngine run", function()
    it("finishes with call failed", function()
        local w = MakeWorld({ callError = "boom" })
        local summary = Run(w)
        assert.are.equal("call failed", summary.result)
        assert.is_truthy(Joined(w):find("call failed: ", 1, true))
        assert.is_truthy(Joined(w):find("boom", 1, true))
        assert.are.equal(0, #w.store:Keys())
        assert.is_false(w.bus:HasSubscribers(REPLICATE))
        assert.is_not_nil(w.cooldown:GetLastAttempt())
        assert.is_nil(w.cooldown:GetLastSuccess())
    end)

    it("stops after 60 s without the event", function()
        local w = MakeWorld({ noEvent = true, rows = { gearRow(1) } })
        local summary = Run(w)
        assert.are.equal("no response (cooldown or blocked)", summary.result)
        assert.is_true(w.tick >= 60 and w.tick <= 62)
        assert.are.equal(0, #w.store:Keys())
        assert.is_false(w.bus:HasSubscribers(REPLICATE))
        assert.is_false(w.bus:HasSubscribers(CLOSED))
        assert.is_nil(w.cooldown:GetLastSuccess())
    end)

    it("reads 2500 rows over several ticks and commits", function()
        local w = MakeWorld({ rows = bigRows() })
        local summary = Run(w)
        assert.are.equal("ok", summary.result)
        assert.is_true(w.tick > 3)
        assert.are.equal(2500, summary.rows)
        assert.are.equal(2500, summary.kept)
        assert.are.equal(520, summary.items)
        assert.are.equal(520, summary.keys)
        assert.are.equal(520, summary.newItems)
        assert.are.equal(0, summary.changed)
        assert.are.equal(0, summary.noKey)
        assert.are.equal(0, summary.pendingMissing)
        assert.are.equal(520, summary.commodityStats.client)
        assert.are.equal(2500, summary.rowStats.rows)
        assert.are.equal(520, #w.store:Keys())

        local gear = w.store:Get("1001#b6001")
        assert.are.equal(5010, gear.latest.market)
        assert.are.equal(5010, gear.latest.min)
        assert.is_false(gear.latest.partial)
        assert.are.equal(1, #gear.today.snaps)
        local commodity = w.store:Get("2001")
        assert.are.equal(1000, commodity.latest.min)
        assert.are.equal(1000, commodity.latest.market)
        assert.are.equal(500, commodity.latest.qty)
        assert.are.equal(100, commodity.latest.auctions)
        assert.is_nil(w.store:Get("2001#b6001"))
        assert.is_not_nil(w.cooldown:GetLastSuccess())
    end)

    it("calls Put only in one frame, after the last read", function()
        local w = MakeWorld({ rows = bigRows() })
        Run(w)
        assert.are.equal(520, #w.putTicks)
        assert.are.equal(w.putTicks[1], w.putTicks[#w.putTicks])
        assert.are.equal(w.tick, w.putTicks[1])
    end)

    it("writes the saved table only on Flush", function()
        local w = MakeWorld({ rows = bigRows() })
        Run(w)
        assert.are.equal(0, CountKeys(SavedItems(w)))
        assert.are.equal(520, w.store:Flush())
        assert.are.equal(520, CountKeys(SavedItems(w)))
    end)

    it("handles an event that fires inside the call", function()
        local w = MakeWorld({ rows = { gearRow(1), gearRow(2) }, syncEvent = true })
        local summary = Run(w)
        assert.are.equal("ok", summary.result)
        assert.are.equal(2, summary.keys)
        assert.are.equal(1, w.tick)
        assert.is_not_nil(summary.timeToEventMs)
    end)

    it("makes a partial scan when the Auction House closes during the read", function()
        local w = MakeWorld({ rows = bigRows() })
        w.onInfo = function(index)
            if index == 1200 then
                w.bus:Emit(CLOSED)
            end
        end
        local summary = Run(w)
        assert.are.equal("partial", summary.result)
        assert.is_true(summary.keys > 0 and summary.keys < 520)
        assert.is_truthy(Joined(w):find("closed", 1, true))
        for _, key in ipairs(w.store:Keys()) do
            local record = w.store:Get(key)
            assert.is_true(record.latest.partial)
            assert.is_nil(record.today)
        end
    end)

    it("leaves out an item that never loads and marks the scan partial", function()
        local rows = { gearRow(1), gearRow(2), gearRow(3) }
        rows[#rows + 1] = gearRow(4)
        rows[4].late = true
        rows[#rows + 1] = gearRow(5)
        rows[5].late = true
        local w = MakeWorld({ rows = rows })
        w.neverLoad[1004] = true
        local summary = Run(w)
        assert.are.equal("partial", summary.result)
        assert.are.equal(1, summary.pendingMissing)
        assert.is_true(w.tick >= 30)
        assert.is_nil(w.store:Get("1004#b6004"))
        assert.is_not_nil(w.store:Get("1005#b6005"))
        assert.is_not_nil(w.store:Get("1001#b6001"))
        assert.are.equal(4, #w.store:Keys())
        local record = w.store:Get("1001#b6001")
        assert.is_true(record.latest.partial)
        assert.is_nil(record.today)
        assert.is_truthy(Joined(w):find("items without data", 1, true))
    end)

    it("skips battle pets", function()
        local rows = { gearRow(1), gearRow(2), gearRow(3) }
        rows[2].pet = true
        rows[3].link = "|cff0070dd|Hbattlepet:1:1:1:1:1:1:1|h[Pet]|h|r"
        local w = MakeWorld({ rows = rows })
        local summary = Run(w)
        assert.are.equal("ok", summary.result)
        assert.are.equal(2, summary.rowStats.pet)
        assert.are.same({ "1001#b6001" }, w.store:Keys())
    end)

    it("counts rows without a key and marks the scan partial", function()
        local rows = { gearRow(1), gearRow(2) }
        rows[2].link = "|cffffffff|Hitem:9999::::::::70:::::|h[X]|h|r"
        local w = MakeWorld({ rows = rows })
        local summary = Run(w)
        assert.are.equal("partial", summary.result)
        assert.are.equal(1, summary.noKey)
        assert.are.equal(1, summary.keys)
    end)

    it("emits Flipside.ScanFinished and calls onFinished", function()
        local w = MakeWorld({ rows = { gearRow(1) } })
        local got
        w.bus:Subscribe("Flipside.ScanFinished", {}, function(_, summary) got = summary end)
        local summary = Run(w)
        assert.are.equal(summary, got)
        assert.are.equal(1, #w.finished)
        assert.is_truthy(Joined(w):find("full scan started", 1, true))
        assert.is_truthy(Joined(w):find("full scan ok: 1 rows, 1 items, 1 keys, 1 new, 0 changed >30%", 1, true))
    end)
end)

describe("ScanEngine cancel", function()
    it("commits nothing when cancelled during the read", function()
        local w = MakeWorld({ rows = bigRows() })
        assert.is_true(w.engine:Start())
        Tick(w)
        Tick(w)
        assert.is_true(w.engine:IsRunning())
        w.engine:Cancel()
        assert.is_false(w.engine:IsRunning())
        Tick(w)
        assert.are.same({}, w.errors)
        assert.are.equal(0, #w.store:Keys())
        assert.are.equal(0, w.store:Flush())
        assert.are.equal(0, CountKeys(SavedItems(w)))
        assert.are.equal("cancelled", w.finished[1].result)
        assert.is_false(w.bus:HasSubscribers(REPLICATE))
        assert.is_false(w.bus:HasSubscribers(CLOSED))
        assert.are.equal(0, #w.putTicks)
    end)

    it("can cancel while it waits for the event", function()
        local w = MakeWorld({ rows = { gearRow(1) }, noEvent = true })
        assert.is_true(w.engine:Start())
        Tick(w)
        w.engine:Cancel()
        assert.are.equal("cancelled", w.finished[1].result)
        assert.is_false(w.bus:HasSubscribers(REPLICATE))
    end)
end)

describe("ScanEngine over days", function()
    it("rolls up the first day and counts new and changed items", function()
        local rows = {}
        for i = 1, 20 do
            rows[#rows + 1] = gearRow(i, 10000)
        end
        local w = MakeWorld({ rows = rows })
        local first = Run(w)
        assert.are.equal(20, first.newItems)
        assert.are.equal(0, first.changed)

        w.server = w.server + DAY
        for i = 1, 5 do
            w.rows[i] = gearRow(i, 14000)
        end
        w.rows[6] = gearRow(6, 12900)
        for i = 21, 23 do
            w.rows[#w.rows + 1] = gearRow(i, 10000)
        end
        local second = Run(w)
        assert.are.equal("ok", second.result)
        assert.are.equal(3, second.newItems)
        assert.are.equal(5, second.changed)

        local record = w.store:Get("1001#b6001")
        assert.are.equal(14000, record.latest.market)
        assert.are.equal(1, #record.days)
        assert.are.equal(FIRST_DAY, record.days[1].day)
        assert.are.equal(10000, record.days[1].market)
        assert.are.equal(FIRST_DAY + 1, record.today.day)
        assert.are.equal(1, #record.today.snaps)
    end)
end)

describe("ScanEngine cpuMs", function()
    it("counts only the work of the scan", function()
        local rows = {}
        for i = 1, 10 do
            rows[#rows + 1] = gearRow(i)
            rows[#rows].late = true
        end
        local w = MakeWorld({ rows = rows, apiCost = 0.5, eventDelay = 5 })
        local summary = Run(w)
        assert.are.equal("ok", summary.result)
        assert.is_true(summary.wallMs >= 6 * 16)
        assert.is_true(summary.timeToEventMs >= 4 * 16)
        assert.is_true(math.abs(summary.cpuMs - 5) < 0.001)
        assert.is_true(summary.frames >= 7)
    end)

    it("does not count the item load wait", function()
        local rows = { gearRow(1), gearRow(2) }
        rows[2].late = true
        local w = MakeWorld({ rows = rows, apiCost = 0.5 })
        w.neverLoad[1002] = true
        local summary = Run(w)
        assert.are.equal("partial", summary.result)
        assert.is_true(summary.wallMs >= 30 * 16)
        assert.is_true(math.abs(summary.cpuMs - 1) < 0.001)
    end)
end)

describe("ScanEngine unknown stack size", function()
    local function rowsWithUnknown()
        return { gearRow(1), commodityRow(3001, 5, 5000), commodityRow(3001, 5, 6000), gearRow(2) }
    end

    it("loads the item and stores it under the right key", function()
        local w = MakeWorld({ rows = rowsWithUnknown(), unknownStack = true })
        w.stackOnLoad[1001] = 1
        w.stackOnLoad[1002] = 1
        w.stackOnLoad[3001] = 20
        local summary = Run(w)
        assert.are.equal("ok", summary.result)
        assert.are.equal(0, summary.unknownItems)
        assert.are.equal(0, summary.noKey)
        assert.are.equal(3, summary.keys)
        assert.is_not_nil(w.store:Get("3001"))
        assert.is_not_nil(w.store:Get("1001#b6001"))
        assert.is_false(w.store:Get("3001").latest.partial)
        assert.are.equal(1, w.requestCount[3001])
        assert.are.equal(1, w.requestCount[1001])
    end)

    it("leaves out an item that never loads and marks the scan partial", function()
        local w = MakeWorld({ rows = rowsWithUnknown(), unknownStack = true })
        w.stackOnLoad[1001] = 1
        w.stackOnLoad[1002] = 1
        w.neverLoad[3001] = true
        local summary = Run(w)
        assert.are.equal("partial", summary.result)
        assert.are.equal(1, summary.unknownItems)
        assert.are.equal(2, summary.noKey)
        assert.is_nil(w.store:Get("3001"))
        assert.is_not_nil(w.store:Get("1001#b6001"))
        assert.is_true(w.store:Get("1001#b6001").latest.partial)
        assert.is_truthy(Joined(w):find("1 items with unknown stack size", 1, true))
    end)

    it("makes one load set for pending and unknown items", function()
        local rows = rowsWithUnknown()
        rows[1].late = true
        local w = MakeWorld({ rows = rows, unknownStack = true })
        w.stackOnLoad[1001] = 1
        w.stackOnLoad[1002] = 1
        w.stackOnLoad[3001] = 20
        local seen = {}
        local realRun = w.ns.ScanItemLoad.Run
        w.ns.ScanItemLoad.Run = function(job, cache, set, options)
            local n = 0
            for _ in pairs(set) do
                n = n + 1
            end
            seen[#seen + 1] = n
            return realRun(job, cache, set, options)
        end
        local summary = Run(w)
        assert.are.equal("ok", summary.result)
        assert.are.same({ 3 }, seen)
    end)
end)