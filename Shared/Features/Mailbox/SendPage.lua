local _, ns = ...

-- The Send page of the Flipside mailbox window (Forever, SPEC 5.5, "Send page"). It writes a mail with a recipient,
-- a subject, a text, money or cash on delivery, and up to 12 attachments. The rules are in MailCompose, the client
-- calls are in MailClient.
-- The send slots are one buffer in the client, for the Send Mail tab, this page and the mailing run. The page
-- does not keep its own copy: it reads the slots from the client at each refresh. The text boxes are the page's own.
-- A right click on a bag item puts the item in the first free slot only while the client knows that a send page
-- shows. The page tells it with SetSendMailShowing (client.SetShowing), as the Send Mail tab of the client does.
-- The page installs no hook and replaces no client function.
local SendPage = {}
SendPage.__index = SendPage
ns.SendPage = SendPage

local OWNER = "Flipside.SendPage"
local SLOT_SIZE, SLOT_GAP = 37, 4
local LABEL_WIDTH = 64
local BODY_WIDTH, BODY_HEIGHT = 680, 84
-- The longest subject and text of a mail in the client (SendMailSubjectEditBox, SendMailBodyEditBox).
local SUBJECT_LETTERS, BODY_LETTERS = 64, 500
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"
local SLOT_BACKGROUND = "Interface\\Buttons\\UI-Slot-Background"
local GREY, RED, WHITE = { 0.6, 0.6, 0.6 }, { 1, 0.3, 0.3 }, { 1, 1, 1 }
-- Seconds to wait after MAIL_UNLOCK_SEND_ITEMS before a send that got no result counts as cancelled.
local UNLOCK_WAIT = 10
local CONTACTS = "Contacts"
-- The most height of the contact menu in pixels (a guild list is long: the menu scrolls), and the seconds that the
-- page waits after a friend or guild event before it reads the contacts again.
local MENU_EXTENT, CONTACTS_DELAY = 320, 2
-- Rows (pixels from the top of the page).
local ROW = { to = -2, resolved = -26, subject = -48, body = -74, slotsLabel = -166, slots = -182, money = -228,
    postage = -262 }

local function setColor(label, color)
    label:SetTextColor(color[1], color[2], color[3])
end

-- Show an item in a slot button. The slot is an ItemButton (the client item button); the global helpers of the client
-- set the icon, the count and the quality border. A plain button gets only the icon.
local function paintSlot(button, item)
    local texture = item and (item.texture or QUESTION_MARK) or nil
    if SetItemButtonTexture and button.icon then
        SetItemButtonTexture(button, texture)
        SetItemButtonCount(button, item and item.count or 0)
        SetItemButtonQuality(button, item and item.quality or nil, item and item.itemID or nil)
    elseif texture then
        button:SetNormalTexture(texture)
    else
        button:ClearNormalTexture()
    end
end

-- Make the slot buttons. Each one works as the client slot does: a click or a drop calls ClickSendMailItemButton.
function SendPage:_BuildSlots(frame)
    local label = ns.Kit.Label(frame, "Attachments", "small")
    label:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, ROW.slotsLabel)
    setColor(label, GREY)
    self.slots = {}
    for index = 1, ns.MailCompose.MAX_SLOTS do
        local made, button = pcall(CreateFrame, "ItemButton", nil, frame)
        if not made then
            button = CreateFrame("Button", nil, frame)
        end
        button:SetSize(SLOT_SIZE, SLOT_SIZE)
        button:SetPoint("TOPLEFT", frame, "TOPLEFT", (index - 1) * (SLOT_SIZE + SLOT_GAP), ROW.slots)
        local background = button:CreateTexture(nil, "BACKGROUND")
        background:SetTexture(SLOT_BACKGROUND)
        background:SetTexCoord(0, 0.640625, 0, 0.640625)
        background:SetSize(SLOT_SIZE + 2, SLOT_SIZE + 2)
        background:SetPoint("TOPLEFT", button, "TOPLEFT", -1, 1)
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        button:RegisterForDrag("LeftButton")
        button.index = index
        button:SetScript("OnClick", function(slot, mouseButton)
            self:_ClickSlot(slot.index, mouseButton == "RightButton")
        end)
        button:SetScript("OnDragStart", function(slot)
            self:_ClickSlot(slot.index, false)
        end)
        button:SetScript("OnReceiveDrag", function(slot)
            self:_ClickSlot(slot.index, false)
        end)
        button:SetScript("OnEnter", function(slot)
            GameTooltip:SetOwner(slot, "ANCHOR_RIGHT")
            if self.deps.client.Item(slot.index) then
                GameTooltip:SetSendMailItem(slot.index)
            else
                GameTooltip:SetText("Attachment", 1, 1, 1)
            end
        end)
        button:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        self.slots[index] = button
    end
