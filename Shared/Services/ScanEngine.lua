local _, ns = ...

-- Runs one full scan as a scheduler job: call, wait, read, load item data, reduce, commit.
local ScanEngine = {}
ns.ScanEngine = ScanEngine

local Engine = {}
Engine.__index = Engine

-- The scan done event comes from deps.api.doneEvent; this default is the Forever event name.
local EVENT_REPLICATE = "REPLICATE_ITEM_LIST_UPDATE"
local EVENT_CLOSED = "AUCTION_HOUSE_CLOSED" -- default; deps.api.closeEvent overrides it
local EVENT_FINISHED = "Flipside.ScanFinished"
local CHANGED_RATIO = 0.30
local FRAME_GAP_MS = 1

local RESULT_NO_RESPONSE = "no response (cooldown or blocked)"

-- Legacy (TBC) scan modes. The page mode reads the list page by page and needs no get all call.
local MODE_PAGE = "page"
local PAGE_SIZE = 50
local PAGE_QUERY_WAIT_SECONDS = 30
local PAGE_EVENT_WAIT_SECONDS = 20
local REFRESH_INTERVAL_SECONDS = 1

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

-- Returns the mode to use: nil without api.modes, otherwise the given mode or the first one.
-- Returns false if the mode is not in api.modes.
function Engine:_ResolveMode(mode)
    local modes = self.deps.api.modes
    if not modes then
        return nil
    end
    if mode == nil then
        return modes[1]
    end
    for _, name in ipairs(modes) do
        if name == mode then
            return mode
        end
    end
    return false
end

-- Returns true, or false with a reason and a detail. The mode is optional; see api.modes.
function Engine:CanStart(mode)
    local deps = self.deps
    mode = self:_ResolveMode(mode)
    if mode == false then
        return false, "bad-mode"
    end
    if self.running then
        return false, "running"
    end
    local isPage = mode == MODE_PAGE
    if (isPage and deps.api.pageQuery == nil) or (not isPage and deps.api.replicateItems == nil) then
        return false, "api-missing"
    end
    if not deps.isAuctionHouseOpen() then
        return false, "ah-closed"
    end
    if deps.store:IsReadOnly() then
        return false, "read-only"
    end
    local left = isPage and 0 or deps.cooldown:Remaining()
    if left > 0 then
        return false, "cooldown", left
    end
    -- Optional api.canStart(mode) gives true, or false and a text. Only the legacy backend defines it.
    if deps.api.canStart then
        local okClient, text = deps.api.canStart(mode)
        if not okClient then
            return false, "client", tostring(text)
        end
    end
    return true
end

local REFUSALS = {
    running = "a scan is already running",
    ["api-missing"] = "the scan call is not available",
    ["ah-closed"] = "open the Auction House first",
    ["read-only"] = "scan data is read-only",
    ["bad-mode"] = "unknown scan mode",
}

-- Starts a scan. The mode is optional; see api.modes.
function Engine:Start(mode)
    local ok, reason, detail = self:CanStart(mode)
    self.mode = self:_ResolveMode(mode) or nil
    self.label = (self.mode == nil or self.mode == "full") and "full scan" or (self.mode .. " scan")
    if not ok then
        local text = REFUSALS[reason]
        if reason == "cooldown" then
            text = "scan on cooldown, " .. ns.ScanCooldown.FormatRemaining(detail) .. " left"
        elseif reason == "client" then
            text = detail
        end
        self.deps.report(self.label .. " not started: " .. text)
        return false
    end
    self.running = true
    self.run = nil
    self.job = self.deps.startJob(self.label, function(job)
        return self:_Run(job)
    end)
    self.job:OnDone(function(_, status, ...)
        if status ~= "done" then
            self:_Abort(status, ...)
        end
    end)
    self.deps.report(self.label .. " started")
    return true
end

-- Returns the mode, the page and the page total of the running scan. The page values are nil before the first page.
function Engine:GetProgress()
    local run = self.run
    if not (self.running and run) then
        return nil
    end
    return self.mode, run.page, run.pages
