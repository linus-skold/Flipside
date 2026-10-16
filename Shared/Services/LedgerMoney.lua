local _, ns = ...

-- The money tracker (SPEC 5.8 point 10). On PLAYER_MONEY it computes the change in copper, labels it with the
-- open context and writes one ledger record. It uses client events and reads only: no hook, no restricted event.
local LedgerMoney = {}
ns.LedgerMoney = LedgerMoney

local OWNER = "Flipside.LedgerMoney"

-- Money can arrive after LOOT_CLOSED. The tail keeps the loot context open for this time (seconds).
LedgerMoney.LOOT_TAIL_SECONDS = 1
-- A quest reward and PLAYER_MONEY come from one server packet, in an order that is not verified. The event and the
-- change must be less than this time apart, in any order. The same time is the hold time of a change that has no
-- label yet. It is short, so a real unknown change waits only this long.
LedgerMoney.QUEST_WINDOW_SECONDS = 1
-- The time that a call to buy or post waits for its money change. The server can be slow, so it is long.
LedgerMoney.HINT_SECONDS = 10
-- The time that a claim from another module waits for its money change.
LedgerMoney.CLAIM_SECONDS = 5
-- The size of the debug ring.
LedgerMoney.RING_SIZE = 200

-- Context kinds, from the highest priority to the lowest. A quest is not in the list: it is open only for a
-- reward event with the same amount, and that match always wins. The order is the rule:
-- trade (the other player gives or takes money directly),
-- loot (a short action, so it is more specific than a frame that stays open),
-- ah, merchant and mail (frames that stay open; the client closes one before it opens another).
LedgerMoney.PRIORITY = { "trade", "loot", "ah", "merchant", "mail" }

-- Events that Flipside never registers (the client restricts them).
LedgerMoney.RESTRICTED = { COMBAT_LOG_EVENT_UNFILTERED = true }

-- Window events: kind -> open event, close event.
local WINDOWS = {
    merchant = { "MERCHANT_SHOW", "MERCHANT_CLOSED" },
    loot = { "LOOT_OPENED", "LOOT_CLOSED" },
    trade = { "TRADE_SHOW", "TRADE_CLOSED" },
    mail = { "MAIL_SHOW", "MAIL_CLOSED" },
}

-- Tail time after the close, in seconds, for each kind.
local TAILS = { loot = LedgerMoney.LOOT_TAIL_SECONDS }

-- Money in: kind -> source, type. Money out: kind -> source, type. A kind that is not here gives "unknown".
local INCOME = {
    merchant = { "vendorSale", "income" },
    loot = { "loot", "loot" },
    trade = { "trade", "income" },
    mail = { "mailMoney", "income" },
}
local EXPENSE = {
    merchant = { "vendorPurchase", "expense" },
    trade = { "trade", "expense" },
}

local Tracker = {}
Tracker.__index = Tracker

local function text(value)
    if type(value) == "string" then
        return value
    end
    return tostring(value)
end

function Tracker:_Secret(value)
    return self._isSecret ~= nil and self._isSecret(value) == true
end

-- Count one skipped value or record.
function Tracker:_Skip()
    self._stats.skipped = self._stats.skipped + 1
end

