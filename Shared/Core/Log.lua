local _, ns = ...

-- The diagnostics log: a ring buffer of entries that SavedVariables keep. No call here raises an error.
local Log = {}
ns.Log = Log

local DEFAULT_CAP = 3000
local MIN_CAP, MAX_CAP = 100, 20000
local MAX_TEXT = 600
local MAX_CATEGORY = 24
local TRACE_ARGS, TRACE_ARG_LENGTH = 6, 40
local RANK = { debug = 1, info = 2, warn = 3, error = 4 }
local EVENT_PATTERN = "^[A-Z][A-Z0-9_]*$"

Log.LEVELS = { "debug", "info", "warn", "error" }
Log.DEFAULT_CAP = DEFAULT_CAP

local function newDB()
    return { version = 1, first = 1, last = 0, entries = {}, debug = false, trace = false, cap = DEFAULT_CAP }
end

local db = newDB()
Log.db = db
local listener

local function clampCap(value)
    if type(value) ~= "number" or value ~= value then
        return DEFAULT_CAP
    end
    return math.max(MIN_CAP, math.min(MAX_CAP, math.floor(value)))
end

-- Make a saved table safe to use. A broken ring is cleared.
local function normalise(saved)
    saved.version = 1
    saved.debug = saved.debug == true
    saved.trace = saved.trace == true
    saved.cap = clampCap(saved.cap)
    local valid = type(saved.entries) == "table" and type(saved.first) == "number" and type(saved.last) == "number"
        and saved.first >= 1 and saved.last >= saved.first - 1
    if not valid then
        saved.entries, saved.first, saved.last = {}, 1, 0
    end
end

local function trim(target)
    while target.last - target.first + 1 > target.cap do
        target.entries[target.first] = nil
        target.first = target.first + 1
    end
end

local function append(target, entry)
    target.last = target.last + 1
    target.entries[target.last] = entry
    trim(target)
end

-- Start using the saved table (the SavedVariable). Entries that were written before this call move into it.
-- Returns the table. The caller stores it in the global.
function Log.Attach(saved)
    if type(saved) ~= "table" then
        saved = {}
    end
    normalise(saved)
    local pending = db
    if saved ~= pending then
        for index = pending.first, pending.last do
            if pending.entries[index] then
                append(saved, pending.entries[index])
            end
        end
    end
    db = saved
    Log.db = saved
    trim(saved)
    return saved
end

local anchor

-- Returns whole seconds and milliseconds. GetTime gives the order inside a second.
local function now()
    local wall = type(time) == "function" and time() or 0
    local game = type(GetTime) == "function" and GetTime() or nil
    if type(game) ~= "number" then
        return wall, 0
    end
    anchor = anchor or (wall - game)
    local exact = anchor + game
    local seconds = math.floor(exact)
    return seconds, math.floor((exact - seconds) * 1000)
end

local function limit(text, length)
    if #text > length then
        return text:sub(1, length - 3) .. "..."
    end
    return text
end

local function record(category, level, text, forced)
    if RANK[level] == nil then
        level = "info"
    end
    if level == "debug" and not db.debug and not forced then
        return
    end
    category = limit(tostring(category or "core"), MAX_CATEGORY)
    text = limit((tostring(text):gsub("\r?\n", " | ")), MAX_TEXT)
    local seconds, ms = now()
    append(db, { time = seconds, ms = ms, level = level, category = category, text = text })
    if listener then
        pcall(listener)
    end
end

-- Add one entry. level is "debug", "info", "warn" or "error". A debug entry needs the debug setting.
function Log.Write(category, level, text)
    pcall(record, category, level, text)
end

local function safeArg(value)
    if type(value) == "number" or type(value) == "string" then
        return value
    end
    local ok, text = pcall(tostring, value)
    return ok and text or "?"
end

-- Add one entry with string.format. If the format fails, the entry holds the raw format text.
function Log.Writef(category, level, fmt, ...)
    pcall(function(...)
        if level == "debug" and not db.debug then
            return
        end
        local count = select("#", ...)
        local args = { ... }
        for index = 1, count do
            args[index] = safeArg(args[index])
        end
        local ok, text = pcall(string.format, tostring(fmt), unpack(args, 1, count))
        record(category, level, ok and text or tostring(fmt))
    end, ...)
