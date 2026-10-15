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
        _G.GetNumAuctionItems = function(kind) return #lists[kind], #lists[kind] end
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

    it("can scan and has no commodity check", function()
        assert.is_true(A().CanScan())
        assert.is_nil(A().ItemIsCommodity(1))
        assert.is_false(A().HasCommodityCheck())
    end)

    describe("capture", function()
        local source, savedHook

        -- A user search: the client global, which the hook sees.
        local function userQuery(getAll)
            _G.QueryAuctionItems("mage", nil, nil, 0, false, 0, getAll == true, false, nil)
        end

        local function row(id, count, buyout, link)
            return { info = { "N", 1, count, 1, true, 1, 0, 0, 0, buyout, 0, false, "", "o", "", 0, id, true },
                link = link }
        end

        before_each(function()
            savedHook = _G.hooksecurefunc
            _G.hooksecurefunc = function(name, fn)
                local original = _G[name]
                _G[name] = function(...)
                    local results = { original(...) }
                    fn(...)
                    return unpack(results)
                end
            end
            source = A().Capture()
        end)

        after_each(function()
            _G.hooksecurefunc = savedHook
        end)

        it("gives the legacy page event and a short debounce", function()
            assert.are.equal("AUCTION_ITEM_LIST_UPDATE", source.pageEvent)
            assert.is_true(source.debounceSeconds > 0 and source.debounceSeconds <= 0.5)
        end)

        it("is off without the list functions", function()
            _G.GetAuctionItemInfo = nil
            assert.is_nil(A().Capture())
        end)

        it("reads one page of a user search with count, buyout, item ID and link", function()
            userQuery()
            lists.list = {
                row(11, 5, 500, "|Hitem:11|h[A]|h"),
                row(12, 1, 90, nil),
            }
            local rows, full = source.readPage()
            assert.are.equal(2, #rows)
            assert.are.same({ itemID = 11, count = 5, buyout = 500, link = "|Hitem:11|h[A]|h" }, rows[1])
            assert.are.same({ itemID = 12, count = 1, buyout = 90 }, rows[2])
            assert.is_true(full)
        end)

        it("marks a page partial when the total is larger than the page", function()
            userQuery()
            lists.list = { row(11, 1, 5) }
            _G.GetNumAuctionItems = function() return 1, 80 end
            local _, full = source.readPage()
            assert.is_false(full)
        end)

        it("reads a page once for each query", function()
            userQuery()
            lists.list = { row(11, 1, 5) }
            assert.is_table(source.readPage())
            assert.is_nil(source.readPage())
            userQuery()
            assert.is_table(source.readPage())
        end)

        it("reads nothing before any query or from an empty page", function()
            lists.list = { row(11, 1, 5) }
            assert.is_nil(source.readPage())
            userQuery()
            lists.list = {}
            assert.is_nil(source.readPage())
        end)

        it("ignores a Flipside scan, a name search and a get-all", function()
            lists.list = { row(11, 1, 5) }
            A().StartScan()
            assert.is_nil(source.readPage())
            A().NameSearch("bolt")
            assert.is_nil(source.readPage())
            userQuery(true)
            assert.is_nil(source.readPage())
            userQuery()
            assert.is_table(source.readPage())
        end)

        it("ignores a page longer than a browse page", function()
            userQuery()
            for i = 1, 51 do
                lists.list[i] = row(11, 1, 5)
            end
            assert.is_nil(source.readPage())
        end)
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

    describe("scan start gate", function()
        it("asks the client about the list query", function()
            -- The mock asserts that the argument is "list".
            assert.is_true(A().ScanCanStart("page"))
            assert.is_true(A().CanQueryPage())
            local ok, text = A().ScanCanStart("full")
            assert.is_false(ok)
            assert.is_truthy(text:find("get all", 1, true))
        end)
    end)

    describe("live search and buy", function()
        local ADDON_NAME = "Copper Bar"
        local timers, bid, emitted, saved2

        -- Legacy tuple with an owner and a buyout.
        local function listing(count, buyout, itemID, owner)
            return { info = { ADDON_NAME, 1, count, 1, true, 1, 0, 0, 0, buyout, 0, false, "", owner or "Seller", "", 0,
                itemID, true }, link = "|Hitem:" .. itemID .. "|h[" .. ADDON_NAME .. "]|h" }
        end

        before_each(function()
            saved2 = {}
            for _, name in ipairs({ "GetItemInfo", "UnitName", "C_Timer", "PlaceAuctionBid", "ERR_AUCTION_WON_S" }) do
                saved2[name] = _G[name]
            end
            timers, bid, emitted = {}, {}, {}
            _G.GetItemInfo = function(id)
                return id == 11 and ADDON_NAME or nil
            end
            _G.UnitName = function() return "Me" end
            _G.C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
            _G.PlaceAuctionBid = function(...) bid[#bid + 1] = { n = select("#", ...), ... } end
            _G.ERR_AUCTION_WON_S = "You won an auction for %s."
            assert(loadfile(manifest.path("EventBus", TOC)))("Flipside", ns)
            ns.bus = ns.EventBus.New({})
            for _, event in ipairs({ "Flipside.LegacyQueryReady", "Flipside.LegacyBuyCompleted",
                "Flipside.LegacyBuyError" }) do
                ns.bus:Subscribe(event, "spec", function(name, ...)
                    emitted[#emitted + 1] = { name, ... }
                end)
            end
        end)

        after_each(function()
            for name, value in pairs(saved2) do
                _G[name] = value
            end
            _G.GetItemInfo, _G.UnitName, _G.C_Timer = saved2.GetItemInfo, saved2.UnitName, saved2.C_Timer
            _G.PlaceAuctionBid, _G.ERR_AUCTION_WON_S = saved2.PlaceAuctionBid, saved2.ERR_AUCTION_WON_S
        end)

        it("can live search and can buy only with the client functions", function()
            assert.is_true(A().CanLiveSearch())
            assert.is_true(A().CanBuy())
            _G.PlaceAuctionBid = nil
            assert.is_false(A().CanBuy())
            _G.QueryAuctionItems = nil
            assert.is_false(A().CanLiveSearch())
        end)

        it("sends one exact-name query for page 0", function()
            assert.is_true(A().LiveSearch(11))
            assert.are.equal(1, #queries)
            assert.are.same({ ADDON_NAME, nil, nil, 0, false, 0, false, true, nil, n = 9 }, queries[1])
        end)

        it("refuses with a text and sends no query when the client is busy", function()
            canQuery = false
            assert.is_false(A().IsReady())
            local ok, text = A().LiveSearch(11)
            assert.is_false(ok)
            assert.is_truthy(text:find("busy", 1, true))
            assert.are.equal(0, #queries)
        end)

        it("refuses with a text when the item name is not loaded", function()
            local ok, text = A().LiveSearch(99)
            assert.is_false(ok)
            assert.is_truthy(text:find("not loaded", 1, true))
            assert.are.equal(0, #queries)
        end)

        it("gives the list update as the item result event", function()
            local commodity, item = A().LiveResultEvents()
            assert.are.equal("AUCTION_ITEM_LIST_UPDATE", item)
            assert.are_not.equal(item, commodity)
        end)

        it("emits the ready event when the client takes a query again", function()
            A().LiveSearch(11)
            assert.are.equal("Flipside.LegacyQueryReady", A().ReadyEvent())
            canQuery = false
            table.remove(timers, 1)()
            assert.are.equal(0, #emitted)
            canQuery = true
            table.remove(timers, 1)()
            assert.are.equal(1, #emitted)
            assert.are.equal("Flipside.LegacyQueryReady", emitted[1][1])
            assert.are.equal(0, #timers)
        end)

        it("reads the rows of the item, cheapest unit first, with the list index as ID", function()
            lists.list = {
                listing(5, 500, 11),
                listing(1, 60, 11, "Me"),
                listing(2, 100, 12),
                listing(3, 0, 11),
                listing(10, 400, 11),
            }
            local rows = A().LiveRows(11)
            assert.are.equal(3, #rows)
            assert.are.equal(5, rows[1].auctionID)
            assert.are.equal(40, rows[1].unitPrice)
            assert.are.equal(2, rows[2].auctionID)
            assert.are.equal(60, rows[2].unitPrice)
            assert.is_true(rows[2].ownerItem)
            assert.are.equal(1, rows[3].auctionID)
            assert.are.equal(100, rows[3].unitPrice)
            assert.are.equal(500, rows[3].buyout)
            assert.are.equal(5, rows[3].quantity)
            assert.is_false(rows[3].isCommodity)
            assert.is_false(rows[3].ownerItem)
            assert.are.equal("|Hitem:11|h[Copper Bar]|h", rows[3].itemLink)
        end)

        describe("buy", function()
            before_each(function()
                lists.list = { listing(5, 500, 11), listing(1, 60, 11) }
                A().LiveRows(11)
            end)

            it("places the bid on the list index at the buyout", function()
                A().BuyItemAuction(1, 500)
                assert.are.same({ "list", 1, 500, n = 3 }, bid[1])
            end)

            it("refuses a row from no search", function()
                local ok, err = pcall(A().BuyItemAuction, 7, 500)
                assert.is_false(ok)
                assert.is_truthy(err:find("search again", 1, true))
                assert.are.equal(0, #bid)
            end)

            it("refuses a row with a changed buyout", function()
                lists.list[1].info[10] = 450
                local ok, err = pcall(A().BuyItemAuction, 1, 500)
                assert.is_false(ok)
                assert.is_truthy(err:find("changed", 1, true))
                assert.are.equal(0, #bid)
            end)

            it("refuses a row with a changed count", function()
                lists.list[1].info[3] = 4
                assert.is_false((pcall(A().BuyItemAuction, 1, 500)))
                assert.are.equal(0, #bid)
            end)

            it("refuses a row with a changed item", function()
                lists.list[1].info[17] = 12
                assert.is_false((pcall(A().BuyItemAuction, 1, 500)))
                assert.are.equal(0, #bid)
            end)

            it("refuses a row with a changed owner", function()
                lists.list[1].info[14] = "Other"
                assert.is_false((pcall(A().BuyItemAuction, 1, 500)))
                assert.are.equal(0, #bid)
            end)

            it("refuses a buyout that is not the buyout of the row", function()
                assert.is_false((pcall(A().BuyItemAuction, 1, 499)))
                assert.are.equal(0, #bid)
            end)

            it("refuses a second buy on the same read", function()
                A().BuyItemAuction(1, 500)
                assert.is_false((pcall(A().BuyItemAuction, 1, 500)))
                assert.are.equal(1, #bid)
            end)

            it("raises the client error and tells no buy", function()
                A().BuyEvents()
                _G.PlaceAuctionBid = function() error("protected") end
                local ok, err = pcall(A().BuyItemAuction, 1, 500)
                assert.is_false(ok)
                assert.is_truthy(err:find("protected", 1, true))
                ns.bus:Emit("CHAT_MSG_SYSTEM", "You won an auction for Copper Bar.")
                assert.are.equal(0, #emitted)
            end)

            it("emits the completed event with the index when the won text comes", function()
                local events = A().BuyEvents()
                assert.are.equal("Flipside.LegacyBuyCompleted", events.itemCompleted)
                assert.are.equal("Flipside.LegacyBuyError", events.itemError)
                A().BuyItemAuction(1, 500)
                ns.bus:Emit("CHAT_MSG_SYSTEM", "You won an auction for Iron Bar.")
                assert.are.equal(0, #emitted)
                ns.bus:Emit("CHAT_MSG_SYSTEM", "You won an auction for Copper Bar.")
                assert.are.same({ "Flipside.LegacyBuyCompleted", 1 }, emitted[1])
                ns.bus:Emit("CHAT_MSG_SYSTEM", "You won an auction for Copper Bar.")
                assert.are.equal(1, #emitted)
            end)

            it("emits the error event with the text of a client error after the buy", function()
                A().BuyEvents()
                ns.bus:Emit("UI_ERROR_MESSAGE", 1, "Not enough money")
                assert.are.equal(0, #emitted)
                A().BuyItemAuction(1, 500)
                ns.bus:Emit("UI_ERROR_MESSAGE", 1, "Not enough money")
                assert.are.same({ "Flipside.LegacyBuyError", "Not enough money" }, emitted[1])
            end)

            it("gives events that the legacy client never sends for the commodity quote", function()
                local events = A().BuyEvents()
                for _, key in ipairs({ "priceUpdated", "priceUnavailable", "commoditySucceeded", "commodityFailed" }) do
                    assert.is_string(events[key])
                    assert.is_nil(events[key]:find("^[A-Z_]+$"))
                end
            end)
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
