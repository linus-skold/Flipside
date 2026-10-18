local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

-- The bid post-hook of the ledger, installed by the flavour backends through AuctionClient.HookBid.
describe("AuctionClient.HookBid", function()
    local hooked, seen

    -- hooksecurefunc(table, name, fn): the post-hook wraps the function and calls fn after it.
    local function hook(target, name, fn)
        hooked[#hooked + 1] = name
        local original = target[name]
        target[name] = function(...)
            local results = { original(...) }
            fn(...)
            return unpack(results)
        end
    end

    local function handler(id)
        seen[#seen + 1] = id
    end

    before_each(function()
        hooked, seen = {}, {}
    end)

    describe("on Forever", function()
        local ns

        before_each(function()
            mock.reset()
            ns = {}
            assert(loadfile(manifest.path("AuctionClient")))("Flipside", ns)
            assert(loadfile(manifest.path("ForeverBackend")))("Flipside", ns)
        end)

        after_each(function()
            mock.teardown()
        end)

        it("hooks PlaceBid and gives the auction ID after the call", function()
            local calls = 0
            _G.C_AuctionHouse.PlaceBid = function()
                calls = calls + 1
                return "result"
            end
            assert.are.equal("C_AuctionHouse.PlaceBid", ns.AuctionClient.HookBid(hook, handler))
            assert.are.equal("result", _G.C_AuctionHouse.PlaceBid(77, 500))
            assert.are.equal(1, calls)
            assert.are.same({ 77 }, seen)
        end)

        it("gives nil when the client has no PlaceBid", function()
            _G.C_AuctionHouse.PlaceBid = nil
            assert.is_nil(ns.AuctionClient.HookBid(hook, handler))
            assert.are.same({}, hooked)
        end)

        describe("AuctionInfo owner", function()
            local KEY = { itemID = 4306 }
            local results

            before_each(function()
                results = { { auctionID = 5, owners = { "Other" } }, { auctionID = 9, owners = { "Poor" } } }
                _G.C_AuctionHouse.GetAuctionInfoByID = function(id)
                    return { itemKey = KEY, itemLink = "link" .. id, buyoutAmount = 500 }
                end
                _G.C_AuctionHouse.GetNumItemSearchResults = function()
                    return #results
                end
                _G.C_AuctionHouse.GetItemSearchResultInfo = function(_, index)
                    return results[index]
                end
            end)

            it("gives the only owner of the search result with the same auction ID", function()
                local info = ns.AuctionClient.AuctionInfo(9)
                assert.are.equal("Poor", info.owner)
                assert.are.equal("link9", info.itemLink)
            end)

            it("gives no owner when the auction is not in the results", function()
                assert.is_nil(ns.AuctionClient.AuctionInfo(77).owner)
            end)

            it("gives no owner when the result lists more than one owner", function()
                results[2].owners = { "A", "B" }
                assert.is_nil(ns.AuctionClient.AuctionInfo(9).owner)
            end)

            it("gives the info with no owner when the search functions fail or are missing", function()
                _G.C_AuctionHouse.GetNumItemSearchResults = function()
                    error("no results")
                end
                assert.is_nil(ns.AuctionClient.AuctionInfo(9).owner)
                _G.C_AuctionHouse.GetItemSearchResultInfo = nil
                assert.are.equal("link9", ns.AuctionClient.AuctionInfo(9).itemLink)
            end)

            it("gives nil when the client has no info", function()
                _G.C_AuctionHouse.GetAuctionInfoByID = function()
                    return nil
                end
                assert.is_nil(ns.AuctionClient.AuctionInfo(9))
            end)
        end)
    end)

    describe("on TBC", function()
        local ns, saved

        before_each(function()
            saved = _G.PlaceAuctionBid
            ns = {}
            assert(loadfile(manifest.path("AuctionClient", "Flipside_TBC.toc")))("Flipside", ns)
            assert(loadfile(manifest.path("LegacyBackend", "Flipside_TBC.toc")))("Flipside", ns)
        end)

        after_each(function()
            _G.PlaceAuctionBid = saved
        end)

        it("hooks PlaceAuctionBid and gives the list index of the browse list only", function()
            _G.PlaceAuctionBid = function() end
            assert.are.equal("PlaceAuctionBid", ns.AuctionClient.HookBid(hook, handler))
            _G.PlaceAuctionBid("list", 4, 900)
            _G.PlaceAuctionBid("bidder", 5, 900)
            _G.PlaceAuctionBid("owner", 6, 900)
            assert.are.same({ 4 }, seen)
        end)

        it("gives the owner of the list row in the auction info", function()
            local saved2 = { _G.GetAuctionItemInfo, _G.GetAuctionItemLink }
            _G.GetAuctionItemInfo = function()
                return "Copper Bar", 1, 5, 1, true, 1, 0, 0, 0, 500, 0, false, "", "Poor", "", 0, 11, true
            end
            _G.GetAuctionItemLink = function()
                return "|Hitem:11|h[Copper Bar]|h"
            end
            local info = ns.AuctionClient.AuctionInfo(3)
            _G.GetAuctionItemInfo, _G.GetAuctionItemLink = saved2[1], saved2[2]
            assert.are.equal("Poor", info.owner)
            assert.are.equal(5, info.quantity)
        end)
        it("gives nil when the client has no PlaceAuctionBid", function()
            _G.PlaceAuctionBid = nil
            assert.is_nil(ns.AuctionClient.HookBid(hook, handler))
        end)
    end)

    it("gives nil with no backend", function()
        local ns = {}
        assert(loadfile(manifest.path("AuctionClient")))("Flipside", ns)
        assert.is_nil(ns.AuctionClient.HookBid(hook, handler))
    end)
end)
