-- LedgerTest: throwaway probe for the Flipside ledger money tracker. It does not depend on Flipside.
-- It logs money, loot, vendor, quest, trade, mail and Auction House events to LedgerTestDB.
--
-- Install: copy the LedgerTest folder to
--   C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\LedgerTest
--
-- Test script (do each step as one action, in this order):
--   1. Kill a mob and loot it. Do it once with auto-loot off, then once with auto-loot on.
--   2. Kill two mobs with an area attack. Loot both (tests GetLootSourceInfo with two corpses).
--      Before the kill, target or mouse over each mob, so the name cache has its name.
--   3. Sell an item to a vendor. Buy an item. Buy back an item. Repair.
--   4. Turn in a quest that gives money.
--   5. (Optional) Trade money with a second character.
--   6. Open the mailbox with an Auction House invoice (a sale). Take the money.
--   7. Buy an item and a commodity at the Auction House. Post an item. Cancel an auction.
--   Then type /reload and send this file:
--   WTF/Account/<ACCOUNT>/SavedVariables/LedgerTestDB.lua
--
-- The probe uses no hooksecurefunc and writes to no Blizzard table, so it cannot taint Blizzard code.
-- It does not register COMBAT_LOG_EVENT_UNFILTERED. The client API docs mark that event HasRestrictions,
-- and the registration shows the "blocked from an action" popup.
-- Mob names come from GetLootSourceInfo (GUID) and a GUID to name cache that unit events fill.
-- Vendor, repair and mail actions show in MERCHANT_*, BAG_UPDATE_DELAYED, PLAYER_MONEY and MAIL_SUCCESS.
-- If the "blocked from an action" popup shows again: run /console taintLog 1, repeat the action,
-- then send Logs\taint.log. The taint log needs /console taintLog 1 before /reload.
--
-- Slash commands: /ledgertest on | off | dump | clear | stats
--   on, off: print each entry to chat. dump: print the last 30 entries.
--   clear: delete all entries. stats: count of entries for each event.
--
-- The probe never opens, reads or takes mail. It does not call GetInboxText (it can mark mail as read).

local ADDON_NAME = "LedgerTest"
local CAP = 2000
local DUMP_COUNT = 30
local MAIL_DEBOUNCE = 0.5
local NAME_CACHE_MAX = 200

local frame = CreateFrame("Frame")
local db
local lastMoney
local mailToken = 0
local nameCache = {}
local nameOrder = {}

local EVENTS = {
    "PLAYER_MONEY", "LOOT_OPENED", "LOOT_CLOSED", "CHAT_MSG_LOOT", "CHAT_MSG_MONEY",
    "MERCHANT_SHOW", "MERCHANT_CLOSED", "QUEST_TURNED_IN",
    "TRADE_SHOW", "TRADE_CLOSED", "TRADE_MONEY_CHANGED", "TRADE_ACCEPT_UPDATE",
    "MAIL_SHOW", "MAIL_CLOSED", "MAIL_INBOX_UPDATE", "MAIL_SUCCESS",
    "AUCTION_HOUSE_PURCHASE_COMPLETED", "COMMODITY_PURCHASE_SUCCEEDED", "AUCTION_HOUSE_AUCTION_CREATED",
    "AUCTION_CANCELED", "CHAT_MSG_SYSTEM", "MERCHANT_UPDATE", "BAG_UPDATE_DELAYED",
    "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED", "PLAYER_SOFT_ENEMY_CHANGED",
}

-- Unit events that fill the GUID to name cache. The value is the unit token (nil: the event gives it).
local UNIT_EVENTS = {
    PLAYER_TARGET_CHANGED = "target",
    UPDATE_MOUSEOVER_UNIT = "mouseover",
    NAME_PLATE_UNIT_ADDED = false,
    PLAYER_SOFT_ENEMY_CHANGED = "softenemy",
}

local FORMAT_GLOBALS = { "YOU_LOOT_MONEY", "LOOT_MONEY_SPLIT", "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE",
    "ERR_AUCTION_SOLD_S" }


local function now()
    if type(_G.GetTimePreciseSec) == "function" then
        return _G.GetTimePreciseSec()
    end
    if type(_G.debugprofilestop) == "function" then
        return _G.debugprofilestop() / 1000
    end
    return 0
end

local function pack(...)
    return { n = select("#", ...), ... }
end

