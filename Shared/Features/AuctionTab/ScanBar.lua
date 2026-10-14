local _, ns = ...

-- The scan controls of the Auction House: one button for each scan mode, a Stop button and a status text.
-- The Flipside tab and the bar on the Blizzard start page both use it, so the scan rules exist once.
-- A bar only reads Blizzard frames. It never writes to them (taint).
local ScanBar = {}
ns.ScanBar = ScanBar

local OWNER = "Flipside.StartPageBar"
local EVENT_FINISHED = "Flipside.ScanFinished"
local BAR_HEIGHT = 22
local LABEL_GAP = 6

local REFUSALS = {
    running = "a scan is already running",
    ["api-missing"] = "the scan call is not available",
    ["ah-closed"] = "open the Auction House first",
    ["read-only"] = "scan data is read-only",
    ["bad-mode"] = "unknown scan mode",
}

-- Button texts of the scan modes.
local MODE_TEXT = { full = "Full scan", fast = "Fast scan", page = "Page scan" }
local MODE_PAGE = "page"

local function scanLabel(mode)
    return (mode == nil or mode == "full") and "full scan" or (mode .. " scan")
end

local function refusalText(reason, detail)
    if reason == "cooldown" then
        return "scan on cooldown, " .. ns.ScanCooldown.FormatRemaining(detail) .. " left"
    end
    return REFUSALS[reason] or tostring(reason)
end

-- Return the short text of a finished scan for the start page bar.
function ScanBar.ResultText(summary)
    local label = summary.label or "full scan"
    if summary.result == "ok" or summary.result == "partial" then
        return string.format("Last: %s %s, %d items", label, summary.result, summary.items or 0)
    elseif summary.result == "error" then
        return "Last: " .. label .. " failed"
    end
    return "Last: " .. label .. " " .. tostring(summary.result)
end

local Bar = {}
Bar.__index = Bar

-- Say a message: to the say function of the owner, or in the status text of the bar.
function Bar:Say(text)
    if self.opts.say then
        self.opts.say(text)
    else
        self.message = text
    end
end

-- Tell the owner that the state can have changed.
function Bar:_Changed()
    if self.opts.onChange then
        self.opts.onChange()
    else
        self:Refresh()
    end
end

-- Remember the last scan result for the status text of the bar.
function Bar:SetResult(summary)
    self.result = summary and ScanBar.ResultText(summary) or nil
    self.message = ""
end

-- Put the status text after the last button, or after the Stop button while a scan runs.
function Bar:_PlaceLabel(running)
    if not self.opts.followLabel or self.labelRunning == running then
        return
    end
    self.labelRunning = running
    local label = self.status
    label:ClearAllPoints()
    label:SetPoint("LEFT", running and self.stop or self.lastButton, "RIGHT", LABEL_GAP, 0)
    label:SetPoint("RIGHT", self.parent, "RIGHT", 0, 0)
end

function Bar:_StatusText(running, left, clientRefuses)
    local short = self.opts.short
    if running then
        local engine = self.deps.scanEngine
        local mode, page, pages
        if engine.GetProgress then
            mode, page, pages = engine:GetProgress()
        end
        if mode == MODE_PAGE and page then
            return (short and "" or "Page scan: ") .. "page " .. page .. " of " .. pages
        elseif mode == MODE_PAGE then
            return short and "starting" or "Page scan: starting"
        end
        return short and "scanning" or "Scan running"
    elseif left > 0 then
        return "Cooldown: " .. ns.ScanCooldown.FormatRemaining(left)
    elseif clientRefuses then
        return "Get all not ready"
    elseif short then
        if self.message ~= "" then
            return self.message
        end
        return self.result or "Ready"
    end
    return "Cooldown: ready"
end

-- Update the buttons and the status text.
function Bar:Refresh()
    local engine, cooldown = self.deps.scanEngine, self.deps.scanCooldown
    if not (engine and cooldown) then
        for _, button in pairs(self.buttons or { self.scan }) do
            button:SetEnabled(false)
        end
        self.scan:SetEnabled(false)
        self.stop:SetShown(false)
        self.status:SetText("scan is not available this session")
        return
    end
    local running = engine:IsRunning()
    local left = running and 0 or cooldown:Remaining()
    local modes = self.deps.scanModes
    -- The client can refuse get all while the addon cooldown is over (for example after a reload).
    local clientRefuses = false
    if modes and not running then
        local _, reason = engine:CanStart(modes[1])
        clientRefuses = reason == "client"
    end
    local getAllReady = not running and left == 0 and not clientRefuses
    if self.buttons then
        for mode, button in pairs(self.buttons) do
            button:SetEnabled(not running and (mode == MODE_PAGE or getAllReady))
        end
    else
        self.scan:SetEnabled(getAllReady)
    end
    self.stop:SetShown(running)
    self:_PlaceLabel(running)
    self.status:SetText(self:_StatusText(running, left, clientRefuses))
end

