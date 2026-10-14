local addonName, ns = ...

local PREFIX = "Flipside: "

-- Game events have upper-case names; internal events (for example "Flipside.Loaded") never match.
local GAME_EVENT_PATTERN = "^[A-Z][A-Z0-9_]*$"

-- The init frame always listens to these events.
local ALWAYS_REGISTERED = { ADDON_LOADED = true, PLAYER_LOGIN = true }

-- Print one line to the chat frame.
local function printLine(text)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. text)
end

-- Show an error as one chat line.
function ns.ReportError(message)
    printLine((tostring(message):gsub("%s*\n%s*", " ")))
end

-- Game event frame: registers an event only while the bus has a subscriber for it.
local eventFrame = CreateFrame("Frame")

local function isGameEvent(event)
    return event:match(GAME_EVENT_PATTERN) ~= nil and not ALWAYS_REGISTERED[event]
end

ns.bus = ns.EventBus.New({
    onError = function(event, _, err)
        ns.ReportError("handler for " .. tostring(event) .. " failed: " .. tostring(err))
    end,
    onFirstSubscriber = function(event)
        if isGameEvent(event) then
            local ok, err = pcall(eventFrame.RegisterEvent, eventFrame, event)
            if not ok then
                ns.ReportError("cannot register event " .. event .. ": " .. tostring(err))
            end
        end
    end,
    onLastUnsubscribed = function(event)
        if isGameEvent(event) then
            eventFrame:UnregisterEvent(event)
        end
    end,
})

ns.scheduler = ns.Scheduler.New({
    clock = debugprofilestop,
    onError = function(job, message)
        ns.ReportError("job " .. tostring(job.name) .. " failed: " .. tostring(message))
    end,
})

-- Item info cache: the client event ITEM_DATA_LOAD_RESULT feeds it through the bus.
ns.itemCache = ns.ItemInfoCache.New({
    getInfo = function(itemID)
        return ns.ItemInfoCache.FromItemInfo(C_Item.GetItemInfo(itemID))
    end,
    requestLoad = function(itemID)
        C_Item.RequestLoadItemDataByID(itemID)
    end,
    onError = ns.ReportError,
})
ns.bus:Subscribe("ITEM_DATA_LOAD_RESULT", ns.itemCache, function(_, itemID, success)
    ns.itemCache:OnLoadResult(itemID, success)
end)

-- Character key Name-Realm, or nil if the client gives no name or realm.
local function characterKey()
    local name = UnitName("player")
    local realm = GetNormalizedRealmName()
    if type(name) ~= "string" or name == "" or type(realm) ~= "string" or realm == "" then
        return nil
    end
    return name .. "-" .. realm
end

-- Open the settings DB; leave ns.db nil and print one line if that is not possible.
local function openSettingsDB()
    local character = characterKey()
    if not character then
        ns.ReportError("settings are not available this session (no character name or realm)")
        return
    end
    if type(FlipsideDB) ~= "table" then
        FlipsideDB = {}
    end
    local ok, result = pcall(ns.SettingsDB.New, FlipsideDB, {
        character = character,
        schemaVersion = 1,
        onWarning = ns.ReportError,
    })
    if not ok then
        ns.ReportError("settings are not available this session: " .. tostring(result))
        return
    end
    ns.db = result
    ns.bus:Emit("Flipside.DBReady")
end

-- Auction House state, from the client events.
local auctionHouseOpen = false

function ns.IsAuctionHouseOpen()
    return auctionHouseOpen
end

local function trackAuctionHouse()
    ns.bus:Subscribe("AUCTION_HOUSE_SHOW", "Flipside.Init", function()
        auctionHouseOpen = true
    end)
    ns.bus:Subscribe("AUCTION_HOUSE_CLOSED", "Flipside.Init", function()
        auctionHouseOpen = false
    end)
end

-- Item key of an item id for the commodity check; nil if the client does not know it.
local function clientIsCommodity(itemID)
    local info = C_AuctionHouse.GetItemKeyInfo(C_AuctionHouse.MakeItemKey(itemID))
    if type(info) == "table" and type(info.isCommodity) == "boolean" then
        return info.isCommodity
    end
    return nil
end

-- Read access to the client replicate API, in the form that the scan engine needs.
local function buildScanApi()
    local ah = C_AuctionHouse
    local api = {
        getNum = ah.GetNumReplicateItems,
        getInfo = ah.GetReplicateItemInfo,
        getLink = ah.GetReplicateItemLink,
        getPetInfo = ah.GetReplicateItemBattlePetInfo,
        maxStack = C_Item.GetItemMaxStackSizeByID,
    }
    if type(ah.ReplicateItems) == "function" then
        api.replicateItems = ah.ReplicateItems
    end
    if type(ah.MakeItemKey) == "function" and type(ah.GetItemKeyInfo) == "function" then
        api.clientIsCommodity = clientIsCommodity
    end
    return api
