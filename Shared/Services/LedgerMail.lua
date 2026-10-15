local _, ns = ...

-- The mail reader of the ledger (SPEC 5.8 points 5 and 6). It reads the inbox with read-only calls on MAIL_SHOW and
-- MAIL_INBOX_UPDATE and keeps a snapshot. It never calls GetInboxText (that call marks a mail as read). It adds no
-- hook and registers no restricted event. When the money tracker sees a gain in the mail context, this module
-- matches it with a mail whose money went down, and writes the sale, refund or mail money record.
local LedgerMail = {}
ns.LedgerMail = LedgerMail

local OWNER = "Flipside.LedgerMail"

-- The wait before the inbox is read again after an event (seconds). Many events come together.
LedgerMail.DEBOUNCE_SECONDS = 0.1
-- A mail whose money went down waits this long for its money change (seconds). Then a sale invoice counts alone.
LedgerMail.PENDING_SECONDS = 10
-- The days that a fingerprint stays saved.
LedgerMail.FINGERPRINT_DAYS = 31
-- The most mails that one read looks at.
LedgerMail.MAX_MAILS = 100

local SECONDS_PER_DAY = 86400

-- Subject kind -> name of the client global string with the subject format. A global that is missing turns
-- the kind off; the invoice type does not need it.
LedgerMail.SUBJECT_GLOBALS = {
    sold = "AUCTION_SOLD_MAIL_SUBJECT",
    expired = "AUCTION_EXPIRED_MAIL_SUBJECT",
    cancelled = "AUCTION_REMOVED_MAIL_SUBJECT",
    outbid = "AUCTION_OUTBID_MAIL_SUBJECT",
    won = "AUCTION_WON_MAIL_SUBJECT",
}

-- Events that this module listens to. It listens to nothing else.
LedgerMail.EVENTS = { "MAIL_SHOW", "MAIL_CLOSED", "MAIL_INBOX_UPDATE" }

local Mail = {}
Mail.__index = Mail

-- Returns a Lua pattern for a client format text such as "Expired: %s", or nil.
local function formatToPattern(format)
    if type(format) ~= "string" or format == "" then
        return nil
    end
    local marked = format:gsub("%%%d*%$?s", "\1")
    local escaped = marked:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    return "^" .. escaped:gsub("\1", "(.+)") .. "$"
end
LedgerMail.FormatToPattern = formatToPattern