end

function Engine:Cancel()
    if self.running and self.job then
        self.job:Cancel()
    end
end

local function newSummary()
    return {
        result = "ok", rows = 0, kept = 0, items = 0, keys = 0, newItems = 0, changed = 0,
        pendingMissing = 0, pending = 0, noKey = 0, unknownItems = 0, itemsKeyed = 0, itemsPendingMissing = 0,
        itemsNoLink = 0, itemsLinkMismatch = 0, itemsUnknown = 0, itemsLinkFallback = 0,
        keyedWithoutLink = 0, failed = 0, refreshSeconds = 0,
        timeToEventMs = nil, cpuMs = 0, wallMs = 0, frames = 1,
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
    self.deps.bus:Unsubscribe(self.deps.api.doneEvent or EVENT_REPLICATE, self)
    self.deps.bus:Unsubscribe(self.deps.api.closeEvent or EVENT_CLOSED, self)
end

local function partialReasons(run, summary)
    local reasons = {}
    if run.readCut then
        reasons[#reasons + 1] = "the Auction House closed during the read"
    end
    if summary.pending > 0 then
        reasons[#reasons + 1] = summary.pending .. " items pending"
    end
    if run.stop then
        reasons[#reasons + 1] = run.stop
    end
    return table.concat(reasons, ", ")
end

function Engine:_ReportSummary(summary, run)
    local report = self.deps.report
    if summary.result == "ok" or summary.result == "partial" then
        local word = summary.result
        if word == "ok" and summary.pending > 0 then
            word = "complete with " .. summary.pending .. " pending"
        end
        report(string.format(
            "%s %s: %d rows, %d items, %d keys, %d new, %d changed >30%%, cpu %d ms, "
                .. "wall %.1f s",
            summary.label or "full scan", word, summary.rows, summary.items, summary.keys,
            summary.newItems, summary.changed, math.floor(summary.cpuMs + 0.5), summary.wallMs / 1000))
        if summary.result == "partial" and run then
            report("partial scan, latest values only: " .. partialReasons(run, summary))
        elseif summary.pending > 0 then
            report(summary.pending .. " items without a key kept their old data")
        end
    elseif summary.result == "error" then
        report((summary.label or "full scan") .. " failed: " .. tostring(summary.error))
    else
        report((summary.label or "full scan") .. " " .. summary.result)
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
    summary.mode = self.mode
    summary.label = self.label
    summary.refreshSeconds = run.refreshSeconds
    summary.pages = run.page
    summary.pagesTotal = run.pages
    summary.failed = count(run.failedSet)
    summary.wallMs = self.deps.ms() - run.startMs
    summary.cpuMs = summary.wallMs - run.suspendedMs
    summary.frames = run.frames
    if run.eventMs then
        summary.timeToEventMs = run.eventMs - run.callMs
    end
    summary.events = run.eventCount
    if run.firstEventMs then
        summary.firstEventMs = run.firstEventMs - run.callMs
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
        getInfo = api.getInfo and function(index)
            if run.closed then
                run.readCut = true
                return nil
            end
            return api.getInfo(index)
        end,
        readRow = api.readRow and function(index)
            if run.closed then
                run.readCut = true
                return nil
            end
            return api.readRow(index)
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
    -- Optional api.settleSeconds: after the first event, wait until api.isComplete() or no event for that long.
    local api = self.deps.api
    while api.settleSeconds do
        if api.isComplete and api.isComplete() then
            break
        end
        if seconds() - run.lastEventAt >= api.settleSeconds then
            break
        end
        jobView:Yield()
        if jobView:IsCancelled() then
            return nil
        end
    end
    return true
end

local REASON_FIELDS = { ["no-link"] = "itemsNoLink", ["link-mismatch"] = "itemsLinkMismatch", unknown = "itemsUnknown" }

-- Returns a map key -> list of auctions, rows used, rows without a key, the resolver and item counts.
-- Each item is counted once: keyed, link fallback, pending, or the reason of its first failed row.
function Engine:_BuildGroups(jobView, rows)
    local api = self.deps.api
    local resolver = ns.ScanKey.New({ clientIsCommodity = api.clientIsCommodity, maxStack = api.maxStack })
    local groups, used, noKey, partialKeys = {}, 0, 0, {}
    local items = {
        itemsKeyed = 0, itemsLinkFallback = 0, itemsPendingMissing = 0,
        itemsNoLink = 0, itemsLinkMismatch = 0, itemsUnknown = 0, keyedWithoutLink = 0,
    }
    -- With api.canKeyWithoutLink (legacy backend), a row without a link does not block the item.
    local canKeyWithoutLink = api.canKeyWithoutLink
    for itemID, list in pairs(rows.byItem) do
        if rows.pending[itemID] and not canKeyWithoutLink then
            items.itemsPendingMissing = items.itemsPendingMissing + 1
        else
            local keyed, fallback, failField = false, false, nil
            local anyLink, withoutLink, blocked = false, false, false
            local itemKeys, unkeyedRows = {}, 0
            if canKeyWithoutLink then
                for _, row in ipairs(list) do
                    if row.link ~= nil then
                        anyLink = true
                        break
                    end
                end
            end
            for _, row in ipairs(list) do
                local key, isCommodity = resolver:KeyFor(itemID, row.link)
                if not key and canKeyWithoutLink and row.link == nil then
                    -- true: the item cannot have a suffix. nil: info unknown, use the base key if no row has a link.
                    local can = canKeyWithoutLink(itemID)
                    if can == true or (can == nil and not anyLink) then
                        key, isCommodity = ns.ItemString.ToBaseKey(itemID), false
                        withoutLink = true
                    else
                        blocked = true
                    end
                end
                if key then
                    keyed = true
                    fallback = fallback or isCommodity == nil
                    local auctions = groups[key]
                    if not auctions then
                        auctions = {}
                        groups[key] = auctions
                    end
                    auctions[#auctions + 1] = { unitPrice = row.unitPrice, count = row.count }
                    itemKeys[key] = true
                    used = used + 1
                else
                    failField = failField or REASON_FIELDS[isCommodity]
                    noKey = noKey + 1
                    unkeyedRows = unkeyedRows + 1
                end
            end
            -- An item with a row that has no key gives an incomplete price: its keys get latest values only.
            if unkeyedRows > 0 then
                for key in pairs(itemKeys) do
                    partialKeys[key] = true
                end
            end
            local field = failField or "itemsUnknown"
            if keyed then
                field = fallback and "itemsLinkFallback" or "itemsKeyed"
            elseif blocked then
                field = "itemsPendingMissing"
            end
            if withoutLink then
                items.keyedWithoutLink = items.keyedWithoutLink + 1
            end
            items[field] = items[field] + 1
            jobView:Checkpoint(1)
        end
    end
    return groups, used, noKey, resolver, items, partialKeys
end

-- Returns the items that still need a link: a row has no link and no key is possible without it.
function Engine:_NeedLinks(jobView, rows, resolver)
    local canKeyWithoutLink = self.deps.api.canKeyWithoutLink
    local need = {}
    for itemID, list in pairs(rows.byItem) do
        local missing = false
        for _, row in ipairs(list) do
            if row.link == nil then
                missing = true
                break
            end
        end
        if missing and resolver:IsCommodity(itemID) ~= true and canKeyWithoutLink(itemID) ~= true then
            need[#need + 1] = itemID
        end
        jobView:Checkpoint(1)
    end
    return need
end

-- Legacy backend: asks for item data and reads the missing links again, until all items are keyed or the time ends.
-- Returns true, or nil if the job is cancelled.
function Engine:_Refresh(jobView, rows, seconds, run)
    local deps, api = self.deps, self.deps.api
    local resolver = ns.ScanKey.New({ clientIsCommodity = api.clientIsCommodity, maxStack = api.maxStack })
    local interval = api.refreshInterval or REFRESH_INTERVAL_SECONDS
    local startAt = deps.seconds()
    while true do
        local need = self:_NeedLinks(jobView, rows, resolver)
        if #need == 0 or deps.seconds() - startAt >= seconds then
            for _, itemID in ipairs(need) do
                if deps.cache:GetState(itemID) == "failed" then
                    run.failedSet[itemID] = true
                end
            end
            run.refreshSeconds = run.refreshSeconds + (deps.seconds() - startAt)
            return true
        end
        deps.cache:ResetFailed()
        for _, itemID in ipairs(need) do
            deps.cache:Request(itemID)
            jobView:Checkpoint(1)
        end
        local waitStart = deps.seconds()
        while deps.seconds() - waitStart < interval do
            jobView:Yield()
            if jobView:IsCancelled() then
                return nil
            end
        end
        ns.ScanRows.RereadLinks(jobView, api, rows, need, true)
    end
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

-- Writes all snapshots in one frame. partial marks the whole read as incomplete; partialKeys marks single keys.
-- Returns the number of new keys and of changed keys.
function Engine:_Commit(snaps, partial, partialKeys)
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
        ns.ScanBucket.Apply(record, snap, now, partial or (partialKeys and partialKeys[key]) or false)
        store:Put(key, record)
    end
    self.deps.cooldown:MarkSuccess()
    return newItems, changed
end

-- Waits until check() is true. Returns true, false on timeout, or nil if the job is cancelled.
function Engine:_WaitFor(jobView, check, timeout)
    local seconds = self.deps.seconds
    local startTime = seconds()
    while not check() do
        if seconds() - startTime >= timeout then
            return false
        end
        jobView:Yield()
        if jobView:IsCancelled() then
            return nil
        end
    end
    return true
end

-- Get all: one call, wait for the event, read all rows.
function Engine:_CollectAll(jobView, run, summary)
    local deps = self.deps
    deps.cooldown:MarkAttempt()
    local ok, err = pcall(deps.api.replicateItems, self.mode)
    if not ok then
        deps.report("call failed: " .. tostring(err))
        summary.result = "call failed"
        self:_Conclude(summary)
        return false
    end
    local arrived = self:_WaitForEvent(jobView)
    if arrived == nil then
        return nil
    end
    if not arrived then
        summary.result = RESULT_NO_RESPONSE
        self:_Conclude(summary)
        return false
    end
    return ns.ScanRows.Read(jobView, readApi(deps.api, run))
end

-- Page mode: one query for each page. Each page is read, its missing links are read again for a short time,
-- and its rows are added to one result. The caller commits the result once.
function Engine:_CollectPages(jobView, run, summary)
    local api = self.deps.api
    local size = api.pageSize or PAGE_SIZE
    local merged = ns.ScanRows.NewResult()
    local readView = setmetatable({ SetProgress = function() end }, { __index = jobView })
    local page = 0
    while true do
        local ready = self:_WaitFor(jobView, api.canQueryPage, PAGE_QUERY_WAIT_SECONDS)
        if ready == nil then
            return nil
        end
        if run.closed then
            run.readCut = true
            break
        end
        if not ready then
            run.stop = "the Auction House did not accept page " .. (page + 1)
            break
        end
        run.eventSeen = false
        local ok, err = pcall(api.pageQuery, page)
        if not ok then
            run.stop = "page " .. (page + 1) .. " failed: " .. tostring(err)
            break
        end
        local arrived = self:_WaitFor(jobView, function()
            return run.eventSeen or run.closed
        end, PAGE_EVENT_WAIT_SECONDS)
        if arrived == nil then
            return nil
        end
        if run.closed then
            run.readCut = true
            break
        end
        if not arrived then
            run.stop = "no answer for page " .. (page + 1)
            break
        end
        local total = api.pageTotal and api.pageTotal() or 0
        run.pages = math.max(1, math.ceil((tonumber(total) or 0) / size))
        local rows = ns.ScanRows.Read(readView, readApi(api, run))
        if not rows then
            return nil
        end
        local seconds = api.refreshSeconds and api.refreshSeconds(MODE_PAGE) or 0
        if api.canKeyWithoutLink and not self:_Refresh(jobView, rows, seconds, run) then
            return nil
        end
        ns.ScanRows.Merge(merged, rows)
        page = page + 1
        run.page = page
        jobView:SetProgress(page, run.pages)
        if page >= run.pages or rows.stats.rows == 0 then
            break
        end
    end
    if merged.stats.rows == 0 and run.stop then
        summary.result = RESULT_NO_RESPONSE
        self:_Conclude(summary)
        return false
    end
    return merged
end

function Engine:_Run(job)
    local deps = self.deps
    local run = {
        startMs = deps.ms(), suspendedMs = 0, frames = 1, closed = false, eventSeen = false,
        readCut = false, concluded = false, eventCount = 0, lastEventAt = 0,
        refreshSeconds = 0, failedSet = {},
    }
    self.run = run
    local jobView = clockedJob(job, run, deps.ms)
    local summary = newSummary()

    deps.bus:Subscribe(deps.api.doneEvent or EVENT_REPLICATE, self, function()
        run.eventSeen = true
        run.eventCount = run.eventCount + 1
        run.lastEventAt = deps.seconds()
        run.eventMs = deps.ms()
        run.firstEventMs = run.firstEventMs or run.eventMs
    end)
    deps.bus:Subscribe(deps.api.closeEvent or EVENT_CLOSED, self, function()
        run.closed = true
    end)

    deps.cache:ResetFailed()
    run.callMs = deps.ms()
    local isPage = self.mode == MODE_PAGE
    -- Both collect calls give the rows, or nil if the job is cancelled, or false if the run is already concluded.
    local rows
    if isPage then
        rows = self:_CollectPages(jobView, run, summary)
    else
        rows = self:_CollectAll(jobView, run, summary)
    end
    if not rows then
        return
    end
    -- Page rows were refreshed one page at a time; their row indexes are no longer valid, so no refresh here.
    if not isPage and deps.api.canKeyWithoutLink then
        local seconds = deps.api.refreshSeconds and deps.api.refreshSeconds(self.mode) or 0
        if not self:_Refresh(jobView, rows, seconds, run) then
            return
        end
    elseif not isPage then
        local clock = { clock = deps.seconds }
        local loadSet = self:_LoadSet(jobView, rows)
        local loaded = ns.ScanItemLoad.Run(jobView, deps.cache, loadSet, clock)
        if not loaded then
            return
        end
        local loadedList = {}
        for itemID in pairs(loaded) do
            loadedList[#loadedList + 1] = itemID
        end
        ns.ScanRows.RereadLinks(jobView, deps.api, rows, loadedList)
    end
    local groups, used, noKey, resolver, itemCounts, partialKeys = self:_BuildGroups(jobView, rows)
    local snaps, keyCount = {}, 0
    for key, auctions in pairs(groups) do
        jobView:Checkpoint(1)
        local snap = ns.ScanMarket.Reduce(auctions)
        if snap then
            snaps[key] = snap
            keyCount = keyCount + 1
        end
    end

    -- Only an incomplete read makes the scan partial. An item without a key keeps its old data (no write).
    local pendingMissing = itemCounts.itemsPendingMissing
    local partial = run.readCut or run.stop ~= nil
    summary.noKey = noKey
    summary.pending = pendingMissing + itemCounts.itemsNoLink + itemCounts.itemsLinkMismatch
        + itemCounts.itemsUnknown
    summary.unknownItems = itemCounts.itemsUnknown
    for field, value in pairs(itemCounts) do
        summary[field] = value
    end
    summary.pendingMissing = pendingMissing
    summary.rows = rows.stats.rows
    summary.kept = used
    summary.items = rows.stats.items
    summary.keys = keyCount
    summary.commodityStats = resolver:GetStats()
    summary.rowStats = rows.stats
    summary.result = partial and "partial" or "ok"
    summary.newItems, summary.changed = self:_Commit(snaps, partial, partialKeys)
    return self:_Conclude(summary)
end