end

-- Roll up and prune the stored records of earlier days, in a job.
local function startRollUp()
    ns.StartJob("scan-rollup", function(job)
        local store = ns.scanStore
        if store:IsReadOnly() then
            return
        end
        local today = ns.ScanClock.DayOf(GetServerTime())
        for _, key in ipairs(store:Keys()) do
            local record = store:Get(key)
            if record then
                local changed = ns.ScanBucket.RollUp(record, today)
                if ns.ScanBucket.Prune(record, today) > 0 then
                    changed = true
                end
                if ns.ScanBucket.IsEmpty(record) then
                    store:Remove(key)
                elseif changed then
                    store:Put(key, record)
                end
            end
            job:Checkpoint(1)
        end
    end)
end

-- Open the scan store and the scan engine; print one line if that is not possible.
local function openScan()
    if not (ns.ScanStore and ns.ScanEngine and ns.ScanCooldown and ns.ScanClock) then
        return
    end
    local region = GetCurrentRegionName and GetCurrentRegionName()
    if type(region) ~= "string" or region == "" then
        ns.ReportError("scan is not available this session (no region name)")
        return
    end
    local meta = {}
    local okRules, standard = pcall(function()
        return C_GameRules.IsStandard()
    end)
    if okRules and type(standard) == "boolean" then
        meta.isStandard = standard
    end
    if type(FlipsideScanDB) ~= "table" then
        FlipsideScanDB = {}
    end
    local ok, result = pcall(ns.ScanStore.New, FlipsideScanDB, {
        region = region,
        ruleset = ns.ScanClock.RULESET_DEFAULT,
        meta = meta,
        schemaVersion = 1,
        onWarning = ns.ReportError,
    })
    if not ok then
        ns.ReportError("scan is not available this session: " .. tostring(result))
        return
    end
    ns.scanStore = result
    ns.scanCooldown = ns.ScanCooldown.New(ns.db, { clock = GetServerTime })
    local okEngine, engine = pcall(ns.ScanEngine.New, {
        bus = ns.bus,
        startJob = ns.StartJob,
        store = ns.scanStore,
        cooldown = ns.scanCooldown,
        cache = ns.itemCache,
        api = buildScanApi(),
        serverTime = GetServerTime,
        seconds = GetTime,
        ms = debugprofilestop,
        isAuctionHouseOpen = ns.IsAuctionHouseOpen,
        report = printLine,
    })
    if not okEngine then
        ns.ReportError("scan is not available this session: " .. tostring(engine))
        return
    end
    ns.scanEngine = engine
    ns.bus:Subscribe("PLAYER_LOGOUT", "Flipside.Init", function()
        local okFlush, err = pcall(ns.scanStore.Flush, ns.scanStore)
        if not okFlush then
            ns.ReportError("scan data was not saved: " .. tostring(err))
        end
    end)
    startRollUp()
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" and (...) == addonName then
        ns.bus:Emit("Flipside.Loaded")
    elseif event == "PLAYER_LOGIN" then
        trackAuctionHouse()
        openSettingsDB()
        if ns.db then
            openScan()
        end
        ns.bus:Emit("Flipside.Login")
    end
    ns.bus:Emit(event, ...)
end)
for event in pairs(ALWAYS_REGISTERED) do
    eventFrame:RegisterEvent(event)
end

-- Update frame: it runs OnUpdate only while it is shown, which is while jobs exist.
local updateFrame = CreateFrame("Frame")
updateFrame:Hide()
updateFrame:SetScript("OnUpdate", function()
    ns.scheduler:Tick()
    if ns.scheduler:IsIdle() then
        updateFrame:Hide()
    end
end)

-- Start a job on the shared scheduler and make sure the frame ticks.
function ns.StartJob(name, fn, ...)
    local job = ns.scheduler:Start(name, fn, ...)
    updateFrame:Show()
    return job
end

-- Print the client version line.
local function printVersion()
    local version, build, _, interface = GetBuildInfo()
    printLine("client " .. tostring(version) .. ", build " .. tostring(build) .. ", interface " .. tostring(interface))
end

local REFUSALS = {
    running = "a scan is already running",
    ["api-missing"] = "the scan call is not available",
    ["ah-closed"] = "open the Auction House first",
    ["read-only"] = "scan data is read-only",
}

