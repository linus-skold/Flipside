local _, ns = ...

-- Runs one full scan as a scheduler job: call, wait, read, load item data, reduce, commit.
local ScanEngine = {}
ns.ScanEngine = ScanEngine

local Engine = {}
Engine.__index = Engine

local EVENT_REPLICATE = "REPLICATE_ITEM_LIST_UPDATE"
local EVENT_CLOSED = "AUCTION_HOUSE_CLOSED"
local EVENT_FINISHED = "Flipside.ScanFinished"
local CHANGED_RATIO = 0.30
local FRAME_GAP_MS = 1

local RESULT_NO_RESPONSE = "no response (cooldown or blocked)"

local REQUIRED_FUNCTIONS = { "startJob", "serverTime", "seconds", "ms", "isAuctionHouseOpen", "report" }
local REQUIRED_TABLES = { "bus", "store", "cooldown", "cache", "api" }

function ScanEngine.New(deps)
    if type(deps) ~= "table" then
        error("deps must be a table", 2)
    end
    for _, name in ipairs(REQUIRED_FUNCTIONS) do
        if type(deps[name]) ~= "function" then
            error("deps." .. name .. " must be a function", 2)
        end
    end
    for _, name in ipairs(REQUIRED_TABLES) do
        if type(deps[name]) ~= "table" then
            error("deps." .. name .. " must be a table", 2)
        end
    end
    return setmetatable({ deps = deps, running = false, job = nil }, Engine)
end

function Engine:IsRunning()
    return self.running
end

-- Returns true, or false with a reason and a detail.
function Engine:CanStart()
    local deps = self.deps
    if self.running then
        return false, "running"
    end
    if deps.api.replicateItems == nil then
        return false, "api-missing"
    end
    if not deps.isAuctionHouseOpen() then
        return false, "ah-closed"
    end
    if deps.store:IsReadOnly() then
        return false, "read-only"
    end
    local left = deps.cooldown:Remaining()
    if left > 0 then
        return false, "cooldown", left
    end
    return true
end

local REFUSALS = {
    running = "a scan is already running",
    ["api-missing"] = "the scan call is not available",
    ["ah-closed"] = "open the Auction House first",
    ["read-only"] = "scan data is read-only",
}

function Engine:Start()
    local ok, reason, detail = self:CanStart()
    if not ok then
        local text = REFUSALS[reason]
        if reason == "cooldown" then
            text = "scan on cooldown, " .. ns.ScanCooldown.FormatRemaining(detail) .. " left"
        end
        self.deps.report("full scan not started: " .. text)
        return false
    end
    self.running = true
    self.run = nil
    self.job = self.deps.startJob("full scan", function(job)
        return self:_Run(job)
    end)
    self.job:OnDone(function(_, status, ...)
        if status ~= "done" then
            self:_Abort(status, ...)
        end
    end)
    self.deps.report("full scan started")
    return true
end

function Engine:Cancel()
    if self.running and self.job then
        self.job:Cancel()
    end
end

local function newSummary()
    return {
        result = "ok", rows = 0, kept = 0, items = 0, keys = 0, newItems = 0, changed = 0,
        pendingMissing = 0, noKey = 0, unknownItems = 0, timeToEventMs = nil, cpuMs = 0, wallMs = 0, frames = 1,
    }
end

local function count(map)
    local n = 0
    for _ in pairs(map) do
        n = n + 1
    end
    return n
end

function Engine:_Unsubscribe()
    self.deps.bus:Unsubscribe(EVENT_REPLICATE, self)
    self.deps.bus:Unsubscribe(EVENT_CLOSED, self)
end

