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

    it("loads the Selling tab after the Buying tab and before the host in the TBC TOC", function()
        local files = manifest.files(TOC)
        local buying = manifest.indexOf(files, "BuyingTab")
        local selling = manifest.indexOf(files, "SellingTab")
        assert.is_truthy(buying and selling)
        assert.are.equal(buying + 1, selling)
        assert.is_true(selling < manifest.indexOf(files, "AuctionTabHost"))
    end)

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

            it("gives the item of a row to the ledger before the buy call", function()
                local seen
                A().OnCall(function(name, id)
                    if name == "BuyItemAuction" then
                        seen = A().AuctionInfo(id)
                    end
                end)
                A().BuyItemAuction(1, 500)
                assert.are.equal("|Hitem:11|h[Copper Bar]|h", seen.itemLink)
                assert.are.equal(5, seen.quantity)
                assert.are.equal(500, seen.buyoutAmount)
            end)

            it("gives no info for a row with no item", function()
                assert.is_nil(A().AuctionInfo(99))
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

    describe("posting", function()
        local NAMES = { "C_Container", "C_Timer", "ClickAuctionSellItemButton", "GetAuctionSellItemInfo", "PostAuction",
            "GetAuctionDeposit", "ClearCursor", "CursorHasItem", "StaticPopup_Hide", "ERR_AUCTION_STARTED",
            "GetOwnerAuctionItems" }
        local keep, bag, cursor, sell, posts, postResult, hidden, timers, emitted, sellRejects, onPost, depositCalls

        local function key(b, s) return b .. ":" .. s end

        -- Picks up the item of a bag slot. As in the client, the item stays in the slot while the cursor holds it.
        local function pickup(b, s)
            local k = key(b, s)
            if cursor == nil and bag[k] then
                cursor = { key = k, item = bag[k] }
            end
        end

        before_each(function()
            keep = {}
            for _, name in ipairs(NAMES) do
                keep[name] = _G[name]
            end
            bag = { [key(0, 1)] = { itemID = 11, stackCount = 20, isBound = false } }
            cursor, sell, postResult, sellRejects, onPost = nil, nil, true, false, nil
            posts, hidden, timers, emitted = {}, {}, 0, {}
            _G.C_Container = {
                GetContainerItemInfo = function(b, s) return bag[key(b, s)] end,
                PickupContainerItem = pickup,
            }
            _G.C_Timer = { After = function() timers = timers + 1 end }
            _G.ClickAuctionSellItemButton = function()
                if cursor and not sellRejects then
                    sell, cursor = cursor, nil
                elseif cursor == nil and sell then
                    cursor, sell = sell, nil
                end
            end
            _G.GetAuctionSellItemInfo = function()
                if not sell then
                    return nil
                end
                return "Copper Bar", 1, sell.item.stackCount, 1, true, 0, 0, 20, sell.item.stackCount, sell.item.itemID
            end
            -- As the client: six arguments (prices, duration index, stack size, stack count, warning flag).
            _G.PostAuction = function(...)
                local n = select("#", ...)
                local a, b, c, d, e, f = ...
                if n ~= 6 or type(a) ~= "number" or type(b) ~= "number" or type(c) ~= "number"
                    or type(d) ~= "number" or type(e) ~= "number" or type(f) ~= "boolean" then
                    error("Usage: PostAuction(minBid, buyoutPrice, runTime, stackSize, numStacks, warning)", 2)
                end
                posts[#posts + 1] = { n = n, ... }
                if onPost then
                    onPost()
                end
                return postResult
            end
            depositCalls = {}
            _G.GetAuctionDeposit = function(...)
                depositCalls[#depositCalls + 1] = { n = select("#", ...), ... }
                return 66
            end
            _G.ClearCursor = function()
                cursor = nil
            end
            _G.CursorHasItem = function() return cursor ~= nil end
            _G.StaticPopup_Hide = function(which) hidden[#hidden + 1] = which end
            _G.ERR_AUCTION_STARTED = "Auction created."
            assert(loadfile(manifest.path("EventBus", TOC)))("Flipside", ns)
            ns.bus = ns.EventBus.New({})
            ns.bus:Subscribe("Flipside.LegacyPosted", "spec", function(name) emitted[#emitted + 1] = name end)
        end)

        after_each(function()
            for _, name in ipairs(NAMES) do
                _G[name] = keep[name]
            end
        end)

        it("can post only with every client function", function()
            assert.is_true(A().CanPost())
            _G.PostAuction = nil
            assert.is_false(A().CanPost())
            _G.PostAuction = function() end
            _G.C_Container.PickupContainerItem = nil
            assert.is_false(A().CanPost())
            _G.C_Container = nil
            assert.is_false(A().CanPost())
        end)

        describe("duration", function()
            it("maps 12 h, 24 h and 48 h to the index 1, 2 and 3", function()
                local backend = A().Backend()
                assert.are.equal(1, backend.DurationIndex(12))
                assert.are.equal(2, backend.DurationIndex(24))
                assert.are.equal(3, backend.DurationIndex(48))
            end)

            it("uses the nearest longer index for a value with no exact match", function()
                local backend = A().Backend()
                assert.are.equal(1, backend.DurationIndex(1))
                assert.are.equal(1, backend.DurationIndex(2))
                assert.are.equal(2, backend.DurationIndex(13))
                assert.are.equal(3, backend.DurationIndex(30))
                assert.are.equal(3, backend.DurationIndex(72))
            end)

            it("refuses a value that is not a number of hours", function()
                local backend = A().Backend()
                assert.is_false((pcall(backend.DurationIndex, 0)))
                assert.is_false((pcall(backend.DurationIndex, nil)))
                assert.is_false((pcall(backend.DurationIndex, "24")))
            end)

            it("sends the index to PostAuction", function()
                A().PostItem(0, 1, 48, 5, nil, 500, 11)
                assert.are.equal(3, posts[1][3])
            end)
        end)

        it("puts the bag item in the sale slot and posts one stack", function()
            assert.is_false(A().PostItem(0, 1, 24, 5, nil, 500, 11))
            assert.are.equal(1, #posts)
            assert.are.same({ 500, 500, 2, 5, 1, false, n = 6 }, posts[1])
            assert.are.equal(11, sell.item.itemID)
            assert.is_nil(cursor)
        end)

        it("uses the bid as the start price", function()
            A().PostItem(0, 1, 24, 5, 300, 500, 11)
            assert.are.same({ 300, 500, 2, 5, 1, false, n = 6 }, posts[1])
            assert.is_false((pcall(A().PostItem, 0, 1, 24, 5, 600, 500, 11)))
            assert.are.equal(1, #posts)
        end)

        it("posts with no planned item ID", function()
            A().PostItem(0, 1, 24, 5, nil, 500)
            assert.are.equal(1, #posts)
        end)

        it("refuses a bag slot that holds another item", function()
            bag[key(0, 1)].itemID = 12
            local ok, err = pcall(A().PostItem, 0, 1, 24, 5, nil, 500, 11)
            assert.is_false(ok)
            assert.is_truthy(err:find("another item", 1, true))
            assert.are.equal(0, #posts)
            assert.is_nil(sell)
            assert.is_nil(cursor)
        end)

        it("refuses a bag slot with fewer items than the plan", function()
            bag[key(0, 1)].stackCount = 4
            local ok, err = pcall(A().PostItem, 0, 1, 24, 5, nil, 500, 11)
            assert.is_false(ok)
            assert.is_truthy(err:find("fewer items", 1, true))
            assert.are.equal(0, #posts)
        end)

        it("refuses an empty bag slot", function()
            bag[key(0, 1)] = nil
            local ok, err = pcall(A().PostItem, 0, 1, 24, 5, nil, 500, 11)
            assert.is_false(ok)
            assert.is_truthy(err:find("empty", 1, true))
            assert.are.equal(0, #posts)
        end)

        it("refuses when the cursor holds an item", function()
            cursor = { key = "9:9", item = { itemID = 5, stackCount = 1 } }
            local ok, err = pcall(A().PostItem, 0, 1, 24, 5, nil, 500, 11)
            assert.is_false(ok)
            assert.is_truthy(err:find("cursor", 1, true))
            assert.are.equal(0, #posts)
            assert.is_not_nil(cursor)
        end)

        it("clears the cursor and posts nothing when the item does not go in the sale slot", function()
            sellRejects = true
            local ok, err = pcall(A().PostItem, 0, 1, 24, 5, nil, 500, 11)
            assert.is_false(ok)
            assert.is_truthy(err:find("sale slot", 1, true))
            assert.are.equal(0, #posts)
            assert.is_nil(cursor)
            assert.is_not_nil(bag[key(0, 1)])
        end)

        it("empties the sale slot of an older item first", function()
            sell = { key = key(0, 1), item = { itemID = 12, stackCount = 3 } }
            A().PostItem(0, 1, 24, 5, nil, 500, 11)
            assert.are.equal(11, sell.item.itemID)
            assert.is_nil(cursor)
            assert.are.equal(1, #posts)
        end)

        it("refuses a bad quantity or buyout before it touches the bags", function()
            assert.is_false((pcall(A().PostItem, 0, 1, 24, 0, nil, 500, 11)))
            assert.is_false((pcall(A().PostItem, 0, 1, 24, 1.5, nil, 500, 11)))
            assert.is_false((pcall(A().PostItem, 0, 1, 24, 5, nil, 0, 11)))
            assert.is_false((pcall(A().PostItem, 0, 1, 24, 5, nil, nil, 11)))
            assert.are.equal(0, #posts)
            assert.is_nil(sell)
        end)

        it("raises the client error and puts the item back", function()
            _G.PostAuction = function() error("protected") end
            local ok, err = pcall(A().PostItem, 0, 1, 24, 5, nil, 500, 11)
            assert.is_false(ok)
            assert.is_truthy(err:find("protected", 1, true))
            assert.is_nil(sell)
            assert.is_nil(cursor)
        end)

        it("starts no timer, so a post runs only in the click that calls it", function()
            A().PostItem(0, 1, 24, 5, nil, 500, 11)
            postResult = false
            A().PostItem(0, 1, 24, 5, nil, 500, 11)
            A().ConfirmPostItem(0, 1, 24, 5, nil, 500)
            assert.are.equal(0, timers)
        end)

        describe("confirm", function()
            it("asks to confirm when PostAuction gives false, and hides the client dialog", function()
                postResult = false
                assert.is_true(A().PostItem(0, 1, 24, 5, nil, 500, 11))
                assert.are.same({ "AUCTION_HOUSE_POST_WARNING", "AUCTION_HOUSE_POST_ERROR" }, hidden)
                assert.are.equal(1, #posts)
            end)

            it("posts with the confirm flag, once", function()
                postResult = false
                A().PostItem(0, 1, 24, 5, nil, 500, 11)
                assert.is_false(A().ConfirmPostItem(0, 1, 24, 5, nil, 500, 11))
                assert.are.same({ 500, 500, 2, 5, 1, true, n = 6 }, posts[2])
                local ok, err = pcall(A().ConfirmPostItem, 0, 1, 24, 5, nil, 500, 11)
                assert.is_false(ok)
                assert.is_truthy(err:find("no post waits", 1, true))
                assert.are.equal(2, #posts)
            end)

            it("refuses a confirm with no post, or with other arguments", function()
                assert.is_false((pcall(A().ConfirmPostItem, 0, 1, 24, 5, nil, 500)))
                postResult = false
                A().PostItem(0, 1, 24, 5, nil, 500, 11)
                assert.is_false((pcall(A().ConfirmPostItem, 0, 1, 24, 4, nil, 500)))
                assert.are.equal(1, #posts)
                A().PostItem(0, 1, 24, 5, nil, 500, 11)
                assert.is_false((pcall(A().ConfirmPostItem, 0, 1, 24, 5, nil, 600)))
                assert.are.equal(2, #posts)
            end)

            it("refuses a confirm when the sale slot changed", function()
                postResult = false
                A().PostItem(0, 1, 24, 5, nil, 500, 11)
                sell = nil
                local ok, err = pcall(A().ConfirmPostItem, 0, 1, 24, 5, nil, 500)
                assert.is_false(ok)
                assert.is_truthy(err:find("sale slot", 1, true))
                assert.are.equal(1, #posts)
            end)

            it("raises the client error text and gives no confirm", function()
                postResult = false
                onPost = function()
                    ns.bus:Emit("AUCTION_HOUSE_POST_ERROR")
                end
                local ok, err = pcall(A().PostItem, 0, 1, 24, 5, nil, 500, 11)
                assert.is_false(ok)
                assert.is_truthy(err:find("refused", 1, true))
                assert.is_nil(sell)
                assert.is_false((pcall(A().ConfirmPostItem, 0, 1, 24, 5, nil, 500)))
            end)

            it("raises a UI error text that comes during a refused call", function()
                postResult = false
                A().PostedEvent()
                onPost = function()
                    ns.bus:Emit("UI_ERROR_MESSAGE", 1, "Not enough money")
                end
                local ok, err = pcall(A().PostItem, 0, 1, 24, 5, nil, 500, 11)
                assert.is_false(ok)
                assert.is_truthy(err:find("Not enough money", 1, true))
            end)

            it("ignores a UI error text when the post went through", function()
                A().PostedEvent()
                onPost = function()
                    ns.bus:Emit("UI_ERROR_MESSAGE", 1, "Something else")
                end
                assert.is_false(A().PostItem(0, 1, 24, 5, nil, 500, 11))
            end)
        end)

        describe("posted event", function()
            it("emits when the created text follows a post", function()
                assert.are.equal("Flipside.LegacyPosted", A().PostedEvent())
                ns.bus:Emit("CHAT_MSG_SYSTEM", "Auction created.")
                assert.are.equal(0, #emitted)
                A().PostItem(0, 1, 24, 5, nil, 500, 11)
                ns.bus:Emit("CHAT_MSG_SYSTEM", "You won an auction for Iron Bar.")
                assert.are.equal(0, #emitted)
                ns.bus:Emit("CHAT_MSG_SYSTEM", "Auction created.")
                assert.are.same({ "Flipside.LegacyPosted" }, emitted)
            end)
        end)

        describe("multisell", function()
            local steps

            before_each(function()
                steps = {}
                -- The sale slot reports the items in all bags: 60 here, in a 20-item stack slot.
                _G.GetAuctionSellItemInfo = function()
                    if not sell then
                        return nil
                    end
                    return "Copper Bar", 1, 20, 1, true, 0, 0, 20, 60, sell.item.itemID
                end
                _G.ERR_AUCTION_DATABASE_ERROR = "Auction House database error."
                ns.bus:Subscribe("Flipside.LegacyMultisell", "spec", function(_, kind, created, total, text)
                    steps[#steps + 1] = { kind = kind, created = created, total = total, text = text }
                end)
                A().MultisellEvent()
            end)

            after_each(function()
                _G.ERR_AUCTION_DATABASE_ERROR = nil
            end)

            it("gives its own event name", function()
                assert.are.equal("Flipside.LegacyMultisell", A().MultisellEvent())
            end)

            it("sends the stack size and the stack count with the prices of one stack", function()
                assert.is_true(A().PostItem(0, 1, 24, 20, 300, 500, 11, nil, 3) == false)
                assert.are.same({ 300, 500, 2, 20, 3, false, n = 6 }, posts[1])
            end)

            it("takes the stacks from all bags: only the total must hold the items", function()
                bag[key(0, 1)].stackCount = 7
                assert.is_false(A().PostItem(0, 1, 24, 20, nil, 500, 11, nil, 3))
                assert.are.same({ 500, 500, 2, 20, 3, false, n = 6 }, posts[1])
            end)

            it("refuses more stacks than the bags hold", function()
                local ok, err = pcall(A().PostItem, 0, 1, 24, 20, nil, 500, 11, nil, 4)
                assert.is_false(ok)
                assert.is_truthy(err:find("sale slot", 1, true))
                assert.are.equal(0, #posts)
                assert.is_nil(sell)
            end)

            it("refuses a bad stack count", function()
                assert.is_false((pcall(A().PostItem, 0, 1, 24, 20, nil, 500, 11, nil, 0)))
                assert.is_false((pcall(A().PostItem, 0, 1, 24, 20, nil, 500, 11, nil, 1.5)))
                assert.are.equal(0, #posts)
            end)

            it("passes the stack count to the confirm call", function()
                postResult = false
                assert.is_true(A().PostItem(0, 1, 24, 20, nil, 500, 11, nil, 3))
                assert.is_false((pcall(A().ConfirmPostItem, 0, 1, 24, 20, nil, 500, 11, nil, 2)))
                postResult = false
                A().PostItem(0, 1, 24, 20, nil, 500, 11, nil, 3)
                assert.is_false(A().ConfirmPostItem(0, 1, 24, 20, nil, 500, 11, nil, 3))
                assert.are.same({ 500, 500, 2, 20, 3, true, n = 6 }, posts[#posts])
            end)

            it("sends the real prices and the stack count to GetAuctionDeposit", function()
                pickup(0, 1)
                _G.ClickAuctionSellItemButton()
                assert.are.equal(66, A().Deposit(0, 1, 24, 20, false, 300, 500, 3))
                assert.are.same({ 2, 300, 500, 20, 3, n = 5 }, depositCalls[1])
            end)

            it("gives no deposit when the bags hold fewer items than the stacks", function()
                pickup(0, 1)
                _G.ClickAuctionSellItemButton()
                assert.is_nil(A().Deposit(0, 1, 24, 20, false, 300, 500, 4))
            end)

            it("keeps the item of all stacks in the sale slot and reads the deposit with no new fill", function()
                assert.is_true(A().HoldSlot(0, 1, 20, 11, 3))
                assert.is_not_nil(sell)
                assert.are.equal(66, A().Deposit(0, 1, 24, 20, false, 300, 500, 3))
                assert.are.same({ 2, 300, 500, 20, 3, n = 5 }, depositCalls[1])
                assert.are.equal(0, #posts)
            end)

            it("posts all stacks with the kept slot", function()
                A().HoldSlot(0, 1, 20, 11, 3)
                local held = sell
                assert.is_false(A().PostItem(0, 1, 24, 20, nil, 500, 11, nil, 3))
                assert.are.equal(held, sell)
                assert.are.same({ 500, 500, 2, 20, 3, false, n = 6 }, posts[1])
            end)
            it("gives the guard the deposit of all stacks", function()
                local seen
                A().PostItem(0, 1, 24, 20, 300, 500, 11, function(deposit)
                    seen = deposit
                    return true
                end, 3)
                assert.are.equal(66, seen)
                assert.are.same({ 2, 300, 500, 20, 3, n = 5 }, depositCalls[1])
            end)

            it("sends the update steps and the created count", function()
                A().PostItem(0, 1, 24, 20, nil, 500, 11, nil, 3)
                ns.bus:Emit("AUCTION_MULTISELL_START", 3)
                ns.bus:Emit("AUCTION_MULTISELL_UPDATE", 1, 3)
                ns.bus:Emit("AUCTION_MULTISELL_UPDATE", 3, 3)
                assert.are.same({ kind = "start", created = 0, total = 3 }, steps[1])
                assert.are.same({ kind = "update", created = 1, total = 3 }, steps[2])
                assert.are.same({ kind = "update", created = 3, total = 3 }, steps[3])
            end)

            it("sends a failure with the created count for AUCTION_MULTISELL_FAILURE", function()
                A().PostItem(0, 1, 24, 20, nil, 500, 11, nil, 3)
                ns.bus:Emit("AUCTION_MULTISELL_START", 3)
                ns.bus:Emit("AUCTION_MULTISELL_UPDATE", 2, 3)
                ns.bus:Emit("AUCTION_MULTISELL_FAILURE")
                assert.are.equal("failure", steps[3].kind)
                assert.are.equal(2, steps[3].created)
                assert.are.equal(3, steps[3].total)
            end)

            it("sends a failure for an ERR_AUCTION_* UI error inside the post window", function()
                A().PostItem(0, 1, 24, 20, nil, 500, 11, nil, 3)
                ns.bus:Emit("AUCTION_MULTISELL_START", 3)
                ns.bus:Emit("AUCTION_MULTISELL_UPDATE", 1, 3)
                ns.bus:Emit("UI_ERROR_MESSAGE", 1, "Something else")
                assert.are.equal(2, #steps)
                ns.bus:Emit("UI_ERROR_MESSAGE", 1, "Auction House database error.")
                assert.are.equal("failure", steps[3].kind)
                assert.are.equal(1, steps[3].created)
                assert.are.equal("Auction House database error.", steps[3].text)
            end)

            it("sends a failure for AUCTION_HOUSE_POST_ERROR after the call returned", function()
                A().PostItem(0, 1, 24, 20, nil, 500, 11, nil, 3)
                ns.bus:Emit("AUCTION_HOUSE_POST_ERROR")
                assert.are.equal("failure", steps[1].kind)
                assert.are.equal(0, steps[1].created)
            end)

            it("sends no failure for a UI error with no multisell", function()
                ns.bus:Emit("UI_ERROR_MESSAGE", 1, "Auction House database error.")
                assert.are.equal(0, #steps)
            end)

            it("ends the window when the last update comes", function()
                A().PostItem(0, 1, 24, 20, nil, 500, 11, nil, 3)
                ns.bus:Emit("AUCTION_MULTISELL_UPDATE", 3, 3)
                ns.bus:Emit("UI_ERROR_MESSAGE", 1, "Auction House database error.")
                assert.are.equal(1, #steps)
            end)

            it("sends a failure of 1 stack for an ERR_AUCTION_* UI error after a one-stack post", function()
                A().PostItem(0, 1, 24, 20, nil, 500, 11)
                ns.bus:Emit("UI_ERROR_MESSAGE", 1, "Something else")
                assert.are.equal(0, #steps)
                ns.bus:Emit("UI_ERROR_MESSAGE", 1, "Auction House database error.")
                assert.are.same({ kind = "failure", created = 0, total = 1, text = "Auction House database error." },
                    steps[1])
                ns.bus:Emit("UI_ERROR_MESSAGE", 1, "Auction House database error.")
                assert.are.equal(1, #steps)
            end)

            it("sends a failure of 1 stack for AUCTION_HOUSE_POST_ERROR after a one-stack post", function()
                A().PostItem(0, 1, 24, 20, nil, 500, 11)
                ns.bus:Emit("AUCTION_HOUSE_POST_ERROR")
                assert.are.equal("failure", steps[1].kind)
                assert.are.equal(1, steps[1].total)
            end)
        end)
        it("gives the item count of a bag slot", function()
            assert.are.equal(20, A().AvailablePostCount(0, 1))
            assert.are.equal(0, A().AvailablePostCount(0, 2))
        end)

        it("tells if a slot item can be posted", function()
            assert.is_true(A().IsSellItemValid(0, 1))
            assert.is_false(A().IsSellItemValid(0, 2))
            bag[key(0, 1)].isBound = true
            assert.is_false(A().IsSellItemValid(0, 1))
        end)

        describe("deposit", function()
            it("is nil while the sale slot is empty", function()
                assert.is_nil(A().Deposit(0, 1, 24, 5, false))
            end)

            it("asks the client with the real prices when the sale slot holds the item", function()
                pickup(0, 1)
                _G.ClickAuctionSellItemButton()
                assert.is_not_nil(sell)
                assert.are.equal(66, A().Deposit(0, 1, 24, 5, false, 300, 500))
                assert.are.same({ 2, 300, 500, 5, 1, n = 5 }, depositCalls[1])
            end)

            it("is nil with no prices and no waiting post", function()
                pickup(0, 1)
                _G.ClickAuctionSellItemButton()
                assert.is_nil(A().Deposit(0, 1, 24, 5, false))
                assert.are.equal(0, #depositCalls)
            end)

            it("takes the prices of the post that waits for a confirm", function()
                postResult = false
                assert.is_true(A().PostItem(0, 1, 24, 5, 300, 500, 11))
                assert.are.equal(66, A().Deposit(0, 1, 24, 5, false))
                assert.are.same({ 2, 300, 500, 5, 1, n = 5 }, depositCalls[#depositCalls])
            end)
        end)

        describe("kept sale slot (select click)", function()
            it("fills the slot and keeps the item there", function()
                assert.is_true(A().HoldSlot(0, 1, 5, 11))
                assert.are.equal(11, sell.item.itemID)
                assert.is_nil(cursor)
                assert.are.equal(0, #posts)
                assert.are.equal(0, #depositCalls)
            end)

            it("reads the deposit again for each change, with no new fill", function()
                local fills = 0
                local click = _G.ClickAuctionSellItemButton
                _G.ClickAuctionSellItemButton = function()
                    fills = fills + 1
                    click()
                end
                A().HoldSlot(0, 1, 5, 11)
                assert.are.equal(1, fills)
                assert.are.equal(66, A().Deposit(0, 1, 24, 5, false, 300, 500))
                assert.are.equal(66, A().Deposit(0, 1, 12, 5, false, 400, 600))
                assert.are.equal(66, A().Deposit(0, 1, 24, 3, false, 100, 300))
                assert.are.same({ 2, 300, 500, 5, 1, n = 5 }, depositCalls[1])
                assert.are.same({ 1, 400, 600, 5, 1, n = 5 }, depositCalls[2])
                assert.are.same({ 2, 100, 300, 3, 1, n = 5 }, depositCalls[3])
                assert.are.equal(1, fills)
                assert.is_not_nil(sell)
            end)

            it("does not fill again when the slot holds the right item", function()
                A().HoldSlot(0, 1, 5, 11)
                local held = sell
                assert.is_true(A().HoldSlot(0, 1, 5, 11))
                assert.are.equal(held, sell)
                assert.is_nil(cursor)
            end)

            it("replaces the item of another bag slot", function()
                bag[key(0, 2)] = { itemID = 12, stackCount = 4, isBound = false }
                A().HoldSlot(0, 1, 5, 11)
                assert.is_true(A().HoldSlot(0, 2, 1, 12))
                assert.are.equal(12, sell.item.itemID)
                assert.is_nil(cursor)
            end)

            it("posts with the kept slot and does not fill twice", function()
                local fills = 0
                local click = _G.ClickAuctionSellItemButton
                _G.ClickAuctionSellItemButton = function()
                    fills = fills + 1
                    click()
                end
                A().HoldSlot(0, 1, 5, 11)
                assert.is_false(A().PostItem(0, 1, 24, 5, nil, 500, 11))
                assert.are.equal(1, fills)
                assert.are.equal(1, #posts)
            end)

            it("gives the guard the deposit from the kept slot", function()
                A().HoldSlot(0, 1, 5, 11)
                local seen
                A().PostItem(0, 1, 24, 5, 300, 500, 11, function(deposit)
                    seen = deposit
                    return true
                end)
                assert.are.equal(66, seen)
            end)

            it("refuses the kept slot for a post of another item", function()
                A().HoldSlot(0, 1, 5, 11)
                local ok, err = pcall(A().PostItem, 0, 1, 24, 5, nil, 500, 99)
                assert.is_false(ok)
                assert.is_truthy(err:find("another item", 1, true))
                assert.are.equal(0, #posts)
                assert.is_nil(cursor)
            end)

            it("gives false and leaves the cursor alone when the cursor holds an item", function()
                pickup(0, 1)
                local held = cursor
                local ok, text = A().HoldSlot(0, 1, 5, 11)
                assert.is_false(ok)
                assert.is_truthy(text:find("cursor", 1, true))
                assert.are.equal(held, cursor)
                assert.is_nil(sell)
            end)

            it("gives false and empties the cursor when the client does not fill the slot", function()
                sellRejects = true
                local ok = A().HoldSlot(0, 1, 5, 11)
                assert.is_false(ok)
                assert.is_nil(sell)
                assert.is_nil(cursor)
                assert.are.equal(0, #posts)
            end)

            it("gives false for an empty bag slot, another item, a bad number or a closed AH", function()
                assert.is_false((A().HoldSlot(0, 2, 5, 11)))
                assert.is_false((A().HoldSlot(0, 1, 5, 99)))
                assert.is_false((A().HoldSlot(0, 1, 0, 11)))
                assert.is_false((A().HoldSlot(0, 1, 5, 11, 1.5)))
                _G.AuctionFrame = { IsShown = function() return false end }
                assert.is_false((A().HoldSlot(0, 1, 5, 11)))
                _G.AuctionFrame = nil
                assert.is_nil(sell)
                assert.is_nil(cursor)
            end)

            it("gives no deposit when the slot is empty after a release", function()
                A().HoldSlot(0, 1, 5, 11)
                assert.is_true(A().ReleaseSlot())
                assert.is_nil(sell)
                assert.is_nil(cursor)
                assert.is_not_nil(bag[key(0, 1)])
                assert.is_nil(A().Deposit(0, 1, 24, 5, false, 300, 500))
            end)

            it("releases nothing and clears nothing when the slot is empty", function()
                cursor = { key = "9:9", item = { itemID = 5, stackCount = 1 } }
                local held = cursor
                assert.is_true(A().ReleaseSlot())
                assert.are.equal(held, cursor)
            end)

            it("leaves the slot as it is when the cursor holds an item", function()
                A().HoldSlot(0, 1, 5, 11)
                cursor = { key = "9:9", item = { itemID = 5, stackCount = 1 } }
                local held = cursor
                assert.is_false(A().ReleaseSlot())
                assert.are.equal(held, cursor)
                assert.is_not_nil(sell)
            end)
        end)
        describe("guard", function()
            it("reads the real deposit and posts when the guard agrees", function()
                local seen
                assert.is_false(A().PostItem(0, 1, 24, 5, 300, 500, 11, function(deposit)
                    seen = deposit
                    return true
                end))
                assert.are.equal(66, seen)
                assert.are.same({ 2, 300, 500, 5, 1, n = 5 }, depositCalls[1])
                assert.are.equal(1, #posts)
            end)

            it("holds the post, calls no PostAuction and clears the sale slot when the guard refuses", function()
                local result, deposit = A().PostItem(0, 1, 24, 5, nil, 500, 11, function() return false end)
                assert.are.equal("held", result)
                assert.are.equal(66, deposit)
                assert.are.equal(0, #posts)
                assert.is_nil(sell)
                assert.is_nil(cursor)
            end)

            it("posts when the next call has no guard", function()
                A().PostItem(0, 1, 24, 5, nil, 500, 11, function() return false end)
                assert.is_false(A().PostItem(0, 1, 24, 5, nil, 500, 11))
                assert.are.equal(1, #posts)
                assert.are.same({ 500, 500, 2, 5, 1, false, n = 6 }, posts[1])
            end)

            it("clears the sale slot and raises when the guard fails", function()
                local ok = pcall(A().PostItem, 0, 1, 24, 5, nil, 500, 11, function() error("boom") end)
                assert.is_false(ok)
                assert.are.equal(0, #posts)
                assert.is_nil(sell)
                assert.is_nil(cursor)
            end)

            it("gives the guard nil when the client has no deposit", function()
                _G.GetAuctionDeposit = function() return nil end
                local seen = "unset"
                A().PostItem(0, 1, 24, 5, nil, 500, 11, function(deposit)
                    seen = deposit
                    return true
                end)
                assert.is_nil(seen)
                assert.are.equal(1, #posts)
            end)
        end)

        it("asks for a fresh owned list", function()
            local called = 0
            _G.GetOwnerAuctionItems = function() called = called + 1 end
            A().RefreshOwned()
            assert.are.equal(1, called)
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
