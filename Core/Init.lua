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

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" and (...) == addonName then
        ns.bus:Emit("Flipside.Loaded")
    elseif event == "PLAYER_LOGIN" then
        openSettingsDB()
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

-- Handle the text after /flipside or /flip.
function ns.HandleSlash(msg)
    local command = tostring(msg or ""):match("^%s*(%S*)"):lower()
    if command == "version" then
        printVersion()
        return
    end
    printLine("addon Flipside")
    if ns.db then
        printLine("profile " .. ns.db:GetProfile())
    end
    printVersion()
    printLine("No feature exists yet.")
end

SLASH_FLIPSIDE1 = "/flipside"
SLASH_FLIPSIDE2 = "/flip"
SlashCmdList.FLIPSIDE = ns.HandleSlash