end

-- deps: client (a MailClient object), bus, after(seconds, fn), characters() (the own character keys), selfName()
-- (the key of this character), mailName(text, keys) (CharacterName.MailName), formatMoney(copper), isRunning()
-- (true while a mailing run uses the send slots), windowShown() (true while the Flipside window shows),
-- clientSendShown() (true while the Send Mail tab of the client shows).
-- Optional deps for the contact list (MailContacts): friends() and guild() (lists of names), request() (asks the
-- client for new friend and guild data), contacts() (the manual list) and saveContacts(list) (returns false if it
-- cannot save), realm() (the home realm, for the match of "Name" and "Name-Realm"). moneyText(copper) gives the
-- money text for the subject default.
-- Returns a page object: frame, Refresh(), Sync(), Clear(), OnTab(key).
function SendPage.Create(parent, deps)
    local Kit, Compose = ns.Kit, ns.MailCompose
    local self = setmetatable({
        deps = deps, mode = Compose.MONEY, previous = "", items = {}, names = {}, typedLength = 0,
    }, SendPage)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    self.frame = frame

    local function rowLabel(text, y)
        local label = Kit.Label(frame, text, "normal")
        label:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, y - 4)
        return label
    end

    rowLabel("To", ROW.to)
    self.recipient = Kit.Input(frame, 220, nil, nil, { placeholder = "Character name" })
    self.recipient:SetPoint("TOPLEFT", frame, "TOPLEFT", LABEL_WIDTH, ROW.to)
    self.recipient:SetScript("OnTextChanged", function(box, userInput)
        self:_RecipientChanged(box, userInput)
    end)
    self.contactList = Kit.Dropdown(frame, 150, {
        items = { { value = "", text = CONTACTS } },
        value = "",
        scrollExtent = MENU_EXTENT,
        onChange = function(value)
            if value ~= "" then
                self:_SetRecipient(value)
            end
            -- Set the list back after the menu closes: a change inside the menu callback builds the menu again.
            deps.after(0, function()
                self.contactList:SetValue("")
            end)
        end,
    })
    self.contactList:SetPoint("LEFT", self.recipient, "RIGHT", 10, 0)
    self.saveContact = Kit.Button(frame, "Save", 56, function()
        self:_SaveContact()
    end)
    self.saveContact:SetPoint("LEFT", self.contactList, "RIGHT", 6, 0)
    self.removeContact = Kit.Button(frame, "Remove", 66, function()
        self:_RemoveContact()
    end)
    self.removeContact:SetPoint("LEFT", self.saveContact, "RIGHT", 4, 0)
    self.resolved = Kit.Label(frame, "", "small")
    self.resolved:SetPoint("TOPLEFT", frame, "TOPLEFT", LABEL_WIDTH + 6, ROW.resolved)

    rowLabel("Subject", ROW.subject)
    self.subject = Kit.Input(frame, 440)
    self.subject:SetMaxLetters(SUBJECT_LETTERS)
    self.subject:SetPoint("TOPLEFT", frame, "TOPLEFT", LABEL_WIDTH, ROW.subject)
    self.subject:SetScript("OnTextChanged", function()
        self:Refresh()
    end)

    self.body = Kit.MultiLineInput(frame, BODY_WIDTH, BODY_HEIGHT)
    self.body:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, ROW.body)
    self.body.EditBox:SetMaxLetters(BODY_LETTERS)

    self:_BuildSlots(frame)

    self.radio = Kit.RadioGroup(frame, {
        items = { { value = Compose.MONEY, text = "Send money" }, { value = Compose.COD, text = "Cash on delivery" } },
        value = Compose.MONEY,
        width = 130,
        onChange = function(value)
            self.mode = value
            self:Refresh()
        end,
    })
    self.radio:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, ROW.money)
    self.money = Kit.MoneyInput(frame, {
        onChange = function()
            self:Refresh()
        end,
    })
    self.money:SetPoint("TOPLEFT", frame, "TOPLEFT", 280, ROW.money + 1)

    self.postage = Kit.Label(frame, "", "small")
    self.postage:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, ROW.postage)

    self.sendButton = Kit.Button(frame, "Send", 90, function()
        self:_Send()
    end)
    self.sendButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    self.status = Kit.Label(frame, "", "small")
    self.status:SetJustifyH("LEFT")
    self.status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 4)
    self.status:SetPoint("RIGHT", self.sendButton, "LEFT", -6, 0)

    -- Tab and Shift-Tab: recipient, subject, text, gold, silver, copper, and round again.
    Kit.TabOrder({ self.recipient, self.subject, self.body.EditBox, self.money.gold, self.money.silver,
        self.money.copper })

    frame:SetScript("OnShow", function()
        if deps.request then
            deps.request()
        end
        self:_LoadContacts()
        self:Refresh()
    end)
    frame:SetScript("OnHide", function()
        self:Sync()
    end)
    self:_Subscribe(deps.bus)
    self.ready = true
    self:_LoadContacts()
    return self
