local _, ns = ...

-- The host of the mailing view. On MAIL_SHOW it places the view with a layout, on MAIL_CLOSED it takes the layout
-- away. Both clients have a MailFrame global, so one host serves both flavours.
-- A layout decides the place of the view. TBC uses "wide": MailFrame gets wider and the view sits in the new strip.
-- Forever uses "window" (a Flipside window covers MailFrame) or "plain" (the client MailFrame, no change).
-- A "tab" layout needs only a new entry in MailHost.LAYOUTS (SPEC 5.5, "Switch to a tab").
local MailHost = {}
ns.MailHost = MailHost

local OWNER = "Flipside.MailHost"
-- The extra width of the wide layout, and the gaps of the view in the new strip, in pixels. The view has the full
-- height of the strip: its header sits in the row of the client title, its bottom bar on the client bottom row.
local EXTRA_WIDTH = 380
-- The Flipside mailbox window (Forever) uses the same extra width.
MailHost.EXTRA_WIDTH = EXTRA_WIDTH
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

    -- Forever, setting "Blizzard mailbox": the client MailFrame stays as the client made it. Only the button that
    -- switches to the Flipside window shows. No view and no inbox list.
    plain = function(deps, host)
        local layout = { plain = true }

        function layout.Open(mailFrame)
            host.toggle = host.toggle or deps.createToggle(mailFrame)
            host.toggle:Show()
        end

        function layout.Close()
            if host.toggle then
                host.toggle:Hide()
            end
        end

        return layout
    end,

    -- Forever, setting "Flipside mailbox": a Flipside window covers MailFrame, which stays shown under it (hiding
    -- MailFrame would end the mail session). The window has the inbox list and the mailing view in its pages.
    -- OpenMailFrame moves to the right edge of the window and goes above it.
    window = function(deps, host)
        local layout = { ownInbox = true, noTabs = true }
        local saved

        function layout.Open(mailFrame)
            host.toggle = host.toggle or deps.createToggle(mailFrame)
            host.toggle:Hide()
            host.window = host.window or deps.createWindow()
            local box = host.window
            box:Open(mailFrame)
            if not host.view then
                host.view = deps.create(box.pages.rules)
                host.view.frame:SetAllPoints(box.pages.rules)
            end
            if not host.inbox and deps.createInbox then
                host.inbox = deps.createInbox(mailFrame, box.pages.inbox)
            end
            if not host.send and deps.createSend then
                host.send = deps.createSend(box.pages.send)
                if box.sendNote then
                    box.sendNote:Hide()
                end
            end
            if host.send then
                -- The page tells the client if a send page shows: the window opens over the client tab.
                host.send:Sync()
            end
            local openMail = deps.openMail and deps.openMail()
            if openMail and not saved then
                saved = { points = moveOpenMail(openMail, box.frame), strata = openMail:GetFrameStrata() }
                openMail:SetFrameStrata("DIALOG")
            end
            host.view:Show()
        end

        function layout.Close()
            if host.view then
                host.view:Hide()
            end
            if host.window then
                host.window:Hide()
            end
            local openMail = saved and deps.openMail and deps.openMail()
            if openMail then
                unpinChild({ child = openMail, points = saved.points })
                openMail:SetFrameStrata(saved.strata)
            end
            saved = nil
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
-- Forever layouts "plain" and "window": mode is a function that gives the key; createToggle(mailFrame) (the button
-- on MailFrame that switches to the window), createWindow() (a MailboxWindow); in "window" create(parent) makes the
-- view in the rules page, and createInbox(mailFrame, parent) makes the inbox list in the inbox page. createSend(parent)
-- (optional) makes the Send page in the send page (a SendPage); host.send is that page.
-- Returns an object with View(), the view or nil, Inbox(), the inbox list or nil, IsBusy(), Switch() and Fallback().
function MailHost.Attach(deps)
    local host = { view = nil, inbox = nil }
    -- deps.mode can be a function: it gives the key again at each MAIL_SHOW and at each host.Switch().
    local layouts, layout = {}, nil
    -- forcePlain: the plain layout for this visit, whatever the mode says (host.Fallback).
    local forcePlain = false
    local function pickLayout()
        local key = forcePlain and "plain" or type(deps.mode) == "function" and deps.mode() or deps.mode or "wide"
        layouts[key] = layouts[key] or MailHost.LAYOUTS[key](deps, host)
        layout = layouts[key]
    end
    pickLayout()
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
        pickLayout()
        layout.Open(mailFrame)
        open = mailFrame
        if layout.plain then
            return
        end
        if not layout.noTabs then
            watchTabs(deps, host)
        end
        -- A run or a take changes the bags: the view reads the plan when it ends (refreshView).
        if host.view.run:IsRunning() or (deps.take and deps.take.IsActive()) then
            viewDirty = true
        else
            host.view:Refresh()
            viewDirty = false
        end
        if deps.createInbox and not layout.ownInbox then
            host.inbox = host.inbox or deps.createInbox(mailFrame)
        end
        if host.inbox then
            host.inbox:Show()
            -- Show reads the inbox, so an update that came before it needs no second read.
            inboxDirty = false
        end
    end

    local function close()
        if open then
            if host.inbox then
                host.inbox:Hide()
            end
            layout.Close(open)
            open = nil
        end
    end

    deps.bus:Subscribe("MAIL_SHOW", OWNER, function()
        show(true)
    end)
    deps.bus:Subscribe("MAIL_CLOSED", OWNER, function()
        close()
        forcePlain = false
    end)
    -- True if a mailing run, an Open all run or a mail take is active. A switch then would hide the Stop button.
    function host.IsBusy()
        return (host.view and host.view.run:IsRunning()) or (deps.take and deps.take.IsActive())
            or (host.inbox and host.inbox.IsOpenAllRunning and host.inbox:IsOpenAllRunning()) or false
    end
    -- Apply the layout that deps.mode gives now, while the mailbox is open. Nothing happens if it is closed.
    -- Returns false and does nothing while a run or a take is active.
    function host.Switch()
        if host.IsBusy() then
            return false
        end
        forcePlain = false
        if open then
            close()
            show(false)
        end
        return true
    end
    -- The window closed but MailFrame did not hide (the client refused in combat): show the plain MailFrame for
    -- this visit. The saved setting does not change.
    function host.Fallback()
        if open then
            forcePlain = true
            close()
            show(false)
        end
    end
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
