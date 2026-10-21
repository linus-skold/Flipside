local _, ns = ...

-- Wire format of the guild price sharing (SPEC 3.5). Pure functions: no game call here.
--
-- A message is text with fields that ";" separates. The text uses only digits, letters and these marks: ; , : / . - _
-- Field 1 is the protocol version. Field 2 is the kind: "Q" (request) or "D" (data chunk).
--   Q: <version>;Q;<scope>;<newest>
--   D: <version>;D;<scope>;<setId>;<index>;<total>;<time>;<items>
--   items = item/item/...    item = key,min,market,qty,age    (age = seconds before <time>; empty for 0)
-- <scope> is the region, the realm and the ruleset (D22). <time> is the scan time of the newest item.

local Codec = {}
ns.GuildSyncCodec = Codec

Codec.VERSION = 1
Codec.PREFIX = "Flipside"
-- The client limit for the text of one addon message is 255 bytes. This value leaves room for the prefix.
Codec.MAX_BYTES = 240
Codec.MAX_CHUNKS = 100
-- A receiver drops a set when no new chunk arrives for this many seconds. It covers the longest throttle wait.
Codec.IDLE_SECONDS = 180

local MAX_DIGITS = 12
local MAX_KEY = 60
-- Space that "999;999" (index and total) needs in a data chunk.
local INDEX_RESERVE = #"999;999"