end

function SendPage:_Subscribe(bus)
    -- The send slots changed (an attach, a clear, a bag click, a run).
    bus:Subscribe("MAIL_SEND_INFO_UPDATE", OWNER, function()
        -- IsVisible: a tab of the window hides the parent of this frame, so IsShown stays true.
        if self.frame:IsVisible() then
            self:Refresh()
        end
    end)
    bus:Subscribe("UI_ERROR_MESSAGE", OWNER, function(_, first, second)
        self.lastError = type(second) == "string" and second or (type(first) == "string" and first or nil)
    end)
    bus:Subscribe("MAIL_SEND_SUCCESS", OWNER, function()
        if self.pending then
            self.pending = false
            self:_ResetForm()
            self.message, self.messageIsError = "Mail sent", false
        end
        self:Refresh()
    end)
    bus:Subscribe("MAIL_FAILED", OWNER, function()
        if self.pending then
            self.pending = false
            self.message, self.messageIsError = "Mail failed: " .. (self.lastError or "unknown reason"), true
        end
        -- A failed send must not leave money or cash on delivery in the send slots.
        self.deps.client.ResetMoney()
        self:Refresh()
    end)
    -- The client unlocks the slots after its confirm popup (an unrefundable item), also when the user accepts it.
    -- The send stays pending until MAIL_SEND_SUCCESS or MAIL_FAILED. If the user cancels the popup, no result
    -- comes: after a long wait, and only if the slots still hold items, the page takes the send as cancelled.
    bus:Subscribe("MAIL_UNLOCK_SEND_ITEMS", OWNER, function()
        self.deps.after(UNLOCK_WAIT, function()
            if self.pending and #self.deps.client.Items() > 0 then
                self.pending = false
                self.message, self.messageIsError = "The send got no result. Check the mailbox before you send again",
                    true
                self.deps.client.ResetMoney()
                self:Refresh()
            end
        end)
    end)
    -- The friend list and the guild roster come after a request, and change while the page shows.
    bus:Subscribe("FRIENDLIST_UPDATE", OWNER, function()
        self:_ContactsChanged()
    end)
    bus:Subscribe("GUILD_ROSTER_UPDATE", OWNER, function()
        self:_ContactsChanged()
    end)
    -- Last: the host closed the window before this handler runs. The client has no send page when the mailbox closes.
    bus:Subscribe("MAIL_CLOSED", OWNER, function()
        self.pending = false
        self.deps.client.SetShowing(false)
    end)
end

