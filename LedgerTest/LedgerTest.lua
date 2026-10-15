-- LedgerTest: throwaway probe for the Flipside ledger money tracker. It does not depend on Flipside.
-- It logs money, loot, vendor, quest, trade, mail and Auction House events to LedgerTestDB.
--
-- Install: copy the LedgerTest folder to
--   C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\LedgerTest
--
-- Test script (do each step as one action, in this order):
--   1. Kill a mob and loot it. Do it once with auto-loot off, then once with auto-loot on.
--   2. Kill two mobs with an area attack. Loot both.
--   3. Sell an item to a vendor. Buy an item. Buy back an item. Repair.
--   4. Turn in a quest that gives money.
--   5. (Optional) Trade money with a second character.
--   6. Open the mailbox with an Auction House invoice (a sale). Take the money.
--   7. Buy an item and a commodity at the Auction House. Post an item. Cancel an auction.
--   Then type /reload and send this file:
--   WTF/Account/<ACCOUNT>/SavedVariables/LedgerTestDB.lua
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

local frame = CreateFrame("Frame")
local db
local lastMoney
local merchantOpen = false
local lastKill
local combatGetter
local combatChecked = false
local mailToken = 0

local EVENTS = {
    "PLAYER_MONEY", "LOOT_OPENED", "LOOT_CLOSED", "CHAT_MSG_LOOT", "CHAT_MSG_MONEY",
    "COMBAT_LOG_EVENT_UNFILTERED", "MERCHANT_SHOW", "MERCHANT_CLOSED", "QUEST_TURNED_IN",
    "TRADE_SHOW", "TRADE_CLOSED", "TRADE_MONEY_CHANGED", "TRADE_ACCEPT_UPDATE",
    "MAIL_SHOW", "MAIL_CLOSED", "MAIL_INBOX_UPDATE", "MAIL_SUCCESS",
    "AUCTION_HOUSE_PURCHASE_COMPLETED", "COMMODITY_PURCHASE_SUCCEEDED", "AUCTION_HOUSE_AUCTION_CREATED",
    "AUCTION_CANCELED", "CHAT_MSG_SYSTEM",
}

local FORMAT_GLOBALS = { "YOU_LOOT_MONEY", "LOOT_MONEY_SPLIT", "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE",
    "ERR_AUCTION_SOLD_S" }

local MERCHANT_HOOKS = { "BuyMerchantItem", "BuybackItem", "RepairAllItems", "SellCursorItem" }
local MAIL_HOOKS = { "TakeInboxMoney", "TakeInboxItem" }

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
        parts[i] = tostring((select(i, ...)))
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

-- Loot: every return of the slot APIs, plus the target and the last combat log kill.
local function logLoot(autoLoot, isFromItem)
    local slots = tonumber((call("GetNumLootItems"))) or 0
    local sourceType = type(_G.GetLootSourceInfo)
    log("LOOT_OPENED", join("autoLoot", autoLoot, "isFromItem", isFromItem, "slots", slots,
        "GetLootSourceInfo", sourceType))
    for i = 1, slots do
        log("LOOT_SLOT", join("slot", i, "info", call("GetLootSlotInfo", i), "type", call("GetLootSlotType", i),
            "link", call("GetLootSlotLink", i)))
        if sourceType == "function" then
            log("LOOT_SOURCE", join("slot", i, call("GetLootSourceInfo", i)))
        end
    end
    local kill = "none"
    if lastKill then
        kill = join(lastKill.sub, lastKill.srcName, lastKill.destGUID, lastKill.destName,
            string.format("age %.3f", now() - lastKill.t))
    end
    log("LOOT_TARGET", join("targetName", call("UnitName", "target"), "targetGUID", call("UnitGUID", "target"),
        "lastKill", kill))
end

local function resolveCombatGetter()
    combatChecked = true
    local c = _G.C_CombatLog
    if type(c) == "table" and type(c.GetCurrentEventInfo) == "function" then
        combatGetter = c.GetCurrentEventInfo
    elseif type(_G.CombatLogGetCurrentEventInfo) == "function" then
        combatGetter = _G.CombatLogGetCurrentEventInfo
    else
        log("COMBAT_LOG", "missing: C_CombatLog.GetCurrentEventInfo and CombatLogGetCurrentEventInfo")
    end
end

local function logCombat()
    if not combatChecked then
        resolveCombatGetter()
    end
    if not combatGetter then
        return
    end
    local res = pack(pcall(combatGetter))
    if not res[1] then
        return
    end
    local timestamp, sub, _, sourceGUID, sourceName, _, _, destGUID, destName = unpack(res, 2, res.n)
    if sub ~= "PARTY_KILL" and sub ~= "UNIT_DIED" then
        return
    end
    lastKill = { t = now(), sub = sub, srcName = sourceName, destGUID = destGUID, destName = destName }
    log("COMBAT_" .. sub, join(timestamp, sub, sourceGUID, sourceName, destGUID, destName))
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
handlers.COMBAT_LOG_EVENT_UNFILTERED = logCombat
handlers.MAIL_INBOX_UPDATE = onMailInboxUpdate
handlers.MERCHANT_SHOW = function(...)
    merchantOpen = true
    log("MERCHANT_SHOW", join(...))
end
handlers.MERCHANT_CLOSED = function(...)
    merchantOpen = false
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

local function installHook(target, name, label, shouldLog)
    local function hook(...)
        if not shouldLog or shouldLog() then
            log("HOOK_" .. label, join(...))
        end
    end
    local ok, err
    if name then
        ok, err = pcall(hooksecurefunc, target, name, hook)
    else
        ok, err = pcall(hooksecurefunc, target, hook)
    end
    log("HOOK_INSTALL", join(label, ok and "ok" or ("error: " .. tostring(err))))
end

local function installHooks()
    if type(_G.hooksecurefunc) ~= "function" then
        log("HOOK_INSTALL", "missing: hooksecurefunc")
        return
    end
    for _, name in ipairs(MERCHANT_HOOKS) do
        if type(_G[name]) == "function" then
            installHook(name, nil, name)
        else
            log("HOOK_INSTALL", join(name, "missing"))
        end
    end
    for _, name in ipairs(MAIL_HOOKS) do
        if type(_G[name]) == "function" then
            installHook(name, nil, name)
        else
            log("HOOK_INSTALL", join(name, "missing"))
        end
    end
    local container = _G.C_Container
    if type(container) == "table" and type(container.UseContainerItem) == "function" then
        installHook(container, "UseContainerItem", "UseContainerItem", function()
            return merchantOpen
        end)
    else
        log("HOOK_INSTALL", "C_Container.UseContainerItem missing")
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
    log("API", join("GetLootSourceInfo", type(_G.GetLootSourceInfo), "C_CombatLog.GetCurrentEventInfo",
        type(_G.C_CombatLog) == "table" and type(_G.C_CombatLog.GetCurrentEventInfo) or "missing",
        "CombatLogGetCurrentEventInfo", type(_G.CombatLogGetCurrentEventInfo)))
    installHooks()
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
