local _, ns = ...

-- The send run of the mailing operation (SPEC 5.5). It sends the mails of a MailingPlan result one after the other,
-- with no click for each mail. The client, the event bus and the timer are arguments, so the run needs no WoW global.
-- After each mail it waits for BAG_UPDATE_DELAYED and a flavour delay, then reads the bags again.
local MailingRun = {}
ns.MailingRun = MailingRun

local OWNER = "Flipside.MailingRun"

-- Write one line to the diagnostics log; the Log module can be missing in a spec.
local function log(level, fmt, ...)
    if ns.Log then
        ns.Log.Writef("mail", level, fmt, ...)
    end
end

-- Seconds to wait after the attach calls, so that a MAIL_LOCK_SEND_ITEMS event can arrive before the send.
MailingRun.SETTLE_SECONDS = 0.2
-- Seconds to wait for MAIL_SEND_SUCCESS or MAIL_FAILED.
MailingRun.SEND_TIMEOUT = 10
-- Fallback seconds to wait for BAG_UPDATE_DELAYED.
MailingRun.BAG_WAIT_SECONDS = 5
-- Seconds to wait after BAG_UPDATE_DELAYED. A flavour can set deps.delay.
MailingRun.DELAY_SECONDS = 0.5

local Run = {}
Run.__index = Run

-- deps: client (see MailClient), bus, after(seconds, fn), delay, bagWait, settle (seconds, optional),
-- onProgress(status), onSending(info), onSent(info) and onDone(result) (optional).
function MailingRun.New(deps)
    return setmetatable({
        _client = deps.client,
        _bus = deps.bus,
        _after = deps.after,
        _delay = deps.delay or MailingRun.DELAY_SECONDS,
        _bagWait = deps.bagWait or MailingRun.BAG_WAIT_SECONDS,
        _settle = deps.settle or MailingRun.SETTLE_SECONDS,
        _onProgress = deps.onProgress,
        _onSending = deps.onSending,
        _onSent = deps.onSent,
        _onDone = deps.onDone,
        _state = "idle",
        _token = 0,
    }, Run)
end

local function slotId(bag, slot)
    return bag .. ":" .. slot
end

function Run:IsRunning()
    return self._state ~= "idle"
end

-- Returns { state, index, total, sent }. The state is idle, starting, settle, sending, bagwait or delay.
function Run:Status()
    return { state = self._state, index = self._index or 0, total = self._queue and #self._queue or 0,
        sent = self._result and self._result.sent or 0 }
end

function Run:_Progress()
    if self._onProgress then
        self._onProgress(self:Status())
    end
end

-- Moves to a new state. The token makes the timers of an old state do nothing.
function Run:_Enter(state)
    self._state = state
    self._token = self._token + 1
    self:_Progress()
    return self._token
end

-- Calls fn after the seconds, unless the run has left the state by then.
function Run:_Wait(seconds, token, fn)
    self._after(seconds, function()
        if self._token == token then
            fn()
        end
    end)
end

