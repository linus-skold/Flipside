local _, ns = ...

-- Guild price sharing (SPEC 3.5): send a summary of the local scan data, answer requests, and keep the
-- data of guild members in a separate store. The setting is off by default (D7, D14). If it is off, the module
-- sends nothing and ignores all received data.

local GuildSync = {}
ns.GuildSync = GuildSync

-- A member answers a request only if its last scan is more than this many seconds newer than the request.
GuildSync.REQUEST_MARGIN = 60
GuildSync.REPLY_DELAY_MIN = 2
GuildSync.REPLY_DELAY_MAX = 12
GuildSync.REPLY_COOLDOWN = 600
GuildSync.REQUEST_COOLDOWN = 300
-- Items older than this are not shared.
GuildSync.MAX_AGE = 7 * 86400
-- A share goes out as small sets, one after the other. A set holds this many items (about 4 messages).
GuildSync.SET_ITEMS = 30
-- The sender adds a set to the queue only while fewer messages than this wait there.
GuildSync.QUEUE_TARGET = 10
-- After a message is dropped for throttle retries, the share waits this many seconds.
GuildSync.THROTTLE_PAUSE = 60
-- A build that did not end after this many seconds does not block a new one.
local BUILD_TIMEOUT = 300

local Sync = {}
Sync.__index = Sync

-- deps: isEnabled(), isInGuild(), selfName() (full Name-Realm of the player), realm(), scope (text),
-- localStore (scan store), guildStore (GuildPriceStore), queue (GuildSyncQueue), clock() (server time),
-- after(seconds, fn), random(low, high), registerPrefix(prefix), runJob(name, fn) (fn gets the job or nil),
-- lastScan() (server time of the last full scan, or nil), log(level, format, ...) (optional),
-- marker (optional saved table { time, done } of the last own share).
function GuildSync.New(deps)
    local self = setmetatable({ deps = deps }, Sync)
    self.stats = { lastSend = nil, lastReceive = nil, lastRequest = nil, lastReply = nil, sent = 0, received = 0 }
    self.senders = {}
    self.dataSeq = 0
    self.replyPending = false
    self.building = nil
    self.registered = false
    self.share = nil
    self.setId = 0
    self.marker = deps.marker or {}
    -- The queue asks for more messages when it has room, and tells about a message that it drops.
    local queue, previousDrop = deps.queue, deps.queue.onDrop
    queue.onSpace = function()
        self:_Feed()
    end
    queue.onDrop = function(text, reason, result)
        if previousDrop then
            previousDrop(text, reason, result)
        end
        self:OnQueueDrop(text, reason)
    end
    self.assembler = ns.GuildSyncCodec.NewAssembler({
        clock = deps.clock,
        onDrop = function(sender, reason)
            self:_Log("info", "drop %s set from %s", reason, sender)
        end,
    })
    return self
end

function Sync:_Log(level, fmt, ...)
    if self.deps.log then
        self.deps.log(level, fmt, ...)
    end
end

function Sync:IsEnabled()
    return self.deps.isEnabled() == true
end

-- Register the addon prefix with the client. Do this once, and only when sharing is on.
function Sync:EnsureRegistered()
    if not self.registered and self:IsEnabled() then
        self.registered = true
        self.deps.registerPrefix(ns.GuildSyncCodec.PREFIX)
    end
end

-- Call this after the player turns the setting on or off.
function Sync:OnSettingChanged()
    if self:IsEnabled() then
        self:EnsureRegistered()
        self:_Log("info", "guild sharing on")
    else
        self.deps.queue:Clear()
        self.share = nil
        self:_Log("info", "guild sharing off")
    end
end

local function fullName(self, name)
    name = tostring(name or "")
    if not string.find(name, "-", 1, true) then
        name = name .. "-" .. tostring(self.deps.realm() or "")
    end
    return (string.lower((string.gsub(name, "%s", ""))))
end

-- Handle CHAT_MSG_ADDON. The bus gives the event name first.
function Sync:OnAddon(_, prefix, text, channel, sender)
    local codec = ns.GuildSyncCodec
    if prefix ~= codec.PREFIX or channel ~= "GUILD" then
        return
    end
    if not self:IsEnabled() then
        self:_Log("debug", "drop disabled message from %s", tostring(sender))
        return
    end
    if fullName(self, sender) == fullName(self, self.deps.selfName()) then
        return
    end
    self.assembler:Sweep()
    local parsed, reason = codec.Parse(text)
    if not parsed then
        self:_Log("info", "drop %s message from %s", reason, tostring(sender))
        return
    end
    if parsed.scope ~= self.deps.scope then
        self:_Log("info", "drop key mismatch from %s (%s)", tostring(sender), parsed.scope)
        return
    end
    if parsed.kind == "Q" then
        self:_OnRequest(sender, parsed)
    else
        self:_OnData(sender, parsed)
    end
