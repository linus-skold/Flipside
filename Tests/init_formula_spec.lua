local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local ns

local function tocFiles()
    return manifest.files()
end

local function slash(text)
    mock.messages = {}
    _G.SlashCmdList.FLIPSIDE(text)
end

local function login()
    mock.fire("ADDON_LOADED", "Flipside")
    mock.fire("PLAYER_LOGIN")
end

local LINEN = "|cff1eff00|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r"

describe("Init formula", function()
    before_each(function()
        mock.reset()
        mock.playerName = "Tester"
        mock.realmName = "TestRealm"
        ns = {}
        for _, path in ipairs(tocFiles()) do
            assert(loadfile(path))("Flipside", ns)
        end
        login()
        mock.commodityResults[2589] = { { unitPrice = 100, quantity = 20 }, { unitPrice = 120, quantity = 30 } }
        mock.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    end)

    after_each(function()
        mock.teardown()
    end)

    it("loads the formula modules before Init", function()
        local position = {}
        for i, path in ipairs(tocFiles()) do
            position[path] = i
        end
        for _, name in ipairs({ "Parse", "Functions", "Sources", "Lookup", "Eval", "Run" }) do
            assert.is_true(position[manifest.path("Formula" .. name)] < position[manifest.path("Init")], name)
        end
        assert.is_table(ns.formulaRun)
        assert.is_table(ns.formulaSources)
    end)

    it("prints the value of a formula", function()
        slash("formula scanmarket 2589")
        assert.are.same({ "Flipside: formula = 100 (1s) for 2589" }, mock.messages)
    end)

    it("works with the /flipside name", function()
        slash("formula scanmin 2589")
        assert.are.equal(1, #mock.messages)
    end)

    it("uses the sell price from the item info", function()
        mock.itemInfo[2589] = { "Linen Cloth", "item:2589", 1, 1, 1, "Trade", "Cloth", 20, "", 0, 13 }
        slash("formula max(scanmin, 1.5 * vendorsell) 2589")
        assert.are.same({ "Flipside: formula = 100 (1s) for 2589" }, mock.messages)
        slash("formula max(scanmin, 10 * vendorsell) 2589")
        assert.are.same({ "Flipside: formula = 130 (1s 30c) for 2589" }, mock.messages)
    end)

    it("handles ifgt with scanage and invalid", function()
        slash("formula ifgt(scanage, 72, invalid, scanmarket) 2589")
        assert.are.same({ "Flipside: formula = 100 (1s) for 2589" }, mock.messages)
    end)

    it("prints the missing names of an invalid result", function()
        slash("formula scanmarket 99")
        assert.are.same({ "Flipside: formula = invalid for 99", "Flipside: missing: scanmarket" }, mock.messages)
    end)

    it("prints sources that are not available yet", function()
        slash("formula crafting 2589")
        assert.are.same({
            "Flipside: formula = invalid for 2589",
            "Flipside: missing: crafting",
            "Flipside: not available yet: crafting",
        }, mock.messages)
    end)

    it("prints the position and the text near a compile error", function()
        slash("formula scanmarkt * 2 2589")
        assert.are.equal(2, #mock.messages)
        assert.is_truthy(mock.messages[1]:match("^Flipside: formula error at 1: "))
        assert.are.equal('Flipside: near "scanmarkt ..."', mock.messages[2])
        slash("formula scanmin * 2 + scanmarkt * 2 2589")
        assert.is_truthy(mock.messages[1]:match("^Flipside: formula error at 15: "))
        assert.are.equal('Flipside: near "... 2 + scanm..."', mock.messages[2])
    end)

    it("compiles only when there is no item", function()
        slash("formula max(scanmin, vendorsell)")
        assert.are.same({ "Flipside: formula ok (sources: scanmin, vendorsell)" }, mock.messages)
        slash("formula 1 +")
        assert.is_truthy(mock.messages[1]:match("^Flipside: formula error at "))
    end)

    it("reads a trailing number as the item only when it fits", function()
        slash("formula scanmin * 2")
        assert.are.same({ "Flipside: formula ok (sources: scanmin)" }, mock.messages)
        slash("formula scanmin * 2 2589")
        assert.are.same({ "Flipside: formula = 200 (2s) for 2589" }, mock.messages)
        slash("formula max(scanmin, 2) 2589")
        assert.are.same({ "Flipside: formula = 100 (1s) for 2589" }, mock.messages)
        slash("formula scanmarkt 2589")
        assert.is_truthy(mock.messages[1]:match("^Flipside: formula error at 1: "))
        assert.are.equal('Flipside: near "scanmarkt"', mock.messages[2])
    end)

    it("prints not an item for a link that is not an item", function()
        local link = "|cff71d5ff|Hspell:1|h[Spell]|h|r"
        slash("formula scanmin " .. link)
        assert.are.same({ "Flipside: not an item: " .. link }, mock.messages)
        slash("formula scanmin 0")
        assert.are.same({ "Flipside: not an item: 0" }, mock.messages)
    end)

    it("prints the usage", function()
        slash("formula")
        assert.are.same({
            "Flipside: usage: /flip formula <formula> [item link or id]",
            "Flipside: example: /flip formula max(scanmin, 1.5 * vendorsell) 2589",
        }, mock.messages)
    end)

    it("finds an item link with spaces in the name", function()
        slash("formula scanmin " .. LINEN)
        assert.are.same({ "Flipside: formula = 100 (1s) for 2589" }, mock.messages)
    end)

    it("lists the formula command in the help", function()
        slash("help")
        local found = false
        for _, msg in ipairs(mock.messages) do
            if msg:find("formula <text> [item]", 1, true) then
                found = true
            end
        end
        assert.is_true(found)
    end)

    it("creates the formula runner when there is no scan store", function()
        mock.playerName = nil
        ns.db = nil
        ns.scanStore = nil
        ns.formulaRun = nil
        mock.fire("PLAYER_LOGIN")
        slash("formula scanmin 2589")
        assert.are.equal("Flipside: formula = invalid for 2589", mock.messages[1])
    end)
end)
