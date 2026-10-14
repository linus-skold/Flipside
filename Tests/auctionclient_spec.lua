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
end)
