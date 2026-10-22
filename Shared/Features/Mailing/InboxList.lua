local _, ns = ...

-- The compact inbox list (SPEC 5.5). One row for each mail, in a scroll list, instead of the seven fixed
-- buttons of the client inbox. While it shows, the client buttons and page buttons are hidden. A click opens the
-- mail with the client function (deps.api.open). The list takes all client calls as deps and knows no place:
-- deps.place(frame) anchors it.
local InboxList = {}
ns.InboxList = InboxList

local Kit = ns.Kit
-- The row pitch: the content height plus the gap between two rows. 22 px still fits 14 rows above Open All.
local ROW_HEIGHT = 22
-- The empty space at the bottom of each row. The separator line sits in it.
local ROW_GAP = 2
-- The square brown slot of the icon (it fills the content height), and the icon inside it.
local SLOT_SIZE = 20
local ICON_SIZE = 18
-- The same space left of the slot and between the slot and the sender.
local SLOT_X = 3
local ICON_TEXCOORD = { 0.07, 0.93, 0.07, 0.93 }
local SENDER_X = SLOT_X + SLOT_SIZE + 3
-- The sender takes its text width up to this width. A longer sender is cut at the end.
local SENDER_MAX_WIDTH = 130
-- The subject always keeps at least this width, so the sender is cut first in a narrow frame.
local SUBJECT_MIN_WIDTH = 40
-- The text sits in the content area, above the gap.
local TEXT_Y = ROW_GAP / 2
local EXTRA_WIDTH = 60
local DAYS_WIDTH = 40
local TEXT_GAP = 4
local DAYS_RIGHT = 2
-- The gap between the bottom of the list and the Open All button of the client.
local OPEN_ALL_GAP = 4
-- The list frame is above the client buttons (children of the Inbox frame) so that they never show through.
local COVER_LEVEL = 10
-- The dark brown row background: solid, so that the art of the client inbox never shows through.
local COVER_COLOR = { 0.12, 0.08, 0.04, 1 }
-- Fonts as in the client mail item (MailItemTemplate), in the small size for the one-line row.
local SENDER_FONT = "GameFontNormalSmall"
local TEXT_FONT = "GameFontHighlightSmall"
-- Colours as InboxFrame_Update sets them. The globals are read when used; these are the values if one is missing.
local NORMAL_FALLBACK = { r = 1, g = 0.82, b = 0 }
local HIGHLIGHT_FALLBACK = { r = 1, g = 1, b = 1 }
-- A read mail: the client sets this grey itself, with no global.
local READ_COLOR = { 0.75, 0.75, 0.75 }
local GREEN_CODE_FALLBACK = "|cff20ff20"
local RED_CODE_FALLBACK = "|cffff2020"
-- The selection and the hover are a gold glow (additive blend, it shows on a dark background).
local SELECT_COLOR = { 1, 0.82, 0 }
local SELECT_ALPHA = 0.2
local HOVER_ALPHA = 0.12
-- The brown client item slot background (as the Send Mail attachment slot), behind each icon and in empty rows.
-- Its art fills the top left 0.640625 of the file.
local SLOT_TEXTURE = "Interface\\Buttons\\UI-Slot-Background"
local SLOT_TEXCOORD = { 0, 0.640625, 0, 0.640625 }
-- The dim bar of a row with no mail.
local EMPTY_BAR_COLOR = { 1, 1, 1, 0.04 }
-- The row separator line: a lighter brown, so that it shows on the dark background.
local SEPARATOR_COLOR = { 0.45, 0.3, 0.15, 0.7 }
local EMPTY_ROW = { empty = true }

local function log(level, text)
    if ns.Log and ns.Log.Write then
        ns.Log.Write("mail", level, text)
    end
end

-- Returns the number of rows that fit in a list of the given height, in pixels.
function InboxList.VisibleRows(height)
    return math.max(0, math.floor(height / ROW_HEIGHT))
end

