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
-- A build that did not end after this many seconds does not block a new one.
local BUILD_TIMEOUT = 300

local Sync = {}
Sync.__index = Sync

-- deps: isEnabled(), isInGuild(), selfName() (full Name-Realm of the player), realm(), scope (text),
-- localStore (scan store), guildStore (GuildPriceStore), queue (GuildSyncQueue), clock() (server time),
-- after(seconds, fn), random(low, high), registerPrefix(prefix), runJob(name, fn) (fn gets the job or nil),
-- lastScan() (server time of the last full scan, or nil), log(level, format, ...) (optional).
function GuildSync.New(deps)
    local self = setmetatable({ deps = deps }, Sync)
    self.stats = { lastSend = nil, lastReceive = nil, lastRequest = nil, lastReply = nil, sent = 0, received = 0 }
    self.senders = {}
    self.dataSeq = 0
    self.replyPending = false
    self.building = nil
    self.registered = false
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
        self.lastSet = nil
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

-- Return the entries to share, newest first, at most MAX_ITEMS. job can be nil.
-- For each item the newest record wins, from the local scans, the shared data or the carried entries
-- (a list of entries that an earlier set did not send). A tie keeps the first one found: local, shared, carried.
-- Each entry keeps its original scan time.
function Sync:_Collect(job, carry)
    local codec = ns.GuildSyncCodec
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
    for _, entry in ipairs(carry or {}) do
        offer(entry.key, entry.min, entry.market, entry.qty, entry.time)
    end
    local entries = {}
    for _, entry in pairs(byKey) do
        entries[#entries + 1] = entry
    end
    table.sort(entries, function(a, b)
        if a.time ~= b.time then
            return a.time > b.time
        end
        return a.key < b.key
    end)
    for i = #entries, codec.MAX_ITEMS + 1, -1 do
        entries[i] = nil
    end
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

-- Remove the messages of the last set that still wait in the queue. Return the entries of that set, or nil
-- if all its messages are gone. Messages of requests stay in the queue.
function Sync:_TakeUnsent()
    local last = self.lastSet
    self.lastSet = nil
    if not last then
        return nil
    end
    local removed = self.deps.queue:RemoveIf(function(text)
        return last.texts[text] == true
    end)
    if removed > 0 then
        return last.entries
    end
    return nil
end

-- Build the data set of the newest known prices (own scans and shared data) and queue it. Return true if the work started.
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
        -- Remove the unsent messages of the earlier set. Its items go into the new set, so nothing is lost.
        local carry = self:_TakeUnsent()
        local entries = self:_Collect(job, carry)
        self.building = nil
        local messages, problem = ns.GuildSyncCodec.BuildSet(self.deps.scope, self.deps.clock(), entries)
        if not messages then
            self:_Log("warn", "send %s failed: %s", tostring(why), tostring(problem))
            return
        end
        if #messages == 0 then
            self:_Log("info", "send %s: no data to share", tostring(why))
            return
        end
        local texts = {}
        for _, text in ipairs(messages) do
            texts[text] = true
            self.deps.queue:Push(text)
        end
        self.lastSet = { entries = entries, texts = texts }
        self.stats.lastSend = self.deps.clock()
        self.stats.sent = self.stats.sent + #entries
        self:_Log("info", "send %s: %d items in %d messages", tostring(why), #entries, #messages)
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
    self.deps.queue:Push(ns.GuildSyncCodec.BuildRequest(self.deps.scope, newest))
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
    return {
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
    return {
        string.format("guild sharing: %s, %s", status.enabled and "on" or "off",
            status.inGuild and "in a guild" or "not in a guild"),
        string.format("last send %s, last receive %s, last request %s", ago(status.lastSend, now),
            ago(status.lastReceive, now), ago(status.lastRequest, now)),
        string.format("senders this session %d, shared items %d, queued messages %d, incoming sets %d",
            status.senders, status.items, status.queued, status.incoming),
    }
end
