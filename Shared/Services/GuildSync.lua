local _, ns = ...

-- Price sharing (SPEC 3.5): send a summary of the local scan data, answer requests, and keep the
-- data of other members in a separate store. There are two channels, each with its own setting: the guild
-- and the group (raid or party). Both settings are off by default (D7, D14). If a setting is off, the module
-- sends nothing on that channel and ignores the data that it receives there. Both channels use one send queue.

local GuildSync = {}
ns.GuildSync = GuildSync

-- A member answers a request only if its last scan is more than this many seconds newer than the request.
GuildSync.REQUEST_MARGIN = 60
GuildSync.REPLY_DELAY_MIN = 2
GuildSync.REPLY_DELAY_MAX = 12
-- A reply to a request in the group waits a random time between 0 and this many seconds.
GuildSync.GROUP_REPLY_JITTER = 5
-- After a roster change, the group request waits this many seconds for the roster to settle.
GuildSync.JOIN_DEBOUNCE = 5
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

-- deps: isEnabled(), isInGuild(), selfName() (full Name-Realm of the player), selfAliases() (optional, a list of
-- other spellings of the own name), realm(), scope (text),
-- localStore (scan store), guildStore (GuildPriceStore), queue (GuildSyncQueue), clock() (server time),
-- after(seconds, fn), random(low, high), registerPrefix(prefix), runJob(name, fn) (fn gets the job or nil),
-- lastScan() (server time of the last full scan, or nil), log(level, format, ...) (optional),
-- marker (optional saved table { time, done } of the last own share),
-- isGroupEnabled() (optional, the group setting; without it the group channel is off),
-- groupChannel() (optional, "RAID" in a raid, "PARTY" in a party, else nil).
-- The queue channel of a message is "guild" or "group". The owner of the queue maps "group" to the chat type.
local KINDS = { "guild", "group" }

function GuildSync.New(deps)
    local self = setmetatable({ deps = deps }, Sync)
    self.stats = { lastSend = nil, lastReceive = nil, lastRequest = nil, sent = 0, received = 0 }
    self.senders = {}
    self.dataSeq = { guild = 0, group = 0 }
    self.replyPending = {}
    self.lastReply = {}
    self.requested = {}
    self.wasInGroup = false
    self.rosterToken = 0
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
    queue.onDrop = function(text, reason, result, channel)
        if previousDrop then
            previousDrop(text, reason, result, channel)
        end
        self:OnQueueDrop(text, reason, channel)
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

-- True if the setting of the channel is on. The kind is "guild" or "group".
function Sync:_KindEnabled(kind)
    if kind == "guild" then
        return self.deps.isEnabled() == true
    end
    return self.deps.isGroupEnabled ~= nil and self.deps.isGroupEnabled() == true
end

-- True if one of the two settings is on.
function Sync:IsEnabled()
    return self:_KindEnabled("guild") or self:_KindEnabled("group")
end

-- Return the chat type for the group ("RAID" or "PARTY"), or nil if the player is not in a group.
function Sync:GroupChannel()
    local find = self.deps.groupChannel
    return find and find() or nil
end

-- Return nil if the channel can send now, or the reason: "disabled", "not-in-guild" or "not-in-group".
function Sync:_Closed(kind)
    if not self:_KindEnabled(kind) then
        return "disabled"
    end
    if kind == "guild" then
        return not self.deps.isInGuild() and "not-in-guild" or nil
    end
    return not self:GroupChannel() and "not-in-group" or nil
end

