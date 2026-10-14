-- ScanTest: throwaway Spike 0 addon. It tests the full Auction House scan on WoW: Forever.

local ADDON_NAME = "ScanTest"
local SLICE_SIZE = 1000
local TIMEOUT_SECONDS = 60
local COOLDOWN_SECONDS = 15 * 60
local POPUP_NAME = "SCANTEST_WARNING"

local frame = CreateFrame("Frame")
local worker = CreateFrame("Frame")
local ahOpen = false
local scan -- working state of the run in progress, nil when idle
local stackCache = {} -- itemID -> max stack size, or false when unknown

local function say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("ScanTest: " .. msg)
end

local function fmt(value, pattern)
    if value == nil then
        return "n/a"
    end
    return string.format(pattern, value)
end

-- Build info: version, build number, interface number, project id.
local function buildInfo()
    local version, build, _, interface = GetBuildInfo()
    return {
        version = version,
        build = build,
        interface = interface,
        project = WOW_PROJECT_ID,
    }
end

local function newRun()
    return {
        date = date("%Y-%m-%d %H:%M:%S"),
        serverTime = GetServerTime(),
        build = buildInfo(),
        counts = {
            rows = 0,
            uniqueItems = 0,
            totalQuantity = 0,
            rowsWithBuyout = 0,
            rowsMissingInfo = 0,
            rowsStackable = 0,
            rowsStackUnknown = 0,
            emptyRows = 0,
        },
    }
end

local function printSummary(run)
    local c = run.counts
    say("result: " .. run.result)
    if run.error then
        say("error: " .. run.error)
    end
    say("time to first event: " .. fmt(run.timeToFirstEvent, "%.0f ms"))
    say("processing time: " .. fmt(run.processingMs, "%.0f ms") .. " in " .. fmt(run.frames, "%d") .. " frames")
    say("memory: before " .. fmt(run.memBefore, "%.0f KB") .. ", after " .. fmt(run.memAfter, "%.0f KB")
        .. ", difference " .. fmt(run.memDiff, "%.0f KB"))
    say("rows " .. c.rows .. ", unique items " .. c.uniqueItems .. ", total quantity " .. c.totalQuantity)
    say("rows with buyout " .. c.rowsWithBuyout .. ", missing info " .. c.rowsMissingInfo
        .. ", stackable " .. c.rowsStackable)
    say("stack size unknown " .. c.rowsStackUnknown .. ", empty rows " .. c.emptyRows)
end

-- Store the run in SavedVariables, print it and go idle.
local function saveRun(run, result, errorText)
    run.result = result
    run.error = errorText
    table.insert(ScanTestDB.runs, run)
    scan = nil
    worker:SetScript("OnUpdate", nil)
    printSummary(run)
end

local function getStackSize(itemID)
    local cached = stackCache[itemID]
    if cached == nil then
        cached = C_Item.GetItemMaxStackSizeByID(itemID) or false
        stackCache[itemID] = cached
    end
    return cached
end

-- Read one row. The index base (0 to n-1) is confirmed by the Spike 0 test.
local function readRow(run, seen, index)
    local c = run.counts
    local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID, hasAllInfo =
        C_AuctionHouse.GetReplicateItemInfo(index)
    c.rows = c.rows + 1
    c.totalQuantity = c.totalQuantity + (count or 0)
    if buyout and buyout > 0 then
        c.rowsWithBuyout = c.rowsWithBuyout + 1
    end
    if hasAllInfo ~= true then
        c.rowsMissingInfo = c.rowsMissingInfo + 1
    end
    if itemID == nil then
        c.emptyRows = c.emptyRows + 1
        return
    end
    if not seen[itemID] then
        seen[itemID] = true
        c.uniqueItems = c.uniqueItems + 1
    end
    local stack = getStackSize(itemID)
    if stack == false then
        c.rowsStackUnknown = c.rowsStackUnknown + 1
    elseif stack > 1 then
        c.rowsStackable = c.rowsStackable + 1
    end
end

