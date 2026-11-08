local _, ns = ...

-- The Flipside mailbox window (Forever, SPEC 5.5). It covers the client MailFrame and has three pages: Inbox, Send
-- and Mailing rules. It knows no place rule except "cover MailFrame": MailHost (layout "window") opens and closes it.
-- MailFrame stays shown under the window, because hiding it would end the mail session (MailMixin:OnHide calls
-- CloseMail). While the window shows, MailFrame is invisible (alpha 0) and takes no mouse. It is not a protected
-- frame, so this works in combat too.
local MailboxWindow = {}
MailboxWindow.__index = MailboxWindow
ns.MailboxWindow = MailboxWindow

local NAME = "FlipsideMailboxWindow"
-- The size in pixels if MailFrame has no size yet. The window has the height of MailFrame and its width plus
-- MailHost.EXTRA_WIDTH, so it covers MailFrame and reaches to the right as the old wide layout did.
local MIN_WIDTH, MIN_HEIGHT = 420, 520
local PAD = 8
-- The space from the top edge to the tabs, and the bottom row that holds the toggle button.
local BODY_TOP = 28
local BAR_HEIGHT = 28
local TOGGLE_WIDTH = 120
-- The toggle button on MailFrame: right of the tabs under the frame. The level is above the highest client child
-- level (the title and the close button have 510).
local MAILFRAME_TOGGLE = { width = 110, height = 22, tabGap = 10, level = 520 }
-- The client tabs that stick out under MailFrame. They hide with MailFrame and take no mouse while the window shows.
local CONCEALED_TABS = { "MailFrameTab1", "MailFrameTab2" }

-- Setting mail.window (account scope, default on): true or no value shows the Flipside window, false shows the
-- Blizzard mailbox. The last choice stays. db is the settings DB (Get and Set).
MailboxWindow.KEY = "mail.window"

function MailboxWindow.IsOn(db)
    return db:Get("account", MailboxWindow.KEY) ~= false
end

-- Returns false if the DB cannot write now.
function MailboxWindow.SetOn(db, on)
    return db:Set("account", MailboxWindow.KEY, on and true or false)
end

local PAGES = {
    { key = "inbox", title = "Inbox" },
    { key = "send", title = "Send" },
    { key = "rules", title = "Mailing rules" },
}

-- Set the setting and switch the open mailbox (host is the MailHost object). A run or a take that is active
-- refuses the switch: it would hide the Stop button. say(text) prints a short line. Returns true if it switched.
function MailboxWindow.Apply(db, host, on, say)
    if host.IsBusy() then
        say("Wait for the mailing run or Open all to end, then switch the mailbox")
        return false
    end
    if not MailboxWindow.SetOn(db, on) then
        return false
    end
    host.Switch()
    return true
end

-- Make the button on MailFrame that switches to the Flipside window. onClick runs on a click.
-- The button sits right of the client tabs under the frame (Inbox, Send Mail). They are children of MailFrame, so
-- the button shows on both tabs. The title bar is not safe: the NineSlice border (level 500), the title and the
-- close button (level 510) of ButtonFrameTemplate sit above a normal child there.
function MailboxWindow.CreateToggle(mailFrame, onClick)
    local spec = MAILFRAME_TOGGLE
    local button = ns.Kit.Button(mailFrame, "Flipside mailbox", spec.width, onClick)
    button:SetHeight(spec.height)
    local tab = _G.MailFrameTab2 or _G.MailFrameTab1
    if tab then
        button:SetPoint("LEFT", tab, "RIGHT", spec.tabGap, 0)
    else
        button:SetPoint("TOPRIGHT", mailFrame, "BOTTOMRIGHT", -spec.tabGap, 2)
    end
    button:SetFrameStrata(mailFrame:GetFrameStrata())
    button:SetFrameLevel(mailFrame:GetFrameLevel() + spec.level)
    return button
end