end

-- Write the first entry of a session. info: version, flavour, client, build, interface, realm, character.
function Log.SessionMarker(info)
    info = type(info) == "table" and info or {}
    Log.Writef("core", "info", "session start: addon %s, flavour %s, client %s (build %s, interface %s), realm %s, "
        .. "character %s", info.version, info.flavour, info.client, info.build, info.interface, info.realm,
        info.character)
end

-- Record a game event with its shortened arguments. It does nothing unless the event trace is on.
function Log.Trace(event, ...)
    if not db.trace then
        return
    end
    pcall(function(...)
        if type(event) ~= "string" or not event:match(EVENT_PATTERN) then
            return
        end
        local count = select("#", ...)
        local parts = {}
        for index = 1, math.min(count, TRACE_ARGS) do
            local value = safeArg((select(index, ...)))
            parts[index] = limit(tostring(value), TRACE_ARG_LENGTH)
        end
        local text = event .. (#parts > 0 and (" " .. table.concat(parts, ", ")) or "")
        if count > TRACE_ARGS then
            text = text .. " (+" .. (count - TRACE_ARGS) .. ")"
        end
        record("event", "debug", text, true)
    end, ...)
end

function Log.IsDebug()
    return db.debug == true
end

function Log.SetDebug(on)
    db.debug = on == true
end

function Log.IsTrace()
    return db.trace == true
end

function Log.SetTrace(on)
    db.trace = on == true
end

function Log.GetCap()
    return db.cap
end

-- Set the entry cap (100 to 20000). The oldest entries go first.
function Log.SetCap(value)
    db.cap = clampCap(value)
    trim(db)
end

function Log.Count()
    return db.last - db.first + 1
end

-- Set the one function that runs after each new entry (nil clears it).
function Log.SetListener(fn)
    listener = type(fn) == "function" and fn or nil
end

-- Remove all entries. The settings stay.
function Log.Clear()
    db.entries, db.first, db.last = {}, 1, 0
end

-- The time of an entry as HH:MM:SS.mmm.
function Log.FormatTime(entry)
    local ok, text = pcall(date, "%H:%M:%S", entry.time)
    return string.format("%s.%03d", ok and text or "??:??:??", entry.ms or 0)
end

-- One entry as a plain text line.
function Log.FormatEntry(entry)
    local ok, day = pcall(date, "%Y-%m-%d", entry.time)
    return string.format("%s %s [%s] [%s] %s", ok and day or "????-??-??", Log.FormatTime(entry), tostring(entry.level),
        tostring(entry.category), tostring(entry.text))
end

local function contains(entry, search)
    return (tostring(entry.category) .. " " .. tostring(entry.text)):lower():find(search, 1, true) ~= nil
end

-- Return the entries, oldest first, that match the filter. filter (all parts optional):
-- minLevel ("debug" shows all), category (exact name), search (plain text, not case-sensitive).
function Log.Query(filter)
    filter = filter or {}
    local minRank = RANK[filter.minLevel] or 1
    local category = filter.category
    if category == "" then
        category = nil
    end
    local search = type(filter.search) == "string" and filter.search ~= "" and filter.search:lower() or nil
    local result = {}
    for index = db.first, db.last do
        local entry = db.entries[index]
        if type(entry) == "table" and (RANK[entry.level] or 2) >= minRank
            and (not category or entry.category == category)
            and (not search or contains(entry, search)) then
            result[#result + 1] = entry
        end
    end
    return result
end

-- Return the category names in the log, sorted.
function Log.Categories()
    local seen, list = {}, {}
    for index = db.first, db.last do
        local entry = db.entries[index]
        if type(entry) == "table" and entry.category and not seen[entry.category] then
            seen[entry.category] = true
            list[#list + 1] = entry.category
        end
    end
    table.sort(list)
    return list
end

-- Return the text of the entries, one line each, in the order of the array.
function Log.ToText(entries)
    local lines = {}
    for index, entry in ipairs(entries) do
        lines[index] = Log.FormatEntry(entry)
    end
    return table.concat(lines, "\n")
end
