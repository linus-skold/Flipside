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
        _G.GetLootSourceInfo = nil
        _G.UnitGUID = nil
        _G.issecretvalue = nil
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

    it("never registers the restricted combat log event", function()
        assert.is_false(mock.isRegistered("COMBAT_LOG_EVENT_UNFILTERED"))
        assert.is_true(mock.isRegistered("LOOT_OPENED"))
        assert.is_true(mock.isRegistered("PLAYER_TARGET_CHANGED"))
    end)

    it("logs loot sources with cached names and creature ids", function()
        local wolf = "Creature-0-4379-1-123-4567-0000AB12CD"
        _G.UnitGUID = function()
            return wolf
        end
        _G.UnitName = function()
            return "Wolf"
        end
        mock.fire("PLAYER_TARGET_CHANGED")
        _G.GetNumLootItems = function()
            return 1
        end
        _G.GetLootSlotInfo = function()
            return "icon", "Pelt", 1, 0, 1, false, false, false
        end
        _G.GetLootSlotType = function()
            return 1
        end
        _G.GetLootSourceInfo = function()
            return wolf, 1, "Creature-0-4379-1-123-9999-0000AB12CE", 1
        end
        mock.fire("LOOT_OPENED", false, false)
        local list = entriesOf("LOOT_SOURCE_NAME")
        _G.UnitGUID = nil
        _G.GetLootSourceInfo = nil
        assert.equals(2, #list)
        assert.is_truthy(list[1].text:find("name | Wolf | guidType | Creature | npcId | 4567", 1, true))
        assert.is_truthy(list[2].text:find("name | unknown | guidType | Creature | npcId | 9999", 1, true))
    end)

    it("shows secret unit values as text and keeps the cache at 200", function()
        _G.issecretvalue = function(v)
            return v == "secret-guid"
        end
        _G.UnitGUID = function()
            return "secret-guid"
        end
        mock.fire("UPDATE_MOUSEOVER_UNIT")
        assert.is_truthy(entriesOf("UNIT_CACHE")[1].text:find("guid | <secret>", 1, true))
        local n = 0
        _G.UnitGUID = function()
            n = n + 1
            return "Creature-0-1-1-1-" .. n .. "-0"
        end
        for _ = 1, 250 do
            mock.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        end
        _G.issecretvalue = nil
        _G.UnitGUID = nil
        _G.GetLootSourceInfo = function()
            return "Creature-0-1-1-1-1-0", 1
        end
        _G.GetNumLootItems = function()
            return 1
        end
        mock.fire("LOOT_OPENED", false, false)
        _G.GetLootSourceInfo = nil
        assert.is_truthy(entriesOf("LOOT_SOURCE_NAME")[1].text:find("name | unknown", 1, true))
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