-- A hash of a text as 8 hex digits. Two seeds give a longer fingerprint.
local function hash(text, seed)
    local h = seed
    for i = 1, #text do
        h = (h * 33 + text:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

-- Returns a whole non-negative number, or nil.
local function count(value)
    if type(value) == "number" and value >= 0 and value < math.huge and value == value then
        return math.floor(value)
    end
    return nil
end

local function text(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

function Mail:_Secret(value)
    return self._isSecret ~= nil and self._isSecret(value) == true
end

-- Returns true if a field of the table is a secret value.
function Mail:_AnySecret(fields)
    if fields == nil then
        return false
    end
    for _, value in pairs(fields) do
        if self:_Secret(value) then
            return true
        end
    end
    return false
end

function Mail:_Note(name, ...)
    if self._tracker and self._tracker.Note then
        self._tracker:Note(name, ...)
    end
end

-- Returns a copy of the counters.
function Mail:Stats()
    local copy = {}
    for name, value in pairs(self._stats) do
        copy[name] = value
    end
    return copy
end

-- Returns the subject kind (sold, expired, cancelled, outbid or won) and the item name in it, or nil.
function Mail:_SubjectKind(subject)
    if type(subject) ~= "string" then
        return nil
    end
    for kind, pattern in pairs(self._patterns) do
        local name = subject:match(pattern)
        if name then
            return kind, name
        end
    end
    return nil
end

-- Read the inbox. Returns the list of entries, or nil if the read is not possible.
function Mail:_Read()
    local api = self._api
    local total = api.numItems()
    if self:_Secret(total) or type(total) ~= "number" then
        self._stats.skipped = self._stats.skipped + 1
        return nil
    end
    local list = {}
    for index = 1, math.min(total, LedgerMail.MAX_MAILS) do
        local header = api.header(index)
        if type(header) == "table" then
            local invoice = self._invoices and api.invoice(index) or nil
            if self:_AnySecret(header) or self:_AnySecret(invoice) then
                self._stats.skipped = self._stats.skipped + 1
            else
                list[#list + 1] = {
                    index = index,
                    sender = text(header.sender) or "",
                    subject = text(header.subject) or "",
                    money = count(header.money) or 0,
                    itemCount = count(header.itemCount) or 0,
                    qty = count(header.itemQuantity),
                    link = text(header.itemLink),
                    invoice = type(invoice) == "table" and invoice or nil,
                }
            end
        end
    end
    return list
end

-- Sets entry.kind: sale, pendingSale, purchase, expired, cancelled, outbid or other.
function Mail:_Classify(entry)
    local invoice = entry.invoice
    local subjectKind, name = self:_SubjectKind(entry.subject)
    entry.subjectName = name
    if invoice then
        local invoiceType = invoice.type
        if invoiceType == "seller" then
            entry.kind = "sale"
        elseif invoiceType == "seller_temp_invoice" then
            entry.kind = "pendingSale"
        elseif invoiceType == "buyer" then
            entry.kind = "purchase"
        else
            entry.kind = "other"
            self._stats.unknownInvoice = self._stats.unknownInvoice + 1
        end
        if not entry.matched then
            self:_Note("invoice", entry.index, tostring(invoiceType), tostring(invoice.itemName),
                tostring(invoice.player), tostring(invoice.bid), tostring(invoice.buyout), tostring(invoice.deposit),
                tostring(invoice.consignment), tostring(invoice.count))
        end
        return
    end
    if subjectKind == "expired" or subjectKind == "cancelled" or subjectKind == "outbid" then
        entry.kind = subjectKind
    elseif subjectKind == "sold" then
        -- The sale subject is known but the client gave no invoice fields.
        entry.kind = "sale"
        if entry.money > 0 and not entry.matched then
            self._stats.noInvoice = self._stats.noInvoice + 1
            self:_Note("noinvoice", entry.index, entry.subject, entry.money)
        end
    elseif subjectKind == "won" then
        entry.kind = "purchase"
    else
        entry.kind = "other"
    end
end

-- The text that two equal mails share. It has no mail money for a mail with an invoice, because the money goes to 0.
function Mail._Base(entry)
    local invoice = entry.invoice
    local parts = { entry.sender, entry.subject }
    if invoice then
        for _, field in ipairs({ "type", "itemName", "player", "bid", "buyout", "deposit", "consignment", "count" }) do
            parts[#parts + 1] = tostring(invoice[field])
        end
    else
        parts[#parts + 1] = tostring(entry.money)
    end
    parts[#parts + 1] = tostring(entry.itemCount)
    parts[#parts + 1] = tostring(entry.qty)
    parts[#parts + 1] = tostring(entry.link)
    local joined = table.concat(parts, "\31")
    return hash(joined, 5381) .. hash(joined, 52711)
end

-- Give each new entry its fingerprint: the base and an occurrence number. A mail with money takes the lowest
-- number that is neither saved nor used, so a new mail equal to an old one is not lost. The other mails take their
-- place among equal mails.
function Mail:_Fingerprints(list)
    local used = {}
    for _, entry in ipairs(list) do
        if entry.fp then
            used[entry.fp] = true
        end
    end
    local seen = {}
    for _, entry in ipairs(list) do
        local base = self._Base(entry)
        seen[base] = (seen[base] or 0) + 1
        if not entry.fp then
            local n = seen[base]
            if entry.money > 0 then
                n = 1
                while used[base .. ":" .. n] or self._fps[base .. ":" .. n] do
                    n = n + 1
                end
            else
                while used[base .. ":" .. n] do
                    n = n + 1
                end
            end
            entry.fp = base .. ":" .. n
            used[entry.fp] = true
        end
    end
end

-- Match the old snapshot with the new list. A new mail matches an old mail with the same sender and subject and
-- no less money. Sets entry.fp for the matches. Returns the drops: money that left a mail.
function Mail._Match(old, list)
    local drops = {}
    local taken = {}
    for _, entry in ipairs(list) do
        for position, previous in ipairs(old) do
            if not taken[position] and previous.sender == entry.sender and previous.subject == entry.subject
                and previous.money >= entry.money then
                taken[position] = true
                entry.fp = previous.fp
                entry.invoice = entry.invoice or previous.invoice
                entry.matched = true
                if previous.money > entry.money then
                    drops[#drops + 1] = { amount = previous.money - entry.money, entry = entry }
                end
                break
            end
        end
    end
    for position, previous in ipairs(old) do
        if not taken[position] and previous.money > 0 then
            drops[#drops + 1] = { amount = previous.money, entry = previous }
        end
    end
    return drops
end

function Mail:_ResolveName(name)
    if name and self._itemKeyByName then
        return self._itemKeyByName(name)
    end
    return nil
end

-- Write one record. Returns true if the buffer took it. A saved fingerprint blocks the record.
function Mail:_Write(fields, fp)
    if fp then
        if self._fps[fp] then
            self._stats.duplicates = self._stats.duplicates + 1
            return false
        end
        fields.fp = fp
    end
    local character = self._character()
    if not character then
        self._stats.skipped = self._stats.skipped + 1
        return false
    end
    fields.char = character
    fields.time = self._serverTime()
    fields.ctx = fields.ctx or self._tracker:Context("mail")
    local ok, message = self._buffer:Add(fields)
    if not ok then
        self._stats.rejected = self._stats.rejected + 1
        if self._report and not self._reported then
            self._reported = true
            self._report("a ledger mail record was rejected: " .. tostring(message))
        end
        return false
    end
    if fp then
        self._fps[fp] = fields.time
        if self._fpSet then
            self._fpSet(self._fps)
        end
    end
    self:_Note("record", fields.source, fields.type, fields.money, fields.ctx)
    return true
end

-- Set item, itemName and qty of a record from an item name and a quantity.
function Mail:_SetItem(fields, name, qty)
    local key = self:_ResolveName(name)
    if key then
        fields.item = key
        fields.qty = qty
    elseif name then
        fields.itemName = name
        fields.qty = qty
    end
end

-- Write the record for money that left a mail. amount is the copper that arrived.
function Mail:_Pay(drop)
    local entry, amount = drop.entry, drop.amount
    if entry.kind == "sale" then
        local invoice = entry.invoice
        local fields = { source = "ahSale", type = "sale", money = amount }
        local name = invoice and text(invoice.itemName) or entry.subjectName
        local qty = invoice and count(invoice.count) or nil
        self:_SetItem(fields, name, qty and qty > 0 and qty or 1)
        if invoice then
            fields.invoiceType = text(invoice.type)
            fields.counterparty = text(invoice.player)
            fields.bid = count(invoice.bid)
            fields.buyout = count(invoice.buyout)
            fields.deposit = count(invoice.deposit)
            fields.cut = count(invoice.consignment)
        end
        if self:_Write(fields, entry.fp) then
            self._stats.sales = self._stats.sales + 1
        end
    elseif entry.kind == "outbid" then
        local fields = { source = "ahOutbidRefund", type = "income", money = amount }
        self:_SetItem(fields, entry.subjectName, entry.qty)
        if self:_Write(fields, entry.fp) then
            self._stats.refunds = self._stats.refunds + 1
        end
    else
        local fields = { source = "mailMoney", type = "income", money = amount, counterparty = text(entry.sender) }
        if self:_Write(fields, entry.fp) then
            self._stats.mailMoney = self._stats.mailMoney + 1
        end
    end
end

-- A mail that returns an item (expired or cancelled auction) gives a record without money.
function Mail:_WriteReturned(entry)
    local expired = entry.kind == "expired"
    local fields = {
        source = expired and "ahExpired" or "ahCancelled", type = expired and "expired" or "cancelled", money = 0,
    }
    local key = entry.link and self._itemKey(entry.link) or nil
    if key then
        fields.item = key
        fields.qty = entry.qty or 1
    else
        self:_SetItem(fields, entry.subjectName, entry.qty or 1)
    end
    if self:_Write(fields, entry.fp) then
        local name = expired and "expired" or "cancelled"
        self._stats[name] = self._stats[name] + 1
    end
end

-- Returns the list of pending drops that match an amount (one drop with the amount, else all drops), or nil.
function Mail:_TakePending(amount)
    for position, drop in ipairs(self._pending) do
        if drop.amount == amount then
            table.remove(self._pending, position)
            return { drop }
        end
    end
    local total = 0
    for _, drop in ipairs(self._pending) do
        total = total + drop.amount
    end
    if #self._pending > 1 and total == amount then
        local all = self._pending
        self._pending = {}
        return all
    end
    return nil
end

-- Pair the mail gains that wait in the tracker with the pending drops.
function Mail:_Settle()
    if #self._pending == 0 then
        return
    end
    for _, amount in ipairs(self._tracker:HeldMail()) do
        local drops = self:_TakePending(amount)
        if drops and self._tracker:ReleaseHeldMail(amount) then
            for _, drop in ipairs(drops) do
                self:_Pay(drop)
            end
        elseif drops then
            -- The hold ended while we matched. Put the drops back.
            for _, drop in ipairs(drops) do
                self._pending[#self._pending + 1] = drop
            end
        end
    end
end

-- A drop that no money change matched is old. An invoice sale still counts, and the tracker gets a claim.
function Mail:_ExpirePending()
    local now = self._now()
    local keep = {}
    for _, drop in ipairs(self._pending) do
        if now - drop.time >= LedgerMail.PENDING_SECONDS then
            if drop.entry.kind == "sale" then
                self._tracker:Claim(drop.amount, "in")
                self._stats.late = self._stats.late + 1
                self:_Pay(drop)
            end
        else
            keep[#keep + 1] = drop
        end
    end
    self._pending = keep
end

-- Read the inbox, compare it with the snapshot, write the first-sight records and keep the drops. If reset is
-- true the old snapshot is dropped first (a new mailbox visit).
function Mail:Refresh(reset)
    if reset then
        self._snapshot = nil
    end
    local list = self:_Read()
    if not list then
        return
    end
    local drops = self._snapshot and self._Match(self._snapshot, list) or {}
    for _, entry in ipairs(list) do
        self:_Classify(entry)
    end
    self:_Fingerprints(list)
    for _, entry in ipairs(list) do
        if not entry.matched and (entry.kind == "expired" or entry.kind == "cancelled") then
            self:_WriteReturned(entry)
        end
    end
    self._snapshot = list
    if #drops > 0 then
        local now = self._now()
        for _, drop in ipairs(drops) do
            drop.time = now
            if not drop.entry.kind then
                self:_Classify(drop.entry)
            end
            self._pending[#self._pending + 1] = drop
        end
        self._after(LedgerMail.PENDING_SECONDS + 0.1, function()
            self:_ExpirePending()
        end)
    end
    self:_Settle()
end

-- The money tracker calls this for a gain in the mail context. Returns true if the records are written.
function Mail:_OnGain(amount)
    self:Refresh()
    local drops = self:_TakePending(amount)
    if not drops then
        return false
    end
    for _, drop in ipairs(drops) do
        self:_Pay(drop)
    end
    return true
end

function Mail:_Schedule()
    if self._scheduled then
        return
    end
    self._scheduled = true
    self._after(LedgerMail.DEBOUNCE_SECONDS, function()
        self._scheduled = false
        self:Refresh()
    end)
end

-- Remove the fingerprints that are older than FINGERPRINT_DAYS.
function Mail:_Prune()
    local limit = self._serverTime() - LedgerMail.FINGERPRINT_DAYS * SECONDS_PER_DAY
    for fp, time in pairs(self._fps) do
        if type(time) ~= "number" or time < limit then
            self._fps[fp] = nil
        end
    end
end

-- deps: bus, buffer (Add), tracker (LedgerMoney: Context, Claim, SetMailMatcher, HeldMail, ReleaseHeldMail, Note),
-- api (numItems(), header(index) -> { sender, subject, money, itemCount, itemQuantity, itemLink },
-- invoice(index) -> { type, itemName, player, bid, buyout, deposit, consignment, count } or nil), now (seconds),
-- serverTime, character (function), after, itemKey(link), fingerprints (a saved table of fingerprint -> time) and
-- saveFingerprints(table). Optional: isSecret, strings(name) -> client global string, itemKeyByName(name),
-- invoices (false turns the invoice read off), report.
function LedgerMail.Attach(deps)
    local patterns = {}
    for kind, globalName in pairs(LedgerMail.SUBJECT_GLOBALS) do
        local pattern = deps.strings and formatToPattern(deps.strings(globalName)) or nil
        if pattern then
            patterns[kind] = pattern
        end
    end
    local mail = setmetatable({
        _buffer = deps.buffer,
        _tracker = deps.tracker,
        _api = deps.api,
        _now = deps.now,
        _serverTime = deps.serverTime,
        _character = deps.character,
        _after = deps.after,
        _itemKey = deps.itemKey,
        _itemKeyByName = deps.itemKeyByName,
        _isSecret = type(deps.isSecret) == "function" and deps.isSecret or nil,
        _report = deps.report,
        _fps = deps.fingerprints or {},
        _fpSet = deps.saveFingerprints,
        _invoices = deps.invoices ~= false,
        _patterns = patterns,
        _pending = {},
        _stats = {
            sales = 0, expired = 0, cancelled = 0, refunds = 0, mailMoney = 0, duplicates = 0, skipped = 0,
            rejected = 0, noInvoice = 0, unknownInvoice = 0, late = 0,
        },
    }, Mail)
    mail:_Prune()

    local bus = deps.bus
    bus:Subscribe("MAIL_SHOW", OWNER, function()
        mail:Refresh(true)
        mail:_Schedule()
    end)
    bus:Subscribe("MAIL_CLOSED", OWNER, function()
        -- The inbox reads empty after the close, so the snapshot ends here.
        mail._snapshot = nil
    end)
    bus:Subscribe("MAIL_INBOX_UPDATE", OWNER, function()
        mail:_Schedule()
    end)
    deps.tracker:SetMailMatcher(function(amount)
        return mail:_OnGain(amount)
    end)
    return mail
end