local function split(text, sep)
    local parts = {}
    local start = 1
    while true do
        local at = string.find(text, sep, start, true)
        if not at then
            parts[#parts + 1] = string.sub(text, start)
            return parts
        end
        parts[#parts + 1] = string.sub(text, start, at - 1)
        start = at + 1
    end
end

local function toNumber(text)
    if type(text) ~= "string" or not string.match(text, "^%d+$") or #text > MAX_DIGITS then
        return nil
    end
    return tonumber(text)
end

local function cleanPart(text)
    text = tostring(text or "")
    if text == "" then
        return "_"
    end
    return (string.gsub(text, "[^%w_%-]", "_"))
end

-- Return the scope text for a region, a realm (can be nil) and a ruleset.
function Codec.ScopeKey(region, realm, ruleset)
    return cleanPart(region) .. "." .. cleanPart(realm) .. "." .. cleanPart(ruleset)
end

-- Return the text of a request. newest is the newest scan time that the sender has.
function Codec.BuildRequest(scope, newest)
    return table.concat({ Codec.VERSION, "Q", scope, string.format("%.0f", newest or 0) }, ";")
end

local function encodeItem(entry, headerTime)
    local age = headerTime - entry.time
    return string.format("%s,%.0f,%.0f,%.0f,%s", entry.key, entry.min, entry.market, entry.qty,
        age > 0 and string.format("%.0f", age) or "")
end

-- Return the data chunks for a list of entries { key, min, market, qty, time }. Each text is at most MAX_BYTES.
-- setId is a positive integer. Return an empty list when there is nothing to send.
-- Return nil and a message when one item does not fit in a chunk.
function Codec.BuildSet(scope, setId, entries)
    if #entries == 0 then
        return {}
    end
    local headerTime = 0
    for _, entry in ipairs(entries) do
        if entry.time > headerTime then
            headerTime = entry.time
        end
    end
    local head = table.concat({ Codec.VERSION, "D", scope, string.format("%.0f", setId) }, ";") .. ";"
    local timeText = string.format("%.0f", headerTime)
    local budget = Codec.MAX_BYTES - (#head + INDEX_RESERVE + 1 + #timeText + 1)
    local bodies, current, size = {}, {}, 0
    for _, entry in ipairs(entries) do
        local text = encodeItem(entry, headerTime)
        local extra = #text + (#current > 0 and 1 or 0)
        if #text > budget then
            return nil, "item does not fit in a message"
        end
        if size + extra > budget then
            bodies[#bodies + 1] = table.concat(current, "/")
            current, size, extra = {}, 0, #text
        end
        current[#current + 1] = text
        size = size + extra
    end
    bodies[#bodies + 1] = table.concat(current, "/")
    if #bodies > Codec.MAX_CHUNKS then
        return nil, "too many messages"
    end
    local messages = {}
    for index, body in ipairs(bodies) do
        messages[index] = string.format("%s%d;%d;%s;%s", head, index, #bodies, timeText, body)
    end
    return messages
end

-- Read a message. Return a table, or nil plus a reason: "version" or "malformed".
-- Request: { kind = "Q", scope, newest }.
-- Data chunk: { kind = "D", scope, setId, index, total, time, items } (items is the unread text).
function Codec.Parse(text)
    if type(text) ~= "string" or #text > 255 then
        return nil, "malformed"
    end
    local fields = split(text, ";")
    if fields[1] ~= tostring(Codec.VERSION) then
        return nil, string.match(fields[1] or "", "^%d+$") and "version" or "malformed"
    end
    if fields[2] == "Q" and #fields == 4 then
        local newest = toNumber(fields[4])
        if fields[3] ~= "" and newest then
            return { kind = "Q", scope = fields[3], newest = newest }
        end
    elseif fields[2] == "D" and #fields == 8 then
        local setId, index = toNumber(fields[4]), toNumber(fields[5])
        local total, time = toNumber(fields[6]), toNumber(fields[7])
        if fields[3] ~= "" and setId and index and total and time and index >= 1 and index <= total
            and total <= Codec.MAX_CHUNKS then
            return { kind = "D", scope = fields[3], setId = setId, index = index, total = total, time = time,
                items = fields[8] }
        end
    end
    return nil, "malformed"
end

-- Read the items text of a chunk. Return a list of { key, min, market, qty, time } and the number of items skipped.
function Codec.ParseItems(text, headerTime)
    local list, skipped = {}, 0
    if text == "" then
        return list, 0
    end
    for _, part in ipairs(split(text, "/")) do
        local f = split(part, ",")
        local key = f[1]
        local min, market, qty = toNumber(f[2]), toNumber(f[3]), toNumber(f[4])
        local age = f[5] == "" and 0 or toNumber(f[5])
        if #f == 5 and key ~= "" and #key <= MAX_KEY and string.match(key, "^[%d:]+$") and min and market and qty
            and age and age <= headerTime then
            list[#list + 1] = { key = key, min = min, market = market, qty = qty, time = headerTime - age }
        else
            skipped = skipped + 1
        end
    end
    return list, skipped
end

local Assembler = {}
Assembler.__index = Assembler

-- Collect the chunks of the data sets of each sender. options: clock (seconds), idleSeconds (IDLE_SECONDS),
-- maxSenders (40), onDrop(sender, reason). A sender sends a long share as many small sets, one after the other.
-- A new set of a sender replaces its open set, so each set is accepted on its own.
function Codec.NewAssembler(options)
    options = options or {}
    return setmetatable({
        clock = options.clock,
        idle = options.idleSeconds or Codec.IDLE_SECONDS,
        maxSenders = options.maxSenders or 40,
        onDrop = options.onDrop,
        sets = {},
        count = 0,
    }, Assembler)
end

function Assembler:_Drop(sender, reason)
    if self.sets[sender] then
        self.sets[sender] = nil
        self.count = self.count - 1
        if self.onDrop then
            self.onDrop(sender, reason)
        end
    end
end

-- Drop each set whose last chunk is older than the idle time. Return the number of sets dropped.
function Assembler:Sweep()
    local now = self.clock()
    local stale = {}
    for sender, set in pairs(self.sets) do
        if now - set.seen > self.idle then
            stale[#stale + 1] = sender
        end
    end
    for _, sender in ipairs(stale) do
        self:_Drop(sender, "incomplete")
    end
    return #stale
end

-- Return the number of sets that wait for chunks.
function Assembler:Pending()
    return self.count
end

-- Add a parsed data chunk. Return the full set { sender, scope, time, parts } when the last chunk arrives.
function Assembler:Add(sender, chunk)
    self:Sweep()
    local set = self.sets[sender]
    if set and (set.setId ~= chunk.setId or set.total ~= chunk.total or set.scope ~= chunk.scope) then
        self:_Drop(sender, "replaced")
        set = nil
    end
    if not set then
        if self.count >= self.maxSenders then
            if self.onDrop then
                self.onDrop(sender, "busy")
            end
            return nil
        end
        set = { setId = chunk.setId, total = chunk.total, scope = chunk.scope, time = chunk.time, parts = {},
            have = 0, seen = self.clock() }
        self.sets[sender] = set
        self.count = self.count + 1
    end
    set.seen = self.clock()
    if not set.parts[chunk.index] then
        set.parts[chunk.index] = chunk.items
        set.have = set.have + 1
    end
    if set.have < set.total then
        return nil
    end
    self.sets[sender] = nil
    self.count = self.count - 1
    return { sender = sender, scope = set.scope, time = set.time, parts = set.parts, total = set.total }
end
