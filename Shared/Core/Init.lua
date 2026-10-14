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
    local name = ns.Flavour.savedVariables.main
    if type(_G[name]) ~= "table" then
        _G[name] = {}
    end
    local ok, result = pcall(ns.SettingsDB.New, _G[name], {
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
    local openEvent, closeEvent = ns.AuctionClient.OpenEvent(), ns.AuctionClient.CloseEvent()
    if openEvent then
        ns.bus:Subscribe(openEvent, "Flipside.Init", function()
            auctionHouseOpen = true
        end)
    end
    if closeEvent then
        ns.bus:Subscribe(closeEvent, "Flipside.Init", function()
            auctionHouseOpen = false
        end)
    end
end


-- Max stack size from the client, or from the item cache when the client gives none.
local function maxStack(itemID)
    local size = C_Item.GetItemMaxStackSizeByID(itemID)
    if size ~= nil then
        return size
    end
    local info = ns.itemCache:Get(itemID)
    return info and info.stackCount or nil
end

-- Read access to the auction client scan calls, in the form that the scan engine needs.
local function buildScanApi()
    local client = ns.AuctionClient
    local api = {
        getNum = client.RowCount,
        readRow = client.ReadRow,
        getLink = client.RowLink,
        -- ScanRows treats any non-nil result as a battle pet.
        getPetInfo = function(index)
            if client.RowIsPet(index) then
                return true
            end
            return nil
        end,
        maxStack = maxStack,
        doneEvent = client.ScanDoneEvent(),
        closeEvent = client.CloseEvent(),
    }
    if client.CanScan() then
        api.replicateItems = client.StartScan
    end
    if client.HasCommodityCheck() then
        api.clientIsCommodity = client.ItemIsCommodity
    end
    return api
end

-- Print the key and row counts of a finished scan.
local function reportScanDetails(summary)
    local c, r = summary.commodityStats, summary.rowStats
    if c then
        printLine(string.format("commodity check: client %d, stack %d, unknown %d, mismatch %d, link fallback %d",
            c.client, c.stack, c.unknown, c.mismatch, c.linkFallback or 0))
        printLine(string.format(
            "items %d: keyed %d, link fallback %d, pending %d, no link %d, link mismatch %d, unknown %d",
            summary.items, summary.itemsKeyed, summary.itemsLinkFallback, summary.itemsPendingMissing,
            summary.itemsNoLink, summary.itemsLinkMismatch, summary.itemsUnknown))
    end
    if r then
        printLine(string.format("rows skipped: empty %d, bid-only %d, pet %d, bad count %d",
            r.empty, r.bidOnly, r.pet, r.badCount))
    end
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

local REGION_BY_ID = { [1] = "US", [2] = "KR", [3] = "EU", [4] = "TW", [5] = "CN", [98] = "beta" }
local TEST_BUILD_FUNCTIONS = { "IsTestBuild", "IsBetaBuild", "IsPublicTestClient" }

-- Call a global function in pcall; return its result, or nil if it is missing or fails.
local function safeGlobal(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then
        return nil
    end
    local ok, value = pcall(fn, ...)
    if ok then
        return value
    end
    return nil
end

-- Returns the region and its source: "test-build", "region-name", "region-id" or "fallback".
local function detectRegion()
    for _, name in ipairs(TEST_BUILD_FUNCTIONS) do
        if safeGlobal(name) == true then
            return "beta", "test-build"
        end
    end
    local name = safeGlobal("GetCurrentRegionName")
    if type(name) == "string" and name ~= "" then
        return name, "region-name"
    end
    local id = safeGlobal("GetCurrentRegion")
    if type(id) == "number" and REGION_BY_ID[id] then
        return REGION_BY_ID[id], "region-id"
    end
    return "beta", "fallback"
end


-- Save the price of each item that the player searches in the Auction House.
local function openCapture()
    local source = ns.Flavour.captureEnabled and ns.AuctionClient.Capture() or nil
    if not (ns.ScanCapture and source) then
        return
    end
    local ok, capture = pcall(ns.ScanCapture.New, {
        store = ns.scanStore,
        serverTime = GetServerTime,
        api = source.api,
        report = ns.ReportError,
        isScanRunning = function()
            return ns.scanEngine ~= nil and ns.scanEngine:IsRunning()
        end,
    })
    if not ok then
        ns.ReportError("search capture is not available this session: " .. tostring(capture))
        return
    end
    ns.scanCapture = capture
    ns.bus:Subscribe(source.commodityEvent, "Flipside.Capture", function(_, itemID)
        capture:OnCommodityResults(itemID)
    end)
    ns.bus:Subscribe(source.itemEvent, "Flipside.Capture", function(_, itemKey)
        capture:OnItemResults(itemKey)
    end)
end

-- Open the scan store and the scan engine; print one line if that is not possible.
local function openScan()
    if not (ns.ScanStore and ns.ScanEngine and ns.ScanCooldown and ns.ScanClock) then
        if not ns.scanModulesOptional then
            ns.ReportError("scan is not available this session (scan modules not loaded; check the Services folder)")
        end
        return
    end
    local region, source = detectRegion()
    if source == "fallback" then
        ns.ReportError('region unknown, scan data is stored under "beta"')
    end
    local meta = {}
    local okRules, standard = pcall(function()
        return C_GameRules.IsStandard()
    end)
    if okRules and type(standard) == "boolean" then
        meta.isStandard = standard
    end
    local scanName = ns.Flavour.savedVariables.scan
    if type(_G[scanName]) ~= "table" then
        _G[scanName] = {}
    end
    local realm
    if ns.Flavour.scopeIncludesRealm then
        realm = GetNormalizedRealmName()
    end
    local ok, result = pcall(ns.ScanStore.New, _G[scanName], {
        region = region,
        realm = realm,
        ruleset = ns.Flavour.ruleset,
        meta = meta,
        schemaVersion = 1,
        onWarning = ns.ReportError,
    })
    if not ok then
        ns.ReportError("scan is not available this session: " .. tostring(result))
        return
    end
    ns.scanStore = result
    ns.scanCooldown = ns.ScanCooldown.New(ns.db, {
        clock = GetServerTime,
        cooldownSeconds = ns.Flavour.scanCooldownSeconds,
    })
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
        onFinished = reportScanDetails,
    })
    if not okEngine then
        ns.ReportError("scan is not available this session: " .. tostring(engine))
        return
    end
    ns.scanEngine = engine
    openCapture()
    ns.bus:Subscribe("PLAYER_LOGOUT", "Flipside.Init", function()
        local okFlush, err = pcall(ns.scanStore.Flush, ns.scanStore)
        if not okFlush then
            ns.ReportError("scan data was not saved: " .. tostring(err))
        end
    end)
    startRollUp()
end

-- Create the formula sources and the formula runner; the store can be nil.
local function openFormula()
    if not (ns.FormulaSources and ns.FormulaRun and ns.ScanSources) then
        return
    end
    local ok, result = pcall(function()
        ns.formulaSources = ns.FormulaSources.New({ itemCache = ns.itemCache })
        ns.formulaRun = ns.FormulaRun.New({
            store = ns.scanStore,
            sources = ns.formulaSources,
            serverTime = GetServerTime,
        })
    end)
    if not ok then
        ns.formulaRun = nil
        ns.ReportError("formulas are not available this session: " .. tostring(result))
    end
end

-- Look an item up by name in the client cache; returns itemID, link, name or nil.
local function clientLookup(name)
    local ok, itemName, link = pcall(C_Item.GetItemInfo, name)
    if not ok or type(itemName) ~= "string" or type(link) ~= "string" then
        return nil
    end
    local parsed = ns.ItemString.ParseLink(link)
    if not parsed or not parsed.itemID then
        return nil
    end
    return parsed.itemID, link, itemName
end


-- Create the Auction House name search; it needs the scan setup.
local function openAHSearch()
    if not (ns.AHNameSearch and ns.scanStore) then
        return
    end
    local ok, result = pcall(ns.AHNameSearch.New, {
        bus = ns.bus,
        api = {
            sendBrowseQuery = function(query)
                return ns.AuctionClient.NameSearch(query.searchString)
            end,
            getBrowseResults = ns.AuctionClient.NameResults,
            getItemKeyInfo = ns.AuctionClient.NameItemKeyInfo,
        },
        event = ns.AuctionClient.NameResultEvent(),
        isAuctionHouseOpen = ns.IsAuctionHouseOpen,
        clock = GetTime,
        after = C_Timer.After,
    })
    if ok then
        ns.ahNameSearch = result
    else
        ns.ReportError("Auction House name search is not available this session: " .. tostring(result))
    end
end

-- Create the item name index; it needs the scan store.
local function openNames()
    if not (ns.ItemNameIndex and ns.scanStore) then
        return
    end
    local ok, result = pcall(ns.ItemNameIndex.New, {
        store = ns.scanStore,
        itemCache = ns.itemCache,
        clientLookup = clientLookup,
    })
    if ok then
        ns.itemNameIndex = result
    else
        ns.ReportError("item name search is not available this session: " .. tostring(result))
    end
end

-- Functions that run when the rules or the custom sources change.
local rulesSubscribers = {}

function ns.SubscribeRules(fn)
    rulesSubscribers[#rulesSubscribers + 1] = fn
end

local function notifyRules()
    if ns.formulaRun then
        ns.formulaRun:ClearCache()
    end
    for _, fn in ipairs(rulesSubscribers) do
        local ok, err = pcall(fn)
        if not ok then
            ns.ReportError("window refresh failed: " .. tostring(err))
        end
    end
    ns.bus:Emit("Flipside.RulesChanged")
end

-- Key resolver for bag items and pasted links, with the same lookups as the scan.
local function buildKeyResolver()
    local lookups = { maxStack = maxStack }
    if ns.AuctionClient.HasCommodityCheck() then
        lookups.clientIsCommodity = ns.AuctionClient.ItemIsCommodity
    end
    return ns.ScanKey.New(lookups)
end

-- Create the groups and operations store and the custom sources; they need the settings DB.
local function openRules()
    if not (ns.db and ns.RulesStore and ns.CustomSources) then
        return
    end
    local ok, err = pcall(function()
        ns.customSources = ns.CustomSources.New(ns.db, { onWarning = ns.ReportError, onChange = notifyRules })
        if ns.formulaSources then
            ns.formulaSources:SetCustom(ns.customSources)
        end
        ns.rules = ns.RulesStore.New(ns.db, {
            onWarning = ns.ReportError,
            onChange = notifyRules,
            compile = function(text)
                return ns.formulaRun:Compile(text)
            end,
        })
        local resolver = buildKeyResolver()
        ns.keyFor = function(link)
            local itemID = ns.ItemString.ParseLink(link)
            itemID = itemID and itemID.itemID
            if not itemID then
                return nil
            end
            return (resolver:KeyFor(itemID, link))
        end
        ns.readBags = function()
            return (ns.BagItems.Read({
                numSlots = C_Container.GetContainerNumSlots,
                itemInfo = C_Container.GetContainerItemInfo,
            }, resolver, { bagIDs = ns.Flavour.bagIDs() }))
        end
    end)
    if not ok then
        ns.rules, ns.customSources = nil, nil
        ns.ReportError("groups and operations are not available this session: " .. tostring(err))
    end
end

-- Client read functions for the inventory capture; mail is left out if the client has no mail functions.
local function buildInventoryApi()
    local api = {
        container = {
            numSlots = C_Container.GetContainerNumSlots,
            itemInfo = C_Container.GetContainerItemInfo,
        },
    }
    if type(GetInboxNumItems) == "function" and type(GetInboxItemLink) == "function"
        and type(GetInboxItem) == "function" then
        api.mail = { numItems = GetInboxNumItems, itemLink = GetInboxItemLink, itemInfo = GetInboxItem }
    end
    if ns.AuctionClient.CanReadOwned() then
        api.auctions = { owned = ns.AuctionClient.OwnedAuctions }
    end
    return api
end

-- Create the holdings and attach the inventory capture; they need the settings DB.
local function openInventory()
    if not (ns.db and ns.Holdings and ns.HoldingsRead and ns.InventoryCapture) then
        return
    end
    local ok, err = pcall(function()
        ns.holdings = ns.Holdings.New(ns.db, { character = characterKey(), clock = GetServerTime })
        ns.inventoryCapture = ns.InventoryCapture.Attach({
            bus = ns.bus,
            holdings = ns.holdings,
            holdingsRead = ns.HoldingsRead,
            api = buildInventoryApi(),
            ownedEvent = ns.AuctionClient.OwnedEvent(),
            bagIDs = ns.Flavour.bagIDs(),
            bankIDs = ns.Flavour.bankIDs(),
            resolver = buildKeyResolver(),
            after = C_Timer.After,
            report = ns.ReportError,
        })
    end)
    if not ok then
        ns.holdings = nil
        ns.ReportError("inventory tracking is not available this session: " .. tostring(err))
    end
end

-- Create the tooltip settings and attach the tooltip lines; they need the settings DB.
local function openTooltip()
    if not (ns.db and ns.TooltipConfig and ns.Tooltip and ns.TooltipLines) then
        return
    end
    local ok, err = pcall(function()
        ns.tooltipConfig = ns.TooltipConfig.New(ns.db, {
            compile = function(text)
                if not ns.formulaRun then
                    return nil, { message = "formulas are not available" }
                end
                return ns.formulaRun:Compile(text)
            end,
            onChange = notifyRules,
            onWarning = ns.ReportError,
        })
        local tooltipDeps = {
            tooltipConfig = ns.tooltipConfig,
            formulaRun = ns.formulaRun,
            rules = ns.rules,
            holdings = ns.holdings,
            getRecord = function(key)
                return ns.scanStore and ns.scanStore:Get(key) or nil
            end,
            now = GetServerTime,
            isAltDown = IsAltKeyDown,
            containerItemInfo = C_Container.GetContainerItemInfo,
            clock = debugprofilestop,
            report = ns.ReportError,
        }
        ns.BuildTooltipPreview = function(input, config)
            return ns.Tooltip.Rows(tooltipDeps, input, false, nil, config)
        end
        ns.Tooltip.Attach(tooltipDeps)
    end)
    if not ok then
        ns.tooltipConfig = nil
        ns.ReportError("tooltip lines are not available this session: " .. tostring(err))
    end
end

-- Set later in this file: attach the Auction House tab.
local openUI

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" and (...) == addonName then
        ns.bus:Emit("Flipside.Loaded")
    elseif event == "PLAYER_LOGIN" then
        trackAuctionHouse()
        openSettingsDB()
        if ns.db then
            openScan()
        end
        openNames()
        openAHSearch()
        openFormula()
        openRules()
        openInventory()
        openTooltip()
        openUI()
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
function ns.VersionLine()
    local version, build, _, interface = GetBuildInfo()
    return "client " .. tostring(version) .. ", build " .. tostring(build) .. ", interface " .. tostring(interface)
end

local function printVersion()
    printLine(ns.VersionLine())
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

-- The callback that the popup runs when the player accepts.
local pendingScanAccept

-- Start the scan from the chat command after the player accepts.
local function startChatScan()
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
end

StaticPopupDialogs["FLIPSIDE_FULL_SCAN"] = {
    text = "Flipside: a full scan has disconnected clients on busy servers in the past. Start the full scan?",
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = function()
        local callback = pendingScanAccept
        pendingScanAccept = nil
        if callback then
            callback()
        end
    end,
    timeout = 0,
    hideOnEscape = true,
    showAlert = true,
}

-- Show the full scan warning; run onAccept if the player accepts.
local function confirmScan(onAccept)
    pendingScanAccept = onAccept
    StaticPopup_Show("FLIPSIDE_FULL_SCAN")
end

-- The Flipside window is created on first use.
function ns.OpenMainWindow()
    if not ns.MainWindow then
        printLine("the window is not available this session")
        return
    end
    local ok, err = pcall(function()
        local window = ns.MainWindow.Create({
            formulaRun = ns.formulaRun,
            formulaSources = ns.formulaSources,
            itemCache = ns.itemCache,
            itemNameIndex = ns.itemNameIndex,
            ahNameSearch = ns.ahNameSearch,
            compile = function(text)
                if not ns.formulaRun then
                    return nil, { message = "formulas are not available" }
                end
                return ns.formulaRun:Compile(text)
            end,
            rules = ns.rules,
            customSources = ns.customSources,
            readBags = ns.readBags,
            keyFor = ns.keyFor,
            subscribe = ns.SubscribeRules,
            tooltipConfig = ns.tooltipConfig,
            holdings = ns.holdings,
            getRecord = function(key)
                return ns.scanStore and ns.scanStore:Get(key) or nil
            end,
            buildPreview = ns.BuildTooltipPreview,
            getVersionLine = ns.VersionLine,
        })
        window:Toggle()
    end)
    if not ok then
        ns.ReportError("window is not available this session: " .. tostring(err))
    end
end

openUI = function()
    if not ns.AuctionTab then
        return
    end
    local ok, result = pcall(ns.AuctionTab.Attach, {
        bus = ns.bus,
        serverTime = GetServerTime,
        scanEngine = ns.scanEngine,
        scanCooldown = ns.scanCooldown,
        scanStore = ns.scanStore,
        formulaLookup = ns.FormulaLookup,
        scanSources = ns.ScanSources,
        itemNameIndex = ns.itemNameIndex,
        confirmScan = confirmScan,
        openMainWindow = ns.OpenMainWindow,
    })
    if ok then
        ns.auctionTab = result
    else
        ns.ReportError("Auction House tab is not available this session: " .. tostring(result))
    end
end

local function scanCommand(argument)
    local engine = ns.scanEngine
    if not engine then
        printLine("scan is not available this session")
        return
    end
    if argument == "reset" then
        if engine:IsRunning() then
            printLine("a scan is running; stop it first with /flip scan stop")
        elseif ns.scanCooldown:Reset() then
            printLine("scan cooldown cleared. The server can still refuse a scan for a while; "
                .. [[Flipside then reports "no response".]])
        else
            printLine("settings are read-only; the cooldown was not cleared")
        end
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
    confirmScan(startChatScan)
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

local function printPrice(record, key)
    local values = ns.ScanSources.Compute(record, GetServerTime())
    printLine("key " .. key .. ": " .. priceText("ScanMin", values.scanMin) .. ", "
        .. priceText("ScanRecent", values.scanRecent))
    printLine(priceText("ScanMarket", values.scanMarket) .. ", "
        .. priceText("ScanHistorical", values.scanHistorical))
    local age = values.scanAge and string.format("%.1f h", values.scanAge) or "-"
    printLine("ScanQty " .. tostring(values.scanQty or "-") .. ", ScanAge " .. age
        .. ", ScanSamples " .. values.scanSamples .. (values.scanPartial and ", partial" or ""))
end

-- Find an item by name: print the price of one match or a numbered list of several.
local function priceByName(argument)
    local result = ns.itemNameIndex:Resolve(argument)
    if result.kind == "error" then
        printLine(result.message)
        return
    end
    local matches = result.matches or {}
    if #matches == 0 then
        printLine('no item named "' .. argument .. '" in the scan data')
    elseif #matches == 1 then
        printPrice(ns.scanStore:Get(matches[1].key), matches[1].key)
    else
        for position, match in ipairs(matches) do
            printLine(position .. ". " .. ns.ItemNameIndex.Describe(match))
        end
        printLine("use /flip price <id>")
    end
    if (result.pendingCount or 0) > 0 then
        printLine(result.pendingCount .. " item names are still loading")
    end
end

local function priceCommand(argument)
    if not ns.scanStore then
        printLine("scan is not available this session")
        return
    end
    local record, key, keys = findRecord(argument)
    if #keys == 0 then
        if ns.itemNameIndex and argument ~= "" then
            priceByName(argument)
        else
            printLine("usage: /flip price <item link or item id>")
        end
        return
    end
    if not record then
        printLine("no scan data for " .. table.concat(keys, " or "))
        return
    end
    printPrice(record, key)
end

-- Split the text of /flip formula into the formula and the item argument (nil if none).
local function splitFormula(text)
    local linkStart = text:find("|[cH]")
    if linkStart then
        return text:sub(1, linkStart - 1):match("^(.-)%s*$"), text:sub(linkStart)
    end
    local formula, number = text:match("^(.-)%s+(%d+)$")
    if not number then
        return text, nil
    end
    local run = ns.formulaRun
    local beforeOk = run:Compile(formula)
    local wholeOk, wholeErr = run:Compile(text)
    if beforeOk then
        return formula, number
    end
    if wholeOk then
        return text, nil
    end
    -- Neither compiles: an error at the number belongs to the formula before it.
    if wholeErr and wholeErr.pos and wholeErr.pos > #formula then
        return formula, number
    end
    return text, nil
end

-- About 10 characters of the formula around the error position.
local function nearText(formula, pos)
    local first = math.max(1, pos - 5)
    local last = math.min(#formula, first + 9)
    local text = formula:sub(first, last)
    return (first > 1 and "..." or "") .. text .. (last < #formula and "..." or "")
end

local function printFormulaError(formula, err)
    printLine(string.format("formula error at %d: %s", err.pos or 0, tostring(err.message)))
    if err.pos then
        printLine(string.format('near "%s"', nearText(formula, err.pos)))
    end
end

local function formulaCommand(text)
    local run = ns.formulaRun
    if not run then
        printLine("formulas are not available this session")
        return
    end
    local formula, item = splitFormula(text)
    if formula == "" then
        printLine("usage: /flip formula <formula> [item link or id]")
        printLine("example: /flip formula max(scanmin, 1.5 * vendorsell) 2589")
        return
    end
    if item and not (item:match("^%d+$") or (item:match("^|[cH]") and item:find("|Hitem:", 1, true))) then
        printLine("not an item: " .. item)
        return
    end
    if not item then
        local compiled, err = run:Compile(formula)
        if not compiled then
            printFormulaError(formula, err)
        else
            local names = #compiled.names > 0 and table.concat(compiled.names, ", ") or "none"
            printLine("formula ok (sources: " .. names .. ")")
        end
        return
    end
    local copper, info = run:Evaluate(formula, item)
    if info.kind == "error" and info.pos then
        printFormulaError(formula, info)
    elseif info.kind == "error" then
        printLine("not an item: " .. item)
    elseif info.kind == "ok" then
        local label = info.key or item:match("|Hitem:(%d+)") or item
        printLine(string.format("formula = %d (%s) for %s", copper, formatMoney(copper), label))
    else
        local label = info.key or item:match("|Hitem:(%d+)") or item
        printLine("formula = invalid for " .. label)
        if #info.missing > 0 then
            printLine("missing: " .. table.concat(info.missing, ", "))
        end
        if #info.later > 0 then
            printLine("not available yet: " .. table.concat(info.later, ", "))
        end
    end
end

local function printScanHelp()
    local last = ns.scanCooldown:GetLastSuccess()
    local age = "never"
    if type(last) == "number" then
        age = string.format("%.1f h ago", ns.ScanClock.HoursBetween(last, GetServerTime()))
    end
    local left = ns.scanCooldown:Remaining()
    local cooldown = left > 0 and ns.ScanCooldown.FormatRemaining(left) or "ready"
    printLine(string.format("scan (region %s): %d items stored, last scan %s, cooldown %s",
        ns.scanStore:GetRegion(), ns.scanStore:CountItems(), age, cooldown))
    printLine("commands: scan, scan stop, scan reset, price <item>, formula <text> [item], version")
end

-- Print the build time of the tooltip lines in milliseconds.
local function tooltipStatsCommand()
    local stats = ns.Tooltip and ns.Tooltip.stats
    if not stats or stats.count == 0 then
        printLine("no tooltip lines were built yet")
        return
    end
    printLine(string.format("tooltip lines: %d builds, max %.3f ms, average %.3f ms",
        stats.count, stats.max, stats.total / stats.count))
end

-- Remove the saved inventory of one character.
local function forgetCommand(character)
    if not ns.holdings then
        printLine("inventory tracking is not available this session")
        return
    end
    if character == "" then
        printLine("usage: /flip forget <Name-Realm>")
        return
    end
    local known = false
    for _, name in ipairs(ns.holdings:Characters()) do
        if name == character then
            known = true
        end
    end
    if not known then
        printLine("no saved character " .. character)
    elseif ns.holdings:Forget(character) then
        printLine("forgot the inventory of " .. character)
    else
        printLine("settings are read-only; the inventory was not removed")
    end
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
    elseif command == "formula" then
        formulaCommand(rest)
        return
    elseif command == "tooltipstats" then
        tooltipStatsCommand()
        return
    elseif command == "forget" then
        forgetCommand(rest)
        return
    elseif command == "" then
        ns.OpenMainWindow()
        return
    end
    printLine("/flip opens the Flipside window")
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