end

function Sync:_OnData(sender, chunk)
    self.dataSeq = self.dataSeq + 1
    local set = self.assembler:Add(sender, chunk)
    if not set then
        return
    end
    local codec, entries, skipped = ns.GuildSyncCodec, {}, 0
    for index = 1, set.total do
        local list, bad = codec.ParseItems(set.parts[index], set.time)
        skipped = skipped + bad
        for _, entry in ipairs(list) do
            entries[#entries + 1] = entry
        end
    end
    local kept, old = self.deps.guildStore:Merge(entries)
    self.stats.lastReceive = self.deps.clock()
    self.stats.received = self.stats.received + kept
    self.senders[sender] = true
    self:_Log("info", "receive from %s: %d items, %d kept, %d old or invalid, %d unreadable", sender, #entries, kept,
        old, skipped)
end

-- Answer a request after a random delay, if this member has newer data and nobody else answered.
function Sync:_OnRequest(sender, request)
    local deps = self.deps
    local last = deps.lastScan and deps.lastScan() or nil
    if not last or last <= request.newest + GuildSync.REQUEST_MARGIN then
        self:_Log("info", "request from %s: no newer data", sender)
        return
    end
    local now = deps.clock()
    if self.replyPending or (self.stats.lastReply and now - self.stats.lastReply < GuildSync.REPLY_COOLDOWN) then
        self:_Log("info", "request from %s: reply already planned or recent", sender)
        return
    end
    self.replyPending = true
    local seq = self.dataSeq
    local delay = deps.random(GuildSync.REPLY_DELAY_MIN, GuildSync.REPLY_DELAY_MAX)
    self:_Log("info", "request from %s: reply in %s s", sender, delay)
    deps.after(delay, function()
        self.replyPending = false
        if seq ~= self.dataSeq then
            self:_Log("info", "reply cancelled: someone answered")
            return
        end
        self.stats.lastReply = deps.clock()
        self:SendSet("reply")
    end)
end

local function sortEntries(entries)
    table.sort(entries, function(a, b)
        if a.time ~= b.time then
            return a.time > b.time
        end
        return a.key < b.key
    end)
end

-- Return all entries to share, newest first. There is no limit on the number. job can be nil.
-- For each item the newest record wins, from the local scans or the shared data. A tie keeps the first one
-- found: local, then shared. Each entry keeps its original scan time.
function Sync:_Collect(job)
    local now, byKey = self.deps.clock(), {}
    local store, guildStore = self.deps.localStore, self.deps.guildStore
    local function offer(key, min, market, qty, time)
        if type(key) == "string" and string.match(key, "^[%d:]+$") and type(time) == "number" and min and market
            and min > 0 and market > 0 and now - time <= GuildSync.MAX_AGE then
            local old = byKey[key]
            if not old or time > old.time then
                byKey[key] = { key = key, min = min, market = market, qty = qty or 0, time = time }
            end
        end
    end
    for _, key in ipairs(store:Keys()) do
        local record = store:Get(key)
        local latest = record and record.latest
        if latest then
            offer(key, latest.min, latest.market, latest.qty, latest.time)
        end
        if job then
            job:Checkpoint(1)
        end
    end
    if guildStore.Keys then
        for _, key in ipairs(guildStore:Keys()) do
            local entry = guildStore:Get(key)
            if entry then
                offer(key, entry.min, entry.market, entry.qty, entry.time)
            end
            if job then
                job:Checkpoint(1)
            end
        end
    end
    local entries = {}
    for _, entry in pairs(byKey) do
        entries[#entries + 1] = entry
    end
    sortEntries(entries)
    return entries
end

-- Why nothing can go out now: "disabled", "not-in-guild", or nil.
function Sync:_Blocked()
    if not self:IsEnabled() then
        return "disabled"
    end
    if not self.deps.isInGuild() then
        return "not-in-guild"
    end
end

-- Count the items in the text of a data message.
local function countItems(text)
    local _, slashes = string.gsub(text, "/", "")
    return slashes + 1
end

-- Remove from the share the messages that left the queue, and count their items as sent.
-- The messages leave the queue in order, so the sent ones are always at the start of share.out.
function Sync:_Prune(share)
    local queue = self.deps.queue
    while share.out[1] and not queue:Has(share.out[1].text) do
        local message = table.remove(share.out, 1)
        share.sentItems = share.sentItems + message.n
        message.set.sent = message.set.sent + message.n
    end
end

-- Build the next set of the share and add its messages to the queue.
function Sync:_PushNextSet(share)
    local from = share.pos
    local last = math.min(#share.entries, from + GuildSync.SET_ITEMS - 1)
    local slice = {}
    for i = from, last do
        slice[#slice + 1] = share.entries[i]
    end
    share.pos = last + 1
    self.setId = math.max(self.setId + 1, self.deps.clock())
    local messages, problem = ns.GuildSyncCodec.BuildSet(self.deps.scope, self.setId, slice)
    if not messages then
        self:_Log("warn", "share set skipped: %s", tostring(problem))
        share.sentItems = share.sentItems + #slice
        return
    end
    local set = { from = from, sent = 0 }
    local texts = {}
    for _, text in ipairs(messages) do
        share.out[#share.out + 1] = { text = text, n = countItems(text), set = set }
        texts[#texts + 1] = text
    end
    for _, text in ipairs(texts) do
        self.deps.queue:Push(text)
    end
end

-- Add sets of the share to the queue while the queue has room. The queue calls this before each step.
-- A throttle wait or a pause stops the share: the cursor stays where it is, and no item is dropped.
function Sync:_Feed()
    local share = self.share
    if not share or self.feeding or share.paused or self:_Blocked() then
        return
    end
    local queue = self.deps.queue
    self.feeding = true
    while share.pos <= #share.entries and queue:Pending() < GuildSync.QUEUE_TARGET and not queue:Waiting() do
        self:_PushNextSet(share)
    end
    self.feeding = false
    if share.pos > #share.entries then
        self:_Prune(share)
        if #share.out == 0 and self.share == share then
            self:_FinishShare(share)
        end
    end
end

function Sync:_FinishShare(share)
    self.share = nil
    self.marker.done = true
    self:_Log("info", "share finished: %d items", share.total)
end

-- The queue dropped a message. After throttle retries, go back to the start of its set, remove the queued
-- messages of the share, and wait. The sender builds those sets again, so no item is lost.
function Sync:OnQueueDrop(text, reason)
    local share = self.share
    if not share or reason ~= "retries" then
        return
    end
    local at
    for index, message in ipairs(share.out) do
        if message.text == text then
            at = index
            break
        end
    end
    if not at then
        return
    end
    local texts = {}
    for index, message in ipairs(share.out) do
        if index < at then
            share.sentItems = share.sentItems + message.n
            message.set.sent = message.set.sent + message.n
        else
            texts[message.text] = true
        end
    end
    local set = share.out[at].set
    self.deps.queue:RemoveIf(function(queued)
        return texts[queued] == true
    end)
    share.sentItems = share.sentItems - set.sent
    set.sent = 0
    share.out = {}
    share.pos = set.from
    share.paused = true
    self:_Log("warn", "share paused for %d s: the guild channel throttles", GuildSync.THROTTLE_PAUSE)
    self.deps.after(GuildSync.THROTTLE_PAUSE, function()
        if self.share == share then
            share.paused = false
            self:_Feed()
        end
    end)
end

-- Return entries (newest first) and the number of items that the share skips, for a new collection of
-- entries while the share runs. Sent items that did not change are skipped. The unsent items stay, and an
-- item in both lists gets the newest record. The messages of the old share leave the queue.
function Sync:_MergeShare(old, entries)
    self:_Prune(old)
    local pos = old.pos
    if old.out[1] then
        local texts = {}
        for _, message in ipairs(old.out) do
            texts[message.text] = true
        end
        self.deps.queue:RemoveIf(function(queued)
            return texts[queued] == true
        end)
        pos = old.out[1].set.from
    end
    local sent = {}
    for i = 1, pos - 1 do
        sent[old.entries[i].key] = old.entries[i]
    end
    local merged, index, skipped = {}, {}, 0
    for _, entry in ipairs(entries) do
        local was = sent[entry.key]
        if was and was.time == entry.time and was.min == entry.min and was.market == entry.market
            and was.qty == entry.qty then
            skipped = skipped + 1
        else
            merged[#merged + 1] = entry
            index[entry.key] = #merged
        end
    end
    for i = pos, #old.entries do
        local entry = old.entries[i]
        local at = index[entry.key]
        if not at then
            merged[#merged + 1] = entry
            index[entry.key] = #merged
        elseif entry.time > merged[at].time then
            merged[at] = entry
        end
    end
    sortEntries(merged)
    return merged, skipped
end

-- Start (or merge into the running) share of the newest known prices.
function Sync:_StartShare(why, entries)
    local old, skipped = self.share, 0
    if old then
        entries, skipped = self:_MergeShare(old, entries)
    end
    if #entries == 0 then
        self.share = nil
        if old then
            self.marker.done = true
        end
        self:_Log("info", "send %s: no data to share", tostring(why))
        return
    end
    local now = self.deps.clock()
    self.share = { entries = entries, pos = 1, out = {}, sentItems = skipped, total = #entries + skipped,
        paused = false }
    self.marker.time, self.marker.done = now, false
    self.stats.lastSend = now
    self.stats.sent = self.stats.sent + #entries
    self:_Log("info", "send %s: %d items to share, %d already sent", tostring(why), #entries, skipped)
    self:_Feed()
end

-- Start the share again if the last own share did not finish before the player logged out. Return true if
-- the work started.
function Sync:ResumeShare()
    if self.marker.done ~= false or self.share then
        return false, "nothing to resume"
    end
    self:_Log("info", "resume the share that did not finish (started %s)", tostring(self.marker.time))
    return self:SendSet("resume")
end

-- Build the share of the newest known prices (own scans and shared data). The sender adds the messages to
-- the queue in small sets when the queue has room. A running share takes the new items in (see _MergeShare).
-- Return true if the work started.
-- The job yields between items, so the reading is not inside a pcall (Lua 5.1 cannot yield there).
function Sync:SendSet(why)
    local blocked = self:_Blocked()
    if blocked then
        self:_Log("info", "send %s skipped: %s", tostring(why), blocked)
        return false, blocked
    end
    local now = self.deps.clock()
    if self.building and now - self.building < BUILD_TIMEOUT then
        return false, "busy"
    end
    self.building = now
    self:EnsureRegistered()
    self.deps.runJob("guild-sync-build", function(job)
        local entries = self:_Collect(job)
        self.building = nil
        -- The next lines do not yield, so the old share cannot change before the merge.
        local blocked2 = self:_Blocked()
        if blocked2 then
            self:_Log("info", "send %s skipped: %s", tostring(why), blocked2)
            return
        end
        self:_StartShare(why, entries)
    end)
    return true
end

-- Send a request for newer data. Without force, a recent request blocks a new one.
function Sync:SendRequest(force)
    local blocked = self:_Blocked()
    if blocked then
        self:_Log("info", "request skipped: %s", blocked)
        return false, blocked
    end
    local now = self.deps.clock()
    if not force and self.stats.lastRequest and now - self.stats.lastRequest < GuildSync.REQUEST_COOLDOWN then
        return false, "recent"
    end
    self:EnsureRegistered()
    local last = self.deps.lastScan and self.deps.lastScan() or 0
    local newest = math.max(last or 0, self.deps.guildStore:Newest())
    self.stats.lastRequest = now
    -- A request goes before the queued items of a long share.
    self.deps.queue:Push(ns.GuildSyncCodec.BuildRequest(self.deps.scope, newest), true)
    self:_Log("info", "request sent: newest %d", newest)
    return true
end

-- Handle Flipside.ScanFinished. Share the data after a scan that ended well or in part, except a page scan.
function Sync:OnScanFinished(_, summary)
    if type(summary) == "table" and (summary.result == "ok" or summary.result == "partial")
        and summary.mode ~= "page" then
        self:SendSet("scan")
    end
end

-- Return a table with the state for /flip sync.
function Sync:Status()
    local count = 0
    for _ in pairs(self.senders) do
        count = count + 1
    end
    local share = self.share
    if share then
        self:_Prune(share)
    end
    return {
        shareSent = share and share.sentItems or nil,
        shareTotal = share and share.total or nil,
        sharePaused = share and share.paused or false,
        enabled = self:IsEnabled(),
        inGuild = self.deps.isInGuild() == true,
        lastSend = self.stats.lastSend,
        lastReceive = self.stats.lastReceive,
        lastRequest = self.stats.lastRequest,
        senders = count,
        items = self.deps.guildStore:Count(),
        queued = self.deps.queue:Pending(),
        incoming = self.assembler:Pending(),
    }
end

local function ago(time, now)
    if not time then
        return "never"
    end
    local seconds = math.max(0, now - time)
    if seconds < 90 then
        return seconds .. " s ago"
    elseif seconds < 5400 then
        return math.floor(seconds / 60 + 0.5) .. " min ago"
    end
    return string.format("%.1f h ago", seconds / 3600)
end

-- Return the lines that /flip sync prints for a status table.
function GuildSync.StatusLines(status, now)
    local lines = {
        string.format("guild sharing: %s, %s", status.enabled and "on" or "off",
            status.inGuild and "in a guild" or "not in a guild"),
        string.format("last send %s, last receive %s, last request %s", ago(status.lastSend, now),
            ago(status.lastReceive, now), ago(status.lastRequest, now)),
        string.format("senders this session %d, shared items %d, queued messages %d, incoming sets %d",
            status.senders, status.items, status.queued, status.incoming),
    }
    if status.shareTotal then
        lines[#lines + 1] = string.format("share running: %d of %d items sent%s", status.shareSent, status.shareTotal,
            status.sharePaused and " (paused, the guild channel throttles)" or "")
    end
    return lines
end
