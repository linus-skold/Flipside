local _, ns = ...

-- The host of the mailing view. On MAIL_SHOW it places the view with a layout, on MAIL_CLOSED it takes the layout
-- away. Both clients have a MailFrame global, so one host serves both flavours.
-- A layout decides the place of the view. Today the only layout is "wide": MailFrame gets wider and the view sits in
-- the new strip. A "tab" layout needs only a new entry in MailHost.LAYOUTS (SPEC 5.5, "Switch to a tab").
local MailHost = {}
ns.MailHost = MailHost

local OWNER = "Flipside.MailHost"
-- The extra width of the wide layout, and the gaps of the view in the new strip, in pixels. The view has the full
-- height of the strip: its header sits in the row of the client title, its bottom bar on the client bottom row.
local EXTRA_WIDTH = 380
local VIEW_GAP = { top = 2, right = 2, bottom = 0 }
local VIEW_LEVEL = 5
local OPEN_MAIL_X = 46
-- Delays in seconds: the inbox list refreshes at most every 0.1 s, the plan of the view after a burst of bag events.
local INBOX_DELAY = 0.1
local VIEW_DELAY = 0.2

-- Keep a child frame at its old width: a frame anchored at two corners of MailFrame would stretch with it.
-- Returns the old points, or nil if the frame does not stretch.
local function pinChild(child, mailFrame, width)
    local count = child:GetNumPoints()
    if count < 2 then
        return nil
    end
    local saved = {}
    for index = 1, count do
        saved[index] = { child:GetPoint(index) }
    end
    child:ClearAllPoints()
    child:SetPoint("TOPLEFT", mailFrame, "TOPLEFT", 0, 0)
    child:SetPoint("BOTTOMLEFT", mailFrame, "BOTTOMLEFT", 0, 0)
    child:SetWidth(width)
    return saved
end

local function unpinChild(pin)
    pin.child:ClearAllPoints()
    for _, point in ipairs(pin.points) do
        pin.child:SetPoint(unpack(point, 1, 5))
    end
    if pin.width then
        pin.child:SetWidth(0)
    end
end

-- Move the open-mail frame to the right edge of MailFrame, where Forever puts it (x 46). TBC anchors it to the
-- Inbox frame, which would put it over the view. Returns the old points.
local function moveOpenMail(openMail, mailFrame)
    local saved = {}
    for index = 1, openMail:GetNumPoints() do
        saved[index] = { openMail:GetPoint(index) }
    end
    openMail:ClearAllPoints()
    openMail:SetPoint("TOPLEFT", mailFrame, "TOPRIGHT", OPEN_MAIL_X, 0)
    return saved
end