-- Join all values as text. A nil value shows as "nil".
local function join(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local v = (select(i, ...))
        if type(_G.issecretvalue) == "function" and _G.issecretvalue(v) then
            parts[i] = "<secret>"
        else
            parts[i] = tostring(v)
        end
    end
    return table.concat(parts, " | ")
end

-- Call a global API by name. Gives "missing" or "error: ..." text when the call cannot run.
local function call(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then
        return "missing"
    end
    local res = pack(pcall(fn, ...))
    if not res[1] then
        return "error: " .. tostring(res[2])
    end
    return join(unpack(res, 2, res.n))
end

local function ensureDB()
    if type(LedgerTestDB) ~= "table" then
        LedgerTestDB = {}
    end
    db = LedgerTestDB
    db.entries = db.entries or {}
    db.counts = db.counts or {}
    db.seq = db.seq or 0
    return db
end

local function say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("LedgerTest: " .. msg)
end

local function log(event, text)
    ensureDB()
    db.seq = db.seq + 1
    local entry = { seq = db.seq, t = now(), event = event, text = text }
    db.entries[(db.seq - 1) % CAP + 1] = entry
    db.counts[event] = (db.counts[event] or 0) + 1
    if db.verbose then
        say(string.format("%.3f %s: %s", entry.t, event, (text:gsub("|", "||"))))
    end
end

local function sortedEntries()
    local list = {}
    for _, entry in pairs(ensureDB().entries) do
        list[#list + 1] = entry
    end
    table.sort(list, function(a, b)
        return a.seq < b.seq
    end)
    return list
end

-- Give the value, or nil when it is a secret value.
local function plain(v)
    if type(_G.issecretvalue) == "function" and _G.issecretvalue(v) then
        return nil
    end
    return v
end

-- Call a unit API and give a plain string, "<secret>" or "unknown".
local function unitValue(name, unit)
    local fn = _G[name]
    if type(fn) ~= "function" then
        return nil, "missing"
    end
    local ok, v = pcall(fn, unit)
    if not ok then
        return nil, "error: " .. tostring(v)
    end
    if plain(v) == nil and v ~= nil then
        return nil, "<secret>"
    end
    return v
end

-- Keep the name for a GUID. Drop the oldest entry after NAME_CACHE_MAX entries.
local function cacheName(guid, name)
    if nameCache[guid] == nil then
        nameOrder[#nameOrder + 1] = guid
        if #nameOrder > NAME_CACHE_MAX then
            nameCache[table.remove(nameOrder, 1)] = nil
        end
    end
    nameCache[guid] = name
end

local function cacheUnit(event, unit)
    if not unit then
        return
    end
    local guid, guidNote = unitValue("UnitGUID", unit)
    local name, nameNote = unitValue("UnitName", unit)
    if guidNote or nameNote then
        db = ensureDB()
        db.unitNotes = db.unitNotes or {}
        if not db.unitNotes[event] then
            db.unitNotes[event] = true
            log("UNIT_CACHE", join(event, unit, "guid", guidNote or "ok", "name", nameNote or "ok"))
        end
        return
    end
    if type(guid) == "string" and type(name) == "string" then
        cacheName(guid, name)
    end
end

-- GUID like Creature-0-1-2-3-<npcId>-<spawn>. Gives the type and the id.
local function parseGuid(guid)
    if type(guid) ~= "string" then
        return "none", "none"
    end
    local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    return kind or "other", id or "none"
end

-- One slot: all returns of GetLootSourceInfo are GUID and quantity pairs.
local function logSource(slot)
    local res = pack(pcall(_G.GetLootSourceInfo, slot))
    if not res[1] then
        log("LOOT_SOURCE", join("slot", slot, "error", tostring(res[2])))
        return
    end
    log("LOOT_SOURCE", join("slot", slot, "returns", res.n - 1, join(unpack(res, 2, res.n))))
    for i = 2, res.n, 2 do
        local guid, qty = res[i], res[i + 1]
        local isSecret = plain(guid) == nil and guid ~= nil
        local name, kind, id
        if isSecret then
            name, kind, id = "<secret>", "<secret>", "<secret>"
        else
            name = nameCache[guid] or "unknown"
            kind, id = parseGuid(guid)
        end
        log("LOOT_SOURCE_NAME", join("slot", slot, "guid", guid, "qty", qty, "name", name, "guidType", kind,
            "npcId", id))
    end
end

-- Loot: every return of the slot APIs, the source GUIDs with cached names, and the target.
local function logLoot(autoLoot, isFromItem)
    local slots = tonumber((call("GetNumLootItems"))) or 0
    local sourceType = type(_G.GetLootSourceInfo)
    log("LOOT_OPENED", join("autoLoot", autoLoot, "isFromItem", isFromItem, "slots", slots,
        "GetLootSourceInfo", sourceType))
    for i = 1, slots do
        log("LOOT_SLOT", join("slot", i, "info", call("GetLootSlotInfo", i), "type", call("GetLootSlotType", i),
            "link", call("GetLootSlotLink", i)))
        if sourceType == "function" then
            logSource(i)
        end
    end
    log("LOOT_TARGET", join("targetName", call("UnitName", "target"), "targetGUID", call("UnitGUID", "target"),
        "cached", #nameOrder))
end
local function logInbox()
    local count = tonumber((call("GetInboxNumItems"))) or 0
    log("INBOX_SCAN", join("items", call("GetInboxNumItems")))
    for i = 1, count do
        log("INBOX_HEADER", join("index", i, call("GetInboxHeaderInfo", i)))
        log("INBOX_INVOICE", join("index", i, call("GetInboxInvoiceInfo", i)))
    end
end

local function onMailInboxUpdate(...)
    log("MAIL_INBOX_UPDATE", join(...))
    mailToken = mailToken + 1
    local token = mailToken
    C_Timer.After(MAIL_DEBOUNCE, function()
        if token == mailToken then
            logInbox()
        end
    end)
end

local function isAuctionSold(text)
    if type(text) ~= "string" then
        return false
    end
    local fmt = _G.ERR_AUCTION_SOLD_S
    if type(fmt) == "string" then
        local pattern = "^" .. fmt:gsub("%p", "%%%0"):gsub("%%%%s", ".+") .. "$"
        if text:find(pattern) then
            return true
        end
    end
    return text:lower():find("auction", 1, true) ~= nil
end

local function tradeMoney()
    return join("player", call("GetPlayerTradeMoney"), "target", call("GetTargetTradeMoney"))
end

local handlers = {}

handlers.PLAYER_MONEY = function(...)
    local money = tonumber((call("GetMoney")))
    local delta = "n/a"
    if money and lastMoney then
        delta = money - lastMoney
    end
    if money then
        lastMoney = money
    end
    log("PLAYER_MONEY", join("money", money, "delta", delta, join(...)))
end
handlers.LOOT_OPENED = logLoot
for event, unit in pairs(UNIT_EVENTS) do
    handlers[event] = function(unitArg)
        cacheUnit(event, unit or unitArg)
    end
end
handlers.MAIL_INBOX_UPDATE = onMailInboxUpdate
handlers.MERCHANT_SHOW = function(...)
    log("MERCHANT_SHOW", join(...))
end
handlers.MERCHANT_CLOSED = function(...)
    log("MERCHANT_CLOSED", join(...))
end
handlers.CHAT_MSG_SYSTEM = function(text, ...)
    if isAuctionSold(text) then
        log("CHAT_MSG_SYSTEM", join(text, ...))
    end
end
for _, event in ipairs({ "TRADE_SHOW", "TRADE_CLOSED", "TRADE_MONEY_CHANGED", "TRADE_ACCEPT_UPDATE" }) do
    handlers[event] = function(...)
        log(event, join(join(...), tradeMoney()))
    end
end

local function registerEvents()
    for _, event in ipairs(EVENTS) do
        local ok, err = pcall(frame.RegisterEvent, frame, event)
        if not ok then
            log("REGISTER_FAILED", join(event, err))
        end
    end
end

local function onLogin()
    local version, build, _, interface = GetBuildInfo()
    ensureDB().build = { version = version, build = build, interface = interface, project = WOW_PROJECT_ID }
    say(string.format("loaded. client %s, build %s, interface %s, project id %s. Type /ledgertest.",
        tostring(version), tostring(build), tostring(interface), tostring(WOW_PROJECT_ID)))
    lastMoney = tonumber((call("GetMoney")))
    log("LOGIN", join("version", version, "build", build, "interface", interface, "project", WOW_PROJECT_ID,
        "money", lastMoney))
    for _, name in ipairs(FORMAT_GLOBALS) do
        log("FORMAT", join(name, tostring(_G[name])))
    end
    log("API", join("GetLootSourceInfo", type(_G.GetLootSourceInfo)))
end

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if (...) == ADDON_NAME then
            ensureDB()
            registerEvents()
        end
        return
    end
    if event == "PLAYER_LOGIN" then
        onLogin()
        return
    end
    local handler = handlers[event]
    if handler then
        handler(...)
    else
        log(event, join(...))
    end
end)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")

local function dump()
    local list = sortedEntries()
    local first = math.max(1, #list - DUMP_COUNT + 1)
    say(string.format("%d entries, showing %d to %d", #list, first, #list))
    for i = first, #list do
        local e = list[i]
        say(string.format("#%d %.3f %s: %s", e.seq, e.t, e.event, (e.text:gsub("|", "||"))))
    end
end

local function stats()
    local names = {}
    for name in pairs(ensureDB().counts) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        say(name .. ": " .. db.counts[name])
    end
    say(string.format("verbose: %s, total entries: %d", tostring(db.verbose == true), db.seq))
end

local commands = {
    on = function()
        ensureDB().verbose = true
        say("verbose on")
    end,
    off = function()
        ensureDB().verbose = false
        say("verbose off")
    end,
    dump = dump,
    clear = function()
        ensureDB()
        db.entries = {}
        db.counts = {}
        db.seq = 0
        say("cleared")
    end,
    stats = stats,
}

SLASH_LEDGERTEST1 = "/ledgertest"
SlashCmdList["LEDGERTEST"] = function(arg)
    local command = commands[(arg or ""):lower():match("^%s*(%S*)")]
    if command then
        command()
    else
        say("usage: /ledgertest on | off | dump | clear | stats")
    end
end
