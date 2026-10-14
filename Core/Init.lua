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

ns.bus = ns.EventBus.New({
    onError = function(event, _, err)
        ns.ReportError("handler for " .. tostring(event) .. " failed: " .. tostring(err))
    end,
})

ns.scheduler = ns.Scheduler.New({
    clock = debugprofilestop,
    onError = function(job, message)
        ns.ReportError("job " .. tostring(job.name) .. " failed: " .. tostring(message))
    end,
})

-- Game event frame: registers an event only while the bus has a subscriber for it.
local eventFrame = CreateFrame("Frame")

local function isGameEvent(event)
    return event:match(GAME_EVENT_PATTERN) ~= nil and not ALWAYS_REGISTERED[event]
end

ns.bus.onFirstSubscriber = function(event)
    if isGameEvent(event) then
        local ok, err = pcall(eventFrame.RegisterEvent, eventFrame, event)
        if not ok then
            ns.ReportError("cannot register event " .. event .. ": " .. tostring(err))
        end
    end
end

ns.bus.onLastUnsubscribed = function(event)
    if isGameEvent(event) then
        eventFrame:UnregisterEvent(event)
    end
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" and (...) == addonName then
        ns.bus:Emit("Flipside.Loaded")
    elseif event == "PLAYER_LOGIN" then
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
    printVersion()
    printLine("No feature exists yet.")
end

SLASH_FLIPSIDE1 = "/flipside"
SLASH_FLIPSIDE2 = "/flip"
SlashCmdList.FLIPSIDE = ns.HandleSlash
