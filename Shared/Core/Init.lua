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

-- Write one log line. The Log module can be missing in a spec.
local function log(category, level, fmt, ...)
    if ns.Log then
        ns.Log.Writef(category, level, fmt, ...)
    end
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
    onError = function(event, _, err, stack)
        ns.ReportError("handler for " .. tostring(event) .. " failed: " .. tostring(err))
        log("core", "error", "handler for %s failed: %s%s", event, err, stack and (" | " .. stack) or "")
    end,
    onEmit = function(...)
        if ns.Log then
            ns.Log.Trace(...)
        end
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
        log("core", "error", "job %s failed: %s", job.name, message)
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
-- Version 2: the saved post durations of an operation use the hours of the flavour (TBC: 2, 8, 24 became 12, 24, 48).
-- A flavour without legacyDurations needs no change.
-- Account defaults: the ledger defaults and ui.sounds (client sounds, default on).
local function accountDefaults()
    local defaults = ns.LedgerRecord and ns.LedgerRecord.Defaults() or {}
    defaults["ui.sounds"] = true
    return defaults
end

-- Setting ui.sounds (account scope, default on). Sounds stay on if settings are missing.
local function uiSoundsEnabled()
    return ns.db == nil or ns.db:Get("account", "ui.sounds") ~= false
end

local function migrateDurations(data)
    local old, new = ns.Flavour.legacyDurations, ns.Flavour.durations
    if not (old and new) then
        return
    end
    for key, value in pairs(data) do
        if type(key) == "string" and key:match("^p/.+/operations$") and type(value) == "table"
            and type(value.ops) == "table" then
            for _, op in pairs(value.ops) do
                local hours = type(op) == "table" and type(op.settings) == "table" and op.settings.duration
                for index, oldHours in ipairs(old) do
                    if hours == oldHours then
                        op.settings.duration = new[index]
                        break
                    end
                end
            end
        end
    end
end

ns.MigrateDurations = migrateDurations

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
        schemaVersion = 2,
        migrations = { [2] = migrateDurations },
        defaults = { account = accountDefaults() },
        onWarning = ns.ReportError,
    })
    if not ok then
        ns.ReportError("settings are not available this session: " .. tostring(result))
        return
    end
    ns.db = result
    if ns.Kit and ns.Kit.SetSoundGate then
        ns.Kit.SetSoundGate(uiSoundsEnabled)
    end
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


-- Emitted with the key when the capture stored a price.
local EVENT_PRICE_CAPTURED = "Flipside.PriceCaptured"
ns.EVENT_PRICE_CAPTURED = EVENT_PRICE_CAPTURED

-- Search the listings of one item in the open Auction House; the capture stores the price.
-- name is optional. Returns true, or false and a text.
function ns.RequestPriceRefresh(itemID, name)
    if not (ns.scanCapture and ns.AuctionClient.CanTargetSearch()) then
        return false
    end
    if not ns.IsAuctionHouseOpen() then
        return false, "open the Auction House to refresh this price"
    end
    if ns.scanEngine and ns.scanEngine:IsRunning() then
        return false, "a scan is running"
    end
    if ns.ahNameSearch and ns.ahNameSearch:IsBusy() then
        return false, "a name search is running"
    end
    if type(name) ~= "string" or name == "" then
        local info = ns.itemCache and ns.itemCache:Get(itemID)
        name = info and info.name or nil
    end
    local ok, err = pcall(ns.AuctionClient.TargetedSearch, itemID, name)
    if not ok then
        return false, tostring(err)
    end
    return true
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

local SUFFIX_CLASSES = { [2] = true, [4] = true } -- weapon and armor can have a random suffix

-- Tells the legacy scan if an item can get its key without a link: true, false (can have a suffix), nil (no info).
local function canKeyWithoutLink(itemID)
    local info = ns.itemCache:Get(itemID)
    if not info then
        return nil
    end
    if SUFFIX_CLASSES[info.classID] then
        return false
    end
    if info.classID == nil and info.equipLoc ~= nil and info.equipLoc ~= "" then
        return false
    end
    return true
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
        api.settleSeconds = client.ScanSettleSeconds()
        api.isComplete = client.ScanComplete
        local backend = client.Backend()
        if backend and backend.ScanCanStart then
            api.canStart = client.ScanCanStart
        end
    end
    if client.HasCommodityCheck() then
        api.clientIsCommodity = client.ItemIsCommodity
    end
    -- A backend with scan modes (legacy) also keys rows without a link.
    -- A backend with ScanRefreshSeconds (Forever too) makes the engine retry item loads and missing links.
    local refreshBackend = client.Backend()
    if refreshBackend and refreshBackend.ScanRefreshSeconds then
        api.refreshSeconds = client.ScanRefreshSeconds
    end
    local modes = client.ScanModes()
    if modes then
        api.modes = modes
        api.canKeyWithoutLink = canKeyWithoutLink
        local backend = client.Backend()
        if client.CanScan() and backend and backend.ScanPageQuery then
            api.pageQuery = client.ScanPageQuery
            api.canQueryPage = client.CanQueryPage
            api.pageTotal = client.ScanTotal
        end
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
    local line = ns.AuctionClient.ScanDiagnostics(summary)
    if line then
        printLine(line)
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


-- Legacy list: many events come for one query. Read the page once, after the events stop for a short time.
local function subscribePageCapture(capture, source)
    local delay = source.debounceSeconds or 0.3
    local lastEvent, waiting = 0, false
    local function check()
        local quiet = GetTime() - lastEvent
        if quiet < delay then
            C_Timer.After(delay - quiet, check)
            return
        end
        waiting = false
        local ok, rows, full = pcall(source.readPage)
        if ok and rows then
            capture:OnPageResults(rows, full)
        elseif not ok then
            ns.ReportError("search capture failed: " .. tostring(rows))
        end
    end
    ns.bus:Subscribe(source.pageEvent, "Flipside.Capture", function()
        lastEvent = GetTime()
        if not waiting then
            waiting = true
            C_Timer.After(delay, check)
        end
    end)
end

