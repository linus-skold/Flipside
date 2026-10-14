local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local ns

local function slash(text)
    mock.messages = {}
    _G.SlashCmdList.FLIPSIDE(text)
end

local function login()
    mock.fire("ADDON_LOADED", "Flipside")
    mock.fire("PLAYER_LOGIN")
end

local function windowFrames()
    local list = {}
    for _, f in ipairs(mock.frames) do
        if f.name == "FlipsideMainWindow" then
            table.insert(list, f)
        end
    end
    return list
end

local function count(text)
    local n = 0
    for _, msg in ipairs(mock.messages) do
        if msg:find(text, 1, true) then
            n = n + 1
        end
    end
    return n
end

describe("Init on TBC", function()
    before_each(function()
        mock.reset({ flavour = "tbc" })
        local methods = getmetatable(CreateFrame("Frame")).__index
        methods.SetJustifyH = function() end
        methods.HasFocus = function(self)
            return self.focused
        end
        _G.ScrollUtil = nil
        _G.C_Timer.NewTicker = function()
            return { Cancel = function() end }
        end
        mock.playerName = "Tester"
        mock.realmName = "TestRealm"
        ns = {}
        for _, path in ipairs(manifest.files("Flipside_TBC.toc")) do
            assert(loadfile(path))("Flipside", ns)
        end
    end)

    after_each(function()
        mock.teardown()
    end)

    it("has no Forever files in its TOC", function()
        local listed = {}
        for _, path in ipairs(manifest.files("Flipside_TBC.toc")) do
            assert.is_nil(path:match("^AH_Forever/"), path)
            assert.is_nil(path:match("^Core_Forever/"), path)
            listed[path] = true
        end
        assert.is_true(listed["Core_TBC/Flavour.lua"])
        assert.is_true(listed["AH_TBC/LegacyBackend.lua"])
    end)

    it("uses the TBC config", function()
        local f = ns.Flavour
        assert.are.equal("tbc", f.id)
        assert.are.equal("tbc-anniversary", f.ruleset)
        assert.is_true(f.scopeIncludesRealm)
        assert.is_false(f.captureEnabled)
        assert.are.same({ 0, 1, 2, 3, 4 }, f.bagIDs())
        assert.are.same({ -1, 5, 6, 7, 8, 9, 10, 11 }, f.bankIDs())
        assert.are.same({ main = "FlipsideDB_TBC", scan = "FlipsideScanDB_TBC" }, f.savedVariables)
    end)

    it("falls back to 4 bags and 7 bank bags without client constants", function()
        _G.NUM_BAG_SLOTS, _G.NUM_BANKBAGSLOTS, _G.BANK_CONTAINER = nil, nil, nil
        assert.are.same({ 0, 1, 2, 3, 4 }, ns.Flavour.bagIDs())
        assert.are.same({ -1, 5, 6, 7, 8, 9, 10, 11 }, ns.Flavour.bankIDs())
    end)

    describe("login", function()
        it("runs every Init step without an error", function()
            login()
            assert.is_table(ns.db)
            assert.is_table(ns.scanStore)
            assert.is_table(ns.scanEngine)
            assert.is_table(ns.itemNameIndex)
            assert.is_table(ns.formulaRun)
            assert.is_table(ns.rules)
            assert.is_table(ns.holdings)
            assert.is_table(ns.tooltipConfig)
            assert.is_nil(ns.scanCapture)
            for _, msg in ipairs(mock.messages) do
                assert.is_nil(msg:find("failed", 1, true), msg)
                assert.is_nil(msg:find("not available this session", 1, true), msg)
            end
        end)

        it("reports the missing tooltip hook once", function()
            login()
            assert.are.equal(1, count("tooltip hook not available"))
        end)

        it("uses the TBC SavedVariables names", function()
            login()
            assert.is_table(_G.FlipsideDB_TBC)
            assert.is_table(_G.FlipsideScanDB_TBC)
            assert.is_nil(_G.FlipsideDB)
        end)

        it("keys the scan data by region, realm and ruleset", function()
            login()
            assert.are.equal("EU", ns.scanStore:GetRegion())
            assert.are.equal("TestRealm", ns.scanStore:GetRealm())
            assert.are.equal("tbc-anniversary", ns.scanStore:GetRuleset())
            assert.is_table(_G.FlipsideScanDB_TBC.data.EU.TestRealm["tbc-anniversary"].items)
        end)

        it("opens the window with /flip", function()
            login()
            slash("")
            local frames = windowFrames()
            assert.are.equal(1, #frames)
            assert.is_true(frames[1]:IsShown())
        end)

        it("refuses a scan cleanly", function()
            login()
            mock.fire("AUCTION_HOUSE_SHOW")
            slash("scan")
            assert.are.equal(1, count("full scan not started: the scan call is not available"))
            assert.is_nil(mock.popup)
        end)

        it("reads bag counts with the TBC bag list", function()
            login()
            local link = "|cffffffff|Hitem:5::::::::::::|h[X]|h|r"
            mock.bags[4] = { [1] = { itemID = 5, hyperlink = link, stackCount = 3 } }
            local items = ns.readBags()
            assert.are.equal(1, #items)
        end)
    end)
end)