local function finishScan()
    local run = scan.run
    run.processingMs = debugprofilestop() - scan.firstEventMs
    run.memAfter = collectgarbage("count")
    run.memDiff = run.memAfter - run.memBefore
    saveRun(run, "ok")
end

-- Read one slice of rows per frame.
local function processSlice()
    local first = scan.nextIndex
    local last = math.min(first + SLICE_SIZE - 1, scan.total - 1)
    for index = first, last do
        readRow(scan.run, scan.seen, index)
    end
    scan.nextIndex = last + 1
    scan.run.frames = scan.run.frames + 1
    if scan.nextIndex >= scan.total then
        finishScan()
    end
end

local function onFirstEvent()
    frame:UnregisterEvent("REPLICATE_ITEM_LIST_UPDATE")
    scan.state = "reading"
    scan.firstEventMs = debugprofilestop()
    scan.run.timeToFirstEvent = scan.firstEventMs - scan.startMs
    scan.total = C_AuctionHouse.GetNumReplicateItems() or 0
    scan.nextIndex = 0
    scan.run.frames = 0
    worker:SetScript("OnUpdate", processSlice)
end

local function onTimeout(timedScan)
    if scan ~= timedScan or scan.state ~= "waiting" then
        return
    end
    frame:UnregisterEvent("REPLICATE_ITEM_LIST_UPDATE")
    saveRun(scan.run, "no response (cooldown or blocked)")
end

local function startScan()
    if scan then
        return
    end
    ScanTestDB.lastAttempt = GetServerTime()
    local run = newRun()
    run.memBefore = collectgarbage("count")
    scan = { run = run, state = "waiting", seen = {}, startMs = debugprofilestop() }
    local thisScan = scan
    frame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
    local ok, err = pcall(C_AuctionHouse.ReplicateItems)
    if not ok then
        frame:UnregisterEvent("REPLICATE_ITEM_LIST_UPDATE")
        saveRun(run, "call failed", tostring(err))
        return
    end
    say("scan started, waiting for the event")
    C_Timer.After(TIMEOUT_SECONDS, function()
        onTimeout(thisScan)
    end)
end

StaticPopupDialogs[POPUP_NAME] = {
    text = "ScanTest: a full scan has disconnected clients on busy servers in the past.%s",
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = startScan,
    timeout = 0,
    hideOnEscape = true,
    showAlert = true,
}

-- Text that shows the time left of the 15-minute cooldown, or an empty string.
local function cooldownText()
    local last = ScanTestDB.lastAttempt
    if not last then
        return ""
    end
    local remaining = COOLDOWN_SECONDS - (GetServerTime() - last)
    if remaining <= 0 then
        return ""
    end
    return string.format("\nCooldown left: %d min %d s. You can still continue.",
        math.floor(remaining / 60), remaining % 60)
end

local function onSlash()
    if scan then
        say("a run is in progress")
        return
    end
    if not ahOpen then
        say("open the Auction House first")
        return
    end
    if not (C_AuctionHouse and C_AuctionHouse.ReplicateItems) then
        say("API not available")
        saveRun(newRun(), "API not available")
        return
    end
    StaticPopup_Show(POPUP_NAME, cooldownText())
end

local function onAddonLoaded()
    ScanTestDB = ScanTestDB or { lastAttempt = nil, runs = {} }
    ScanTestDB.runs = ScanTestDB.runs or {}
    local b = buildInfo()
    say("client " .. tostring(b.version) .. ", build " .. tostring(b.build)
        .. ", interface " .. tostring(b.interface) .. ", project id " .. tostring(b.project))
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            frame:UnregisterEvent("ADDON_LOADED")
            onAddonLoaded()
        end
    elseif event == "AUCTION_HOUSE_SHOW" then
        ahOpen = true
    elseif event == "AUCTION_HOUSE_CLOSED" then
        ahOpen = false
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
        if scan and scan.state == "waiting" then
            onFirstEvent()
        end
    end
end)

SLASH_SCANTEST1 = "/scantest"
SlashCmdList["SCANTEST"] = onSlash
