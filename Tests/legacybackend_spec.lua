local manifest = require("Tests.manifest")

local TOC = "Flipside_TBC.toc"

-- Legacy tuple: name, texture, count, quality, canUse, level, levelType, minBid, minIncrement, buyout,
-- bidAmount, highBidder, bidderName, owner, ownerName, saleStatus, itemID, hasAllInfo.
local function tuple(name, count, saleStatus, itemID)
    return name, 134400, count, 1, true, 1, 0, 0, 0, 100, 0, false, "", "o", "", saleStatus or 0, itemID, true
end

describe("LegacyBackend", function()
    local ns, lists, canQuery, queries, saved

    before_each(function()
        saved = {}
        for _, name in ipairs({ "CanSendAuctionQuery", "QueryAuctionItems", "GetNumAuctionItems",
            "GetAuctionItemInfo", "GetAuctionItemLink" }) do
            saved[name] = _G[name]
        end
        lists = { list = {}, owner = {} }
        canQuery, queries = true, {}
        _G.CanSendAuctionQuery = function(kind)
            assert.are.equal("list", kind)
            return canQuery
        end
        _G.QueryAuctionItems = function(...)
            queries[#queries + 1] = { n = select("#", ...), ... }
        end
        _G.GetNumAuctionItems = function(kind) return #lists[kind] end
        _G.GetAuctionItemInfo = function(kind, i) return unpack(lists[kind][i].info) end
        _G.GetAuctionItemLink = function(kind, i) return lists[kind][i].link end
        ns = {}
        assert(loadfile(manifest.path("AuctionClient", TOC)))("Flipside", ns)
        assert(loadfile(manifest.path("LegacyBackend", TOC)))("Flipside", ns)
    end)

    after_each(function()
        for name, value in pairs(saved) do
            _G[name] = value
        end
        _G.CanSendAuctionQuery, _G.QueryAuctionItems = saved.CanSendAuctionQuery, saved.QueryAuctionItems
    end)

    local A = function() return ns.AuctionClient end

    it("can scan and has no capture or commodity check", function()
        assert.is_true(A().CanScan())
        assert.is_nil(A().Capture())
        assert.is_nil(A().ItemIsCommodity(1))
        assert.is_false(A().HasCommodityCheck())
    end)

    describe("name search", function()
        it("uses the legacy browse event and sends one page-0 query", function()
            assert.are.equal("AUCTION_ITEM_LIST_UPDATE", A().NameResultEvent())
            A().NameSearch("bolt")
            assert.are.equal(1, #queries)
            assert.are.same({ "bolt", nil, nil, 0, false, 0, false, false, nil, n = 9 }, queries[1])
        end)

        it("gives a clear error and no query when the client is busy", function()
            canQuery = false
            local ok, err = pcall(A().NameSearch, "bolt")
            assert.is_false(ok)
            assert.are.equal("the Auction House is busy, try again in a moment", err)
            assert.are.equal(0, #queries)
        end)

        it("gives one row for each item ID and the name through the item key", function()
            lists.list = {
                { info = { tuple("Copper Bolt", 5, 0, 11) } },
                { info = { tuple("Copper Bolt", 1, 0, 11) } },
                { info = { tuple("Iron Bolt", 2, 0, 12) } },
                { info = { tuple("", 2, 0, 13) } },
            }
            local rows = A().NameResults()
            assert.are.equal(2, #rows)
            assert.are.equal(11, rows[1].itemKey.itemID)
            assert.are.equal("Copper Bolt", A().NameItemKeyInfo(rows[1].itemKey).itemName)
            assert.are.equal("Iron Bolt", A().NameItemKeyInfo(rows[2].itemKey).itemName)
            assert.is_nil(A().NameItemKeyInfo({ itemID = 99 }).itemName)
        end)
    end)

    describe("owned auctions", function()
        it("can read and uses the owned event", function()
            assert.is_true(A().CanReadOwned())
            assert.are.equal("AUCTION_OWNED_LIST_UPDATE", A().OwnedEvent())
            _G.GetAuctionItemInfo = nil
            assert.is_false(A().CanReadOwned())
        end)

        it("maps count, sale status, item ID and link", function()
            lists.owner = {
                { info = { tuple("A", 20, 0, 11) }, link = "|Hitem:11|h[A]|h" },
                { info = { tuple("B", 3, 1, 12) }, link = "|Hitem:12|h[B]|h" },
            }
            local rows = A().OwnedAuctions()
            assert.are.equal(2, #rows)
            assert.are.equal(20, rows[1].quantity)
            assert.are.equal(0, rows[1].status)
            assert.are.equal("|Hitem:11|h[A]|h", rows[1].itemLink)
            assert.are.equal(11, rows[1].itemKey.itemID)
            assert.are.equal(1, rows[2].status)
        end)

        it("does not query the owner list", function()
            _G.GetOwnerAuctionItems = function() error("must not be called") end
            A().OwnedAuctions()
            _G.GetOwnerAuctionItems = nil
        end)
    end)
end)
