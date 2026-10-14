-- ScanTest (TBC): throwaway spike. It tests the legacy getAll scan on TBC Anniversary.

local ADDON_NAME = "ScanTest"
local SLICE_SIZE = 1000
local FIRST_EVENT_TIMEOUT = 120
local SECOND_PASS_DELAY = 5
local POLL_SECONDS = 10
local POLL_MAX_SECONDS = 20 * 60
local POPUP_NAME = "SCANTEST_TBC_WARNING"

local frame = CreateFrame("Frame")
local worker = CreateFrame("Frame")
local scan -- working state of the run in progress, nil when idle

local function say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("ScanTest TBC: " .. msg)
end

local function fmt(value, pattern)
    if value == nil then
        return "n/a"
    end
    return string.format(pattern, value)
end

local function ahIsOpen()
    return AuctionFrame ~= nil and AuctionFrame:IsShown()
end

local function region()
    if GetCurrentRegionName then
        return GetCurrentRegionName()
    end
    return nil
end

local function newRun()
    local version, build, buildDate, interface = GetBuildInfo()
    return {
        date = date("%Y-%m-%d %H:%M:%S"),
        serverTime = GetServerTime(),
        build = { version = version, build = build, buildDate = buildDate, interface = interface },
        project = WOW_PROJECT_ID,
        region = region(),
        events = 0,
    }
end

local function printSummary(run)
    say("result: " .. run.result)
    if run.error then
        say("error: " .. run.error)
    end
    say("can query before: " .. tostring(run.canQueryBefore)
        .. ", can getAll before: " .. tostring(run.canGetAllBefore))
    say("time to first event: " .. fmt(run.timeToFirstEvent, "%.0f ms") .. ", list update events: " .. run.events)
    say("GetNumAuctionItems: batch " .. tostring(run.numBatch) .. ", total " .. tostring(run.numTotal))
    local p = run.pass1
    if p then
        say("read: " .. fmt(run.readMs, "%.0f ms") .. " in " .. fmt(run.frames, "%d") .. " frames, rows " .. p.rows
            .. ", unique items " .. p.uniqueItems .. ", nil link " .. p.nilLink .. ", nil name " .. p.nilName
            .. ", zero buyout " .. p.zeroBuyout)
        say("GetAuctionItemInfo returns: " .. tostring(run.infoReturns))
    end
    if run.pass2 then
        say("second pass: nil link " .. run.pass2.nilLink .. ", nil name " .. run.pass2.nilName
            .. ", filled links " .. tostring(run.filledLinks) .. ", filled names " .. tostring(run.filledNames))
    end
    say("getAll ready again: " .. tostring(run.getAllReadyAfter))
end

-- Store the run in SavedVariables, print it and go idle.
local function saveRun(run, result, errorText)
    run.result = result
    run.error = errorText
    table.insert(ScanTestDB.runs, run)
    scan = nil
    worker:SetScript("OnUpdate", nil)
    frame:UnregisterEvent("AUCTION_ITEM_LIST_UPDATE")
    printSummary(run)
end

local function newStats()
    return { rows = 0, uniqueItems = 0, nilLink = 0, nilName = 0, zeroBuyout = 0, seen = {} }
end

local function pack(...)
    return select("#", ...), { ... }
end

-- Read one row into the stats. Info return 17 is itemId, return 10 is buyoutPrice (Blizzard_AuctionUI.lua:977).
local function readRow(run, stats, index)
    local n, info = pack(GetAuctionItemInfo("list", index))
    local link = GetAuctionItemLink("list", index)
    stats.rows = stats.rows + 1
    if not run.infoReturns then
        run.infoReturns = n
    end
    if link == nil then
        stats.nilLink = stats.nilLink + 1
    end
    if info[1] == nil then
        stats.nilName = stats.nilName + 1
    end
    if not info[10] or info[10] == 0 then
        stats.zeroBuyout = stats.zeroBuyout + 1
    end
    local itemID = info[17]
    if itemID and not stats.seen[itemID] then
        stats.seen[itemID] = true
        stats.uniqueItems = stats.uniqueItems + 1
    end
    -- Keep the first row that has a name, with every return value as text.
    if not run.sample and info[1] ~= nil then
        local sample = { index = index, link = tostring(link) }
        for i = 1, n do
            sample[i] = tostring(info[i])
        end
        run.sample = sample
    end
end

