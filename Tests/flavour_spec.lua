local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local ns

local function load()
    ns = {}
    for _, path in ipairs(manifest.files()) do
        assert(loadfile(path))("Flipside", ns)
    end
end

local function login()
    mock.fire("ADDON_LOADED", "Flipside")
    mock.fire("PLAYER_LOGIN")
end

describe("Flavour config", function()
    before_each(function()
        mock.reset()
        mock.playerName = "Tester"
        mock.realmName = "TestRealm"
        load()
    end)

    after_each(function()
        mock.teardown()
    end)

    it("has the Forever values", function()
        local f = ns.Flavour
        assert.are.equal("forever", f.id)
        assert.are.equal(900, f.scanCooldownSeconds)
        assert.are.equal("standard", f.ruleset)
        assert.is_false(f.scopeIncludesRealm)
        assert.is_true(f.captureEnabled)
        assert.is_true(f.hasCommodityMarket)
        assert.is_false(f.ledgerRealmFilter)
        assert.are.same({ main = "FlipsideDB", scan = "FlipsideScanDB", ledger = "FlipsideLedgerDB" }, f.savedVariables)
        assert.are.same({ 0, 1, 2, 3, 4, 5 }, f.bagIDs())
        assert.are.same({ 6, 7, 8, 9, 10, 11, 12, 13, 14 }, f.bankIDs())
    end)

    it("loads right after ItemInfoCache in the TOC", function()
        local files = manifest.files()
        assert.are.equal(manifest.indexOf(files, "ItemInfoCache") + 1, manifest.indexOf(files, "Flavour"))
    end)

    describe("ScanStore realm scope", function()
        it("keeps the Forever layout without a realm", function()
            local saved = {}
            ns.ScanStore.New(saved, { region = "EU", ruleset = "standard", schemaVersion = 1 })
            assert.is_table(saved.data.EU.standard.items)
        end)

        it("adds the realm to the scope with a realm", function()
            local saved = {}
            local store = ns.ScanStore.New(saved, {
                region = "EU", realm = "Realm", ruleset = "tbc-anniversary", schemaVersion = 1,
            })
            assert.is_table(saved.data.EU.Realm["tbc-anniversary"].items)
            assert.are.equal("Realm", store:GetRealm())
            assert.is_nil(store:Get("5"))
        end)
    end)

    describe("bag lists", function()
        local function api(slots)
            return {
                numSlots = function(bag)
                    return slots[bag] or 0
                end,
                itemInfo = function(bag)
                    local id = 100 + bag
                    local link = "|cffffffff|Hitem:" .. id .. "::::::::::::|h[X]|h|r"
                    return { itemID = id, hyperlink = link, stackCount = 1 }
                end,
            }
        end

        it("HoldingsRead.Bags reads the given ids", function()
            local items = ns.HoldingsRead.Bags(api({ [0] = 1, [4] = 1, [5] = 1 }), nil, { 0, 4 })
            local n = 0
            for _ in pairs(items) do
                n = n + 1
            end
            assert.are.equal(2, n)
        end)

        it("BagItems.Read reads the given ids", function()
            local items = ns.BagItems.Read(api({ [0] = 1, [4] = 1, [5] = 1 }), nil, { bagIDs = { 5 } })
            assert.are.equal(1, #items)
            assert.are.equal(105, items[1].itemID)
        end)
    end)

    describe("Init", function()
        it("reads the SavedVariables names, ruleset, cooldown and capture from ns.Flavour", function()
            ns.Flavour.savedVariables = { main = "FlipsideDB_X", scan = "FlipsideScanDB_X" }
            ns.Flavour.ruleset = "special"
            ns.Flavour.scanCooldownSeconds = 60
            ns.Flavour.captureEnabled = false
            ns.Flavour.scopeIncludesRealm = true
            login()
            assert.is_table(_G.FlipsideDB_X)
            assert.is_table(_G.FlipsideScanDB_X)
            assert.is_nil(_G.FlipsideDB)
            assert.are.equal("special", ns.scanStore:GetRuleset())
            assert.are.equal("TestRealm", ns.scanStore:GetRealm())
            assert.is_nil(ns.scanCapture)
            ns.scanCooldown:MarkAttempt()
            assert.are.equal(60, ns.scanCooldown:Remaining())
            _G.FlipsideDB_X, _G.FlipsideScanDB_X = nil, nil
        end)

        it("keeps capture and the default ruleset with the Forever config", function()
            login()
            assert.is_table(ns.scanCapture)
            assert.are.equal("standard", ns.scanStore:GetRuleset())
            assert.is_nil(ns.scanStore:GetRealm())
            assert.is_table(_G.FlipsideScanDB.data)
        end)
    end)
end)