-- Layouts. Each one is function(deps, host) returning { Open(mailFrame), Close() }. Open makes the view if it does
-- not exist (host.view = deps.create(parent, size)), places it and shows it. Close hides it and undoes the change
-- to the Blizzard frames.
MailHost.LAYOUTS = {
    -- Widen MailFrame and put the view in the new strip. The art of the Inbox and Send tabs keeps its size.
    wide = function(deps, host)
        local state
        local layout = {}

        function layout.Open(mailFrame)
            if not state then
                local width = mailFrame:GetWidth()
                state = { width = width, pins = {} }
                for _, child in ipairs(deps.children()) do
                    local points = pinChild(child, mailFrame, width)
                    if points then
                        state.pins[#state.pins + 1] = { child = child, points = points, width = true }
                    end
                end
                mailFrame:SetWidth(width + EXTRA_WIDTH)
                local openMail = deps.openMail and deps.openMail()
                if openMail then
                    state.pins[#state.pins + 1] = { child = openMail, points = moveOpenMail(openMail, mailFrame) }
                end
            end
            if not host.view then
                host.view = deps.create(mailFrame, {
                    width = EXTRA_WIDTH - VIEW_GAP.right,
                    height = math.max(1, mailFrame:GetHeight() - VIEW_GAP.top - VIEW_GAP.bottom),
                })
            end
            local frame = host.view.frame
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", mailFrame, "TOPLEFT", state.width, -VIEW_GAP.top)
            frame:SetPoint("BOTTOMRIGHT", mailFrame, "BOTTOMRIGHT", -VIEW_GAP.right, VIEW_GAP.bottom)
            frame:SetFrameLevel(mailFrame:GetFrameLevel() + VIEW_LEVEL)
            host.view:Show()
        end

        function layout.Close(mailFrame)
            if host.view then
                host.view:Hide()
            end
            if state then
                mailFrame:SetWidth(state.width)
                for _, pin in ipairs(state.pins) do
                    unpinChild(pin)
                end
                state = nil
            end
        end

        return layout
    end,
}

-- Each tab of MailFrame has its own bottom button. A small child frame of each tab frame shows and hides with the
-- tab. Its OnShow script (a script of our own frame, not a hook) puts the bottom bar of the view on the row of
-- the button of that tab. tab = { frame, ref (the client button), fallback = { bottom, height } }.
local function watchTabs(deps, host)
    if host.watching or not deps.tabs then
        return
    end
    host.watching = true
    host.markers = {}
    for _, tab in ipairs(deps.tabs()) do
        local marker = CreateFrame("Frame", nil, tab.frame)
        marker:SetSize(1, 1)
        local function align()
            host.view:AlignBar(tab.ref, tab.fallback)
        end
        marker:SetScript("OnShow", align)
        host.markers[#host.markers + 1] = marker
        if tab.frame:IsShown() then
            align()
        end
    end
end

-- deps: bus, create(parent, size) (returns a MailingView), after(seconds, fn), frame() (returns the MailFrame or
-- nil), openMail() (the open-mail frame or nil), children() (the frames inside MailFrame that must keep their
-- width: InboxFrame, SendMailFrame), mode (a key of MailHost.LAYOUTS, default "wide"), createInbox(mailFrame)
-- (optional; returns the compact inbox list, an InboxList, or nil), tabs() (optional; returns the tab list of
-- watchTabs, one entry for each of Inbox and Send Mail). The inbox list does not depend on the layout:
-- it shows on MAIL_SHOW, refreshes on MAIL_INBOX_UPDATE and hides on MAIL_CLOSED.
-- take (optional, a MailTake): while it is active, the view does not read the bags; it reads once when the take ends.
-- Returns an object with View(), the view or nil, and Inbox(), the inbox list or nil.
function MailHost.Attach(deps)
    local host = { view = nil, inbox = nil }
    local layout = MailHost.LAYOUTS[deps.mode or "wide"](deps, host)
    local open
    local inboxDirty, inboxScheduled, viewDirty, viewScheduled = false, false, false, false

    local function show(retry)
        local mailFrame = deps.frame()
        if not mailFrame then
            -- The client can load its mail frame after this event handler runs.
            if retry then
                deps.after(0, function()
                    show(false)
                end)
            end
            return
        end
        layout.Open(mailFrame)
        open = mailFrame
        watchTabs(deps, host)
        host.view:Refresh()
        viewDirty = false
        if deps.createInbox then
            host.inbox = host.inbox or deps.createInbox(mailFrame)
            if host.inbox then
                host.inbox:Show()
                -- Show reads the inbox, so an update that came before it needs no second read.
                inboxDirty = false
            end
        end
    end

    deps.bus:Subscribe("MAIL_SHOW", OWNER, function()
        show(true)
    end)
    deps.bus:Subscribe("MAIL_CLOSED", OWNER, function()
        if open then
            if host.inbox then
                host.inbox:Hide()
            end
            layout.Close(open)
            open = nil
        end
    end)
    -- Many MAIL_INBOX_UPDATE events come in one take. They mark the list dirty, and one timer of INBOX_DELAY seconds
    -- refreshes it once. An event after the refresh starts a new timer, so the last state always shows.
    deps.bus:Subscribe("MAIL_INBOX_UPDATE", OWNER, function()
        if not (open and host.inbox and host.inbox.frame:IsShown()) then
            return
        end
        inboxDirty = true
        if inboxScheduled then
            return
        end
        inboxScheduled = true
        deps.after(INBOX_DELAY, function()
            inboxScheduled = false
            if inboxDirty and open and host.inbox and host.inbox.frame:IsShown() then
                inboxDirty = false
                host.inbox:Refresh()
            end
        end)
    end)
    -- Read the plan again if the bags changed, but not while a run changes the bags or a mail take is in progress.
    local function refreshView()
        local view = host.view
        if not (viewDirty and open and view and view.frame:IsShown()) then
            return
        end
        if deps.take and deps.take.IsActive() then
            return
        end
        viewDirty = false
        if not view.run:IsRunning() then
            view:Refresh()
        end
    end
    -- The bags changed: read the plan again after a short delay.
    -- A hidden view stays dirty until it shows again (show() refreshes it).
    deps.bus:Subscribe("BAG_UPDATE_DELAYED", OWNER, function()
        viewDirty = true
        if viewScheduled then
            return
        end
        viewScheduled = true
        deps.after(VIEW_DELAY, function()
            viewScheduled = false
            refreshView()
        end)
    end)
    -- The take ended: the skipped plan read runs once.
    deps.bus:Subscribe("Flipside.MailTakeEnded", OWNER, refreshView)

    function host.View()
        return host.view
    end
    function host.Inbox()
        return host.inbox
    end
    return host
end