-- deps: onToggle() (the click on "Blizzard mailbox"), closeMail() (the user closed the window: end the mail
-- session), onTab(key) (optional; the user chose the page with this key: inbox, send or rules).
-- Returns an object with frame, pages (inbox, send and rules: the content frames of the tabs), Open(mailFrame)
-- and Hide().
function MailboxWindow.Create(deps)
    local Kit = ns.Kit
    local self = setmetatable({ deps = deps, closing = false }, MailboxWindow)
    local frame = Kit.CreateWindow(NAME, {
        width = MIN_WIDTH,
        height = MIN_HEIGHT,
        title = "Flipside mailbox",
        square = true,
        strata = "HIGH",
    })
    -- The window follows MailFrame: the user cannot drag it away.
    frame:SetMovable(false)
    -- Kit.CreateWindow made the title drag call StartMoving: take it off for this window only.
    local handle = frame.TitleContainer or frame
    handle:RegisterForDrag()
    handle:SetScript("OnDragStart", nil)
    handle:SetScript("OnDragStop", nil)
    self.frame = frame
    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -BODY_TOP)
    body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, PAD + BAR_HEIGHT)
    self.tabs = Kit.CreateTopTabs(body, PAGES, {
        onSelect = function(key)
            if deps.onTab then
                deps.onTab(key)
            end
        end,
    })
    self.pages = {}
    for _, page in ipairs(PAGES) do
        self.pages[page.key] = self.tabs:GetContent(page.key)
    end
    local note = Kit.Label(self.pages.send, "Sending mail in this window comes next. Use the Blizzard mailbox to send.",
        "normal")
    note:SetPoint("CENTER", self.pages.send, "CENTER", 0, 0)
    -- The host hides the note when it puts the Send page in (SendPage).
    self.sendNote = note
    self.toggle = Kit.Button(frame, "Blizzard mailbox", TOGGLE_WIDTH, function()
        deps.onToggle()
    end)
    self.toggle:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD)
    -- The X button and ESC hide the window: that ends the mail session. A hide by the host does not.
    frame:HookScript("OnHide", function()
        -- Also after the X button or ESC: MailFrame shows again at once, if the client keeps it.
        self:_Reveal()
        if not self.closing and deps.closeMail then
            deps.closeMail()
        end
    end)
    return self
end

-- Make MailFrame and the tabs under it invisible and deaf to the mouse. Each frame keeps its old alpha and mouse state.
function MailboxWindow:_Conceal(mailFrame)
    if self.concealed then
        return
    end
    local saved = {}
    local targets = { mailFrame }
    for _, name in ipairs(CONCEALED_TABS) do
        targets[#targets + 1] = _G[name]
    end
    for _, target in ipairs(targets) do
        saved[#saved + 1] = { frame = target, alpha = target:GetAlpha(), mouse = target:IsMouseEnabled() }
    end
    self.concealed = saved
    for _, entry in ipairs(saved) do
        entry.frame:SetAlpha(0)
        entry.frame:EnableMouse(false)
    end
end

-- Give MailFrame and the tabs back their alpha and mouse state. Nothing happens if they are not concealed.
function MailboxWindow:_Reveal()
    local saved = self.concealed
    if not saved then
        return
    end
    self.concealed = nil
    for _, entry in ipairs(saved) do
        entry.frame:SetAlpha(entry.alpha)
        entry.frame:EnableMouse(entry.mouse)
    end
end

-- Cover MailFrame and show the window.
function MailboxWindow:Open(mailFrame)
    local frame = self.frame
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", mailFrame, "TOPLEFT", 0, 0)
    local width, height = mailFrame:GetWidth() or 0, mailFrame:GetHeight() or 0
    frame:SetSize(width > 0 and width + ns.MailHost.EXTRA_WIDTH or MIN_WIDTH, height > 0 and height or MIN_HEIGHT)
    if not self.hooked then
        self.hooked = true
        -- The client hides MailFrame on ESC and on a walk away: the window goes with it.
        mailFrame:HookScript("OnHide", function()
            self:Hide()
        end)
    end
    frame:Show()
    self:_Conceal(mailFrame)
end

-- Hide the window and keep the mail session. MailFrame shows again.
function MailboxWindow:Hide()
    self.closing = true
    self.frame:Hide()
    self.closing = false
    self:_Reveal()
end