local function startPolling()
    scan.state = "polling"
    local thisScan = scan
    local startMs = scan.startMs
    local function poll()
        if scan ~= thisScan then
            return
        end
        local waited = (debugprofilestop() - startMs) / 1000
        if not ahIsOpen() then
            thisScan.run.getAllReadyAfter = "AH closed after " .. string.format("%.0f s", waited)
            saveRun(thisScan.run, "ok")
            return
        end
        local _, canGetAll = CanSendAuctionQuery()
        if canGetAll then
            thisScan.run.getAllReadyAfter = string.format("%.0f s", waited)
            saveRun(thisScan.run, "ok")
        elseif waited >= POLL_MAX_SECONDS then
            thisScan.run.getAllReadyAfter = "not ready after " .. string.format("%.0f s", waited)
            saveRun(thisScan.run, "ok")
        else
            C_Timer.After(POLL_SECONDS, poll)
        end
    end
    say("read done. Keep the AH open. Polling the getAll cooldown every " .. POLL_SECONDS .. " s, max 20 min.")
    C_Timer.After(POLL_SECONDS, poll)
end

local function endPass(run)
    if scan.pass == 1 then
        scan.stats.seen = nil
        run.pass1 = scan.stats
        run.readMs = debugprofilestop() - scan.readStartMs
        say("read done, second pass in " .. SECOND_PASS_DELAY .. " s")
        worker:SetScript("OnUpdate", nil)
        local thisScan = scan
        C_Timer.After(SECOND_PASS_DELAY, function()
            if scan ~= thisScan then
                return
            end
            scan.pass = 2
            scan.stats = newStats()
            scan.nextIndex = 1
            worker:SetScript("OnUpdate", scan.slice)
        end)
    else
        scan.stats.seen = nil
        run.pass2 = scan.stats
        run.filledLinks = run.pass1.nilLink - run.pass2.nilLink
        run.filledNames = run.pass1.nilName - run.pass2.nilName
        worker:SetScript("OnUpdate", nil)
        startPolling()
    end
end

-- Read one slice of rows per frame.
local function processSlice()
    local run = scan.run
    local first = scan.nextIndex
    local last = math.min(first + SLICE_SIZE - 1, scan.total)
    for index = first, last do
        readRow(run, scan.stats, index)
    end
    scan.nextIndex = last + 1
    if scan.pass == 1 then
        run.frames = (run.frames or 0) + 1
    end
    if scan.nextIndex > scan.total then
        endPass(run)
    end
end

local function onFirstEvent()
    local now = debugprofilestop()
    scan.run.timeToFirstEvent = now - scan.startMs
    scan.state = "reading"
    local batch, total = GetNumAuctionItems("list")
    scan.run.numBatch = batch
    scan.run.numTotal = total
    scan.total = batch or 0
    scan.pass = 1
    scan.stats = newStats()
    scan.nextIndex = 1
    scan.readStartMs = now
    scan.slice = processSlice
    worker:SetScript("OnUpdate", processSlice)
end

local function onTimeout(timedScan)
    if scan ~= timedScan or scan.state ~= "waiting" then
        return
    end
    saveRun(scan.run, "no response (cooldown or blocked)")
end

local function startScan()
    if scan then
        return
    end
    local run = newRun()
    run.canQueryBefore, run.canGetAllBefore = CanSendAuctionQuery()
    scan = { run = run, state = "waiting", startMs = debugprofilestop() }
    local thisScan = scan
    frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
    local ok, err = pcall(QueryAuctionItems, "", nil, nil, 0, nil, nil, true)
    if not ok then
        saveRun(run, "call failed", tostring(err))
        return
    end
    say("getAll query sent, waiting for the event")
    C_Timer.After(FIRST_EVENT_TIMEOUT, function()
        onTimeout(thisScan)
    end)
end

StaticPopupDialogs[POPUP_NAME] = {
    text = "ScanTest TBC: a getAll scan has disconnected clients in the past. Keep the AH open for the cooldown test.",
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = startScan,
    timeout = 0,
    hideOnEscape = true,
    showAlert = true,
}

local function onSlash(msg)
    if msg == "stop" and scan then
        saveRun(scan.run, "stopped by user")
        return
    end
    if scan then
        say("a run is in progress. Type '/scantest stop' to end it.")
        return
    end
    if not ahIsOpen() then
        say("open the Auction House first")
        return
    end
    if not (QueryAuctionItems and CanSendAuctionQuery) then
        say("API not available")
        saveRun(newRun(), "API not available")
        return
    end
    StaticPopup_Show(POPUP_NAME)
end

frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            frame:UnregisterEvent("ADDON_LOADED")
            ScanTestDB = ScanTestDB or { runs = {} }
            ScanTestDB.runs = ScanTestDB.runs or {}
            local version, build, _, interface = GetBuildInfo()
            say("client " .. tostring(version) .. ", build " .. tostring(build)
                .. ", interface " .. tostring(interface) .. ", project id " .. tostring(WOW_PROJECT_ID))
        end
    elseif event == "AUCTION_ITEM_LIST_UPDATE" then
        if scan then
            scan.run.events = scan.run.events + 1
            if scan.state == "waiting" then
                onFirstEvent()
            end
        end
    end
end)

SLASH_SCANTEST1 = "/scantest"
SlashCmdList["SCANTEST"] = onSlash