-- Anchors the list on the area of the client mail buttons. first is MailItem1, inbox is the Inbox frame, openAll is
-- the client Open All button (optional). The area keeps the left edge, the top edge and the width of MailItem1. It
-- reaches down to the Open All button, so it fits more rows than the seven client buttons. Without Open All it ends
-- at the last client button, lastItem (optional).
function InboxList.Anchor(frame, inbox, first, openAll, lastItem)
    local _, _, _, left = first:GetPoint(1)
    local right = (left or 0) + first:GetWidth() - inbox:GetWidth()
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", first, "TOPLEFT", 0, 0)
    local bottom
    if openAll then
        -- A call inside "and" gives one value only, so the call has its own statement.
        local _, _, relativePoint, _, openY = openAll:GetPoint(1)
        if relativePoint == "BOTTOM" then
            bottom = (openY or 0) + openAll:GetHeight() / 2 + OPEN_ALL_GAP
        end
    end
    if bottom then
        frame:SetPoint("BOTTOMRIGHT", inbox, "BOTTOMRIGHT", right, bottom)
    else
        frame:SetPoint("BOTTOMRIGHT", lastItem or first, "BOTTOMRIGHT", 0, 0)
    end
end

local function greenCode()
    return _G.GREEN_FONT_COLOR_CODE or GREEN_CODE_FALLBACK
end

local function redCode()
    return _G.RED_FONT_COLOR_CODE or RED_CODE_FALLBACK
end

local function closeCode()
    return _G.FONT_COLOR_CODE_CLOSE or "|r"
end

-- Returns r, g, b of a client colour global, or of the fallback.
local function colorOf(name, fallback)
    local color = _G[name] or fallback
    return color.r, color.g, color.b
end

-- The sender width for a sender text of the given width in a row of the given width: the text width, up to the
-- maximum, and never so wide that the subject falls under its minimum width.
function InboxList.SenderWidth(textWidth, rowWidth)
    local room = SENDER_MAX_WIDTH
    if rowWidth > 0 then
        room = rowWidth - SENDER_X - 3 * TEXT_GAP - EXTRA_WIDTH - DAYS_WIDTH - DAYS_RIGHT - SUBJECT_MIN_WIDTH
    end
    return math.max(0, math.min(math.ceil(textWidth) + 1, SENDER_MAX_WIDTH, room))
end

-- The time left as short coloured text, as the client does: green whole days ("29 Days"), red hours when under
-- one day. The format strings and the colour codes are the client globals.
function InboxList.DaysText(days)
    if days >= 1 then
        return string.format(greenCode() .. (_G.DAYS_ABBR or "%d Days") .. closeCode(), math.floor(days))
    end
    return string.format(redCode() .. (_G.HOURS_ABBR or "%d Hr") .. closeCode(), math.max(1, math.floor(days * 24)))
end

-- Reads one mail. api.header(index) is GetInboxHeaderInfo; the first nine results have the same meaning on both
-- clients: package icon, stationery icon, sender, subject, money, COD, days left, item count, was read.
function InboxList.ReadMail(api, index)
    local packageIcon, stationeryIcon, sender, subject, money, cod, days, itemCount, wasRead, _, _, _, isGM =
        api.header(index)
    return {
        index = index,
        icon = (packageIcon and not isGM) and packageIcon or stationeryIcon,
        sender = sender or _G.UNKNOWN or "Unknown",
        subject = subject or "",
        money = money or 0,
        cod = cod or 0,
        days = days or 0,
        items = itemCount or 0,
        read = wasRead and true or false,
    }
end

