local manifest = require("Tests.manifest")
local FILES = {
    manifest.path("EventBus"), manifest.path("Scheduler"), manifest.path("ItemInfoCache"), manifest.path("SettingsDB"),
    manifest.path("ItemString"), manifest.path("ScanClock"), manifest.path("ScanKey"), manifest.path("ScanCooldown"),
    manifest.path("ScanRecord"), manifest.path("ScanMarket"), manifest.path("ScanItemLoad"),
    manifest.path("ScanBucket"), manifest.path("ScanStore"), manifest.path("ScanRows"), manifest.path("ScanEngine"),
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
        putTicks = {}, ahOpen = true, apiCost = options.apiCost or 0.001, failLoad = {}, canKey = {},
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
            if r.linkAfter then
                r.reads = (r.reads or 0) + 1
                return r.reads > r.linkAfter and r.link or nil
            end
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
    if options.legacy then
        -- Legacy backend: modes, a refresh time and a rule for rows without a link.
        w.api.clientIsCommodity = nil
        w.api.maxStack = function(id) return w.stack[id] end
        w.api.modes = { "full", "fast" }
        w.api.refreshSeconds = function() return options.refresh or 10 end
        w.api.canKeyWithoutLink = function(id) return w.canKey[id] end
    end
    if options.forever then
        -- Forever backend: a refresh time, no scan modes, no rule for rows without a link.
        w.api.refreshSeconds = function() return options.refresh or 30 end
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
        if w.failLoad[id] then
            w.requested[id] = nil
            w.cache:OnLoadResult(id, false)
        elseif not w.neverLoad[id] then
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

    it("leaves out an item that never loads and stores the other items as complete", function()
        local rows = { gearRow(1), gearRow(2), gearRow(3) }
        rows[#rows + 1] = gearRow(4)
        rows[4].late = true
        rows[#rows + 1] = gearRow(5)
        rows[5].late = true
        local w = MakeWorld({ rows = rows })
        w.neverLoad[1004] = true
        local summary = Run(w)
        assert.are.equal("ok", summary.result)
        assert.are.equal(1, summary.pendingMissing)
        assert.are.equal(1, summary.pending)
        assert.is_true(w.tick >= 30)
        assert.is_nil(w.store:Get("1004#b6004"))
        assert.is_not_nil(w.store:Get("1005#b6005"))
        assert.is_not_nil(w.store:Get("1001#b6001"))
        assert.are.equal(4, #w.store:Keys())
        local record = w.store:Get("1001#b6001")
        assert.is_false(record.latest.partial)
        assert.are.equal(1, #record.today.snaps)
        assert.is_truthy(Joined(w):find("full scan complete with 1 pending:", 1, true))
        assert.is_nil(Joined(w):find("partial scan", 1, true))
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

    it("counts rows without a key and stores the item as latest only", function()
        local rows = { gearRow(1), gearRow(2) }
        rows[2].link = "|cffffffff|Hitem:9999::::::::70:::::|h[X]|h|r"
        local w = MakeWorld({ rows = rows })
        local summary = Run(w)
        assert.are.equal("ok", summary.result)
        assert.are.equal(1, summary.noKey)
        assert.are.equal(1, summary.keys)
        assert.are.equal(1, summary.pending)
        assert.is_false(w.store:Get("1001#b6001").latest.partial)
        assert.is_nil(w.store:Get("1002#b6002"))
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
        assert.are.equal("ok", summary.result)
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

    it("uses the exact key of the link for an item that never loads", function()
        local w = MakeWorld({ rows = rowsWithUnknown(), unknownStack = true })
        w.stackOnLoad[1001] = 1
        w.stackOnLoad[1002] = 1
        w.neverLoad[3001] = true
        local summary = Run(w)
        assert.are.equal("ok", summary.result)
        assert.are.equal(1, summary.itemsLinkFallback)
        assert.are.equal(1, summary.commodityStats.linkFallback)
        assert.are.equal(0, summary.noKey)
        assert.are.equal(10, w.store:Get("3001").latest.qty)
        assert.is_false(w.store:Get("3001").latest.partial)
    end)

    it("leaves out rows with a link of another item and counts the item as pending", function()
        local rows = rowsWithUnknown()
        rows[2].link = commodityRow(3999).link
        rows[3].link = commodityRow(3999).link
        local w = MakeWorld({ rows = rows, unknownStack = true })
        w.neverLoad[3001] = true
        local summary = Run(w)
        assert.are.equal("ok", summary.result)
        assert.are.equal(1, summary.itemsLinkMismatch)
        assert.are.equal(1, summary.pending)
        assert.are.equal(2, summary.noKey)
        assert.is_nil(w.store:Get("3001"))
        assert.is_truthy(Joined(w):find("complete with 1 pending", 1, true))
    end)

    it("counts every item in one group", function()
        local rows = {
            gearRow(1), gearRow(2), gearRow(3), gearRow(4), gearRow(5), gearRow(6),
        }
        rows[3].late = true
        rows[4].link = "garbage"
        rows[5].link = commodityRow(3999).link
        rows[6].link = "garbage"
        local w = MakeWorld({ rows = rows, unknownStack = true })
        w.stackOnLoad[1001] = 1
        w.stackOnLoad[1004] = 1
        w.stackOnLoad[1005] = 1
        w.neverLoad[1002] = true
        w.neverLoad[1003] = true
        w.neverLoad[1006] = true
        local s = Run(w)
        assert.are.equal("ok", s.result)
        assert.are.equal(4, s.pending)
        assert.are.equal(6, s.items)
        assert.are.equal(1, s.itemsKeyed)
        assert.are.equal(1, s.itemsLinkFallback)
        assert.are.equal(1, s.itemsPendingMissing)
        assert.are.equal(1, s.itemsNoLink)
        assert.are.equal(1, s.itemsLinkMismatch)
        assert.are.equal(1, s.itemsUnknown)
        assert.are.equal(s.items, s.itemsKeyed + s.itemsLinkFallback + s.itemsPendingMissing + s.itemsNoLink
            + s.itemsLinkMismatch + s.itemsUnknown)
        assert.is_truthy(Joined(w):find("complete with 4 pending", 1, true))
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

describe("ScanEngine legacy keys and refresh", function()
    local function plain(id, count, link)
        return { item = id, count = count or 1, buyout = 1000, link = link }
    end
    local function linkOf(id)
        return "|cffffffff|Hitem:" .. id .. "::::::::60:::::|h[X]|h|r"
    end

    it("keys an item when the link appears after 2 refresh polls", function()
        local row = plain(3001, 1, linkOf(3001))
        row.linkAfter = 2
        local w = MakeWorld({ rows = { row }, legacy = true })
        w.canKey[3001] = false
        local s = Run(w)
        assert.are.equal("ok", s.result)
        assert.are.equal(1, s.keys)
        assert.are.equal(0, s.keyedWithoutLink)
        assert.are.equal(0, s.pendingMissing)
        assert.is_true(w.requested[3001] ~= nil or w.requestCount[3001] >= 1)
        assert.is_true(s.refreshSeconds >= 2 and s.refreshSeconds < 10)
        assert.are.equal("full", s.mode)
        assert.is_not_nil(w.store:Get("3001"))
    end)

    it("keys by item id when no link ever appears and the item has no suffix", function()
        local w = MakeWorld({ rows = { plain(3002), plain(3002) }, legacy = true })
        w.canKey[3002] = true
        local s = Run(w)
        assert.are.equal("ok", s.result)
        assert.are.equal(1, s.keys)
        assert.are.equal(1, s.keyedWithoutLink)
        assert.is_not_nil(w.store:Get("3002"))
    end)

    it("uses the item id key when the item info is unknown and no row has a link", function()
        local w = MakeWorld({ rows = { plain(3003) }, legacy = true, refresh = 3 })
        local s = Run(w)
        assert.are.equal(1, s.keys)
        assert.are.equal(1, s.keyedWithoutLink)
        assert.is_true(s.refreshSeconds >= 3)
    end)

    it("keeps a suffix item without any link pending", function()
        local w = MakeWorld({ rows = { plain(3004), plain(3005, 20) }, legacy = true, refresh = 4 })
        w.canKey[3004] = false
        w.stackOnLoad[3005] = 20
        local s = Run(w)
        assert.are.equal("ok", s.result)
        assert.are.equal(1, s.pendingMissing)
        assert.are.equal(1, s.noKey)
        assert.are.equal(0, s.keyedWithoutLink)
        assert.is_nil(w.store:Get("3004"))
        assert.is_not_nil(w.store:Get("3005"))
        assert.are.equal(1, #w.store:Get("3005").today.snaps)
        assert.is_false(w.store:Get("3005").latest.partial)
    end)

    it("does not stop the scan when one item load fails", function()
        local w = MakeWorld({ rows = { plain(3006), plain(3007, 1, linkOf(3007)) }, legacy = true, refresh = 3 })
        w.canKey[3006] = false
        w.failLoad[3006] = true
        local s = Run(w)
        assert.are.equal("ok", s.result)
        assert.are.equal(1, s.pending)
        assert.are.equal(1, s.failed)
        assert.are.equal(1, s.keys)
        assert.is_not_nil(w.store:Get("3007"))
        assert.is_true(s.refreshSeconds >= 3)
    end)

    it("uses links for the rows of an item when some rows have a link", function()
        local w = MakeWorld({ rows = { plain(3008, 1, linkOf(3008)), plain(3008) }, legacy = true, refresh = 2 })
        w.canKey[3008] = false
        local s = Run(w)
        assert.are.equal(1, s.keys)
        assert.are.equal(1, s.noKey)
        assert.are.equal(0, s.keyedWithoutLink)
    end)

    it("does not refresh without the legacy options", function()
        local w = MakeWorld({ rows = { gearRow(1) } })
        local s = Run(w)
        assert.are.equal(0, s.refreshSeconds)
        assert.is_nil(s.mode)
        assert.are.equal(0, s.keyedWithoutLink)
    end)
end)

describe("ScanEngine Forever retry", function()
    it("keys an item when the link appears on the second poll", function()
        local row = gearRow(1)
        row.linkAfter = 2
        local w = MakeWorld({ rows = { row, gearRow(2) }, forever = true })
        local s = Run(w)
        assert.are.equal("ok", s.result)
        assert.are.equal(0, s.pending)
        assert.are.equal(2, s.keys)
        assert.is_not_nil(w.store:Get("1001#b6001"))
        assert.are.equal(1, s.retried)
        assert.is_true(s.refreshSeconds >= 2 and s.refreshSeconds < 30)
        assert.are.equal(1, #w.store:Get("1001#b6001").today.snaps)
    end)

    it("keys an item when hasAllInfo changes from false to true", function()
        local rows = { gearRow(1), gearRow(2) }
        rows[2].late = true
        local w = MakeWorld({ rows = rows, forever = true })
        local s = Run(w)
        assert.are.equal(0, s.pending)
        assert.are.equal(2, s.keys)
        assert.is_true(w.requested[1002] ~= nil or w.requestCount[1002] >= 1)
        assert.is_not_nil(w.store:Get("1002#b6002"))
    end)

    it("keys an item when the load fails once and then works", function()
        local rows = { gearRow(1), gearRow(2) }
        rows[2].late = true
        local w = MakeWorld({ rows = rows, forever = true })
        w.failLoad[1002] = true
        assert.is_true(w.engine:Start())
        for _ = 1, 300 do
            if not w.engine:IsRunning() then
                break
            end
            Tick(w)
            if (w.requestCount[1002] or 0) >= 2 then
                w.failLoad[1002] = nil
            end
        end
        assert.are.same({}, w.errors)
        local s = w.finished[#w.finished]
        assert.are.equal(0, s.pending)
        assert.are.equal(0, s.failed)
        assert.are.equal(1, s.retried)
        assert.is_not_nil(w.store:Get("1002#b6002"))
    end)

    it("leaves an item pending when its load never answers, and stores the others for today", function()
        local rows = { gearRow(1), gearRow(2), gearRow(3) }
        rows[2].late = true
        local w = MakeWorld({ rows = rows, forever = true })
        w.neverLoad[1002] = true
        local s = Run(w)
        assert.are.equal("ok", s.result)
        assert.are.equal(1, s.pending)
        assert.are.equal(1, s.pendingMissing)
        assert.are.equal(1, s.nilLink)
        assert.are.equal(1, s.notAllInfo)
        assert.are.equal(1, s.retried)
        assert.is_true(s.refreshSeconds >= 30)
        assert.is_nil(w.store:Get("1002#b6002"))
        for _, key in ipairs({ "1001#b6001", "1003#b6003" }) do
            local record = w.store:Get(key)
            assert.is_false(record.latest.partial)
            assert.are.equal(1, #record.today.snaps)
        end
        assert.is_truthy(Joined(w):find("full scan complete with 1 pending:", 1, true))
    end)

    it("counts an item whose load keeps failing", function()
        local rows = { gearRow(1), gearRow(2) }
        rows[2].late = true
        local w = MakeWorld({ rows = rows, forever = true, refresh = 5 })
        w.failLoad[1002] = true
        local s = Run(w)
        assert.are.equal(1, s.pending)
        assert.are.equal(1, s.failed)
        assert.is_not_nil(w.store:Get("1001#b6001"))
    end)

    it("uses the base key for a commodity without a link", function()
        local rows = { commodityRow(2001), commodityRow(2001, 5, 6000), gearRow(1) }
        rows[1].late, rows[2].late = true, true
        local w = MakeWorld({ rows = rows, forever = true })
        w.neverLoad[2001] = true
        local s = Run(w)
        assert.are.equal(0, s.pending)
        assert.are.equal(2, s.keys)
        assert.are.equal(10, w.store:Get("2001").latest.qty)
        assert.is_false(w.store:Get("2001").latest.partial)
        assert.are.equal(0, s.retried)
    end)

    it("keeps a gear item without a link pending", function()
        local rows = { gearRow(1), gearRow(2) }
        rows[2].late = true
        local w = MakeWorld({ rows = rows, forever = true, refresh = 4 })
        w.neverLoad[1002] = true
        local s = Run(w)
        assert.are.equal(1, s.pending)
        assert.is_nil(w.store:Get("1002#b6002"))
        assert.is_not_nil(w.store:Get("1001#b6001"))
    end)

    it("keeps a partial scan latest only when the read is cut", function()
        local w = MakeWorld({ rows = bigRows(), forever = true })
        w.onInfo = function(index)
            if index == 1200 then
                w.bus:Emit(CLOSED)
            end
        end
        local s = Run(w)
        assert.are.equal("partial", s.result)
        for _, key in ipairs(w.store:Keys()) do
            assert.is_nil(w.store:Get(key).today)
        end
    end)

    it("writes an item with one loaded row and one unloaded row after the load", function()
        local second = gearRow(1, 7000)
        second.late = true
        local w = MakeWorld({ rows = { gearRow(1, 6000), second, gearRow(2) }, forever = true, refresh = 15 })
        local s = Run(w)
        assert.are.equal(0, s.pending)
        assert.are.equal(0, s.pendingRows)
        assert.are.equal(2, s.keys)
        local record = w.store:Get("1001#b6001")
        assert.are.equal(2, record.latest.qty)
        assert.are.equal(1, #record.today.snaps)
        assert.is_true(w.requestCount[1001] >= 1)
    end)

    it("writes an item whose data arrives after 40 s while other items keep arriving", function()
        local rows = {}
        for i = 1, 4 do
            rows[i] = gearRow(i)
            rows[i].late = true
            -- Not through neverLoad of the world: this test releases each item itself.
        end
        local w = MakeWorld({ rows = rows, forever = true, refresh = 15 })
        local releaseAt = { [1001] = 10, [1002] = 20, [1003] = 30, [1004] = 44 }
        for id in pairs(releaseAt) do
            w.neverLoad[id] = true
        end
        assert.is_true(w.engine:Start())
        for _ = 1, 300 do
            if not w.engine:IsRunning() then
                break
            end
            for id, at in pairs(releaseAt) do
                if w.tick >= at then
                    w.neverLoad[id] = nil
                end
            end
            Tick(w)
        end
        assert.are.same({}, w.errors)
        local s = w.finished[#w.finished]
        assert.are.equal("ok", s.result)
        assert.are.equal(0, s.pending)
        assert.are.equal(4, s.keys)
        assert.is_true(s.refreshSeconds > 40)
        assert.is_not_nil(w.store:Get("1004#b6004"))
    end)

    it("stops after no row was accepted for the no-progress time and reports the pending rows", function()
        local rows = { gearRow(1), gearRow(2), gearRow(2, 9000) }
        rows[2].late, rows[3].late = true, true
        local w = MakeWorld({ rows = rows, forever = true, refresh = 15 })
        w.neverLoad[1002] = true
        local s = Run(w)
        assert.are.equal("ok", s.result)
        assert.are.equal(1, s.pending)
        assert.are.equal(2, s.pendingRows)
        assert.is_true(s.refreshSeconds >= 15 and s.refreshSeconds < 20)
        assert.is_nil(w.store:Get("1002#b6002"))
        assert.is_not_nil(w.store:Get("1001#b6001"))
    end)

    it("stops the scan when the Auction House closes during the event wait", function()
        local w = MakeWorld({ rows = { gearRow(1), gearRow(2) }, forever = true, eventDelay = 5 })
        assert.is_true(w.engine:Start())
        Tick(w)
        w.bus:Emit(CLOSED)
        Pump(w)
        assert.are.same({}, w.errors)
        local s = w.finished[#w.finished]
        assert.is_truthy(s.result:find("closed", 1, true))
        assert.are.equal(0, #w.putTicks)
        assert.is_nil(w.store:Get("1001#b6001"))
    end)

    it("does not refresh when the api has no refresh time", function()
        local rows = { gearRow(1), gearRow(2) }
        rows[2].late = true
        local w = MakeWorld({ rows = rows })
        local s = Run(w)
        assert.are.equal(0, s.retried)
        assert.are.equal(0, s.refreshSeconds)
    end)
end)

describe("ScanEngine page mode", function()
    local function linkOf(id)
        return "|cffffffff|Hitem:" .. id .. "::::::::60:::::|h[X]|h|r"
    end

    -- Six rows on three pages of two. The row of item 4003 gets its link on the second re-read.
    local function PageWorld()
        local pages = {}
        for p = 1, 3 do
            pages[p] = {}
            for r = 1, 2 do
                local id = 4000 + (p - 1) * 2 + r
                pages[p][r] = { item = id, count = 1, buyout = 1000 * r, link = linkOf(id) }
            end
        end
        pages[2][1].linkAfter = 2
        local w = MakeWorld({ rows = {}, legacy = true, refresh = 2 })
        w.api.modes = { "full", "fast", "page" }
        w.api.pageSize = 2
        w.api.canKeyWithoutLink = function() return false end
        w.queries, w.canCalls = {}, 0
        w.api.canQueryPage = function()
            w.canCalls = w.canCalls + 1
            return w.canCalls % 2 == 0
        end
        w.api.pageTotal = function() return 6 end
        w.api.pageQuery = function(page)
            w.queries[#w.queries + 1] = page
            w.rows = pages[page + 1]
            w.fireAt = w.tick + 1
        end
        return w
    end

    it("reads 3 pages, fills a nil row on re-read and commits once", function()
        local w = PageWorld()
        assert.is_true(w.engine:Start("page"))
        local seen
        for _ = 1, 400 do
            if not w.engine:IsRunning() then break end
            Tick(w)
            local _, page, total = w.engine:GetProgress()
            if page then seen = { page, total } end
        end
        assert.are.same({}, w.errors)
        local s = w.finished[#w.finished]
        assert.are.same({ 0, 1, 2 }, w.queries)
        assert.are.equal("ok", s.result, Joined(w))
        assert.are.equal("page", s.mode)
        assert.are.equal(3, s.pages)
        assert.are.equal(3, s.pagesTotal)
        assert.are.equal(6, s.rows)
        assert.are.equal(6, s.keys)
        assert.are.equal(0, s.pendingMissing)
        assert.is_not_nil(w.store:Get("4003"))
        assert.is_truthy(seen)
        assert.is_truthy(Joined(w):find("page scan ok:", 1, true))
        -- One commit: every key written once.
        assert.are.equal(6, #w.putTicks)
        assert.is_nil(w.cooldown:GetLastAttempt())
        assert.is_not_nil(w.cooldown:GetLastSuccess())
    end)

    it("runs while get all is on cooldown", function()
        local w = PageWorld()
        w.cooldown:MarkAttempt()
        assert.are.equal("cooldown", select(2, w.engine:CanStart("full")))
        assert.are.equal("cooldown", select(2, w.engine:CanStart("fast")))
        assert.is_true(w.engine:CanStart("page"))
        assert.are.equal("bad-mode", select(2, w.engine:CanStart("slow")))
    end)

    it("stops when the player cancels and stores nothing", function()
        local w = PageWorld()
        assert.is_true(w.engine:Start("page"))
        for _ = 1, 5 do
            Tick(w)
        end
        w.engine:Cancel()
        Pump(w)
        assert.are.equal("cancelled", w.finished[#w.finished].result)
        assert.are.equal(0, #w.store:Keys())
        assert.is_false(w.bus:HasSubscribers(REPLICATE))
    end)

    it("ends partial when a page gets no answer", function()
        local w = PageWorld()
        local realQuery = w.api.pageQuery
        w.api.pageQuery = function(page)
            realQuery(page)
            if page == 1 then
                w.fireAt = nil
            end
        end
        assert.is_true(w.engine:Start("page"))
        Pump(w, 600)
        local s = w.finished[#w.finished]
        assert.are.equal("partial", s.result, Joined(w))
        assert.are.equal(1, s.pages)
        assert.are.equal(2, #w.store:Keys())
        assert.is_truthy(Joined(w):find("no answer for page 2", 1, true))
    end)
end)







