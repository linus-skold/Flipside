local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local ns

-- A recorded Forever tuple: name, texture, count, quality, canUse, level, levelType, minBid, minIncrement,
-- buyout, bidAmount, highBidder, bidderName, owner, ownerName, saleStatus, itemID, hasAllInfo.
local function tuple(count, buyout, itemID, hasAll)
    return "name", 134400, count, 1, true, 1, 0, 0, 0, buyout, 0, false, "", "owner", "", 0, itemID, hasAll
end

describe("AuctionClient", function()
    before_each(function()
        mock.reset()
        ns = {}
        assert(loadfile(manifest.path("AuctionClient")))("Flipside", ns)
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("without a backend", function()
        it("cannot scan and has no capabilities", function()
            assert.is_false(ns.AuctionClient.CanScan())
            assert.is_false(ns.AuctionClient.HasCommodityCheck())
            assert.is_false(ns.AuctionClient.CanReadOwned())
            assert.is_nil(ns.AuctionClient.ScanDoneEvent())
            assert.is_nil(ns.AuctionClient.Capture())
            assert.is_nil(ns.AuctionClient.ItemIsCommodity(1))
        end)

        it("raises an error for a call that needs a backend", function()
            assert.has_error(function()
                ns.AuctionClient.StartScan()
            end, "auction backend has no StartScan")
        end)
    end)

    describe("Use", function()
        it("forwards calls and events to the backend", function()
            ns.AuctionClient.Use({
                CanScan = function() return true end,
                RowCount = function() return 7 end,
                ScanDoneEvent = function() return "DONE" end,
            })
            assert.is_true(ns.AuctionClient.CanScan())
            assert.are.equal(7, ns.AuctionClient.RowCount())
            assert.are.equal("DONE", ns.AuctionClient.ScanDoneEvent())
        end)

        it("rejects a backend that is not a table", function()
            assert.has_error(function()
                ns.AuctionClient.Use("x")
            end)
        end)
    end)

    describe("Forever backend scan part", function()
        before_each(function()
            assert(loadfile(manifest.path("ForeverBackend")))("Flipside", ns)
        end)

        it("loads before ScanClock in the TOC", function()
            local files = manifest.files()
            assert.is_true(manifest.indexOf(files, "AuctionClient") < manifest.indexOf(files, "ForeverBackend"))
            assert.is_true(manifest.indexOf(files, "ForeverBackend") < manifest.indexOf(files, "ScanClock"))
        end)

        it("can scan when ReplicateItems exists and starts it", function()
            assert.is_true(ns.AuctionClient.CanScan())
            ns.AuctionClient.StartScan()
            assert.are.equal(1, mock.replicateCalls)
            assert.are.equal("REPLICATE_ITEM_LIST_UPDATE", ns.AuctionClient.ScanDoneEvent())
        end)

        it("cannot scan when ReplicateItems is missing", function()
            _G.C_AuctionHouse.ReplicateItems = nil
            assert.is_false(ns.AuctionClient.CanScan())
        end)

        it("maps a recorded Forever tuple to count, buyout, itemID, hasAllInfo", function()
            _G.C_AuctionHouse.GetReplicateItemInfo = function()
                return tuple(5, 12345, 777, true)
            end
            local count, buyout, itemID, hasAll = ns.AuctionClient.ReadRow(0)
            assert.are.equal(5, count)
            assert.are.equal(12345, buyout)
            assert.are.equal(777, itemID)
            assert.is_true(hasAll)
        end)

        it("returns no item id for a missing row", function()
            _G.C_AuctionHouse.GetReplicateItemInfo = function() end
            assert.is_nil(select(3, ns.AuctionClient.ReadRow(9)))
        end)

        it("reads the row count, the link and the pet flag", function()
            mock.rows = { { itemID = 1, count = 1, buyout = 10, hasAll = true, link = "L" } }
            assert.are.equal(1, ns.AuctionClient.RowCount())
            assert.are.equal("L", ns.AuctionClient.RowLink(0))
            assert.is_false(ns.AuctionClient.RowIsPet(0))
            _G.C_AuctionHouse.GetReplicateItemBattlePetInfo = function() return "Pet" end
            assert.is_true(ns.AuctionClient.RowIsPet(0))
        end)

        it("gives the commodity flag, or nil if unknown", function()
            mock.commodity[5] = true
            assert.is_true(ns.AuctionClient.HasCommodityCheck())
            assert.is_true(ns.AuctionClient.ItemIsCommodity(5))
            assert.is_nil(ns.AuctionClient.ItemIsCommodity(6))
        end)

        it("gives the same rows as the raw client tuples through ScanRows", function()
            local records = {
                { 1, 5000, 1001, true }, { 5, 25000, 2001, true }, { 5, 0, 2001, true },
                { 0, 700, 2002, false }, { 3, 900, nil, true },
            }
            _G.C_AuctionHouse.GetNumReplicateItems = function() return #records end
            _G.C_AuctionHouse.GetReplicateItemInfo = function(index)
                local r = records[index + 1]
                return tuple(r[1], r[2], r[3], r[4])
            end
            _G.C_AuctionHouse.GetReplicateItemLink = function() return nil end
            assert(loadfile(manifest.path("ScanKey")))("Flipside", ns)
            assert(loadfile(manifest.path("ScanRows")))("Flipside", ns)
            local job = {
                IsCancelled = function() return false end,
                Checkpoint = function() end,
                SetProgress = function() end,
            }
            local client = ns.AuctionClient
            local viaClient = ns.ScanRows.Read(job, {
                getNum = client.RowCount, readRow = client.ReadRow, getLink = client.RowLink,
            })
            local viaRaw = ns.ScanRows.Read(job, {
                getNum = _G.C_AuctionHouse.GetNumReplicateItems,
                getInfo = _G.C_AuctionHouse.GetReplicateItemInfo,
                getLink = _G.C_AuctionHouse.GetReplicateItemLink,
            })
            assert.are.same(viaRaw, viaClient)
            assert.are.equal(2, viaClient.stats.kept)
        end)
    end)

    describe("Forever backend name search, capture and owned auctions", function()
        before_each(function()
            assert(loadfile(manifest.path("ForeverBackend")))("Flipside", ns)
        end)

        it("sends a browse query and reads the results", function()
            mock.browseRows = { { itemKey = { itemID = 5 } } }
            mock.itemNames[5] = "Bolt"
            ns.AuctionClient.NameSearch("bol")
            assert.are.equal("bol", mock.browseQueries[1].searchString)
            assert.are.same({}, mock.browseQueries[1].sorts)
            assert.are.equal("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", ns.AuctionClient.NameResultEvent())
            assert.are.equal(mock.browseRows, ns.AuctionClient.NameResults())
            assert.are.equal("Bolt", ns.AuctionClient.NameItemKeyInfo({ itemID = 5 }).itemName)
        end)

        it("raises a clear error when a name search function is missing", function()
            _G.C_AuctionHouse.SendBrowseQuery = nil
            assert.has_error(function()
                ns.AuctionClient.NameSearch("x")
            end, "C_AuctionHouse.SendBrowseQuery is not available")
        end)

        it("gives the capture reads and events", function()
            local capture = ns.AuctionClient.Capture()
            assert.are.equal(_G.C_AuctionHouse.GetNumCommoditySearchResults, capture.api.commodityNum)
            assert.are.equal(_G.C_AuctionHouse.HasFullItemSearchResults, capture.api.itemFull)
            assert.are.equal("COMMODITY_SEARCH_RESULTS_UPDATED", capture.commodityEvent)
            assert.are.equal("ITEM_SEARCH_RESULTS_UPDATED", capture.itemEvent)
        end)

        it("searches one item by item key", function()
            local sent
            _G.C_AuctionHouse.MakeItemKey = function(itemID) return { itemID = itemID } end
            _G.C_AuctionHouse.SendSearchQuery = function(...) sent = { ... } end
            assert.is_true(ns.AuctionClient.CanTargetSearch())
            ns.AuctionClient.TargetedSearch(2589)
            assert.are.same({ { itemID = 2589 }, {}, true }, sent)
            _G.C_AuctionHouse.SendSearchQuery = nil
            assert.is_false(ns.AuctionClient.CanTargetSearch())
        end)

        it("reads the owned auctions", function()
            mock.ownedAuctions = { { itemID = 1 } }
            assert.is_true(ns.AuctionClient.CanReadOwned())
            assert.are.equal(mock.ownedAuctions, ns.AuctionClient.OwnedAuctions())
            assert.are.equal("OWNED_AUCTIONS_UPDATED", ns.AuctionClient.OwnedEvent())
            _G.C_AuctionHouse.GetOwnedAuctions = nil
            assert.is_false(ns.AuctionClient.CanReadOwned())
        end)

        it("gives the open and close events", function()
            assert.are.equal("AUCTION_HOUSE_SHOW", ns.AuctionClient.OpenEvent())
            assert.are.equal("AUCTION_HOUSE_CLOSED", ns.AuctionClient.CloseEvent())
        end)
    end)

    describe("Forever backend live search", function()
        before_each(function()
            assert(loadfile(manifest.path("ForeverBackend")))("Flipside", ns)
        end)

        it("sends one targeted search for the item key", function()
            assert.is_true(ns.AuctionClient.CanLiveSearch())
            assert.is_true(ns.AuctionClient.LiveSearch(5))
            assert.are.equal(5, mock.searchQueries[1].itemKey.itemID)
            assert.is_true(mock.searchQueries[1].separate)
        end)

        it("stops after 100 searches in a minute and allows again later", function()
            for _ = 1, 100 do
                assert.is_true(ns.AuctionClient.LiveSearch(5))
            end
            local ok, text = ns.AuctionClient.LiveSearch(5)
            assert.is_false(ok)
            assert.are.equal("search limit, wait", text)
            assert.are.equal(100, #mock.searchQueries)
            mock.clock = mock.clock + 61
            assert.is_true(ns.AuctionClient.LiveSearch(5))
        end)

        it("gives the result and ready events", function()
            local commodity, item = ns.AuctionClient.LiveResultEvents()
            assert.are.equal("COMMODITY_SEARCH_RESULTS_UPDATED", commodity)
            assert.are.equal("ITEM_SEARCH_RESULTS_UPDATED", item)
            assert.are.equal("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", ns.AuctionClient.ReadyEvent())
        end)

        it("gives commodity rows sorted by unit price", function()
            mock.commodity[5] = true
            mock.commodityResults[5] = {
                { auctionID = 2, unitPrice = 30, quantity = 4, timeLeftSeconds = 900 },
                { auctionID = 1, unitPrice = 10, quantity = 20, owner = true },
            }
            local rows = ns.AuctionClient.LiveRows(5)
            assert.are.equal(2, #rows)
            assert.are.same({ auctionID = 1, unitPrice = 10, quantity = 20, isCommodity = true, ownerItem = true },
                rows[1])
            assert.are.equal(30, rows[2].unitPrice)
            assert.are.equal(900, rows[2].timeLeft)
            assert.is_false(rows[2].ownerItem)
        end)

        it("gives item rows with the unit price and skips bid-only rows", function()
            mock.commodity[6] = false
            mock.itemResults[6] = {
                { auctionID = 3, link = "L3", buyout = 900, quantity = 3, timeLeft = 2 },
                { auctionID = 4, link = "L4", buyout = nil, quantity = 1 },
                { auctionID = 5, link = "L5", buyout = 100, quantity = 1 },
            }
            local rows = ns.AuctionClient.LiveRows(6)
            assert.are.equal(2, #rows)
            assert.are.equal(5, rows[1].auctionID)
            assert.are.equal(300, rows[2].unitPrice)
            assert.are.equal(3, rows[2].quantity)
            assert.are.equal("L3", rows[2].itemLink)
            assert.are.equal(2, rows[2].timeLeft)
            assert.is_false(rows[2].isCommodity)
        end)

        it("reads the ready flag and asks for the owned list", function()
            assert.is_true(ns.AuctionClient.IsReady())
            mock.throttleReady = false
            assert.is_false(ns.AuctionClient.IsReady())
            ns.AuctionClient.RefreshOwned()
            assert.are.same({ {} }, mock.ownedQueries)
        end)
    end)

    describe("live search without support", function()
        it("is off without a backend", function()
            assert.is_false(ns.AuctionClient.CanLiveSearch())
            assert.is_false(ns.AuctionClient.LiveSearch(5))
            assert.is_nil(ns.AuctionClient.LiveResultEvents())
            assert.are.same({}, ns.AuctionClient.LiveRows(5))
            assert.is_nil(ns.AuctionClient.ReadyEvent())
            assert.is_nil(ns.AuctionClient.RefreshOwned())
        end)

        it("is off on a backend without the calls (TBC legacy)", function()
            ns.AuctionClient.Use({ CanScan = function() return true end })
            assert.is_false(ns.AuctionClient.CanLiveSearch())
            assert.is_false(ns.AuctionClient.LiveSearch(5))
            assert.are.same({}, ns.AuctionClient.LiveRows(5))
        end)

        it("is off when the Forever calls are missing", function()
            assert(loadfile(manifest.path("ForeverBackend")))("Flipside", ns)
            _G.C_AuctionHouse.SendSearchQuery = nil
            assert.is_false(ns.AuctionClient.CanLiveSearch())
        end)
    end)
end)