-- Save the price of each item that the player searches in the Auction House.
local function openCapture()
    local source = ns.Flavour.captureEnabled and ns.AuctionClient.Capture() or nil
    if not (ns.ScanCapture and ns.ScanKey and source) then
        return
    end
    local resolver = ns.ScanKey.New({ clientIsCommodity = ns.AuctionClient.ItemIsCommodity, maxStack = maxStack })
    local ok, capture = pcall(ns.ScanCapture.New, {
        store = ns.scanStore,
        serverTime = GetServerTime,
        api = source.api,
        report = ns.ReportError,
        onCaptured = function(key)
            ns.bus:Emit(EVENT_PRICE_CAPTURED, key)
        end,
        keyFor = function(itemID, link)
            return resolver:KeyFor(itemID, link)
        end,
        isScanRunning = function()
            return ns.scanEngine ~= nil and ns.scanEngine:IsRunning()
        end,
    })
    if not ok then
        ns.ReportError("search capture is not available this session: " .. tostring(capture))
        return
    end
    ns.scanCapture = capture
    if source.pageEvent then
        subscribePageCapture(capture, source)
        return
    end
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

-- Turn Flipside client sounds on or off. Return false if settings are read-only or missing.
function ns.SetUISounds(on)
    return ns.db ~= nil and ns.db:Set("account", "ui.sounds", on and true or false) and true or false
end

-- Setting sync.guildEnabled (account scope, default off): share scan prices with the guild (SPEC 3.5).
local function guildSyncEnabled()
    return ns.db ~= nil and ns.db:Get("account", "sync.guildEnabled") == true
end

