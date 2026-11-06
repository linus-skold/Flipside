local _, ns = ...

-- The rules of the Send page of the Flipside mailbox window (SPEC 5.5, "Send page"). Pure logic: no frame and no
-- client call. The rules follow the client send form (Blizzard_MailFrame/MailFrame.lua, Forever): the subject
-- default, the cash on delivery rules and the checks of SendMailFrame_CanSend.
local MailCompose = {}
ns.MailCompose = MailCompose

-- The most attachments of one mail (ATTACHMENTS_MAX_SEND).
MailCompose.MAX_SLOTS = 12
-- The highest cash on delivery amount in copper: 10000 gold (MAX_COD_AMOUNT * COPPER_PER_GOLD in the client).
MailCompose.MAX_COD = 10000 * 10000
-- The two money modes of the form.
MailCompose.MONEY = "money"
MailCompose.COD = "cod"

local function trim(text)
    return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

-- Returns the subject that the client puts in an empty subject box: the name of the first attachment, with the
-- stack size in brackets if it is more than 1. items is a list of { index, name, count } of the filled slots.
-- Returns "" if the list is empty.
function MailCompose.DefaultSubject(items)
    local first
    for _, item in ipairs(items or {}) do
        if not first or (item.index or 0) < (first.index or 0) then
            first = item
        end
    end
    if not first or not first.name then
        return ""
    end
    if (tonumber(first.count) or 1) > 1 then
        return first.name .. " (" .. first.count .. ")"
    end
    return first.name
end

-- The subject after the attachments changed, as the client does it. previous is the default subject that was put
-- in the box last time. An empty box or a box that still holds the previous default gets the new default. With no
-- attachments, a box that holds the previous default is cleared. Returns the new subject and the new previous one.
function MailCompose.SubjectUpdate(current, previous, items)
    current, previous = current or "", previous or ""
    if #(items or {}) > 0 then
        local title = MailCompose.DefaultSubject(items)
        if current == "" or current == previous then
            return title, title
        end
        return current, previous
    end
    if current == previous then
        current = ""
    end
    return current, ""
end

-- Returns the money mode that can hold: cash on delivery needs at least one attachment.
function MailCompose.Mode(mode, items)
    if mode == MailCompose.COD and #(items or {}) > 0 then
        return MailCompose.COD
    end
    return MailCompose.MONEY
end

-- Returns the money to send and the cash on delivery amount, in copper, for the mode.
function MailCompose.Amounts(mode, copper)
    copper = math.max(0, math.floor(tonumber(copper) or 0))
    if mode == MailCompose.COD then
        return 0, copper
    end
    return copper, 0
end

-- Returns the 12 slots as a list of { index, item (the entry of items or nil) }.
function MailCompose.Slots(items)
    local byIndex = {}
    for _, item in ipairs(items or {}) do
        byIndex[item.index] = item
    end
    local slots = {}
    for index = 1, MailCompose.MAX_SLOTS do
        slots[index] = { index = index, item = byIndex[index] }
    end
    return slots
end

-- Returns the first empty slot, or nil if all 12 hold an item.
function MailCompose.NextFree(items)
    for _, slot in ipairs(MailCompose.Slots(items)) do
        if not slot.item then
            return slot.index
        end
    end
    return nil
end

-- Resolves the typed recipient. mailName(text, keys) is CharacterName.MailName (the name for the mail call, or nil
-- and a reason). Returns { text (trimmed), full (the name for the call), reason (why there is no name) }.
-- An empty text gives no full name and no reason.
function MailCompose.Recipient(text, keys, mailName)
    text = trim(text)
    if text == "" then
        return { text = "" }
    end
    local full, reason
    if mailName then
        full, reason = mailName(text, keys)
    else
        full = text
    end
    if not full then
        return { text = text, reason = reason or "Unknown recipient" }
    end
    return { text = text, full = full }
end

-- Returns the first name of the list that starts with the typed text and is longer (case does not matter), or nil.
function MailCompose.Complete(text, names)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local wanted = text:lower()
    for _, name in ipairs(names or {}) do
        if #name > #text and name:sub(1, #text):lower() == wanted then
            return name
        end
    end
    return nil
end

-- Checks the form. form: recipient (the table of Recipient), subject, items, mode, copper, running (a mailing run
-- is active). Returns true, or false and the reason. The checks are the ones of the client (a recipient, a subject
-- and a cash on delivery amount of at most 10000 gold), and the new ones: a cash on delivery mail needs an
-- attachment, and no manual send runs together with a mailing run.
function MailCompose.Validate(form)
    if form.running then
        return false, "A mailing run is active"
    end
    local recipient = form.recipient or {}
    if (recipient.text or "") == "" then
        return false, "Enter a recipient"
    end
    if not recipient.full then
        return false, recipient.reason or "Unknown recipient"
    end
    if (form.subject or "") == "" then
        return false, "Enter a subject"
    end
    if form.mode == MailCompose.COD then
        if #(form.items or {}) == 0 then
            return false, "Cash on delivery needs an attachment"
        end
        if (tonumber(form.copper) or 0) > MailCompose.MAX_COD then
            return false, "Cash on delivery is 10000 gold at most"
        end
    end
    return true
end