-- The attachment text of a row: the item count, the money or the COD amount.
function InboxList.ExtraText(mail, formatMoney)
    local parts = {}
    if mail.items > 0 then
        parts[#parts + 1] = "x" .. mail.items
    end
    if mail.cod > 0 then
        parts[#parts + 1] = redCode() .. "COD " .. formatMoney(mail.cod) .. closeCode()
    elseif mail.money > 0 then
        parts[#parts + 1] = formatMoney(mail.money)
    end
    return table.concat(parts, " ")
end

local function setNoWrap(label)
    if label.SetWordWrap then
        label:SetWordWrap(false)
    end
end

local function showTooltip(row, mail, formatMoney)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText(mail.subject ~= "" and mail.subject or "(no subject)")
    GameTooltip:AddLine("From: " .. mail.sender, 1, 1, 1)
    if mail.items > 0 then
        GameTooltip:AddLine("Attachments: " .. mail.items, 1, 1, 1)
    end
    if mail.money > 0 then
        GameTooltip:AddLine("Money: " .. formatMoney(mail.money), 1, 1, 1)
    end
    if mail.cod > 0 then
        GameTooltip:AddLine("COD: " .. formatMoney(mail.cod), 1, 0.25, 0.25)
    end
    GameTooltip:Show()
end

-- Builds the fields of a row once.
local function buildRow(view, row)
    row.border = row:CreateTexture(nil, "ARTWORK", nil, -1)
    row.border:SetSize(SLOT_SIZE, SLOT_SIZE)
    row.border:SetPoint("LEFT", row, "LEFT", SLOT_X, TEXT_Y)
    row.border:SetTexture(SLOT_TEXTURE)
    row.border:SetTexCoord(SLOT_TEXCOORD[1], SLOT_TEXCOORD[2], SLOT_TEXCOORD[3], SLOT_TEXCOORD[4])
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON_SIZE, ICON_SIZE)
    row.icon:SetPoint("LEFT", row, "LEFT", SLOT_X + (SLOT_SIZE - ICON_SIZE) / 2, TEXT_Y)
    row.icon:SetTexCoord(ICON_TEXCOORD[1], ICON_TEXCOORD[2], ICON_TEXCOORD[3], ICON_TEXCOORD[4])
    row.separator = row:CreateTexture(nil, "BORDER")
    row.separator:SetHeight(1)
    row.separator:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row.separator:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    row.separator:SetColorTexture(SEPARATOR_COLOR[1], SEPARATOR_COLOR[2], SEPARATOR_COLOR[3], SEPARATOR_COLOR[4])
    row.selection = Kit.SelectionTexture(row, view.deps.skin)
    row.selection:SetBlendMode("ADD")
    row.selection:SetVertexColor(SELECT_COLOR[1], SELECT_COLOR[2], SELECT_COLOR[3])
    row.selection:SetAlpha(SELECT_ALPHA)
    row.hover = row:CreateTexture(nil, "BACKGROUND")
    row.hover:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.hover:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, ROW_GAP)
    row.hover:SetColorTexture(SELECT_COLOR[1], SELECT_COLOR[2], SELECT_COLOR[3], HOVER_ALPHA)
    if row.hover.SetBlendMode then
        row.hover:SetBlendMode("ADD")
    end
    row.hover:Hide()
    row.days = row:CreateFontString(nil, "ARTWORK", TEXT_FONT)
    row.days:SetPoint("RIGHT", row, "RIGHT", -DAYS_RIGHT, TEXT_Y)
    row.days:SetWidth(DAYS_WIDTH)
    row.days:SetJustifyH("RIGHT")
    row.extra = row:CreateFontString(nil, "ARTWORK", TEXT_FONT)
    row.extra:SetPoint("RIGHT", row.days, "LEFT", -TEXT_GAP, 0)
    row.extra:SetWidth(EXTRA_WIDTH)
    row.extra:SetJustifyH("RIGHT")
    row.sender = row:CreateFontString(nil, "ARTWORK", SENDER_FONT)
    row.sender:SetPoint("LEFT", row, "LEFT", SENDER_X, TEXT_Y)
    row.sender:SetWidth(SENDER_MAX_WIDTH)
    row.sender:SetJustifyH("LEFT")
    -- The subject starts after the sender and fills the space up to the money. The client cuts it with "...".
    row.subject = row:CreateFontString(nil, "ARTWORK", TEXT_FONT)
    row.subject:SetPoint("LEFT", row.sender, "RIGHT", TEXT_GAP, 0)
    row.subject:SetPoint("RIGHT", row.extra, "LEFT", -TEXT_GAP, 0)
    row.subject:SetJustifyH("LEFT")
    for _, label in ipairs({ row.days, row.extra, row.sender, row.subject }) do
        setNoWrap(label)
    end
    row.slot = row:CreateTexture(nil, "ARTWORK")
    row.slot:SetSize(SLOT_SIZE, SLOT_SIZE)
    row.slot:SetPoint("LEFT", row, "LEFT", SLOT_X, TEXT_Y)
    row.slot:SetTexture(SLOT_TEXTURE)
    row.slot:SetTexCoord(SLOT_TEXCOORD[1], SLOT_TEXCOORD[2], SLOT_TEXCOORD[3], SLOT_TEXCOORD[4])
    row.bar = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    row.bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.bar:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, ROW_GAP)
    row.bar:SetColorTexture(EMPTY_BAR_COLOR[1], EMPTY_BAR_COLOR[2], EMPTY_BAR_COLOR[3], EMPTY_BAR_COLOR[4])
    row:SetScript("OnClick", function(self)
        if self.mail then
            view:Click(self.mail.index)
        end
    end)
    row:SetScript("OnEnter", function(self)
        if self.mail then
            self.hover:Show()
            showTooltip(self, self.mail, view.deps.formatMoney)
        end
    end)
    row:SetScript("OnLeave", function(self)
        self.hover:Hide()
        GameTooltip:Hide()
    end)