-- Add one line to the debug ring. Does nothing if the debug setting is off.
function Tracker:_Ring(name, ...)
    if not self._debug() then
        return
    end
    local parts = {}
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        parts[#parts + 1] = self:_Secret(value) and "<secret>" or text(value)
    end
    local ring = self._ring
    ring.last = ring.last % LedgerMoney.RING_SIZE + 1
    ring[ring.last] = { time = self._now(), line = name .. (#parts > 0 and (" " .. table.concat(parts, " ")) or "") }
    ring.count = math.min(ring.count + 1, LedgerMoney.RING_SIZE)
end

-- Returns up to n of the last debug lines, oldest first.
function Tracker:DebugLines(n)
    local ring = self._ring
    local count = math.min(n or ring.count, ring.count)
    local lines = {}
    for i = count - 1, 0, -1 do
        local entry = ring[(ring.last - 1 - i) % LedgerMoney.RING_SIZE + 1]
        lines[#lines + 1] = string.format("%.3f %s", entry.time, entry.line)
    end
    return lines
end

-- Returns a copy of the counters: records, skipped, claimed, rejected, unpaired.
function Tracker:Stats()
    local copy = {}
    for name, value in pairs(self._stats) do
        copy[name] = value
    end
    return copy
end

function Tracker:_NewId(kind)
    self._counter = self._counter + 1
    return kind .. ":" .. self._counter
end

-- Returns the id of the open context of a kind (a loot tail counts as open), or nil.
function Tracker:Context(kind)
    local now = self._now()
    local open = self._open[kind]
    if open then
        return open.id
    end
    local tail = self._tail[kind]
    if tail and now <= tail.untilTime then
        return tail.id
    end
    return nil
end

-- Returns the kind and id of the context with the highest priority, or nil.
function Tracker:ActiveContext()
    for _, kind in ipairs(LedgerMoney.PRIORITY) do
        local id = self:Context(kind)
        if id then
            return kind, id
        end
    end
    return nil
end

-- Another module wrote a record for a change of this amount. The tracker then writes none for it.
-- direction is "in" or "out".
function Tracker:Claim(amount, direction)
    if type(amount) ~= "number" or amount <= 0 or (direction ~= "in" and direction ~= "out") then
        return false
    end
    self._claims[#self._claims + 1] = {
        amount = amount, direction = direction, untilTime = self._now() + LedgerMoney.CLAIM_SECONDS,
    }
    return true
end

-- Write a record. Returns true if the buffer took it.
function Tracker:_Write(fields)
    local character = self._character()
    if not character then
        self:_Skip()
        return false
    end
    fields.time = self._serverTime()
    fields.char = character
    local ok, message = self._buffer:Add(fields)
    if not ok then
        self._stats.rejected = self._stats.rejected + 1
        if self._report and not self._reported then
            self._reported = true
            self._report("a ledger record was rejected: " .. tostring(message))
        end
        return false
    end
    self._stats.records = self._stats.records + 1
    self:_Ring("record", fields.source, fields.type, fields.money, fields.ctx)
    return true
end

-- Write a record for a money change that has a context kind (not ah, not quest).
function Tracker:_WriteKind(kind, delta, ctx)
    local table_ = delta > 0 and INCOME or EXPENSE
    local pair = table_[kind]
    local source, recordType
    if pair then
        source, recordType = pair[1], pair[2]
    else
        source, recordType = "unknown", delta > 0 and "income" or "expense"
    end
    self:_Write({ source = source, type = recordType, money = math.abs(delta), ctx = ctx })
end

function Tracker:_WriteUnknown(delta, ctx)
    self:_Write({
        source = "unknown", type = delta > 0 and "income" or "expense", money = math.abs(delta), ctx = ctx,
    })
end

-- Take the best hint for a money change out of the hint list: a confirmed hint first, then the oldest.
function Tracker:_TakeHint(kinds)
    local now = self._now()
    local fresh = {}
    for _, hint in ipairs(self._hints) do
        if now - hint.time <= LedgerMoney.HINT_SECONDS then
            fresh[#fresh + 1] = hint
        end
    end
    self._hints = fresh
    local chosen
    for _, hint in ipairs(fresh) do
        if kinds[hint.kind] and not hint.paid then
            if hint.confirmed then
                chosen = hint
                break
            end
            chosen = chosen or hint
        end
    end
    return chosen
end

-- Write the money record of an Auction House hint: one record, with the real amount from the money change.
function Tracker:_WriteHint(hint, delta, ctx)
    hint.paid = true
    local fields = {
        money = math.abs(delta), item = hint.item, qty = hint.qty, ctx = hint.ctx or ctx,
        source = hint.kind == "buy" and "ahPurchase" or "ahDeposit",
        type = hint.kind == "buy" and "purchase" or "expense",
    }
    if fields.item == nil then
        fields.qty = nil
    end
    self:_Write(fields)
end

-- Try to label the money changes that wait in the hold list with the hints.
function Tracker:_ResolveHeld()
    for _, held in ipairs(self._held) do
        if not held.done and held.kind == "ah" and held.delta < 0 then
            local hint = self:_TakeHint({ buy = true, post = true })
            if hint then
                held.done = true
                self:_WriteHint(hint, held.delta, held.ctx)
            end
        end
    end
end

-- Write what a held change is when the hold time ends.
function Tracker:_FlushHeld(held)
    if held.done then
        return
    end
    held.done = true
    if held.kind == "mail" then
        -- No mail invoice claimed the money, so it is mail money.
        self:_WriteKind("mail", held.delta, held.ctx)
        return
    end
    self._stats.unpaired = self._stats.unpaired + 1
    self:_WriteUnknown(held.delta, held.ctx)
end

-- LedgerMail sets a function that gets each money gain in the mail context. It returns true if it wrote the records.
function Tracker:SetMailMatcher(matcher)
    self._mailMatcher = matcher
end

-- Returns the amounts of the mail gains that wait for a mail match (copper), oldest first.
function Tracker:HeldMail()
    local amounts = {}
    for _, held in ipairs(self._held) do
        if not held.done and held.kind == "mail" then
            amounts[#amounts + 1] = held.delta
        end
    end
    return amounts
end

-- LedgerMail wrote the records for a held mail gain of this amount. Returns true if there was one.
function Tracker:ReleaseHeldMail(amount)
    for _, held in ipairs(self._held) do
        if not held.done and held.kind == "mail" and held.delta == amount then
            held.done = true
            self._stats.claimed = self._stats.claimed + 1
            return true
        end
    end
    return false
end

-- Add a line to the debug ring for another module. Does nothing if the debug setting is off.
function Tracker:Note(name, ...)
    self:_Ring(name, ...)
end

function Tracker:_Hold(kind, delta, ctx)
    local held = { kind = kind, delta = delta, ctx = ctx, time = self._now() }
    self._held[#self._held + 1] = held
    self._after(LedgerMoney.QUEST_WINDOW_SECONDS, function()
        self:_FlushHeld(held)
        local keep = {}
        for _, other in ipairs(self._held) do
            if not other.done then
                keep[#keep + 1] = other
            end
        end
        self._held = keep
    end)
end

-- Find and remove a claim for this change. Returns true if there was one.
function Tracker:_Claimed(delta)
    local now = self._now()
    local direction = delta > 0 and "in" or "out"
    for i, claim in ipairs(self._claims) do
        if now > claim.untilTime then
            table.remove(self._claims, i)
            return self:_Claimed(delta)
        elseif claim.amount == math.abs(delta) and claim.direction == direction then
            table.remove(self._claims, i)
            return true
        end
    end
    return false
end

-- Find a quest reward event of this amount. Returns its context id and removes it, or nil.
function Tracker:_TakeQuest(delta)
    if delta <= 0 then
        return nil
    end
    local now = self._now()
    for i, quest in ipairs(self._quests) do
        if now - quest.time > LedgerMoney.QUEST_WINDOW_SECONDS then
            table.remove(self._quests, i)
            return self:_TakeQuest(delta)
        elseif quest.amount == delta then
            table.remove(self._quests, i)
            return quest.ctx
        end
    end
    return nil
end

-- One money change.
function Tracker:_Process(delta)
    self:_Ring("delta", delta)
    if self:_Claimed(delta) then
        self._stats.claimed = self._stats.claimed + 1
        return
    end
    local questCtx = self:_TakeQuest(delta)
    if questCtx then
        self:_Write({ source = "quest", type = "income", money = delta, ctx = questCtx })
        return
    end
    local kind, ctx = self:ActiveContext()
    if kind == "ah" then
        if delta < 0 then
            local hint = self:_TakeHint({ buy = true, post = true })
            if hint then
                self:_WriteHint(hint, delta, ctx)
            else
                -- The event of the purchase or post can come after the money change.
                self:_Hold("ah", delta, ctx)
            end
        else
            self:_WriteUnknown(delta, ctx)
        end
    elseif kind == "mail" and delta > 0 and self._mailMatcher then
        -- The mail module may know this money (an invoice). Its inbox update can come after the money change.
        if self._mailMatcher(delta) then
            self._stats.claimed = self._stats.claimed + 1
        else
            self:_Hold("mail", delta, ctx)
        end
    elseif kind then
        self:_WriteKind(kind, delta, ctx)
    elseif delta > 0 then
        -- A quest reward event can follow. Wait for it.
        self:_Hold("none", delta, self:_NewId("unknown"))
    else
        self:_WriteUnknown(delta, self:_NewId("unknown"))
    end
end

function Tracker:_OnMoney()
    self:_Ring("PLAYER_MONEY")
    local money = self._getMoney()
    if self:_Secret(money) or type(money) ~= "number" then
        self:_Skip()
        self._last = nil
        return
    end
    local previous = self._last
    self._last = money
    if previous == nil or money == previous then
        return
    end
    self:_Process(money - previous)
end

function Tracker:_Open(kind)
    self._tail[kind] = nil
    self._open[kind] = { id = self:_NewId(kind) }
end

function Tracker:_Close(kind)
    local open = self._open[kind]
    self._open[kind] = nil
    local tail = TAILS[kind]
    if open and tail then
        self._tail[kind] = { id = open.id, untilTime = self._now() + tail }
    end
end

function Tracker:_OnQuest(questID, _, moneyReward)
    if self:_Secret(moneyReward) or self:_Secret(questID) then
        self:_Skip()
        return
    end
    if type(moneyReward) ~= "number" or moneyReward <= 0 then
        return
    end
    local ctx = self:_NewId("quest")
    -- The money change can come first. It waits in the hold list.
    for _, held in ipairs(self._held) do
        if not held.done and held.kind == "none" and held.delta == moneyReward then
            held.done = true
            self:_Write({ source = "quest", type = "income", money = moneyReward, ctx = ctx })
            return
        end
    end
    self._quests[#self._quests + 1] = { amount = moneyReward, time = self._now(), ctx = ctx }
end

-- A call to buy or post that Flipside made. The arguments are the ones of the AuctionClient call.
function Tracker:_OnCall(name, ...)
    local deps = self._deps
    local hint
    if name == "ConfirmCommodityPurchase" then
        local itemID, quantity = ...
        hint = { kind = "buy", item = deps.itemKey(itemID, true), qty = quantity }
    elseif name == "BuyItemAuction" then
        local auctionID = ...
        local info = deps.auctionInfo and deps.auctionInfo(auctionID)
        hint = { kind = "buy", auctionID = auctionID }
        if type(info) == "table" then
            hint.item = deps.itemKey(info.itemLink, false)
            hint.qty = type(info.quantity) == "number" and info.quantity or nil
        end
    elseif name == "PostItem" or name == "ConfirmPostItem" or name == "PostCommodity"
        or name == "ConfirmPostCommodity" then
        local bag, slot, duration, quantity, bid, buyout = ...
        -- A multi-stack post (TBC) gives one post hint and one created event for each stack.
        local stacks = (name == "PostItem" or name == "ConfirmPostItem") and select(9, ...) or 1
        stacks = (type(stacks) == "number" and stacks >= 1) and math.floor(stacks) or 1
        local commodity = name == "PostCommodity" or name == "ConfirmPostCommodity"
        if commodity then
            buyout = type(bid) == "number" and type(quantity) == "number" and bid * quantity or nil
        end
        hint = {
            kind = "post", qty = quantity, buyout = buyout, stacks = stacks,
            item = deps.itemKey(deps.bagLink and deps.bagLink(bag, slot), commodity),
            deposit = deps.deposit and deps.deposit(bag, slot, duration, quantity, commodity) or nil,
        }
        -- A confirm call replaces the post call of the same post.
        local keep = {}
        for _, other in ipairs(self._hints) do
            if not (other.kind == "post" and not other.posted and not other.paid) then
                keep[#keep + 1] = other
            end
        end
        self._hints = keep
    else
        return
    end
    hint.time, hint.seen = self._now(), {}
    hint.ctx = self:Context("ah")
    self._hints[#self._hints + 1] = hint
    for _ = 2, hint.kind == "post" and hint.stacks or 1 do
        local copy = {}
        for k, v in pairs(hint) do
            copy[k] = v
        end
        copy.seen = {}
        self._hints[#self._hints + 1] = copy
    end
    self:_Ring("call", name)
    self:_ResolveHeld()
end

-- A purchase event: the first fresh buy hint that has not seen this event takes it, or a new hint starts.
-- The event confirms the hint and can add the item. The hint stays after its money change, so a later event
-- of the same purchase finds it and makes no second hint.
function Tracker:_OnPurchase(event, auctionID, itemID, quantity)
    self:_Ring(event, auctionID, itemID, quantity)
    if self:_Secret(auctionID) or self:_Secret(itemID) or self:_Secret(quantity) then
        self:_Skip()
        return
    end
    local now = self._now()
    local found
    for _, hint in ipairs(self._hints) do
        if hint.kind == "buy" and now - hint.time <= LedgerMoney.HINT_SECONDS and not hint.seen[event]
            and (auctionID == nil or hint.auctionID == nil or hint.auctionID == auctionID) then
            found = hint
            break
        end
    end
    if not found then
        found = { kind = "buy", time = now, ctx = self:Context("ah"), auctionID = auctionID, seen = {} }
        self._hints[#self._hints + 1] = found
    end
    found.seen[event], found.confirmed = true, true
    if itemID and not found.item then
        found.item = self._deps.itemKey(itemID, true)
        found.qty = type(quantity) == "number" and quantity or found.qty
    end
    self:_ResolveHeld()
end
-- A post event: write the post record from the hint or from the auction data.
function Tracker:_OnCreated(auctionID)
    self:_Ring("AUCTION_CREATED", auctionID)
    if self:_Secret(auctionID) then
        self:_Skip()
        return
    end
    local deps = self._deps
    local hint
    for _, other in ipairs(self._hints) do
        if other.kind == "post" and not other.posted then
            hint = other
            break
        end
    end
    if not hint then
        hint = { kind = "post", time = self._now(), ctx = self:Context("ah") }
        local info = deps.auctionInfo and deps.auctionInfo(auctionID)
        if type(info) == "table" then
            hint.item = deps.itemKey(info.itemLink, false)
            hint.qty = type(info.quantity) == "number" and info.quantity or nil
            hint.buyout = type(info.buyoutAmount) == "number" and info.buyoutAmount or nil
        end
        self._hints[#self._hints + 1] = hint
    end
    hint.confirmed, hint.posted = true, true
    local fields = {
        source = "ahPost", type = "post", money = 0, item = hint.item, qty = hint.item and hint.qty or nil,
        buyout = hint.buyout, deposit = hint.deposit, ctx = hint.ctx or self:Context("ah") or self:_NewId("ahPost"),
    }
    hint.ctx = fields.ctx
    self:_Write(fields)
    self:_ResolveHeld()
end

-- deps: bus, buffer, getMoney, now (seconds, GetTime), serverTime, character (function), after, itemKey(input,
-- isCommodity), setting(key). Optional: isSecret, client (AuctionClient: OnCall, OpenEvent, CloseEvent, BuyEvents,
-- PostedEvent), auctionInfo(auctionID), bagLink(bag, slot), deposit(bag, slot, duration, quantity, isCommodity),
-- commodityMarket (flag), report.
function LedgerMoney.Attach(deps)
    local tracker = setmetatable({
        _deps = deps,
        _buffer = deps.buffer,
        _getMoney = deps.getMoney,
        _now = deps.now,
        _serverTime = deps.serverTime,
        _character = deps.character,
        _after = deps.after,
        _isSecret = type(deps.isSecret) == "function" and deps.isSecret or nil,
        _report = deps.report,
        _debug = function()
            return deps.setting("ledger.debug") == true
        end,
        _ring = { last = 0, count = 0 },
        _stats = { records = 0, skipped = 0, claimed = 0, rejected = 0, unpaired = 0 },
        _counter = 0,
        _open = {},
        _tail = {},
        _hints = {},
        _held = {},
        _claims = {},
        _quests = {},
    }, Tracker)

    local bus = deps.bus
    local function listen(event, handler)
        if LedgerMoney.RESTRICTED[event] then
            error("event " .. event .. " is restricted", 2)
        end
        bus:Subscribe(event, OWNER, function(_, ...)
            tracker:_Ring(event)
            handler(...)
        end)
    end

    for kind, events in pairs(WINDOWS) do
        listen(events[1], function()
            tracker:_Open(kind)
        end)
        listen(events[2], function()
            tracker:_Close(kind)
        end)
    end
    listen("QUEST_TURNED_IN", function(...)
        tracker:_OnQuest(...)
    end)
    bus:Subscribe("PLAYER_MONEY", OWNER, function()
        tracker:_OnMoney()
    end)

    local client = deps.client
    if client then
        local openEvent, closeEvent = client.OpenEvent and client.OpenEvent(), client.CloseEvent and client.CloseEvent()
        if openEvent and closeEvent then
            listen(openEvent, function()
                tracker:_Open("ah")
            end)
            listen(closeEvent, function()
                tracker:_Close("ah")
            end)
        end
        local buyEvents = client.BuyEvents and client.BuyEvents()
        if buyEvents then
            listen(buyEvents.commoditySucceeded, function()
                tracker:_OnPurchase(buyEvents.commoditySucceeded)
            end)
            listen(buyEvents.itemCompleted, function(auctionID)
                tracker:_OnPurchase(buyEvents.itemCompleted, auctionID)
            end)
        end
        local posted = client.PostedEvent and client.PostedEvent()
        if posted then
            listen(posted, function(auctionID)
                tracker:_OnCreated(auctionID)
            end)
        end
        if client.OnCall then
            client.OnCall(function(name, ...)
                tracker:_OnCall(name, ...)
            end)
        end
    end
    if deps.commodityMarket then
        listen("COMMODITY_PURCHASED", function(itemID, quantity)
            tracker:_OnPurchase("COMMODITY_PURCHASED", nil, itemID, quantity)
        end)
    end

    local money = deps.getMoney()
    if not tracker:_Secret(money) and type(money) == "number" then
        tracker._last = money
    end
    return tracker
end
