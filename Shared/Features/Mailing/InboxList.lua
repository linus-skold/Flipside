local _, ns = ...

-- The compact inbox list (SPEC 5.5). One row for each mail, in a scroll list, instead of the seven fixed
-- buttons of the client inbox. While it shows, the client buttons and page buttons are hidden. A click opens the
-- mail with the client function (deps.api.open). The list takes all client calls as deps and knows no place:
-- deps.place(frame) anchors it.
local InboxList = {}
ns.InboxList = InboxList

local Kit = ns.Kit
-- The row height of the Ledger list (LedgerPage).
local ROW_HEIGHT = 18
local ICON_SIZE = 16
local SENDER_X = 22
local SENDER_WIDTH = 66
local SUBJECT_X = 92
local EXTRA_WIDTH = 74
local DAYS_WIDTH = 30
local TEXT_GAP = 4
local GREY = { 0.75, 0.75, 0.75 }
local GOLD = { 1, 0.82, 0 }
local WHITE = { 1, 1, 1 }

local function log(level, text)
    if ns.Log and ns.Log.Write then
        ns.Log.Write("mail", level, text)
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
    row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.selection = Kit.SelectionTexture(row, view.deps.skin)
    row.days = Kit.Label(row, "", "small")
    row.days:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row.days:SetWidth(DAYS_WIDTH)
    row.days:SetJustifyH("RIGHT")
    row.extra = Kit.Label(row, "", "small")
    row.extra:SetPoint("RIGHT", row.days, "LEFT", -TEXT_GAP, 0)
    row.extra:SetWidth(EXTRA_WIDTH)
    row.extra:SetJustifyH("RIGHT")
    row.sender = Kit.Label(row, "", "small")
    row.sender:SetPoint("LEFT", row, "LEFT", SENDER_X, 0)
    row.sender:SetWidth(SENDER_WIDTH)
    row.sender:SetJustifyH("LEFT")
    row.subject = Kit.Label(row, "", "small")
    row.subject:SetPoint("LEFT", row, "LEFT", SUBJECT_X, 0)
    row.subject:SetPoint("RIGHT", row.extra, "LEFT", -TEXT_GAP, 0)
    row.subject:SetJustifyH("LEFT")
    for _, label in ipairs({ row.days, row.extra, row.sender, row.subject }) do
        setNoWrap(label)
    end
    row:SetScript("OnClick", function(self)
        view:Open(self.mail.index)
    end)
    row:SetScript("OnEnter", function(self)
        showTooltip(self, self.mail, view.deps.formatMoney)
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

local function initRow(view, row, mail)
    if not row.icon then
        buildRow(view, row)
    end
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
-- (the index of the open mail or 0) }, formatMoney(copper), blizzard() (the client frames to hide while the list
-- shows), openMail() (the open-mail frame or nil), place(frame) (anchors the list), skin (optional).
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
    self.list:SetData(mails)
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