end

-- Shows a row with no mail: only the empty slot and the dim bar. The row takes no mouse input.
local function initEmptyRow(row)
    row.mail = nil
    row.slot:Show()
    row.bar:Show()
    row.icon:Hide()
    row.border:Hide()
    row.selection:Hide()
    row.hover:Hide()
    for _, label in ipairs({ row.days, row.extra, row.sender, row.subject }) do
        label:SetText("")
    end
    row:EnableMouse(false)
end

local function initRow(view, row, mail)
    if not row.icon then
        buildRow(view, row)
    end
    if mail.empty then
        initEmptyRow(row)
        return
    end
    row:EnableMouse(true)
    row.slot:Hide()
    row.bar:Hide()
    row.border:Show()
    row.icon:Show()
    row.mail = mail
    row.icon:SetTexture(mail.icon)
    if row.icon.SetDesaturated then
        row.icon:SetDesaturated(mail.read)
    end
    row.selection:SetShown(view.openID == mail.index)
    local sr, sg, sb = colorOf("NORMAL_FONT_COLOR", NORMAL_FALLBACK)
    local jr, jg, jb = colorOf("HIGHLIGHT_FONT_COLOR", HIGHLIGHT_FALLBACK)
    if mail.read then
        sr, sg, sb = READ_COLOR[1], READ_COLOR[2], READ_COLOR[3]
        jr, jg, jb = sr, sg, sb
    end
    -- Measure the sender at the maximum width, then fit the width to the text (the client cuts a long one).
    row.sender:SetWidth(SENDER_MAX_WIDTH)
    row.sender:SetText(mail.sender)
    local measure = row.sender.GetUnboundedStringWidth or row.sender.GetStringWidth
    local rowWidth = row:GetWidth()
    if not rowWidth or rowWidth <= 0 then
        rowWidth = view.frame:GetWidth() or 0
    end
    row.sender:SetWidth(InboxList.SenderWidth(measure(row.sender), rowWidth))
    row.sender:SetTextColor(sr, sg, sb)
    row.subject:SetText(mail.subject)
    row.subject:SetTextColor(jr, jg, jb)
    row.extra:SetText(InboxList.ExtraText(mail, view.deps.formatMoney))
    row.days:SetText(InboxList.DaysText(mail.days))
end

-- deps: api = { numItems() (GetInboxNumItems), header(index) (GetInboxHeaderInfo), open(index), openID()
-- (the index of the open mail or 0), isModified() (optional, the Shift-click test), autoLoot(index) (optional,
-- AutoLootMailItem), freeSlots() (optional, the free bag slots) }, notify(text) (optional, a short status),
-- onTake() (optional, called when a take starts),
-- formatMoney(copper), blizzard() (the client frames to hide while the list shows),
-- openMail() (the open-mail frame or nil),
-- place(frame) (anchors the list), skin (optional).
function InboxList.Create(parent, deps)
    local view = { deps = deps, mails = {}, openID = 0, hidden = nil }
    view.list = Kit.CreateList(parent, {
        rowHeight = ROW_HEIGHT,
        inset = true,
        skin = deps.skin,
        retainScroll = true,
        initRow = function(row, mail)
            initRow(view, row, mail)
        end,
    })
    view.frame = view.list.frame
    -- The list fills empty rows to its height: draw again when the height changes.
    view.frame:SetScript("OnSizeChanged", function()
        if view.frame:IsShown() and view.mails then
            view:Refresh()
        end
    end)
    view.frame:SetFrameLevel(parent:GetFrameLevel() + COVER_LEVEL)
    view.cover = view.frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    view.cover:SetAllPoints(view.frame)
    view.cover:SetColorTexture(COVER_COLOR[1], COVER_COLOR[2], COVER_COLOR[3], COVER_COLOR[4])
    if deps.place then
        deps.place(view.frame)
    end
    return setmetatable(view, { __index = InboxList })