local function partialReasons(run, summary)
    local reasons = {}
    if run.readCut then
        reasons[#reasons + 1] = "the Auction House closed during the read"
    end
    if run.itemsMissing > 0 then
        reasons[#reasons + 1] = run.itemsMissing .. " items without data"
    end
    if (summary.unknownItems or 0) > 0 then
        reasons[#reasons + 1] = summary.unknownItems .. " items with unknown stack size"
    end
    if summary.noKey > 0 then
        reasons[#reasons + 1] = summary.noKey .. " rows without a key"
    end
    return table.concat(reasons, ", ")
end

function Engine:_ReportSummary(summary, run)
    local report = self.deps.report
    if summary.result == "ok" or summary.result == "partial" then
        report(string.format(
            "full scan %s: %d rows, %d items, %d keys, %d new, %d changed >30%%, cpu %d ms, wall %.1f s",
            summary.result, summary.rows, summary.items, summary.keys, summary.newItems, summary.changed,
            math.floor(summary.cpuMs + 0.5), summary.wallMs / 1000))
        if summary.result == "partial" and run then
            report("partial scan, latest values only: " .. partialReasons(run, summary))
        end
    elseif summary.result == "error" then
        report("full scan failed: " .. tostring(summary.error))
    else
        report("full scan " .. summary.result)
    end
end

-- Ends the run once: unsubscribes, fills the timing, reports, calls the callbacks.
function Engine:_Conclude(summary)
    local run = self.run
    if not run or run.concluded then
        return
    end
    run.concluded = true
    self:_Unsubscribe()
    self.running = false
    summary.wallMs = self.deps.ms() - run.startMs
    summary.cpuMs = summary.wallMs - run.suspendedMs
    summary.frames = run.frames
    if run.eventMs then
        summary.timeToEventMs = run.eventMs - run.callMs
    end
    self:_ReportSummary(summary, run)
    if self.deps.onFinished then
        pcall(self.deps.onFinished, summary)
    end
    self.deps.bus:Emit(EVENT_FINISHED, summary)
end

-- Called when the job ends without a normal return: cancel or error.
function Engine:_Abort(status, message)
    if not self.run then
        self.running = false
        return
    end
    local summary = newSummary()
    if status == "cancelled" then
        summary.result = "cancelled"
    else
        summary.result = "error"
        summary.error = message
    end
    self:_Conclude(summary)
end

-- A job view that adds the time spent suspended to the run.
local function clockedJob(job, run, ms)
    local view = {}
    local function pause(startMs)
        local gap = ms() - startMs
        run.suspendedMs = run.suspendedMs + gap
        if gap >= FRAME_GAP_MS then
            run.frames = run.frames + 1
        end
    end
    view.Checkpoint = function(_, units)
        local startMs = ms()
        job:Checkpoint(units)
        pause(startMs)
    end
    view.Yield = function()
        local startMs = ms()
        job:Yield()
        pause(startMs)
    end
    view.SetProgress = function(_, done, total)
        job:SetProgress(done, total)
    end
    view.IsCancelled = function()
        return job:IsCancelled()
    end
    return view
end

-- The api for ScanRows: after the Auction House closes, rows read as empty.
local function readApi(api, run)
    return {
        getNum = api.getNum,
        getInfo = function(index)
            if run.closed then
                run.readCut = true
                return nil
            end
            return api.getInfo(index)
        end,
        getLink = api.getLink,
        getPetInfo = api.getPetInfo,
    }
end

-- Returns true if the event came, false on timeout, nil if cancelled.
function Engine:_WaitForEvent(jobView)
    local run = self.run
    local seconds = self.deps.seconds
    local startTime = seconds()
    while not run.eventSeen do
        if seconds() - startTime >= ns.ScanClock.EVENT_TIMEOUT_SECONDS then
            return false
        end
        jobView:Yield()
        if jobView:IsCancelled() then
            return nil
        end
    end
    return true
end

-- Returns a map key -> list of auctions, the number of rows used and the number without a key.
function Engine:_BuildGroups(jobView, rows)
    local api = self.deps.api
    local resolver = ns.ScanKey.New({ clientIsCommodity = api.clientIsCommodity, maxStack = api.maxStack })
    local groups, used, noKey = {}, 0, 0
    local unknown, unknownItems = {}, 0
    for itemID, list in pairs(rows.byItem) do
        if not rows.pending[itemID] then
            for _, row in ipairs(list) do
                local key, reason = resolver:KeyFor(itemID, row.link)
                if not key and reason == "unknown" and not unknown[itemID] then
                    unknown[itemID] = true
                    unknownItems = unknownItems + 1
                end
                if key then
                    local auctions = groups[key]
                    if not auctions then
                        auctions = {}
                        groups[key] = auctions
                    end
                    auctions[#auctions + 1] = { unitPrice = row.unitPrice, count = row.count }
                    used = used + 1
                else
                    noKey = noKey + 1
                end
            end
            jobView:Checkpoint(1)
        end
    end
    return groups, used, noKey, resolver, unknownItems
end

-- Returns the items to load: pending items and items with an unknown commodity status.
function Engine:_LoadSet(jobView, rows)
    local api = self.deps.api
    local probe = ns.ScanKey.New({ clientIsCommodity = api.clientIsCommodity, maxStack = api.maxStack })
    local set = {}
    for itemID in pairs(rows.pending) do
        set[itemID] = true
    end
    for itemID in pairs(rows.byItem) do
        if not set[itemID] and probe:IsCommodity(itemID) == nil then
            set[itemID] = true
        end
        jobView:Checkpoint(1)
    end
    return set
end

-- Writes all snapshots in one frame. Returns the number of new keys and of changed keys.
function Engine:_Commit(snaps, partial)
    local store = self.deps.store
    local now = self.deps.serverTime()
    local newItems, changed = 0, 0
    for key, snap in pairs(snaps) do
        local record = store:Get(key)
        local old
        if record then
            old = record.latest and record.latest.market
        else
            newItems = newItems + 1
            record = ns.ScanRecord.New()
        end
        if old and old > 0 and math.abs(snap.market - old) / old > CHANGED_RATIO then
            changed = changed + 1
        end
        ns.ScanBucket.Apply(record, snap, now, partial)
        store:Put(key, record)
    end
    self.deps.cooldown:MarkSuccess()
    return newItems, changed
end

function Engine:_Run(job)
    local deps = self.deps
    local run = {
        startMs = deps.ms(), suspendedMs = 0, frames = 1, closed = false, eventSeen = false,
        readCut = false, itemsMissing = 0, concluded = false,
    }
    self.run = run
    local jobView = clockedJob(job, run, deps.ms)
    local summary = newSummary()

    deps.bus:Subscribe(EVENT_REPLICATE, self, function()
        run.eventSeen = true
        run.eventMs = deps.ms()
    end)
    deps.bus:Subscribe(EVENT_CLOSED, self, function()
        run.closed = true
    end)

    deps.cooldown:MarkAttempt()
    deps.cache:ResetFailed()
    run.callMs = deps.ms()
    local ok, err = pcall(deps.api.replicateItems)
    if not ok then
        deps.report("call failed: " .. tostring(err))
        summary.result = "call failed"
        return self:_Conclude(summary)
    end

    local arrived = self:_WaitForEvent(jobView)
    if arrived == nil then
        return
    end
    if not arrived then
        summary.result = RESULT_NO_RESPONSE
        return self:_Conclude(summary)
    end

    local rows = ns.ScanRows.Read(jobView, readApi(deps.api, run))
    if not rows then
        return
    end
    local clock = { clock = deps.seconds }
    local loadSet = self:_LoadSet(jobView, rows)
    local loaded, missing = ns.ScanItemLoad.Run(jobView, deps.cache, loadSet, clock)
    if not loaded then
        return
    end
    run.itemsMissing = count(missing)
    local loadedList = {}
    for itemID in pairs(loaded) do
        loadedList[#loadedList + 1] = itemID
    end
    ns.ScanRows.RereadLinks(jobView, deps.api, rows, loadedList)

    local groups, used, noKey, resolver, unknownItems = self:_BuildGroups(jobView, rows)
    local snaps, keyCount = {}, 0
    for key, auctions in pairs(groups) do
        jobView:Checkpoint(1)
        local snap = ns.ScanMarket.Reduce(auctions)
        if snap then
            snaps[key] = snap
            keyCount = keyCount + 1
        end
    end

    local pendingMissing = count(rows.pending)
    local partial = run.readCut or pendingMissing > 0 or noKey > 0 or run.itemsMissing > 0
    summary.noKey = noKey
    summary.unknownItems = unknownItems
    summary.pendingMissing = pendingMissing
    summary.rows = rows.stats.rows
    summary.kept = used
    summary.items = rows.stats.items
    summary.keys = keyCount
    summary.commodityStats = resolver:GetStats()
    summary.rowStats = rows.stats
    summary.result = partial and "partial" or "ok"
    summary.newItems, summary.changed = self:_Commit(snaps, partial)
    return self:_Conclude(summary)
end
