local manifest = require("Tests.manifest")

local TOC = "Flipside_TBC.toc"

describe("LegacyBackend scan", function()
    local ns, saved, rows, canQuery, canMass, queries, batchOverride, tuples

    local names = { "CanSendAuctionQuery", "QueryAuctionItems", "GetNumAuctionItems", "GetAuctionItemInfo",
        "GetAuctionItemLink", "GetTime", "GetServerTime", "FlipsideScanDB_TBC" }

    before_each(function()
        saved = {}
        for _, name in ipairs(names) do
            saved[name] = _G[name]
        end
        rows, canQuery, canMass, queries, batchOverride = {}, true, true, {}, nil
        _G.CanSendAuctionQuery = function() return canQuery, canMass end
        _G.QueryAuctionItems = function(...) queries[#queries + 1] = { n = select("#", ...), ... } end
        _G.GetNumAuctionItems = function() return batchOverride or #rows, #rows end
        _G.GetAuctionItemInfo = function(kind, i)
            assert.are.equal("list", kind)
            local r = rows[i]
            return r.name, 1, r.count, 1, true, 1, 0, 0, 0, r.buyout, 0, false, "", "o", "", 0, r.id, r.hasAll
        end
        _G.GetAuctionItemLink = function(_, i) return rows[i].link end
        _G.GetTime = function() return 10 end
        _G.GetServerTime = function() return 1000 end
        _G.FlipsideScanDB_TBC = {}
        ns = { Flavour = { savedVariables = { scan = "FlipsideScanDB_TBC" } } }
        assert(loadfile(manifest.path("AuctionClient", TOC)))("Flipside", ns)
        assert(loadfile(manifest.path("LegacyBackend", TOC)))("Flipside", ns)
        assert(loadfile(manifest.path("ScanKey", TOC)))("Flipside", ns)
        assert(loadfile(manifest.path("ScanRows", TOC)))("Flipside", ns)
        tuples = ns.AuctionClient
    end)

    after_each(function()
        for _, name in ipairs(names) do
            _G[name] = saved[name]
        end
    end)

    it("starts a getAll query with the seventh argument true", function()
        tuples.StartScan()
        assert.are.same({ "", nil, nil, 0, false, 0, true, false, nil, n = 9 }, queries[1])
        assert.are.equal("AUCTION_ITEM_LIST_UPDATE", tuples.ScanDoneEvent())
        assert.are.equal(2, tuples.ScanSettleSeconds())
    end)

    it("can scan only with the three legacy functions", function()
        assert.is_true(tuples.CanScan())
        _G.GetAuctionItemInfo = nil
        assert.is_false(tuples.CanScan())
    end)

    it("refuses when get all is on cooldown, and when the client is busy", function()
        assert.is_true(tuples.ScanCanStart())
        canMass = false
        local ok, text = tuples.ScanCanStart()
        assert.is_false(ok)
        assert.is_truthy(text:find("get all is on cooldown", 1, true))
        canQuery = false
        ok, text = tuples.ScanCanStart()
        assert.is_false(ok)
        assert.is_truthy(text:find("busy", 1, true))
    end)

    it("is complete when the batch equals the total", function()
        rows[1] = { name = "A", count = 1, buyout = 5, id = 1, hasAll = true }
        rows[2] = rows[1]
        batchOverride = 1
        assert.is_false(tuples.ScanComplete())
        batchOverride = nil
        assert.is_true(tuples.ScanComplete())
        rows = {}
        assert.is_false(tuples.ScanComplete())
    end)

    it("maps 0-based rows to the legacy tuple", function()
        rows[1] = { name = "A", count = 20, buyout = 2000, id = 7, hasAll = true, link = "L" }
        assert.are.equal(1, tuples.RowCount())
        local count, buyout, id, all = tuples.ReadRow(0)
        assert.are.same({ 20, 2000, 7, true }, { count, buyout, id, all })
        assert.are.equal("L", tuples.RowLink(0))
        assert.is_false(tuples.RowIsPet(0))
        assert.is_nil(tuples.ItemIsCommodity(7))
    end)

    it("gives per-item prices and skips bid-only rows through ScanRows", function()
        local link = "|cffffffff|Hitem:2589::::::::60:::::|h[X]|h|r"
        rows[1] = { name = "X", count = 20, buyout = 2000, id = 2589, hasAll = true, link = link }
        rows[2] = { name = "X", count = 5, buyout = 0, id = 2589, hasAll = true, link = link }
        local job = { IsCancelled = function() return false end, Checkpoint = function() end,
            SetProgress = function() end }
        local result = ns.ScanRows.Read(job, {
            getNum = tuples.RowCount, readRow = tuples.ReadRow, getLink = tuples.RowLink,
            getPetInfo = function() return nil end,
        })
        assert.are.equal(1, result.stats.kept)
        assert.are.equal(1, result.stats.bidOnly)
        assert.are.equal(100, result.byItem[2589][1].unitPrice)
    end)

    it("fills the diagnostics line and keeps the last 5 runs", function()
        rows[1] = { name = "A", count = 1, buyout = 5, id = 1, hasAll = true }
        rows[2] = { name = "", count = 1, buyout = 0, id = 2, hasAll = true }
        local line
        for _ = 1, 7 do
            tuples.StartScan()
            tuples.RowCount()
            tuples.ReadRow(0)
            tuples.ReadRow(1)
            tuples.RowLink(0)
            tuples.RowLink(0)
            line = tuples.ScanDiagnostics({ result = "ok", rows = 2, items = 1, keys = 1, events = 3,
                firstEventMs = 1500 })
        end
        assert.is_truthy(line:find("rows 2, batch 2 of 2, first event 1500 ms, events 3", 1, true))
        assert.is_truthy(line:find("nil link 1, nil name 1, zero buyout 1, items 1", 1, true))
        assert.are.equal(5, #_G.FlipsideScanDB_TBC.diag)
        assert.are.equal(1000, _G.FlipsideScanDB_TBC.diag[5].time)
    end)

    it("lists the three scan modes with refresh times", function()
        assert.are.same({ "full", "fast", "page" }, tuples.ScanModes())
        assert.is_true(tuples.ScanRefreshSeconds("full") > tuples.ScanRefreshSeconds("fast"))
        assert.is_true(tuples.ScanRefreshSeconds("fast") > 0)
    end)

    it("queries one page without the get all flag and reads the total", function()
        rows[1] = { name = "A", count = 1, buyout = 5, id = 1, hasAll = true }
        tuples.ScanPageQuery(0)
        tuples.ScanPageQuery(7)
        assert.are.same({ "", nil, nil, 0, false, 0, false, false, nil, n = 9 }, queries[1])
        assert.are.same({ "", nil, nil, 7, false, 0, false, false, nil, n = 9 }, queries[2])
        assert.are.equal(1, tuples.ScanTotal())
    end)

    it("needs no get all permission for the page mode", function()
        canMass = false
        assert.is_false(tuples.ScanCanStart("full"))
        assert.is_false(tuples.ScanCanStart("fast"))
        assert.is_true(tuples.ScanCanStart("page"))
        assert.is_true(tuples.CanQueryPage())
        canQuery = false
        assert.is_false(tuples.CanQueryPage())
        assert.is_false(tuples.ScanCanStart("page"))
    end)

    it("shows the new fields in the diagnostics line", function()
        local line = tuples.ScanDiagnostics({ result = "ok", mode = "page", rows = 2, items = 1, keys = 1,
            pendingMissing = 3, failed = 4, keyedWithoutLink = 5, refreshSeconds = 6, pages = 7 })
        assert.is_truthy(line:find("mode page, rows 2", 1, true))
        assert.is_truthy(line:find("keys 1, pending 3, failed 4, keyed without link 5, refresh 6.0 s, pages 7", 1,
            true))
    end)
end)