end

-- Reads all mails again and shows them. The scroll position stays.
function InboxList:Refresh()
    local api = self.deps.api
    local mails = {}
    for index = 1, api.numItems() or 0 do
        mails[index] = InboxList.ReadMail(api, index)
    end
    self.mails = mails
    self.openID = api.openID() or 0
    local data = mails
    local empty = self:VisibleRowCount() - #mails
    if empty > 0 then
        data = {}
        for index, mail in ipairs(mails) do
            data[index] = mail
        end
        for index = #mails + 1, #mails + empty do
            data[index] = EMPTY_ROW
        end
    end
    self.list:SetData(data)
end

-- The number of rows that fit in the list now. It is 0 while the frame has no size.
function InboxList:VisibleRowCount()
    local pad = Kit.Theme.insetPadding
    return InboxList.VisibleRows((self.frame:GetHeight() or 0) - 2 * (pad or 0))
end

-- Takes all money and attachments of a mail with the client function AutoLootMailItem, as the client does on a
-- Shift-click. Calls deps.onTake() (optional) before the take starts. Never pays a COD mail.
-- Does not take items when the bags have no free slot.
function InboxList:TakeAll(index)
    local api = self.deps.api
    local mail = InboxList.ReadMail(api, index)
    local tell = self.deps.notify or function() end
    if mail.cod > 0 then
        log("info", string.format("take skipped for mail %d from %s: COD %d", index, mail.sender, mail.cod))
        tell("COD mail skipped: Shift-click never pays")
        return false
    end
    if mail.items == 0 and mail.money == 0 then
        log("info", string.format("take skipped for mail %d: nothing to take", index))
        return false
    end
    if mail.items > 0 and api.freeSlots and api.freeSlots() == 0 then
        log("warn", string.format("take stopped for mail %d: bags are full", index))
        tell("Bags are full")
        return false
    end
    log("info", string.format("take all from mail %d from %s: %d items, money %d", index, mail.sender, mail.items,
        mail.money))
    if self.deps.onTake then
        self.deps.onTake()
    end
    api.autoLoot(index)
    return true
end

-- A click on a row. With the client modifier (Shift by default) it takes the contents first, then it opens the mail,
-- as InboxFrame_OnModifiedClick does. A normal click only opens the mail.
function InboxList:Click(index)
    local api = self.deps.api
    if api.isModified and api.autoLoot and api.isModified() then
        self:TakeAll(index)
    end
    self:Open(index)
end

-- Opens the mail with the client function. A second click on the open mail closes it, as the client does.
function InboxList:Open(index)
    self.deps.api.open(index)
    self:Refresh()
end

function InboxList:_HideClientFrames()
    if self.hidden then
        return
    end
    self.hidden = {}
    for _, frame in ipairs(self.deps.blizzard()) do
        self.hidden[#self.hidden + 1] = { frame = frame, shown = frame:IsShown() }
        frame:Hide()
    end
end

function InboxList:_RestoreClientFrames()
    for _, entry in ipairs(self.hidden or {}) do
        if entry.shown then
            entry.frame:Show()
        end
    end
    self.hidden = nil
end

-- Shows the list and hides the client buttons. If the list cannot read the mails, the client buttons stay.
function InboxList:Show()
    local ok, err = pcall(self.Refresh, self)
    if not ok then
        log("error", "compact inbox failed: " .. tostring(err))
        self:Hide()
        return
    end
    self:_HideClientFrames()
    self.frame:Show()
    local openMail = self.deps.openMail and self.deps.openMail()
    if openMail and not self.hooked then
        self.hooked = true
        -- The client clears the open mail when its frame hides: draw the selection again.
        openMail:HookScript("OnHide", function()
            if self.frame:IsShown() then
                self:Refresh()
            end
        end)
    end
end

-- Hides the list and puts the client buttons back.
function InboxList:Hide()
    self.frame:Hide()
    self:_RestoreClientFrames()
end