-- Return the list of open channels, or an empty list and the reason. With only (a kind), look at that one.
function Sync:_OpenKinds(only)
    local open, reasons = {}, {}
    for _, kind in ipairs(KINDS) do
        if not only or only == kind then
            reasons[kind] = self:_Closed(kind)
            if not reasons[kind] then
                open[#open + 1] = kind
            end
        end
    end
    if #open > 0 then
        return open
    end
    -- The guild reason comes first, but a group reason is better when the guild setting is off.
    local reason = reasons.guild
    if reason == nil or (reason == "disabled" and reasons.group) then
        reason = reasons.group
    end
    return open, reason
end

-- Register the addon prefix with the client. Do this once, and only when sharing is on.
function Sync:EnsureRegistered()
    if not self.registered and self:IsEnabled() then
        self.registered = true
        self.deps.registerPrefix(ns.GuildSyncCodec.PREFIX)
    end
end

-- Call this after the player turns a setting on or off.
function Sync:OnSettingChanged()
    if not self:IsEnabled() then
        self.deps.queue:Clear()
        self.share = nil
        self:_Log("info", "sharing off (guild and group)")
        return
    end
    self:EnsureRegistered()
    local share = self.share
    for _, kind in ipairs(KINDS) do
        if not self:_KindEnabled(kind) then
            self.deps.queue:RemoveIf(function(_, channel)
                return channel == kind
            end)
            if share then
                share.channels[kind] = nil
            end
        end
    end
    if share and next(share.channels) == nil then
        self.share = nil
    end
    self:_Log("info", "sharing on: guild %s, group %s", self:_KindEnabled("guild") and "on" or "off",
        self:_KindEnabled("group") and "on" or "off")
end

local function fullName(self, name)
    name = tostring(name or "")
    if not string.find(name, "-", 1, true) then
        name = name .. "-" .. tostring(self.deps.realm() or "")
    end
    return (string.lower((string.gsub(name, "%s", ""))))
end

-- True if the sender is the player: the sender matches selfName() or one of selfAliases() (other spellings of the
-- own name, for example the name alone or "Name Surname"). All texts go through the same fullName rule.
local function isSelf(self, sender)
    local wanted = fullName(self, sender)
    if wanted == fullName(self, self.deps.selfName()) then
        return true
    end
    for _, alias in ipairs(self.deps.selfAliases and self.deps.selfAliases() or {}) do
        if wanted == fullName(self, alias) then
            return true
        end
    end
    return false
end

-- Handle CHAT_MSG_ADDON. The bus gives the event name first.
-- The chat type "GUILD" is the guild channel. "RAID" and "PARTY" are the group channel (the home group only).
function Sync:OnAddon(_, prefix, text, channel, sender)
    local codec = ns.GuildSyncCodec
    local kind = channel == "GUILD" and "guild" or ((channel == "RAID" or channel == "PARTY") and "group" or nil)
    if prefix ~= codec.PREFIX or not kind then
        return
    end
    if not self:_KindEnabled(kind) then
        self:_Log("debug", "drop disabled %s message from %s", kind, tostring(sender))
        return
    end
    if isSelf(self, sender) then
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
        self:_OnRequest(sender, parsed, kind)
    else
        self:_OnData(sender, parsed, kind)
    end
end

function Sync:_OnData(sender, chunk, kind)
    self.dataSeq[kind] = self.dataSeq[kind] + 1
    -- A member in the guild and in the group sends the same set on both channels: keep the two apart.
    local set = self.assembler:Add(kind == "guild" and sender or (sender .. "|group"), chunk)
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
    self:_Log("info", "receive from %s (%s): %d items, %d kept, %d old or invalid, %d unreadable", sender, kind,
        #entries, kept, old, skipped)
end

-- Answer a request after a random delay, if this member has newer data and nobody else answered on the channel.
-- The reply goes to the channel of the request only. In the group the delay is 0 to GROUP_REPLY_JITTER seconds,
-- so in a raid not all members answer at the same time. A set that arrives from another member first cancels it.
function Sync:_OnRequest(sender, request, kind)
    local deps = self.deps
    local last = deps.lastScan and deps.lastScan() or nil
    if not last or last <= request.newest + GuildSync.REQUEST_MARGIN then
        self:_Log("info", "request from %s (%s): no newer data", sender, kind)
        return
    end
    local now = deps.clock()
    local lastReply = self.lastReply[kind]
    if self.replyPending[kind] or (lastReply and now - lastReply < GuildSync.REPLY_COOLDOWN) then
        self:_Log("info", "request from %s (%s): reply already planned or recent", sender, kind)
        return
    end
    self.replyPending[kind] = true
    local seq = self.dataSeq[kind]
    local delay
    if kind == "group" then
        delay = deps.random(0, GuildSync.GROUP_REPLY_JITTER)
    else
        delay = deps.random(GuildSync.REPLY_DELAY_MIN, GuildSync.REPLY_DELAY_MAX)
    end
    self:_Log("info", "request from %s (%s): reply in %s s", sender, kind, delay)
    deps.after(delay, function()
        self.replyPending[kind] = false
        if seq ~= self.dataSeq[kind] then
            self:_Log("info", "reply cancelled (%s): someone answered", kind)
            return
        end
        self.lastReply[kind] = deps.clock()
        self:SendSet("reply", kind)
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

-- Return the open channels of the share (a list of kinds). The list is empty if nothing can go out now.
function Sync:_ShareKinds(share)
    local kinds = {}
    for _, kind in ipairs(KINDS) do
        if share.channels[kind] and not self:_Closed(kind) then
            kinds[#kinds + 1] = kind
        end
    end
    return kinds
end

-- True if a message of the share still waits in the queue on one of its channels.
function Sync:_Queued(message)
    for _, kind in ipairs(message.kinds) do
        if self.deps.queue:Has(message.text, kind) then
            return true
        end
    end
    return false
end

-- Count the items in the text of a data message.
local function countItems(text)
    local _, slashes = string.gsub(text, "/", "")
    return slashes + 1
end

-- Remove from the share the messages that left the queue, and count their items as sent.
-- The messages leave the queue in order, so the sent ones are always at the start of share.out.
function Sync:_Prune(share)
    while share.out[1] and not self:_Queued(share.out[1]) do
        local message = table.remove(share.out, 1)
        share.sentItems = share.sentItems + message.n
        message.set.sent = message.set.sent + message.n
    end
end

-- Build the next set of the share and add its messages to the queue, one time for each open channel.
function Sync:_PushNextSet(share, kinds)
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
        share.out[#share.out + 1] = { text = text, n = countItems(text), set = set, kinds = kinds }
        texts[#texts + 1] = text
    end
    for _, text in ipairs(texts) do
        for _, kind in ipairs(kinds) do
            self.deps.queue:Push(text, false, kind)
        end
    end
end

-- Add sets of the share to the queue while the queue has room. The queue calls this before each step.
-- A throttle wait or a pause stops the share: the cursor stays where it is, and no item is dropped.
function Sync:_Feed()
    local share = self.share
    if not share or self.feeding or share.paused then
        return
    end
    local kinds = self:_ShareKinds(share)
    if #kinds == 0 then
        return
    end
    local queue = self.deps.queue
    self.feeding = true
    while share.pos <= #share.entries and queue:Pending() < GuildSync.QUEUE_TARGET and not queue:Waiting() do
        self:_PushNextSet(share, kinds)
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
function Sync:OnQueueDrop(text, reason, channel)
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
    self:_Log("warn", "share paused for %d s: the %s channel throttles", GuildSync.THROTTLE_PAUSE,
        tostring(channel or "guild"))
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
-- With grew (the new share has a channel that the old one has not), no item counts as sent.
function Sync:_MergeShare(old, entries, grew)
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
    for i = 1, grew and 0 or pos - 1 do
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

-- Start (or merge into the running) share of the newest known prices, for the channels in kinds.
-- A merged share keeps the channels of the old share and adds the new ones.
function Sync:_StartShare(why, entries, kinds)
    local old, skipped = self.share, 0
    local channels, grew = {}, false
    for _, kind in ipairs(kinds) do
        channels[kind] = true
        grew = grew or not (old and old.channels[kind])
    end
    if old then
        for kind in pairs(old.channels) do
            channels[kind] = true
        end
        entries, skipped = self:_MergeShare(old, entries, grew)
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
        paused = false, channels = channels }
    self.marker.time, self.marker.done = now, false
    self.stats.lastSend = now
    self.stats.sent = self.stats.sent + #entries
    self:_Log("info", "send %s: %d items to share, %d already sent (%s)", tostring(why), #entries, skipped,
        table.concat(kinds, "+"))
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
-- Return true if the work started. One build serves all open channels. With only (a kind), the share goes to that
-- channel only. The job yields between items, so the reading is not inside a pcall (Lua 5.1 cannot yield there).
function Sync:SendSet(why, only)
    local kinds, blocked = self:_OpenKinds(only)
    if #kinds == 0 then
        self:_Log("info", "send %s skipped: %s", tostring(why), tostring(blocked))
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
        local kinds2, blocked2 = self:_OpenKinds(only)
        if #kinds2 == 0 then
            self:_Log("info", "send %s skipped: %s", tostring(why), tostring(blocked2))
            return
        end
        self:_StartShare(why, entries, kinds2)
    end)
    return true
end

-- Send a request for newer data to the open channels (or to the channel only). Without force, a recent request on
-- a channel blocks a new one on that channel. Return true and the list of channels, or false and the reason.
function Sync:SendRequest(force, only)
    local open, blocked = self:_OpenKinds(only)
    if #open == 0 then
        self:_Log("info", "request skipped: %s", tostring(blocked))
        return false, blocked
    end
    local now = self.deps.clock()
    local kinds = {}
    for _, kind in ipairs(open) do
        local before = self.requested[kind]
        if force or not before or now - before >= GuildSync.REQUEST_COOLDOWN then
            kinds[#kinds + 1] = kind
        end
    end
    if #kinds == 0 then
        return false, "recent"
    end
    self:EnsureRegistered()
    local last = self.deps.lastScan and self.deps.lastScan() or 0
    local newest = math.max(last or 0, self.deps.guildStore:Newest())
    self.stats.lastRequest = now
    for _, kind in ipairs(kinds) do
        self.requested[kind] = now
        -- A request goes before the queued items of a long share.
        self.deps.queue:Push(ns.GuildSyncCodec.BuildRequest(self.deps.scope, newest), true, kind)
    end
    self:_Log("info", "request sent (%s): newest %d", table.concat(kinds, "+"), newest)
    return true, kinds
end

-- Handle GROUP_ROSTER_UPDATE. When the player joins a group (not in a group before, in a group now), send one
-- request to the group. The check waits JOIN_DEBOUNCE seconds after the last roster change, because the roster
-- changes often when a group forms. A change from a party to a raid is not a new join.
function Sync:OnGroupChanged()
    self.rosterToken = self.rosterToken + 1
    local token = self.rosterToken
    self.deps.after(GuildSync.JOIN_DEBOUNCE, function()
        if token ~= self.rosterToken then
            return
        end
        local inGroup = self:GroupChannel() ~= nil
        local joined = inGroup and not self.wasInGroup
        self.wasInGroup = inGroup
        if joined and self:_KindEnabled("group") then
            self:_Log("info", "joined a group: request")
            self:SendRequest(false, "group")
        end
    end)
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
    local group
    if self.deps.isGroupEnabled then
        group = { enabled = self:_KindEnabled("group"), channel = self:GroupChannel() }
    end
    return {
        group = group,
        shareSent = share and share.sentItems or nil,
        shareTotal = share and share.total or nil,
        sharePaused = share and share.paused or false,
        enabled = self:_KindEnabled("guild"),
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
    if status.group then
        table.insert(lines, 2, string.format("group sharing: %s, %s", status.group.enabled and "on" or "off",
            status.group.channel and ("channel " .. status.group.channel) or "not in a group"))
    end
    if status.shareTotal then
        lines[#lines + 1] = string.format("share running: %d of %d items sent%s", status.shareSent, status.shareTotal,
            status.sharePaused and " (paused, the channel throttles)" or "")
    end
    return lines
end