-- Print why a scan cannot start.
local function printRefusal(reason, detail)
    local text = REFUSALS[reason] or tostring(reason)
    if reason == "cooldown" then
        text = "scan on cooldown, " .. ns.ScanCooldown.FormatRemaining(detail) .. " left"
    end
    printLine("full scan not started: " .. text)
end

StaticPopupDialogs["FLIPSIDE_FULL_SCAN"] = {
    text = "Flipside: a full scan has disconnected clients on busy servers in the past. Start the full scan?",
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = function()
        local engine = ns.scanEngine
        if not engine then
            return
        end
        local ok, reason, detail = engine:CanStart()
        if ok then
            engine:Start()
        else
            printRefusal(reason, detail)
        end
    end,
    timeout = 0,
    hideOnEscape = true,
    showAlert = true,
}

local function scanCommand(argument)
    local engine = ns.scanEngine
    if not engine then
        printLine("scan is not available this session")
        return
    end
    if argument == "stop" then
        if engine:IsRunning() then
            engine:Cancel()
        else
            printLine("no scan is running")
        end
        return
    end
    local ok, reason, detail = engine:CanStart()
    if not ok then
        printRefusal(reason, detail)
        return
    end
    StaticPopup_Show("FLIPSIDE_FULL_SCAN")
end

-- Money in copper as "Xg Ys Zc".
local function formatMoney(copper)
    if type(copper) ~= "number" then
        return "-"
    end
    copper = math.floor(copper + 0.5)
    return string.format("%dg %ds %dc", math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

local function priceText(name, copper)
    if type(copper) ~= "number" then
        return name .. " -"
    end
    return string.format("%s %d (%s)", name, math.floor(copper + 0.5), formatMoney(copper))
end

-- Find the record for an item link or item id. Returns the record, the key and the keys tried.
local function findRecord(argument)
    local keys = {}
    if argument:match("^%d+$") then
        if ns.ItemString.ParseKey(argument) then
            keys[1] = argument
        end
    else
        local exact, base = ns.ItemString.ToExactKey(argument), ns.ItemString.ToBaseKey(argument)
        keys[1] = exact
        if base and base ~= exact then
            keys[#keys + 1] = base
        end
    end
    for _, key in ipairs(keys) do
        local record = ns.scanStore:Get(key)
        if record then
            return record, key, keys
        end
    end
    return nil, nil, keys
end

local function priceCommand(argument)
    if not ns.scanStore then
        printLine("scan is not available this session")
        return
    end
    local record, key, keys = findRecord(argument)
    if #keys == 0 then
        printLine("usage: /flip price <item link or item id>")
        return
    end
    if not record then
        printLine("no scan data for " .. table.concat(keys, " or "))
        return
    end
    local values = ns.ScanSources.Compute(record, GetServerTime())
    printLine("key " .. key .. ": " .. priceText("ScanMin", values.scanMin) .. ", "
        .. priceText("ScanRecent", values.scanRecent))
    printLine(priceText("ScanMarket", values.scanMarket) .. ", "
        .. priceText("ScanHistorical", values.scanHistorical))
    local age = values.scanAge and string.format("%.1f h", values.scanAge) or "-"
    printLine("ScanQty " .. tostring(values.scanQty or "-") .. ", ScanAge " .. age
        .. ", ScanSamples " .. values.scanSamples .. (values.scanPartial and ", partial" or ""))
end

local function printScanHelp()
    local last = ns.scanCooldown:GetLastSuccess()
    local age = "never"
    if type(last) == "number" then
        age = string.format("%.1f h ago", ns.ScanClock.HoursBetween(last, GetServerTime()))
    end
    local left = ns.scanCooldown:Remaining()
    local cooldown = left > 0 and ns.ScanCooldown.FormatRemaining(left) or "ready"
    printLine(string.format("scan: %d items stored, last scan %s, cooldown %s",
        ns.scanStore:CountItems(), age, cooldown))
    printLine("commands: scan, scan stop, price <item>, version")
end

-- Handle the text after /flipside or /flip.
function ns.HandleSlash(msg)
    local text = tostring(msg or "")
    local command, rest = text:match("^%s*(%S*)%s*(.-)%s*$")
    command = command:lower()
    if command == "version" then
        printVersion()
        return
    elseif command == "scan" then
        scanCommand(rest:lower())
        return
    elseif command == "price" then
        priceCommand(rest)
        return
    end
    printLine("addon Flipside")
    if ns.db then
        printLine("profile " .. ns.db:GetProfile())
    end
    printVersion()
    if ns.scanStore and ns.scanCooldown then
        printScanHelp()
    end
    printLine("No feature exists yet.")
end

SLASH_FLIPSIDE1 = "/flipside"
SLASH_FLIPSIDE2 = "/flip"
SlashCmdList.FLIPSIDE = ns.HandleSlash