function Run:_Skip(entry)
    local skipped = self._result.skipped
    skipped[#skipped + 1] = entry
    log("warn", "skipped %s x%s for %s: %s", entry.name or entry.key, entry.count, entry.recipient, entry.reason)
end

function Run:_Finish(reason)
    if self._state == "idle" then
        return
    end
    self._bus:UnsubscribeAll(OWNER)
    self._token = self._token + 1
    self._state = "idle"
    self._result.stopped = reason
    local result = self._result
    log("info", "run finished: %d mails sent, %d skipped, stopped: %s", result.sent, #result.skipped, reason)
    self:_Progress()
    if self._onDone then
        self._onDone(result)
    end
end

-- Starts a run. plan is a MailingPlan.Build result. Returns false and a message if a run is active or there is no mail.
function Run:Start(plan)
    if self._state ~= "idle" then
        return false, "a run is active"
    end
    if type(plan) ~= "table" or #(plan.mails or {}) == 0 then
        return false, "no mail to send"
    end
    log("info", "run started: %d mails, %d skipped by the plan", #plan.mails, #(plan.skipped or {}))
    self._queue = {}
    for _, mail in ipairs(plan.mails) do
        self._queue[#self._queue + 1] = mail
    end
    self._index = 0
    self._result = { sent = 0, postage = 0, recipients = {}, skipped = {}, stopped = nil }
    for _, entry in ipairs(plan.skipped or {}) do
        self:_Skip({ key = entry.key, count = entry.count, reason = entry.reason })
    end
    self._byName = {}
    self._locked = {}
    self._stopping = false
    self._state = "starting"
    local bus = self._bus
    bus:Subscribe("MAIL_SEND_SUCCESS", OWNER, function()
        self:_OnResult(true)
    end)
    bus:Subscribe("MAIL_FAILED", OWNER, function()
        self:_OnResult(false)
    end)
    bus:Subscribe("BAG_UPDATE_DELAYED", OWNER, function()
        self:_OnBags()
    end)
    bus:Subscribe("MAIL_LOCK_SEND_ITEMS", OWNER, function(_, index)
        if type(index) == "number" then
            self._locked[index] = true
        end
    end)
    bus:Subscribe("UI_ERROR_MESSAGE", OWNER, function(_, first, second)
        self._lastError = type(second) == "string" and second or (type(first) == "string" and first or nil)
    end)
    bus:Subscribe("MAIL_CLOSED", OWNER, function()
        self:Abort("mailbox closed")
    end)
    self:_Next()
    return true
end

-- Stops the run. A mail in flight completes first; the run stops after it.
function Run:Stop()
    if self._state == "idle" then
        return
    end
    if self._state == "sending" then
        self._stopping = true
        return
    end
    self:Abort("stopped")
end

-- Stops now. Items on the send frame go back to the bags.
function Run:Abort(reason)
    if self._state == "idle" then
        return
    end
    if self._state == "settle" or self._state == "sending" then
        self._client.ClearAll()
    end
    self:_Finish(reason)
end

-- Finds a bag slot for a planned attachment: the planned slot if it still holds it, else any free slot with the
-- same item and count. A locked slot or a slot that this mail used is never chosen.
local function findSlot(slots, attachment, used)
    local fallback
    for _, slot in ipairs(slots) do
        if slot.key == attachment.key and slot.count == attachment.count and not slot.locked
            and not used[slotId(slot.bag, slot.slot)] then
            if slot.bag == attachment.bag and slot.slot == attachment.slot then
                return slot
            end
            fallback = fallback or slot
        end
    end
    return fallback
end

-- Starts the next mail: reads the bags, attaches the items, waits for the lock events.
function Run:_Next()
    if self._stopping then
        self:_Finish("stopped")
        return
    end
    self._index = self._index + 1
    local mail = self._queue[self._index]
    if not mail then
        self:_Finish(nil)
        return
    end
    local client = self._client
    local slots = client.ReadSlots()
    local used = {}
    self._locked = {}
    self._lastError = nil
    self._attached = 0
    for _, attachment in ipairs(mail.attachments) do
        local slot = findSlot(slots, attachment, used)
        if not slot then
            self:_Skip({ recipient = mail.recipient, key = attachment.key, count = attachment.count,
                reason = "item not found in the bags" })
        else
            used[slotId(slot.bag, slot.slot)] = true
            if client.Attach(slot.bag, slot.slot, self._attached + 1) then
                self._attached = self._attached + 1
            else
                self:_Skip({ recipient = mail.recipient, key = attachment.key, count = attachment.count,
                    reason = "attach failed" })
            end
        end
    end
    if self._attached == 0 then
        client.ClearAll()
        self:_Next()
        return
    end
    local token = self:_Enter("settle")
    self:_Wait(self._settle, token, function()
        self:_Send(mail)
    end)
end

-- Clears the attachments that the client wants to confirm (MAIL_LOCK_SEND_ITEMS) and reports them as skipped.
function Run:_DropLocked(mail)
    for index in pairs(self._locked) do
        local item = self._client.Attachment(index)
        self._client.ClearSlot(index)
        self:_Skip({ recipient = mail.recipient, key = item and item.itemID and ("item:" .. item.itemID) or nil,
            name = item and item.name, count = item and item.count,
            reason = "needs a confirm (cannot be returned)" })
    end
    self._locked = {}
end

-- Skips all mails from the current one on for a recipient.
function Run:_SkipRecipient(recipient, reason)
    local wanted = recipient:lower()
    local kept = {}
    for i, mail in ipairs(self._queue) do
        if i <= self._index or mail.recipient:lower() ~= wanted then
            kept[#kept + 1] = mail
        else
            for _, attachment in ipairs(mail.attachments) do
                self:_Skip({ recipient = mail.recipient, key = attachment.key, count = attachment.count,
                    reason = reason })
            end
        end
    end
    self._queue = kept
end

function Run:_Send(mail)
    local client = self._client
    self:_DropLocked(mail)
    local items = client.Attachments()
    if #items == 0 then
        client.ClearAll()
        self:_Next()
        return
    end
    local postage = client.Postage()
    if postage > client.Money() then
        client.ClearAll()
        self:_Finish("not enough money for the postage")
        return
    end
    if self._onSending then
        self._onSending({ recipient = mail.recipient, postage = postage })
    end
    log("info", "sending to %s: %d attachments, postage %s", mail.recipient, #items, postage)
    local ok, sendError = pcall(client.Send, mail.recipient, items[1].name)
    if not ok then
        log("error", "send call to %s failed: %s", mail.recipient, sendError)
        client.ClearAll()
        self:_Finish("the send call failed")
        return
    end
    self._sending = { mail = mail, postage = postage, items = items }
    local token = self:_Enter("sending")
    self:_Wait(MailingRun.SEND_TIMEOUT, token, function()
        self:_OnResult(false)
    end)
end

-- The result of the send: MAIL_SEND_SUCCESS (true) or MAIL_FAILED and the time-out (false).
function Run:_OnResult(success)
    if self._state ~= "sending" then
        return
    end
    local sending = self._sending
    local mail = sending.mail
    if not success then
        self._client.ClearAll()
        local reason = "mail failed" .. (self._lastError and (": " .. self._lastError) or "")
        log("warn", "mail to %s: %s", mail.recipient, reason)
        self:_SkipItems(mail, sending.items, reason)
        self:_SkipRecipient(mail.recipient, reason)
        self:_AfterBags()
        return
    end
    local result = self._result
    result.sent = result.sent + 1
    result.postage = result.postage + sending.postage
    local entry = self._byName[mail.recipient:lower()]
    if not entry then
        entry = { name = mail.recipient, mails = 0, units = 0 }
        self._byName[mail.recipient:lower()] = entry
        result.recipients[#result.recipients + 1] = entry
    end
    entry.mails = entry.mails + 1
    log("info", "sent to %s, postage %s", mail.recipient, sending.postage)
    for _, item in ipairs(sending.items) do
        entry.units = entry.units + item.count
    end
    if self._onSent then
        self._onSent({ recipient = mail.recipient, postage = sending.postage, items = sending.items })
    end
    if self._stopping then
        self:_Finish("stopped")
    elseif self._index >= #self._queue then
        self:_Finish(nil)
    else
        local token = self:_Enter("bagwait")
        self:_Wait(self._bagWait, token, function()
            self:_AfterBags()
        end)
    end
end

function Run:_SkipItems(mail, items, reason)
    for _, item in ipairs(items) do
        self:_Skip({ recipient = mail.recipient, name = item.name, count = item.count, reason = reason })
    end
end

function Run:_OnBags()
    if self._state == "bagwait" then
        self:_AfterBags()
    end
end

-- The bags changed (or the wait ended): wait the flavour delay, then start the next mail.
function Run:_AfterBags()
    if self._stopping then
        self:_Finish("stopped")
        return
    end
    local token = self:_Enter("delay")
    self:_Wait(self._delay, token, function()
        self:_Next()
    end)
end
