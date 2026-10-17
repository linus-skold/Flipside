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
