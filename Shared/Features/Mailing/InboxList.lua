local _, ns = ...

-- The compact inbox list (SPEC 5.5). One row for each mail, in a scroll list, instead of the seven fixed
-- buttons of the client inbox. While it shows, the client buttons and page buttons are hidden. A click opens the
-- mail with the client function (deps.api.open). The list takes all client calls as deps and knows no place:
-- deps.place(frame) anchors it.
local InboxList = {}
ns.InboxList = InboxList

local Kit = ns.Kit
-- The row pitch: the content height plus the gap between two rows. 21 px still fits 14 rows above Open All.
local ROW_HEIGHT = 21
-- The empty space at the bottom of each row. The separator line sits in it.
local ROW_GAP = 2
-- The square slot (border) of the icon, and the icon inside it with its padding.
local SLOT_SIZE = 18
local ICON_SIZE = 14
local SLOT_X = 2
local ICON_TEXCOORD = { 0.07, 0.93, 0.07, 0.93 }
local SENDER_X = 24
local SENDER_WIDTH = 64
local SUBJECT_X = 90
-- The text sits in the content area, above the gap.
local TEXT_Y = ROW_GAP / 2
local EXTRA_WIDTH = 74
local DAYS_WIDTH = 30
local TEXT_GAP = 4
-- The gap between the bottom of the list and the Open All button of the client.
local OPEN_ALL_GAP = 4
-- The list frame is above the client buttons (children of the Inbox frame) so that they never show through.
local COVER_LEVEL = 10
local COVER_COLOR = { 0.04, 0.03, 0.02, 0.92 }
local GREY = { 0.75, 0.75, 0.75 }
local GOLD = { 1, 0.82, 0 }
local WHITE = { 1, 1, 1 }
-- The look of a row with no mail: a client empty item slot and a dim bar.
local EMPTY_SLOT_TEXTURE = "Interface\\Buttons\\UI-Slot-Background"
local EMPTY_BAR_COLOR = { 0, 0, 0, 0.25 }
-- The client item frame border (the quality border of item buttons), tinted dark, and the row separator line.
local BORDER_TEXTURE = "Interface\\Common\\WhiteIconFrame"
local BORDER_COLOR = { 0.45, 0.4, 0.32 }
local SEPARATOR_COLOR = { 0.55, 0.45, 0.3, 0.45 }
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

-- The time left as short coloured text: whole days, or hours when under one day.
function InboxList.DaysText(days)
    if days >= 1 then
        return string.format("|cff40ff40%dd|r", math.floor(days))
    end
    return string.format("|cffff4040%dh|r", math.max(1, math.floor(days * 24)))
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
        parts[#parts + 1] = "|cffff4040COD " .. formatMoney(mail.cod) .. "|r"
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
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON_SIZE, ICON_SIZE)
    row.icon:SetPoint("LEFT", row, "LEFT", SLOT_X + (SLOT_SIZE - ICON_SIZE) / 2, TEXT_Y)
    row.icon:SetTexCoord(ICON_TEXCOORD[1], ICON_TEXCOORD[2], ICON_TEXCOORD[3], ICON_TEXCOORD[4])
    row.border = row:CreateTexture(nil, "OVERLAY")
    row.border:SetSize(SLOT_SIZE, SLOT_SIZE)
    row.border:SetPoint("LEFT", row, "LEFT", SLOT_X, TEXT_Y)
    row.border:SetTexture(BORDER_TEXTURE)
    row.border:SetVertexColor(BORDER_COLOR[1], BORDER_COLOR[2], BORDER_COLOR[3])
    row.separator = row:CreateTexture(nil, "BORDER")
    row.separator:SetHeight(1)
    row.separator:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row.separator:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    row.separator:SetColorTexture(SEPARATOR_COLOR[1], SEPARATOR_COLOR[2], SEPARATOR_COLOR[3], SEPARATOR_COLOR[4])
    row.selection = Kit.SelectionTexture(row, view.deps.skin)
    row.days = Kit.Label(row, "", "small")
    row.days:SetPoint("RIGHT", row, "RIGHT", -2, TEXT_Y)
    row.days:SetWidth(DAYS_WIDTH)
    row.days:SetJustifyH("RIGHT")
    row.extra = Kit.Label(row, "", "small")
    row.extra:SetPoint("RIGHT", row.days, "LEFT", -TEXT_GAP, 0)
    row.extra:SetWidth(EXTRA_WIDTH)
    row.extra:SetJustifyH("RIGHT")
    row.sender = Kit.Label(row, "", "small")
    row.sender:SetPoint("LEFT", row, "LEFT", SENDER_X, TEXT_Y)
    row.sender:SetWidth(SENDER_WIDTH)
    row.sender:SetJustifyH("LEFT")
    row.subject = Kit.Label(row, "", "small")
    row.subject:SetPoint("LEFT", row, "LEFT", SUBJECT_X, TEXT_Y)
    row.subject:SetPoint("RIGHT", row.extra, "LEFT", -TEXT_GAP, 0)
    row.subject:SetJustifyH("LEFT")
    for _, label in ipairs({ row.days, row.extra, row.sender, row.subject }) do
        setNoWrap(label)
    end
    row.slot = row:CreateTexture(nil, "ARTWORK")
    row.slot:SetSize(SLOT_SIZE - 2, SLOT_SIZE - 2)
    row.slot:SetPoint("LEFT", row, "LEFT", SLOT_X + 1, TEXT_Y)
    row.slot:SetTexture(EMPTY_SLOT_TEXTURE)
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
            showTooltip(self, self.mail, view.deps.formatMoney)
        end
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

-- Shows a row with no mail: only the empty slot and the dim bar. The row takes no mouse input.
local function initEmptyRow(row)
    row.mail = nil
    row.slot:Show()
    row.bar:Show()
    row.icon:Hide()
    row.selection:Hide()
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
    row.icon:Show()
    row.mail = mail
    row.icon:SetTexture(mail.icon)
    if row.icon.SetDesaturated then
        row.icon:SetDesaturated(mail.read)
    end
    row.selection:SetShown(view.openID == mail.index)
    local senderColor, subjectColor = GOLD, WHITE
    if mail.read then
        senderColor, subjectColor = GREY, GREY
    end
    row.sender:SetText(mail.sender)
    row.sender:SetTextColor(senderColor[1], senderColor[2], senderColor[3])
    row.subject:SetText(mail.subject)
    row.subject:SetTextColor(subjectColor[1], subjectColor[2], subjectColor[3])
    row.extra:SetText(InboxList.ExtraText(mail, view.deps.formatMoney))
    row.days:SetText(InboxList.DaysText(mail.days))
end

-- deps: api = { numItems() (GetInboxNumItems), header(index) (GetInboxHeaderInfo), open(index), openID()
-- (the index of the open mail or 0), isModified() (optional, the Shift-click test), autoLoot(index) (optional,
-- AutoLootMailItem), freeSlots() (optional, the free bag slots) }, notify(text) (optional, a short status),
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
-- Shift-click. Never pays a COD mail. Does not take items when the bags have no free slot.
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