-- Start a scan. The mode is nil without scan modes. The page mode needs no warning.
function Bar:Click(mode)
    local engine = self.deps.scanEngine
    self.message = ""
    local ok, reason, detail = engine:CanStart(mode)
    if not ok then
        self:Say(scanLabel(mode) .. " not started: " .. refusalText(reason, detail))
        self:_Changed()
        return
    end
    self:Say("")
    local function start()
        local canStart, why, more = engine:CanStart(mode)
        if canStart then
            engine:Start(mode)
        else
            self:Say(scanLabel(mode) .. " not started: " .. refusalText(why, more))
        end
        self:_Changed()
    end
    if mode == MODE_PAGE then
        start()
    else
        self.deps.confirmScan(start)
    end
end

-- Build the scan buttons, the Stop button and the status text in the parent frame.
-- deps: scanEngine, scanCooldown, scanModes (optional list of scan modes), confirmScan(onAccept).
-- opts: x, y (offset of the first button), buttonWidth, step (distance of the buttons), stopWidth,
-- labelDx, labelDy (status text offset, from the Stop button), say(text), onChange(), short, followLabel, labelRole.
-- Call :Refresh() after the build.
function ScanBar.New(parent, deps, opts)
    local Kit = ns.Kit
    opts = opts or {}
    local bar = setmetatable({ deps = deps, opts = opts, parent = parent, message = "" }, Bar)
    local x, y = opts.x or 0, opts.y or 0
    local width, step = opts.buttonWidth or 90, opts.step or 96
    local function place(widget, atX, atY)
        widget:SetPoint("TOPLEFT", parent, "TOPLEFT", atX, atY)
        return widget
    end
    local modes = deps.scanModes
    if modes then
        bar.buttons = {}
        for _, mode in ipairs(modes) do
            bar.buttons[mode] = place(Kit.Button(parent, MODE_TEXT[mode] or mode, width, function()
                bar:Click(mode)
            end), x, y)
            bar.lastButton = bar.buttons[mode]
            x = x + step
        end
        bar.scan = bar.buttons[modes[1]]
    else
        bar.scan = place(Kit.Button(parent, "Full scan", width, function()
            bar:Click()
        end), x, y)
        bar.lastButton = bar.scan
        x = x + step
    end
    bar.stopX = x
    bar.stop = place(Kit.Button(parent, "Stop", opts.stopWidth or 60, function()
        deps.scanEngine:Cancel()
        bar:_Changed()
    end), x, y)
    bar.status = Kit.Label(parent, "", opts.labelRole or "highlight")
    bar.status:SetJustifyH("LEFT")
    if bar.status.SetWordWrap then
        bar.status:SetWordWrap(false)
    end
    if not opts.followLabel then
        place(bar.status, x + (opts.labelDx or 0), y + (opts.labelDy or 0))
    end
    return bar
end

-- Mount the bar on the Blizzard start page.
-- placement: parent (Blizzard frame), page (Blizzard frame that the bar follows), anchor(frame),
-- width (optional), buttonWidth, stopWidth.
-- deps: the scan deps of the bar, bus (optional), startPageEnabled() -> boolean (optional).
-- Returns an object with :Update() and :Destroy().
function ScanBar.MountStartPage(deps, placement)
    local holder = CreateFrame("Frame", nil, placement.parent)
    holder:SetSize(placement.width or 300, BAR_HEIGHT)
    placement.anchor(holder)
    holder:SetShown(false)
    local bar = ScanBar.New(holder, deps, {
        buttonWidth = placement.buttonWidth,
        step = (placement.buttonWidth or 90) + 2,
        stopWidth = placement.stopWidth,
        short = true,
        followLabel = true,
        labelRole = "small",
    })
    local mount = { frame = holder, bar = bar }
    local ticker
    local function startTicker()
        if not ticker and C_Timer and C_Timer.NewTicker then
            ticker = C_Timer.NewTicker(1, function()
                bar:Refresh()
            end)
        end
    end
    local function stopTicker()
        if ticker then
            ticker:Cancel()
            ticker = nil
        end
    end
    -- Show the bar while the Blizzard page is shown and the setting is on.
    function mount:Update()
        local enabled = not deps.startPageEnabled or deps.startPageEnabled() ~= false
        local visible = not self.destroyed and enabled and placement.page:IsShown()
        holder:SetShown(visible)
        if visible then
            bar:Refresh()
            startTicker()
        else
            stopTicker()
        end
    end
    function mount:Destroy()
        self.destroyed = true
        holder:Hide()
        stopTicker()
        if deps.bus then
            deps.bus:Unsubscribe(EVENT_FINISHED, OWNER)
        end
    end
    -- The holder hides with the Blizzard frame: stop the ticker then.
    holder:SetScript("OnShow", function()
        bar:Refresh()
        startTicker()
    end)
    holder:SetScript("OnHide", stopTicker)
    placement.page:HookScript("OnShow", function()
        mount:Update()
    end)
    placement.page:HookScript("OnHide", function()
        mount:Update()
    end)
    if deps.bus then
        deps.bus:Subscribe(EVENT_FINISHED, OWNER, function(_, summary)
            bar:SetResult(summary)
            if holder:IsShown() then
                bar:Refresh()
            end
        end)
    end
    mount:Update()
    return mount
end