-- Create the guild price sharing; it needs the scan store and the settings DB.
local function openGuildSync()
    ns.guildSync, ns.priceReader, ns.IsGuildPrice = nil, nil, nil
    if not (ns.GuildSync and ns.GuildSyncCodec and ns.GuildSyncQueue and ns.GuildPriceStore and ns.scanStore
        and ns.db and C_ChatInfo) then
        return
    end
    local ok, err = pcall(function()
        local scan = ns.scanStore
        local scope = ns.GuildSyncCodec.ScopeKey(scan:GetRegion(), scan:GetRealm(), scan:GetRuleset())
        local saved = ns.db:Get("account", "sync.guild")
        if type(saved) ~= "table" then
            saved = {}
            ns.db:Set("account", "sync.guild", saved)
        end
        local guildStore = ns.GuildPriceStore.New(saved, { scope = scope, now = GetServerTime })
        local queue = ns.GuildSyncQueue.New({
            send = function(text)
                return C_ChatInfo.SendAddonMessage(ns.GuildSyncCodec.PREFIX, text, "GUILD")
            end,
            after = C_Timer.After,
            clock = GetTime,
            onSent = function(text)
                log("sync", "info", "sent a message of %d bytes", #text)
            end,
            onDrop = function(text, reason, result)
                log("sync", "warn", "message of %d bytes dropped: %s %s", #text, reason, tostring(result))
            end,
        })
        ns.guildSync = ns.GuildSync.New({
            isEnabled = guildSyncEnabled,
            isInGuild = IsInGuild,
            selfName = function()
                return tostring(UnitName("player")) .. "-" .. tostring(GetNormalizedRealmName())
            end,
            realm = GetNormalizedRealmName,
            scope = scope,
            localStore = scan,
            guildStore = guildStore,
            queue = queue,
            clock = GetServerTime,
            after = C_Timer.After,
            random = math.random,
            registerPrefix = C_ChatInfo.RegisterAddonMessagePrefix,
            runJob = ns.StartJob,
            lastScan = function()
                return ns.scanCooldown and ns.scanCooldown:GetLastSuccess() or nil
            end,
            log = function(level, fmt, ...)
                log("sync", level, fmt, ...)
            end,
        })
        ns.priceReader = ns.GuildPriceStore.NewReader({
            localStore = scan,
            guildStore = guildStore,
            isEnabled = guildSyncEnabled,
        })
        ns.IsGuildPrice = function(key)
            local reader = ns.priceReader
            local base = ns.ItemString.ToBaseKey(key)
            return reader:IsGuild(key) or (base ~= nil and reader:IsGuild(base))
        end
        local sync = ns.guildSync
        ns.bus:Subscribe("CHAT_MSG_ADDON", "Flipside.GuildSync", function(...)
            sync:OnAddon(...)
        end)
        ns.bus:Subscribe("Flipside.ScanFinished", "Flipside.GuildSync", function(...)
            sync:OnScanFinished(...)
        end)
        sync:EnsureRegistered()
        C_Timer.After(30, function()
            sync:SendRequest()
        end)
    end)
    if not ok then
        ns.guildSync, ns.priceReader = nil, nil
        ns.ReportError("guild sharing is not available this session: " .. tostring(err))
    end
end

-- Turn guild sharing on or off. Return false if settings are read-only or the feature is missing.
function ns.SetGuildSync(on)
    if not (ns.guildSync and ns.db) or not ns.db:Set("account", "sync.guildEnabled", on and true or false) then
        return false
    end
    ns.guildSync:OnSettingChanged()
    return true
end

-- Create the formula sources and the formula runner; the store can be nil.
local function openFormula()
    if not (ns.FormulaSources and ns.FormulaRun and ns.ScanSources) then
        return
    end
    local ok, result = pcall(function()
        ns.formulaSources = ns.FormulaSources.New({ itemCache = ns.itemCache })
        ns.formulaRun = ns.FormulaRun.New({
            store = ns.priceReader or ns.scanStore,
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
        addedEvent = ns.AuctionClient.NameAddedEvent(),
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
            seedDefault = true,
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
        -- The bag items with their stacks (bag and slot), for the Selling tab.
        ns.readBagStacks = function()
            return (ns.BagItems.Read({
                numSlots = C_Container.GetContainerNumSlots,
                itemInfo = C_Container.GetContainerItemInfo,
            }, resolver, { bagIDs = ns.Flavour.bagIDs(), stacks = true }))
        end
        -- The bag stacks for the Destroy window, flat, with the bound items. Each one is { bag, slot, itemID, link }.
        ns.readDestroyStacks = function()
            local items = ns.BagItems.Read({
                numSlots = C_Container.GetContainerNumSlots,
                itemInfo = C_Container.GetContainerItemInfo,
            }, resolver, { bagIDs = ns.Flavour.bagIDs(), stacks = true, includeBound = true })
            local stacks = {}
            for _, item in ipairs(items) do
                for _, stack in ipairs(item.stacks) do
                    stacks[#stacks + 1] = {
                        bag = stack.bag, slot = stack.slot, itemID = item.itemID, link = stack.link,
                    }
                end
            end
            return stacks
        end
    end)
    if not ok then
        ns.rules, ns.customSources = nil, nil
        ns.ReportError("groups and operations are not available this session: " .. tostring(err))
    end
end

-- Create the saved search lists; they need the settings DB.
local function openSearchLists()
    if not (ns.db and ns.SearchLists) then
        return
    end
    local ok, result = pcall(ns.SearchLists.New, ns.db, {
        bus = ns.bus,
        isAuctionHouseOpen = ns.IsAuctionHouseOpen,
    })
    if ok then
        ns.searchLists = result
    else
        ns.ReportError("search lists are not available this session: " .. tostring(result))
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
        api.mail = { numItems = GetInboxNumItems, itemLink = GetInboxItemLink, itemInfo = GetInboxItem,
            header = type(GetInboxHeaderInfo) == "function" and GetInboxHeaderInfo or nil }
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
        -- Save the class file of this character for the class colours in the tooltip counts.
        ns.holdings:SetClass((select(2, UnitClass("player"))))
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

-- Create the ledger buffer and the loader of the ledger addon; they need the settings DB.
-- The ledger addon has no Lua code: the client puts its saved table in the global of its name.
local function openLedger()
    if not (ns.db and ns.LedgerRecord and ns.LedgerBuffer and ns.LedgerStore and ns.LedgerLoader) then
        return
    end
    local ok, err = pcall(function()
        local loadAddOn = C_AddOns and C_AddOns.LoadAddOn or LoadAddOn
        local region = detectRegion()
        local loader
        ns.ledgerBuffer = ns.LedgerBuffer.New(ns.db, {
            warn = ns.ReportError,
            onCap = function()
                loader:RequestFlush()
            end,
        })
        loader = ns.LedgerLoader.New({
            bus = ns.bus,
            buffer = ns.ledgerBuffer,
            loadAddOn = loadAddOn,
            inCombat = InCombatLockdown,
            now = GetServerTime,
            after = C_Timer.After,
            setting = function(key)
                return ns.db:Get("account", key)
            end,
            openStore = function()
                local name = ns.Flavour.savedVariables.ledger
                if type(_G[name]) ~= "table" then
                    _G[name] = {}
                end
                return ns.LedgerStore.New(_G[name], {
                    region = region,
                    ruleset = ns.Flavour.ruleset,
                    onWarning = ns.ReportError,
                })
            end,
        })
        ns.ledgerLoader = loader
        ns.bus:Subscribe(ns.LedgerLoader.EVENT_FAILED, "Flipside.Init", function(_, reason)
            ns.ReportError("the ledger addon did not load: " .. tostring(reason))
        end)
        loader:Attach()
    end)
    if not ok then
        ns.ledgerBuffer, ns.ledgerLoader = nil, nil
        ns.ReportError("the ledger is not available this session: " .. tostring(err))
    end
end

-- Create the money tracker; it needs the ledger buffer. It reads money changes and client events only.
local function openLedgerMoney()
    if not (ns.db and ns.ledgerBuffer and ns.LedgerMoney and type(GetMoney) == "function") then
        return
    end
    local ok, err = pcall(function()
        local client = ns.AuctionClient
        ns.ledgerMoney = ns.LedgerMoney.Attach({
            bus = ns.bus,
            buffer = ns.ledgerBuffer,
            getMoney = GetMoney,
            now = GetTime,
            serverTime = GetServerTime,
            character = characterKey,
            after = C_Timer.After,
            report = ns.ReportError,
            isSecret = type(issecretvalue) == "function" and issecretvalue or nil,
            setting = function(key)
                return ns.db:Get("account", key)
            end,
            itemKey = function(input, isCommodity)
                return input ~= nil and ns.ItemString.ToKey(input, isCommodity) or nil
            end,
            client = client,
            commodityMarket = ns.Flavour.hasCommodityMarket,
            auctionInfo = client.AuctionInfo,
            tradePartner = function()
                local name, realm = UnitName("NPC")
                if name and realm and realm ~= "" then
                    return name .. "-" .. realm
                end
                return name
            end,
            taxiNodes = type(NumTaxiNodes) == "function" and function()
                local nodes = {}
                for index = 1, NumTaxiNodes() do
                    if TaxiNodeGetType(index) == "REACHABLE" then
                        nodes[#nodes + 1] = { name = TaxiNodeName(index), cost = TaxiNodeCost(index) }
                    end
                end
                return nodes
            end or nil,
            bagLink = function(bag, slot)
                local info = C_Container.GetContainerItemInfo(bag, slot)
                return info and info.hyperlink or nil
            end,
            deposit = client.Deposit,
        })
    end)
    if not ok then
        ns.ledgerMoney = nil
        ns.ReportError("the money tracker is not available this session: " .. tostring(err))
    end
end

-- Read one mail header into a table. The call only reads.
local function mailHeader(index)
    local _, _, sender, subject, money, _, _, itemCount, _, _, _, _, _, quantity, link = GetInboxHeaderInfo(index)
    if sender == nil and subject == nil then
        return nil
    end
    return { sender = sender, subject = subject, money = money, itemCount = itemCount, itemQuantity = quantity,
        itemLink = link }
end

-- Read the invoice fields of one mail. The order is the one in Blizzard_MailFrame/MailFrame.lua.
local function mailInvoice(index)
    local ok, invoiceType, itemName, player, bid, buyout, deposit, consignment, _, _, _, quantity =
        pcall(GetInboxInvoiceInfo, index)
    if not ok or invoiceType == nil then
        return nil
    end
    return { type = invoiceType, itemName = itemName, player = player, bid = bid, buyout = buyout, deposit = deposit,
        consignment = consignment, count = quantity }
end

-- Resolve an item name to a key when exactly one scanned or cached item has that name.
local function itemKeyByName(name)
    if not ns.itemNameIndex or type(name) ~= "string" then
        return nil
    end
    local ok, matches = pcall(ns.itemNameIndex.Find, ns.itemNameIndex, '"' .. name .. '"', 2)
    if ok and type(matches) == "table" and #matches == 1 then
        return matches[1].key
    end
    return nil
end

-- Create the mail reader of the ledger; it needs the money tracker. It reads the inbox and adds no hook.
local function openLedgerMail()
    if not (ns.db and ns.ledgerBuffer and ns.ledgerMoney and ns.LedgerMail and type(GetInboxNumItems) == "function"
        and type(GetInboxHeaderInfo) == "function") then
        return
    end
    local ok, err = pcall(function()
        local KEY = "ledger.mailFps"
        local fingerprints = ns.db:Get("account", KEY)
        if type(fingerprints) ~= "table" then
            fingerprints = {}
            ns.db:Set("account", KEY, fingerprints)
        end
        ns.ledgerMail = ns.LedgerMail.Attach({
            bus = ns.bus,
            buffer = ns.ledgerBuffer,
            tracker = ns.ledgerMoney,
            api = {
                numItems = GetInboxNumItems, header = mailHeader, invoice = mailInvoice,
                text = type(GetInboxText) == "function" and function(index)
                    pcall(GetInboxText, index)
                end or nil,
            },
            invoices = ns.Flavour.hasMailInvoices == true and type(GetInboxInvoiceInfo) == "function",
            -- The text read waits while a take (for example Open All) is in flight.
            busy = function()
                return C_Mail ~= nil and type(C_Mail.IsCommandPending) == "function"
                    and C_Mail.IsCommandPending() == true
            end,
            now = GetTime,
            serverTime = GetServerTime,
            character = characterKey,
            after = C_Timer.After,
            report = ns.ReportError,
            isSecret = type(issecretvalue) == "function" and issecretvalue or nil,
            strings = function(name)
                return _G[name]
            end,
            itemKey = function(input)
                return ns.ItemString.ToKey(input, false)
            end,
            itemKeyByName = itemKeyByName,
            fillSeller = function(item, qty, seller)
                local me = characterKey()
                local function match(record)
                    return record.source == "ahPurchase" and record.char == me and record.item == item
                        and (not qty or qty == 0 or record.qty == 0 or record.qty == qty)
                end
                if ns.ledgerBuffer:FillCounterparty(seller, match) then
                    return true
                end
                -- A record that moved to the ledger addon is changed only if the addon is loaded.
                local store = ns.ledgerLoader and ns.ledgerLoader:Store()
                return store ~= nil and store:FillCounterparty(me, seller, match) or false
            end,
            fingerprints = fingerprints,
            saveFingerprints = function(value)
                ns.db:Set("account", KEY, value)
            end,
        })
    end)
    if not ok then
        ns.ledgerMail = nil
        ns.ReportError("the mail reader of the ledger is not available this session: " .. tostring(err))
    end
end

-- Print the money gain at the mailbox close. It does not need the ledger. It adds no hook.
-- The key mail.totalLine has no page yet. A false value turns the chat line off.
local function openMailTotal()
    if not (ns.db and ns.MailTotal and ns.TooltipLines and type(GetMoney) == "function") then
        return
    end
    local ok, err = pcall(function()
        ns.MailTotal.Attach({
            bus = ns.bus,
            money = GetMoney,
            print = printLine,
            format = ns.TooltipLines.FormatMoney,
            after = C_Timer.After,
            enabled = function()
                return ns.db:Get("account", "mail.totalLine") ~= false
            end,
            log = function(fmt, ...)
                log("mail", "debug", fmt, ...)
            end,
        })
    end)
    if not ok then
        ns.ReportError("the mail money line is not available this session: " .. tostring(err))
    end
end
-- Install the four read-only post-hooks of the ledger (SPEC 5.8). The send hook is the only writer of sent mail,
-- for the Blizzard Send tab and for the Flipside mailing run.
local function openLedgerHooks()
    if not (ns.ledgerBuffer and ns.ledgerMoney and ns.MailingLedger and ns.LedgerHooks) then
        return
    end
    local ok, err = pcall(function()
        local mail = ns.MailingLedger.New({
            buffer = ns.ledgerBuffer,
            tracker = ns.ledgerMoney,
            bus = ns.bus,
            character = characterKey,
            serverTime = GetServerTime,
            now = GetTime,
            itemKey = function(itemID)
                return ns.ItemString.ToKey(itemID, false)
            end,
            api = {
                item = function(index)
                    return GetSendMailItem(index)
                end,
                money = function()
                    return GetSendMailMoney()
                end,
                price = function()
                    return GetSendMailPrice()
                end,
            },
        })
        local vendor = ns.LedgerVendor and ns.LedgerVendor.New({
            bus = ns.bus,
            tracker = ns.ledgerMoney,
            now = GetTime,
            itemKey = function(link)
                return ns.ItemString.ToKey(link, false)
            end,
            api = {
                buybackCount = function()
                    return GetNumBuybackItems()
                end,
                buyback = function(index)
                    return GetBuybackItemInfo(index)
                end,
                buybackLink = function(index)
                    return GetBuybackItemLink(index)
                end,
                merchantLink = function(index)
                    return GetMerchantItemLink(index)
                end,
                -- Forever has C_MerchantFrame.GetItemInfo (a table); TBC has the global GetMerchantItemInfo.
                merchantInfo = function(index)
                    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
                        local info = C_MerchantFrame.GetItemInfo(index)
                        return info and info.price, info and info.stackCount
                    end
                    local _, _, price, stackCount = GetMerchantItemInfo(index)
                    return price, stackCount
                end,
                repairCost = function()
                    return GetRepairAllCost()
                end,
            },
        })
        ns.LedgerHooks.Install({
            hook = hooksecurefunc,
            globals = _G,
            report = ns.ReportError,
            onSendMail = function(recipient)
                mail.OnSendMail(recipient)
            end,
            onBuyMerchantItem = vendor and vendor.OnBuy or nil,
            hookBid = ns.AuctionClient and ns.AuctionClient.HookBid or nil,
            onBid = function(auctionID)
                ns.ledgerMoney:OnBid(auctionID)
            end,
        })
    end)
    if not ok then
        ns.ReportError("the ledger hooks are not available this session: " .. tostring(err))
    end
end

-- Save the gold balance of this character for the Ledger graph, at login and at logout.
local function saveBalance()
    if not (ns.db and ns.LedgerBalance and type(GetMoney) == "function") then
        return
    end
    local copper = GetMoney()
    if type(issecretvalue) == "function" and issecretvalue(copper) then
        return
    end
    ns.LedgerBalance.WriteSnapshot(ns.db, copper, GetServerTime())
end

local function openBalance()
    saveBalance()
    ns.bus:Subscribe("PLAYER_LOGOUT", "Flipside.LedgerBalance", saveBalance)
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
                local source = ns.priceReader or ns.scanStore
                return source and source:Get(key) or nil
            end,
            isGuild = function(key)
                return ns.IsGuildPrice ~= nil and ns.IsGuildPrice(key) or false
            end,
            now = GetServerTime,
            isAltDown = IsAltKeyDown,
            containerItemInfo = C_Container.GetContainerItemInfo,
            bus = ns.bus,
            currentRealmOnly = ns.Flavour.countsCurrentRealmOnly == true,
            realm = GetNormalizedRealmName,
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

-- Attach the auto rules runner: it puts new bag items of no group into groups by the rules.
local function openAutoRules()
    if not (ns.rules and ns.AutoRules and ns.readBags) then
        return
    end
    local ok, err = pcall(ns.AutoRules.Attach, {
        bus = ns.bus,
        rules = ns.rules,
        readBags = ns.readBags,
        itemCache = ns.itemCache,
        after = C_Timer.After,
        print = printLine,
    })
    if not ok then
        ns.ReportError("auto rules are not available this session: " .. tostring(err))
    end
end

-- The client frames that the compact inbox list hides: the seven mail buttons and the page buttons.
local function inboxClientFrames()
    local inbox = _G.InboxFrame
    local list = {}
    for index = 1, 7 do
        list[#list + 1] = _G["MailItem" .. index]
    end
    -- TBC names the page buttons as globals; Forever keeps them in InboxFrame.
    for _, key in ipairs({ "PrevPageButton", "NextPageButton", "PageTurnIndicatorLeft", "PageTurnIndicatorRight" }) do
        list[#list + 1] = _G["Inbox" .. key] or (inbox and inbox[key])
    end
    return list
end

-- Make the compact inbox list in the client InboxFrame. Returns nil if the client has no inbox function to reuse.
local function createInboxList()
    local inbox = _G.InboxFrame
    if not (ns.InboxList and inbox and type(InboxFrame_OnClick) == "function" and type(GetInboxHeaderInfo) == "function"
        and type(GetInboxNumItems) == "function" and type(AutoLootMailItem) == "function"
        and type(IsModifiedClick) == "function") then
        return nil
    end
    return ns.InboxList.Create(inbox, {
        api = {
            numItems = GetInboxNumItems,
            header = GetInboxHeaderInfo,
            openID = function()
                return inbox.openMailID
            end,
            -- Shift-click (the client setting MAILAUTOLOOTTOGGLE) takes all contents with AutoLootMailItem.
            isModified = function()
                return IsModifiedClick("MAILAUTOLOOTTOGGLE")
            end,
            autoLoot = AutoLootMailItem,
            freeSlots = function()
                local free = 0
                for bag = 0, _G.NUM_BAG_SLOTS or 4 do
                    free = free + (C_Container.GetContainerNumFreeSlots(bag) or 0)
                end
                return free
            end,
            -- The client function opens the mail from the state of the button: checked opens, unchecked closes.
            open = function(index)
                local opening = inbox.openMailID ~= index
                InboxFrame_OnClick({ GetChecked = function() return opening end }, index)
            end,
        },
        formatMoney = ns.TooltipLines.FormatMoney,
        notify = printLine,
        blizzard = inboxClientFrames,
        openMail = function()
            return _G.OpenMailFrame
        end,
        skin = ns.AuctionTabs and ns.AuctionTabs.Skin,
        -- The area of the client buttons, taller: down to the Open All button.
        place = function(frame)
            ns.InboxList.Anchor(frame, inbox, _G.MailItem1, _G.OpenAllMail, _G.MailItem7)
        end,
    })
end

-- Attach the mailing view to the MailFrame; it needs the groups and operations.
local function openMailing()
    if not (ns.rules and ns.MailClient and ns.MailingRun and ns.MailingView and ns.MailHost and ns.Kit
        and type(SendMail) == "function") then
        return
    end
    local ok, err = pcall(function()
        local client = ns.MailClient.New(ns.MailClient.Default())
        ns.rules:EnsureAllBagsGroup()
        local function itemName(key)
            local parsed = ns.ItemString.ParseKey(key)
            local info = parsed and ns.itemCache:Get(parsed.itemID)
            return info and info.name or key
        end
        ns.MailHost.Attach({
            bus = ns.bus,
            after = C_Timer.After,
            frame = function()
                return _G.MailFrame
            end,
            openMail = function()
                return _G.OpenMailFrame
            end,
            children = function()
                local list = {}
                for _, name in ipairs({ "InboxFrame", "SendMailFrame" }) do
                    list[#list + 1] = _G[name]
                end
                return list
            end,
            createInbox = function()
                return createInboxList()
            end,
            -- The bottom bar of the view follows Open All on the Inbox tab and Cancel on the Send Mail tab.
            tabs = function()
                local bar = ns.Flavour.mailBar
                return {
                    { frame = _G.InboxFrame, ref = _G.OpenAllMail, fallback = bar.inbox },
                    { frame = _G.SendMailFrame, ref = _G.SendMailCancelButton, fallback = bar.send },
                }
            end,
            create = function(parent, size)
                return ns.MailingView.Create(parent, {
                    rules = ns.rules,
                    client = client,
                    skin = ns.AuctionTabs and ns.AuctionTabs.Skin,
                    characters = function()
                        return ns.holdings and ns.holdings:Characters() or {}
                    end,
                    selfName = function()
                        return characterKey() or UnitName("player")
                    end,
                    itemName = itemName,
                    formatMoney = ns.TooltipLines.FormatMoney,
                    confirm = function(text, onAccept)
                        ns.Kit.Confirm("FLIPSIDE_MAILING_SEND", text, onAccept)
                    end,
                    newRun = function(callbacks)
                        return ns.MailingRun.New({
                            client = client,
                            bus = ns.bus,
                            after = C_Timer.After,
                            delay = ns.Flavour.mailDelay,
                            bagWait = ns.Flavour.mailBagWait,
                            onProgress = callbacks.onProgress,
                            onDone = callbacks.onDone,
                        })
                    end,
                }, size)
            end,
        })
    end)
    if not ok then
        ns.ReportError("the mailing view is not available this session: " .. tostring(err))
    end
end

-- Attach the craft profit panel to the profession window; it needs the settings DB and the formula runner.
local function openCrafting()
    if not (ns.db and ns.formulaRun and ns.CraftPanel and ns.CraftClient and ns.CraftCost and ns.SellingPlan
        and ns.Kit and ns.TooltipLines) then
        return
    end
    local ok, err = pcall(function()
        local Panel = ns.CraftPanel
        local keys = { reagent = Panel.REAGENT_KEY, item = Panel.ITEM_KEY }
        ns.craftPanel = Panel.Attach({
            kit = ns.Kit,
            client = ns.CraftClient.New(_G),
            bus = ns.bus,
            format = ns.TooltipLines.FormatMoney,
            run = ns.formulaRun,
            cut = ns.SellingPlan.Cut,
            getFormulas = function()
                return ns.db:Get("account", Panel.REAGENT_KEY) or Panel.DEFAULT_REAGENT_FORMULA,
                    ns.db:Get("account", Panel.ITEM_KEY) or Panel.DEFAULT_ITEM_FORMULA
            end,
            setFormula = function(which, text)
                local compiled, compileErr = ns.formulaRun:Compile(text)
                if not compiled then
                    return false, compileErr and compileErr.message or "The formula is not valid."
                end
                if not ns.db:Set("account", keys[which], text) then
                    return false, "Settings are read-only."
                end
                return true
            end,
        })
    end)
    if not ok then
        ns.ReportError("the craft profit panel is not available this session: " .. tostring(err))
    end
end

-- Write the session marker: addon version, flavour, client build, realm and character.
local function writeSessionMarker()
    if not ns.Log then
        return
    end
    local client, build, _, interface = GetBuildInfo()
    local okVersion, version = pcall(function() return C_AddOns.GetAddOnMetadata(addonName, "Version") end)
    ns.Log.SessionMarker({
        version = okVersion and version or nil,
        flavour = ns.Flavour.savedVariables.main,
        client = client,
        build = build,
        interface = interface,
        realm = GetNormalizedRealmName(),
        character = UnitName("player"),
    })
end

-- Set later in this file: attach the Auction House tab.
local openUI, openMinimapButton

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" and (...) == addonName then
        if ns.Log then
            _G.FlipsideLogDB = ns.Log.Attach(_G.FlipsideLogDB)
        end
        ns.bus:Emit("Flipside.Loaded")
    elseif event == "PLAYER_LOGIN" then
        pcall(writeSessionMarker)
        trackAuctionHouse()
        openSettingsDB()
        if ns.db then
            openScan()
        end
        openGuildSync()
        openNames()
        openAHSearch()
        openFormula()
        openRules()
        openSearchLists()
        openInventory()
        openLedger()
        openLedgerMoney()
        openLedgerMail()
        openMailTotal()
        openLedgerHooks()
        openBalance()
        openTooltip()
        openMailing()
        openCrafting()
        openAutoRules()
        openUI()
        openMinimapButton()
        if ns.RecipeSearch then
            ns.RecipeSearch.Attach()
        end
        log("core", "info", "login done: settings %s, scan %s, ledger %s", ns.db and "on" or "off",
            ns.scanEngine and "on" or "off", ns.ledgerBuffer and "on" or "off")
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
    ["bad-mode"] = "unknown scan mode",
}

-- Returns the name of a scan in messages: "full scan", "fast scan" or "page scan".
local function scanLabel(mode)
    return (mode == nil or mode == "full") and "full scan" or (mode .. " scan")
end

-- Print why a scan cannot start.
local function printRefusal(reason, detail, mode)
    local text = REFUSALS[reason] or tostring(reason)
    if reason == "cooldown" then
        text = "scan on cooldown, " .. ns.ScanCooldown.FormatRemaining(detail) .. " left"
    elseif reason == "client" then
        text = detail
    end
    printLine(scanLabel(mode) .. " not started: " .. text)
end

-- The callback that the popup runs when the player accepts.
local pendingScanAccept

-- Start the scan from the chat command after the player accepts.
local function startChatScan(mode)
    local engine = ns.scanEngine
    if not engine then
        return
    end
    local ok, reason, detail = engine:CanStart(mode)
    if ok then
        engine:Start(mode)
    else
        printRefusal(reason, detail, mode)
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
local function withMainWindow(action)
    if not ns.MainWindow then
        printLine("the window is not available this session")
        return
    end
    local ok, err = pcall(function()
        local window = ns.MainWindow.Create({
            windowPosition = ns.db and {
                get = function()
                    return ns.db:Get("account", "ui.windowPosition")
                end,
                set = function(position)
                    ns.db:Set("account", "ui.windowPosition", position)
                end,
            } or nil,
            windowSize = ns.db and {
                get = function()
                    return ns.db:Get("character", "ui.windowSize")
                end,
                set = function(size)
                    ns.db:Set("character", "ui.windowSize", size)
                end,
            } or nil,
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
                local source = ns.priceReader or ns.scanStore
                return source and source:Get(key) or nil
            end,
            buildPreview = ns.BuildTooltipPreview,
            ledgerLoader = ns.ledgerLoader,
            ledgerBuffer = ns.ledgerBuffer,
            getMoney = GetMoney,
            bus = ns.bus,
            db = ns.db,
            character = characterKey(),
            now = GetServerTime,
            after = C_Timer.After,
            getVersionLine = ns.VersionLine,
            openLog = ns.OpenLogWindow,
            guildSync = ns.guildSync and { isEnabled = guildSyncEnabled, setEnabled = ns.SetGuildSync } or nil,
            sounds = { isEnabled = uiSoundsEnabled, setEnabled = ns.SetUISounds },
        })
        action(window)
    end)
    if not ok then
        ns.ReportError("window is not available this session: " .. tostring(err))
    end
end

function ns.OpenMainWindow()
    withMainWindow(function(window)
        window:Toggle()
    end)
end

-- Show or hide the log window.
function ns.OpenLogWindow()
    if not (ns.LogWindow and ns.Log) then
        printLine("the log window is not available this session")
        return
    end
    local ok, err = pcall(function()
        ns.LogWindow.Create({ log = ns.Log, after = C_Timer.After }):Toggle()
    end)
    if not ok then
        ns.ReportError("the log window is not available this session: " .. tostring(err))
    end
end

local DISENCHANT_SPELL = 13262

-- Return the name of the Disenchant spell (nil if the client gives none) and true if the player knows it.
-- The two clients have different spell functions, so each call checks which one exists.
local function disenchantSpell()
    local name
    if C_Spell and C_Spell.GetSpellName then
        name = C_Spell.GetSpellName(DISENCHANT_SPELL)
    end
    if not name and GetSpellInfo then
        name = GetSpellInfo(DISENCHANT_SPELL)
    end
    local known = false
    if IsPlayerSpell then
        known = IsPlayerSpell(DISENCHANT_SPELL)
    elseif IsSpellKnown then
        known = IsSpellKnown(DISENCHANT_SPELL)
    elseif C_SpellBook and C_SpellBook.IsSpellKnown then
        known = C_SpellBook.IsSpellKnown(DISENCHANT_SPELL)
    end
    return name, known == true
end

-- Show or hide the Destroy window. It is created on first use, and not in combat (the Destroy button is secure).
function ns.OpenDestroyWindow()
    if not (ns.DestroyWindow and ns.DestroyRules and ns.db and ns.readDestroyStacks) then
        printLine("the Destroy window is not available this session")
        return
    end
    if not ns.DestroyWindow.Get() and InCombatLockdown() then
        printLine("the Destroy window cannot open for the first time in combat")
        return
    end
    local ok, err = pcall(function()
        ns.DestroyWindow.Create({
            store = ns.DestroyRules.NewStore(ns.db),
            readStacks = ns.readDestroyStacks,
            itemInfo = function(itemID)
                return (ns.itemCache:Get(itemID))
            end,
            requestInfo = function(itemID, callback)
                ns.itemCache:Request(itemID, callback)
            end,
            player = function()
                return { level = UnitLevel("player"), class = select(2, UnitClass("player")) }
            end,
            disenchant = disenchantSpell,
            inCombat = InCombatLockdown,
            log = function(text)
                log("destroy", "debug", "%s", text)
            end,
            bus = ns.bus,
            after = C_Timer.After,
            print = printLine,
            position = {
                get = function()
                    return ns.db:Get("account", "ui.destroyPosition")
                end,
                set = function(position)
                    ns.db:Set("account", "ui.destroyPosition", position)
                end,
            },
        }):Toggle()
    end)
    if not ok then
        ns.ReportError("the Destroy window is not available this session: " .. tostring(err))
    end
end

-- The minimap button: hide the window if it shows the Ledger page; otherwise show the Ledger page.
function ns.ToggleLedgerWindow()
    withMainWindow(function(window)
        if window:IsShown() and window:GetSelectedPage() == "ledger" then
            window:Hide()
        else
            window:Show()
            window:SelectPage("ledger")
        end
    end)
end

-- Create the minimap button; it needs the settings DB and the minimap frame.
openMinimapButton = function()
    if not (ns.db and ns.Kit and ns.Kit.CreateMinimapButton and Minimap) then
        return
    end
    local ok, result = pcall(ns.Kit.CreateMinimapButton, "FlipsideMinimapButton", {
        parent = Minimap,
        icon = "Interface\\Icons\\INV_Misc_Coin_02",
        title = "Flipside",
        lines = { "Left click: open the ledger", "Drag: move this button around the minimap" },
        angle = ns.db:Get("account", "ui.minimapAngle"),
        hidden = ns.db:Get("account", "ui.minimapHidden") == true,
        onClick = function(_, mouseButton)
            if mouseButton == nil or mouseButton == "LeftButton" then
                ns.ToggleLedgerWindow()
            end
        end,
        onAngleChanged = function(angle)
            ns.db:Set("account", "ui.minimapAngle", angle)
        end,
    })
    if ok then
        ns.minimapButton = result
    else
        ns.ReportError("minimap button is not available this session: " .. tostring(result))
    end
end

-- Toggle the minimap button and save the choice.
local function minimapCommand()
    if not (ns.minimapButton and ns.db) then
        printLine("the minimap button is not available this session")
        return
    end
    local hidden = ns.db:Get("account", "ui.minimapHidden") ~= true
    if not ns.db:Set("account", "ui.minimapHidden", hidden) then
        printLine("settings are read-only; the choice was not saved")
    end
    ns.minimapButton:SetHidden(hidden)
    printLine(hidden and "minimap button hidden" or "minimap button shown")
end

-- Put the window back in the centre of the screen and forget the saved position.
local function resetPositionCommand()
    if ns.db then
        ns.db:Set("account", "ui.windowPosition", nil)
    end
    local window = ns.MainWindow and ns.MainWindow.Get()
    if window then
        window:ResetPosition()
    end
    printLine("window position reset")
end

openUI = function()
    if not ns.AuctionTab then
        return
    end
    local ok, result = pcall(ns.AuctionTab.Attach, {
        bus = ns.bus,
        serverTime = GetServerTime,
        scanEngine = ns.scanEngine,
        scanModes = ns.AuctionClient.ScanModes(),
        scanCooldown = ns.scanCooldown,
        scanStore = ns.scanStore,
        formulaLookup = ns.FormulaLookup,
        scanSources = ns.ScanSources,
        itemNameIndex = ns.itemNameIndex,
        requestPriceRefresh = ns.RequestPriceRefresh,
        confirmScan = confirmScan,
        openMainWindow = ns.OpenMainWindow,
        -- Profile setting ui.startPageScanBar: the scan bar on the start page of the Auction House. Default on.
        startPageEnabled = function()
            return not ns.db or ns.db:Get("profile", "ui.startPageScanBar") ~= false
        end,
        setStartPageEnabled = function(on)
            return ns.db ~= nil and ns.db:Set("profile", "ui.startPageScanBar", on and true or false)
        end,
    })
    if ok then
        ns.auctionTab = result
    else
        ns.ReportError("Auction House tab is not available this session: " .. tostring(result))
    end
    if ns.AuctionTabs then
        ns.auctionTabs = ns.AuctionTabs.AttachAll({
            bus = ns.bus,
            rules = ns.rules,
            formulaRun = ns.formulaRun,
            after = C_Timer.After,
            db = ns.db,
            readBags = ns.readBagStacks,
            searchLists = ns.searchLists,
            itemNameIndex = ns.itemNameIndex,
            ahNameSearch = ns.ahNameSearch,
            keyFor = ns.keyFor,
            isAuctionHouseOpen = ns.IsAuctionHouseOpen,
            getRecord = function(key)
                local source = ns.priceReader or ns.scanStore
                return source and source:Get(key) or nil
            end,
            now = GetServerTime,
        })
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
    -- With scan modes, the argument is the mode: "" or "full", "fast", "page". Without modes, it is ignored.
    local mode
    if ns.AuctionClient.ScanModes() then
        mode = argument == "" and "full" or argument
    end
    local ok, reason, detail = engine:CanStart(mode)
    if not ok then
        if reason == "bad-mode" then
            printLine("scan modes: " .. table.concat(ns.AuctionClient.ScanModes(), ", "))
        else
            printRefusal(reason, detail, mode)
        end
        return
    end
    if mode == "page" then
        startChatScan(mode)
        return
    end
    confirmScan(function()
        startChatScan(mode)
    end)
end

-- Money in copper, shown with the shared formatter.
local function formatMoney(copper)
    if type(copper) ~= "number" then
        return "-"
    end
    return ns.TooltipLines.FormatMoney(copper)
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
    if argument:match("^%d+$") or ns.ItemString.ParseKey(argument) then
        -- An item ID or a Flipside key such as 25320#s-44.
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
        local record = (ns.priceReader or ns.scanStore):Get(key)
        if record then
            return record, key, keys
        end
    end
    return nil, nil, keys
end

local function printPrice(record, key)
    local values = ns.ScanSources.Compute(record, GetServerTime())
    local guild = ns.IsGuildPrice and ns.IsGuildPrice(key) and " (guild)" or ""
    printLine("key " .. key .. guild .. ": " .. priceText("ScanMin", values.scanMin) .. ", "
        .. priceText("ScanRecent", values.scanRecent))
    printLine(priceText("ScanMarket", values.scanMarket) .. ", "
        .. priceText("ScanHistorical", values.scanHistorical))
    local age = values.scanAge and string.format("%.1f h", values.scanAge) or "-"
    printLine("ScanQty " .. tostring(values.scanQty or "-") .. ", ScanAge " .. age
        .. ", ScanSamples " .. values.scanSamples .. (values.scanPartial and ", partial" or ""))
end

local PRICE_WAIT_SECONDS = 10
local pendingRefresh

-- Search the item in the open Auction House and print the fresh price when the capture stores it.
-- If the Auction House is closed, print the hint.
local function refreshPrice(itemID, name)
    if not itemID then
        return
    end
    local ok, err = ns.RequestPriceRefresh(itemID, name)
    if not ok then
        if err then
            printLine(err)
        end
        return
    end
    pendingRefresh = { itemID = itemID, startedAt = GetTime() }
    ns.bus:Subscribe(EVENT_PRICE_CAPTURED, "Flipside.PriceCommand", function(_, key)
        local pending = pendingRefresh
        if not pending or GetTime() - pending.startedAt > PRICE_WAIT_SECONDS then
            pendingRefresh = nil
            ns.bus:Unsubscribe(EVENT_PRICE_CAPTURED, "Flipside.PriceCommand")
            return
        end
        if ns.ItemString.KeyToBaseKey(key) == string.format("%d", pending.itemID) then
            printLine("fresh price from the Auction House:")
            printPrice((ns.priceReader or ns.scanStore):Get(key), key)
        end
    end)
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
        printPrice((ns.priceReader or ns.scanStore):Get(matches[1].key), matches[1].key)
        refreshPrice(matches[1].itemID, matches[1].name)
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
            printLine("usage: /flip price <item name, id, link or key>")
        end
        return
    end
    local parsed = ns.ItemString.ParseKey(keys[1]) or ns.ItemString.ParseLink(keys[1])
    if not record then
        printLine("no scan data for " .. table.concat(keys, " or "))
    else
        printPrice(record, key)
    end
    refreshPrice(parsed and parsed.itemID, argument:match("|h%[(.-)%]|h"))
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
    local scanWord = ns.AuctionClient.ScanModes() and "scan [fast|page]" or "scan"
    printLine("commands: " .. scanWord .. ", scan stop, scan reset, price <item>, formula <text> [item], version")
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

-- Print the last 30 lines of the money tracker event ring, and its counters.
local function ledgerDebugCommand()
    local tracker = ns.ledgerMoney
    if not tracker then
        printLine("the money tracker is not available this session")
        return
    end
    local stats = tracker:Stats()
    printLine(string.format("ledger money: %d records, %d skipped, %d claimed, %d rejected, %d unpaired",
        stats.records, stats.skipped, stats.claimed, stats.rejected, stats.unpaired))
    if ns.ledgerMail then
        local mail = ns.ledgerMail:Stats()
        printLine(string.format(
            "ledger mail: %d sales, %d expired, %d cancelled, %d refunds, %d mail money, %d duplicates, "
            .. "%d skipped, %d without invoice, %d unknown invoice, %d late",
            mail.sales, mail.expired, mail.cancelled, mail.refunds, mail.mailMoney, mail.duplicates, mail.skipped,
            mail.noInvoice, mail.unknownInvoice, mail.late))
    end
    local lines = tracker:DebugLines(30)
    if #lines == 0 then
        printLine("no events in the ring; set ledger.debug to true to fill it")
    end
    for _, line in ipairs(lines) do
        printLine(line)
    end
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

-- Print the state of the guild price sharing, or send a request with "request".
local function syncCommand(argument)
    local sync = ns.guildSync
    if not sync then
        printLine("guild sharing is not available this session")
        return
    end
    if argument == "request" then
        local sent, reason = sync:SendRequest(true)
        printLine(sent and "request sent to the guild" or ("request not sent: " .. tostring(reason)))
        return
    end
    for _, line in ipairs(ns.GuildSync.StatusLines(sync:Status(), GetServerTime())) do
        printLine(line)
    end
end

-- Handle the text after /flipside or /flip.

function ns.HandleSlash(msg)
    local text = tostring(msg or "")
    log("core", "info", "slash command: /flip %s", text)
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
    elseif command == "sync" then
        syncCommand(rest:lower())
        return
    elseif command == "ledgerdebug" then
        ledgerDebugCommand()
        return
    elseif command == "log" then
        ns.OpenLogWindow()
        return
    elseif command == "destroy" then
        ns.OpenDestroyWindow()
        return
    elseif command == "minimap" then
        minimapCommand()
        return
    elseif command == "resetpos" then
        resetPositionCommand()
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
    printLine("/flip destroy opens the Destroy window")
    printLine("No feature exists yet.")
end

SLASH_FLIPSIDE1 = "/flipside"
SLASH_FLIPSIDE2 = "/flip"
SlashCmdList.FLIPSIDE = ns.HandleSlash