-- Reads all contact sources again: the own characters, the friends, the guild and the manual list. They make the
-- groups of the contact list and the names for the autocomplete. The current character is not in them.
function SendPage:_LoadContacts()
    local deps, Contacts = self.deps, ns.MailContacts
    local own = deps.selfName and deps.selfName()
    local exclude = {}
    self.realm = deps.realm and deps.realm() or nil
    if own then
        exclude = { own, ns.CharacterName.Display(own), ns.CharacterName.Plain(own) }
    end
    local ownNames = {}
    for _, key in ipairs(deps.characters()) do
        if key ~= own then
            ownNames[#ownNames + 1] = ns.CharacterName.Display(key)
        end
    end
    self.exclude = exclude
    self.manual = deps.contacts and deps.contacts() or {}
    local groups = Contacts.Merge({
        own = ownNames,
        friends = deps.friends and deps.friends() or {},
        guild = deps.guild and deps.guild() or {},
        manual = self.manual,
    }, exclude, self.realm)
    self.names = Contacts.Flat(groups)
    self.contactList:SetItems(Contacts.MenuItems(groups, CONTACTS))
end

-- A friend or guild event came: read the contacts again after a short wait, and only while the page shows.
function SendPage:_ContactsChanged()
    if self.contactsWait or not self.frame:IsVisible() then
        return
    end
    self.contactsWait = true
    self.deps.after(CONTACTS_DELAY, function()
        self.contactsWait = false
        if self.frame:IsVisible() then
            self:_LoadContacts()
            self:Refresh()
        end
    end)
end

-- Saves the typed recipient in the manual list.
function SendPage:_SaveContact()
    local deps = self.deps
    if not deps.saveContacts then
        return
    end
    local list, added, reason = ns.MailContacts.Add(self.manual, self.recipient:GetText(),
        { exclude = self.exclude, realm = self.realm })
    if not added then
        self:_Say(reason, true)
        return
    end
    if not deps.saveContacts(list) then
        self:_Say("Flipside could not save the contact", true)
        return
    end
    self:_LoadContacts()
    self:_Say(list[#list] .. " saved as a contact", false)
end

-- Removes the typed recipient from the manual list. A friend, a guild member or an own character stays.
function SendPage:_RemoveContact()
    local deps = self.deps
    if not deps.saveContacts then
        return
    end
    local list, removed = ns.MailContacts.Remove(self.manual, self.recipient:GetText(), self.realm)
    if not removed then
        self:_Say("The recipient is not a saved contact", true)
        return
    end
    if not deps.saveContacts(list) then
        self:_Say("Flipside could not save the contact", true)
        return
    end
    self:_LoadContacts()
    self:_Say("Contact removed", false)
end

function SendPage:_SetRecipient(text)
    self.typedLength = #text
    self.recipient:SetText(text)
    self.recipient:SetCursorPosition(#text)
end

-- The user types in the recipient box: finish the name from the own characters, as long as the text grows.
function SendPage:_RecipientChanged(box, userInput)
    local text = box:GetText()
    if userInput then
        self.message = nil
        local grew = #text > self.typedLength
        self.typedLength = #text
        local full = grew and ns.MailCompose.Complete(text, self.names)
        if full then
            box:SetText(full)
            box:HighlightText(#text, #full)
        end
    end
    self:Refresh()
end

-- True while a mailing run uses the send slots: the page then changes nothing.
function SendPage:_Locked()
    return self.deps.isRunning() and true or false
end

function SendPage:_ClickSlot(index, clear)
    if self:_Locked() then
        self:_Say("A mailing run is active", true)
        return
    end
    self.message = nil
    self.deps.client.Click(index, clear)
    self:Refresh()
end

function SendPage:_Say(text, isError)
    self.message, self.messageIsError = text, isError and true or false
    self:Refresh()
end

-- Returns the form as MailCompose reads it.
function SendPage:_Form()
    local deps, Compose = self.deps, ns.MailCompose
    return {
        recipient = Compose.Recipient(self.recipient:GetText(), deps.characters(), deps.mailName),
        subject = self.subject:GetText(),
        items = self.items,
        mode = self.mode,
        copper = self.money:GetCopper(),
        running = self:_Locked(),
    }
end

-- Tells the client if a send page shows. While the Flipside window shows, only the visible Send page counts, and not
-- while a mailing run works. While the window is hidden, the Send Mail tab of the client decides.
function SendPage:Sync()
    local deps = self.deps
    local shown
    if deps.windowShown() then
        shown = self.frame:IsVisible() and not self:_Locked()
    else
        shown = deps.clientSendShown()
    end
    deps.client.SetShowing(shown and true or false)
end

-- Reads the send slots and the fields again and shows the state of the page.
function SendPage:Refresh()
    if not self.ready or self.refreshing then
        return
    end
    self.refreshing = true
    local deps, Compose = self.deps, ns.MailCompose
    local running = self:_Locked()
    self.items = deps.client.Items()

    local mode = Compose.Mode(self.mode, self.items)
    if mode ~= self.mode then
        -- The last attachment went in cash on delivery mode: the amount must not turn into a money send.
        if self.mode == Compose.COD then
            self.money:SetCopper(nil)
            self.message, self.messageIsError = "Cash on delivery needs an attachment. The amount is cleared", false
        end
        self.mode = mode
        self.radio:SetValue(mode)
    end
    if not running then
        -- The default subject: the first attachment, or with none the money to send.
        local current = self.subject:GetText()
        local subject, previous = Compose.SubjectFor(current, self.previous, self.items, self.mode,
            self.money:GetCopper(), deps.moneyText)
        self.previous = previous
        if subject ~= current then
            self.subject:SetText(subject)
        end
    end
    self.radio.buttons[2]:SetEnabled(#self.items > 0 and not running)
    for _, slot in ipairs(Compose.Slots(self.items)) do
        paintSlot(self.slots[slot.index], slot.item)
    end

    local form = self:_Form()
    local recipient = form.recipient
    if recipient.reason then
        self.resolved:SetText(recipient.reason)
        setColor(self.resolved, RED)
    elseif recipient.full then
        self.resolved:SetText("Sends to: " .. recipient.full)
        setColor(self.resolved, GREY)
    else
        self.resolved:SetText("")
    end

    local postage = deps.client.Postage()
    self.postage:SetText("Postage: " .. deps.formatMoney(postage))
    setColor(self.postage, postage > deps.client.Money() and RED or WHITE)

    local ok, reason = Compose.Validate(form)
    self.sendButton:SetEnabled(ok and not self.pending)
    local Contacts = ns.MailContacts
    local typed = recipient.text
    local realm = self.realm
    local _, canAdd = Contacts.Add(self.manual, typed, { exclude = self.exclude, realm = realm })
    self.saveContact:SetEnabled(deps.saveContacts ~= nil and canAdd and not Contacts.Has(self.names, typed, realm))
    self.removeContact:SetEnabled(deps.saveContacts ~= nil and Contacts.Has(self.manual, typed, realm))
    self.money:SetEnabled(not running)
    if running then
        self.status:SetText("A mailing run is active. The Send page waits.")
        setColor(self.status, RED)
    elseif self.message then
        self.status:SetText(self.message)
        setColor(self.status, self.messageIsError and RED or GREY)
    else
        self.status:SetText(self.pending and "Sending..." or reason or "")
        setColor(self.status, GREY)
    end
    self:Sync()
    self.refreshing = false
end

function SendPage:_Send()
    local deps, Compose = self.deps, ns.MailCompose
    if self.pending or self:_Locked() then
        return
    end
    local form = self:_Form()
    local ok, reason = Compose.Validate(form)
    if not ok then
        self:_Say(reason, true)
        return
    end
    local money, cod = Compose.Amounts(form.mode, form.copper)
    self.lastError, self.message = nil, nil
    -- The client resolves the recipient to the full name (api.recipientName) and sets the money before SendMail.
    local sent, why = deps.client.Send(form.recipient.text, form.subject, self.body:GetText(),
        { money = money, cod = cod })
    if not sent then
        self:_Say(why or "The mail was not sent", true)
        return
    end
    self.pending = true
    self:Refresh()
end

-- Empties the fields and the money. The attachments stay: Clear returns them.
function SendPage:_ResetForm()
    self.mode, self.previous, self.pending = ns.MailCompose.MONEY, "", false
    -- The money goes first: an empty subject would get the money default again.
    self.money:SetCopper(nil)
    self.radio:SetValue(ns.MailCompose.MONEY)
    self:_SetRecipient("")
    self.subject:SetText("")
    self.body:SetText("")
    self.message = nil
end

-- The user chose a page of the window. The Inbox page and the Mailing rules page clear this page
-- (MailCompose.ClearOnTab), but not while a mailing run works or a send waits for its result.
function SendPage:OnTab(key)
    if ns.MailCompose.ClearOnTab(key, self:_Locked(), self.pending) then
        self:Clear()
    end
end

-- Returns all attachments to the bags and empties the fields.
function SendPage:Clear()
    if self:_Locked() then
        return
    end
    self.deps.client.ClearAll()
    self.deps.client.ResetMoney()
    self:_ResetForm()
    self:Refresh()
end
