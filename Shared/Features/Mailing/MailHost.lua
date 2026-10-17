local _, ns = ...

-- The host of the mailing view. On MAIL_SHOW it places the view with a layout, on MAIL_CLOSED it takes the layout
-- away. Both clients have a MailFrame global, so one host serves both flavours.
-- A layout decides the place of the view. Today the only layout is "wide": MailFrame gets wider and the view sits in
-- the new strip. A "tab" layout needs only a new entry in MailHost.LAYOUTS (SPEC 5.5, "Switch to a tab").
local MailHost = {}
ns.MailHost = MailHost

local OWNER = "Flipside.MailHost"
-- The extra width of the wide layout, and the gaps of the view in the new strip, in pixels.
local EXTRA_WIDTH = 330
local VIEW_GAP = { top = 64, right = 8, bottom = 8 }
local VIEW_LEVEL = 5
local OPEN_MAIL_X = 46

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

-- deps: bus, create(parent, size) (returns a MailingView), after(seconds, fn), frame() (returns the MailFrame or
-- nil), openMail() (the open-mail frame or nil), children() (the frames inside MailFrame that must keep their
-- width: InboxFrame, SendMailFrame), mode (a key of MailHost.LAYOUTS, default "wide").
-- Returns an object with View(), the view or nil.
function MailHost.Attach(deps)
    local host = { view = nil }
    local layout = MailHost.LAYOUTS[deps.mode or "wide"](deps, host)
    local open

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
        host.view:Refresh()
    end

    deps.bus:Subscribe("MAIL_SHOW", OWNER, function()
        show(true)
    end)
    deps.bus:Subscribe("MAIL_CLOSED", OWNER, function()
        if open then
            layout.Close(open)
            open = nil
        end
    end)
    -- The bags changed: read the plan again, but not while a run changes the bags.
    deps.bus:Subscribe("BAG_UPDATE_DELAYED", OWNER, function()
        local view = host.view
        if open and view and view.frame:IsShown() and not view.run:IsRunning() then
            view:Refresh()
        end
    end)

    function host.View()
        return host.view
    end
    return host
end
