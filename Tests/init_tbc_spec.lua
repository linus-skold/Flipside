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
        local tip = _G.GameTooltip
        tip.scripts = {}
        tip.HookScript = function(self, name, fn)
            self.scripts[name] = fn
        end
        tip.GetItem = function(self)
            return "Item", self.link
        end
        _G.ItemRefTooltip = { HookScript = function() end, GetItem = function() end }
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
        _G.ItemRefTooltip = nil
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

        it("installs the tooltip hook and adds Flipside lines to an item tooltip", function()
            login()
            assert.are.equal(0, count("tooltip hook not available"))
            local linen = "|cff1eff00|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r"
            local tip = _G.GameTooltip
            tip.link = linen
            tip.scripts.OnTooltipSetItem(tip)
            local found
            for _, line in ipairs(mock.tooltip.lines) do
                if line == "Flipside" then
                    found = true
                end
            end
            assert.is_true(found)
        end)

        describe("legacy auction", function()
            local list, owner

            before_each(function()
                list, owner = {}, {}
                local function tuple(name, quantity, status, id)
                    return name, 1, quantity, 1, true, 1, 0, 0, 0, 100, 0, false, "", "o", "", status, id, true
                end
                _G.CanSendAuctionQuery = function() return true end
                _G.QueryAuctionItems = function() end
                _G.GetNumAuctionItems = function(kind)
                    return #(kind == "list" and list or owner)
                end
                _G.GetAuctionItemInfo = function(kind, i)
                    local row = (kind == "list" and list or owner)[i]
                    return tuple(row.name, row.count, row.status, row.id)
                end
                _G.GetAuctionItemLink = function(kind, i)
                    return (kind == "list" and list or owner)[i].link
                end
                login()
                mock.fire("AUCTION_HOUSE_SHOW")
            end)

            after_each(function()
                for _, name in ipairs({ "CanSendAuctionQuery", "QueryAuctionItems", "GetNumAuctionItems",
                    "GetAuctionItemInfo", "GetAuctionItemLink" }) do
                    _G[name] = nil
                end
            end)

            it("finds items by name with the AH open", function()
                local result, err
                ns.ahNameSearch:Find("copper", function(items, e) result, err = items, e end)
                list[1] = { name = "Copper Bar", count = 5, status = 0, id = 2840 }
                list[2] = { name = "Copper Ore", count = 5, status = 0, id = 2770 }
                mock.fire("AUCTION_ITEM_LIST_UPDATE")
                assert.is_nil(err)
                assert.are.equal(2, #result)
                assert.are.equal("Copper Bar", result[1].name)
                assert.are.equal(2840, result[1].itemID)
            end)

            it("shows the busy error", function()
                _G.CanSendAuctionQuery = function() return false end
                local result, err
                ns.ahNameSearch:Find("copper", function(items, e) result, err = items, e end)
                assert.is_nil(result)
                assert.is_truthy(err:find("busy", 1, true))
            end)

            it("counts the own auctions that are not sold in the holdings", function()
                local saved
                local holdings = ns.holdings
                local original = holdings.SetLocation
                holdings.SetLocation = function(self, location, items)
                    if location == "auctions" then saved = items end
                    return original(self, location, items)
                end
                local link = "|cffffffff|Hitem:2840::::::::60:::::|h[Copper Bar]|h|r"
                owner[1] = { name = "Copper Bar", count = 20, status = 0, id = 2840, link = link }
                owner[2] = { name = "Copper Bar", count = 7, status = 1, id = 2840, link = link }
                mock.fire("AUCTION_OWNED_LIST_UPDATE")
                mock.advance(1)
                assert.is_table(saved)
                local total = 0
                for _, n in pairs(saved) do total = total + n end
                assert.are.equal(20, total)
            end)
        end)
        describe("legacy scan", function()
            local rows, batchOverride, canMass, queries
            local names = { "CanSendAuctionQuery", "QueryAuctionItems", "GetNumAuctionItems", "GetAuctionItemInfo",
                "GetAuctionItemLink" }
            local LINK = "|cffffffff|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r"

            local function pump(frames)
                for _ = 1, frames do
                    mock.update()
                    mock.advance(1)
                end
            end

            before_each(function()
                rows, batchOverride, canMass, queries = {}, nil, true, {}
                mock.stackSizes[2589] = 200
                _G.CanSendAuctionQuery = function() return true, canMass end
                _G.QueryAuctionItems = function(...) queries[#queries + 1] = { n = select("#", ...), ... } end
                _G.GetNumAuctionItems = function() return batchOverride or #rows, #rows end
                _G.GetAuctionItemInfo = function(_, i)
                    local r = rows[i]
                    return "Linen Cloth", 1, r.count, 1, true, 1, 0, 0, 0, r.buyout, 0, false, "", "o", "", 0,
                        2589, true
                end
                _G.GetAuctionItemLink = function(_, i) return rows[i].link end
                login()
                mock.fire("AUCTION_HOUSE_SHOW")
            end)

            after_each(function()
                for _, name in ipairs(names) do
                    _G[name] = nil
                end
            end)

            it("refuses with the get-all cooldown text", function()
                canMass = false
                slash("scan")
                assert.are.equal(1, count("get all is on cooldown"))
                assert.is_nil(mock.popup)
                assert.is_false(ns.scanEngine:IsRunning())
            end)

            it("runs a getAll scan, waits for the full batch and stores per-item prices", function()
                slash("scan")
                mock.acceptPopup()
                pump(2)
                assert.are.equal(1, #queries)
                assert.are.equal(true, queries[1][7])
                rows[1] = { count = 20, buyout = 2000, link = LINK }
                rows[2] = { count = 10, buyout = 2000, link = LINK }
                batchOverride = 1
                mock.fire("AUCTION_ITEM_LIST_UPDATE")
                pump(1)
                assert.is_true(ns.scanEngine:IsRunning())
                batchOverride = nil
                mock.fire("AUCTION_ITEM_LIST_UPDATE")
                for _ = 1, 300 do
                    if not ns.scanEngine:IsRunning() then break end
                    pump(1)
                end
                assert.is_false(ns.scanEngine:IsRunning())
                assert.are.equal(1, ns.scanStore:CountItems())
                assert.are.equal("EU", ns.scanStore:GetRegion())
                assert.are.equal("tbc-anniversary", ns.scanStore:GetRuleset())
                local record = ns.scanStore:Get(ns.scanStore:Keys()[1])
                assert.are.equal(100, record.latest.market)                local diag = _G.FlipsideScanDB_TBC.diag
                assert.are.equal(1, #diag)
                assert.are.equal(2, diag[1].events)
                assert.are.equal(2, diag[1].rows)
                assert.are.equal(1, count("legacy scan: rows 2, batch 2 of 2"))
            end)
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
