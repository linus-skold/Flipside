local mock = require("Tests.wow_mock")

local function loadProbe()
    local chunk = assert(loadfile("LedgerTest/LedgerTest.lua"))
    chunk()
    mock.fire("ADDON_LOADED", "LedgerTest")
    mock.fire("PLAYER_LOGIN")
end

local function entriesOf(event)
    local list = {}
    for _, e in ipairs(LedgerTestDB.entries) do
        if e.event == event then
            table.insert(list, e)
        end
    end
    return list
end

describe("LedgerTest probe", function()
    local money

    before_each(function()
        mock.reset()
        money = 1000
        _G.LedgerTestDB = nil
        _G.GetMoney = function()
            return money
        end
        _G.hooksecurefunc = function()
            error("LedgerTest must not hook")
        end
        loadProbe()
    end)

    after_each(function()
        mock.teardown()
        _G.LedgerTestDB = nil
        _G.SLASH_LEDGERTEST1 = nil
        _G.GetMoney = nil
        _G.hooksecurefunc = nil
        _G.GetNumLootItems = nil
        _G.GetLootSlotInfo = nil
        _G.GetLootSlotType = nil
        _G.GetLootSlotLink = nil
    end)

    it("prints one login line with the build info", function()
        assert.is_truthy(mock.messages[1]:find("build 70009", 1, true))
        assert.is_truthy(mock.messages[1]:find("project id 99", 1, true))
    end)

    it("logs the money delta", function()
        money = 1250
        mock.fire("PLAYER_MONEY")
        local list = entriesOf("PLAYER_MONEY")
        assert.equals(1, #list)
        assert.is_truthy(list[1].text:find("money | 1250 | delta | 250", 1, true))
    end)

    it("logs the coin slot at LOOT_OPENED", function()
        _G.GetNumLootItems = function()
            return 1
        end
        _G.GetLootSlotInfo = function()
            return "icon", "12 Copper", 0, 0, 1, false, false, false
        end
        _G.GetLootSlotType = function()
            return 2
        end
        mock.fire("LOOT_OPENED", true, false)
        assert.equals(1, #entriesOf("LOOT_OPENED"))
        local slot = entriesOf("LOOT_SLOT")[1]
        assert.is_truthy(slot.text:find("12 Copper", 1, true))
        assert.is_truthy(slot.text:find("type | 2", 1, true))
        assert.is_truthy(slot.text:find("link | missing", 1, true))
        assert.equals(1, #entriesOf("LOOT_TARGET"))
    end)

    it("logs a missing combat log API without an error", function()
        mock.fire("COMBAT_LOG_EVENT_UNFILTERED")
        mock.fire("COMBAT_LOG_EVENT_UNFILTERED")
        local list = entriesOf("COMBAT_LOG")
        assert.equals(1, #list)
        assert.is_truthy(list[1].text:find("missing", 1, true))
    end)

    it("logs only the kill subevents", function()
        _G.C_CombatLog = {
            GetCurrentEventInfo = function()
                return 5, mock.subevent, false, "src", "Me", 0, 0, "Creature-1", "Wolf"
            end,
        }
        mock.subevent = "SWING_DAMAGE"
        mock.fire("COMBAT_LOG_EVENT_UNFILTERED")
        mock.subevent = "PARTY_KILL"
        mock.fire("COMBAT_LOG_EVENT_UNFILTERED")
        _G.C_CombatLog = nil
        assert.equals(0, #entriesOf("COMBAT_SWING_DAMAGE"))
        assert.equals(1, #entriesOf("COMBAT_PARTY_KILL"))
    end)

    it("logs a failed event registration", function()
        mock.invalidEvents["TRADE_SHOW"] = true
        mock.fire("ADDON_LOADED", "LedgerTest")
        local list = entriesOf("REGISTER_FAILED")
        assert.equals(1, #list)
        assert.is_truthy(list[1].text:find("TRADE_SHOW", 1, true))
    end)

    it("keeps at most 2000 entries as a ring", function()
        for _ = 1, 2100 do
            mock.fire("MAIL_SHOW")
        end
        local count = 0
        for _ in pairs(LedgerTestDB.entries) do
            count = count + 1
        end
        assert.equals(2000, count)
        assert.is_true(LedgerTestDB.seq > 2100)
    end)

    it("installs no hook and shows secret values as text", function()
        assert.equals(0, #entriesOf("HOOK_INSTALL"))
        _G.issecretvalue = function(v)
            return v == "s"
        end
        mock.fire("QUEST_TURNED_IN", "s", 5)
        _G.issecretvalue = nil
        assert.is_truthy(entriesOf("QUEST_TURNED_IN")[1].text:find("<secret> | 5", 1, true))
    end)

    it("debounces the inbox scan", function()
        mock.fire("MAIL_INBOX_UPDATE")
        mock.fire("MAIL_INBOX_UPDATE")
        mock.advance(0.6)
        assert.equals(1, #entriesOf("INBOX_SCAN"))
    end)

    it("runs the slash commands", function()
        mock.fire("MAIL_SHOW")
        local slash = _G.SlashCmdList["LEDGERTEST"]
        slash("on")
        assert.is_true(LedgerTestDB.verbose)
        slash("stats")
        slash("dump")
        slash("clear")
        assert.equals(0, LedgerTestDB.seq)
    end)
end)
