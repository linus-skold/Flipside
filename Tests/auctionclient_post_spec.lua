local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

describe("AuctionClient post functions", function()
    local ns, calls

    -- Install fake post calls on the mock client; each call is recorded in calls.
    local function installPostApi()
        calls = {}
        _G.ItemLocation = {
            CreateFromBagAndSlot = function(_, bag, slot)
                return { bag = bag, slot = slot }
            end,
        }
        _G.C_Item.GetItemID = function(where)
            return 1000 + where.slot
        end
        local ah = _G.C_AuctionHouse
        local function record(name, result)
            ah[name] = function(...)
                calls[#calls + 1] = { name = name, args = { ... } }
                return result
            end
        end
        record("PostItem", false)
        record("PostCommodity", true)
        record("ConfirmPostItem")
        record("ConfirmPostCommodity")
        record("CalculateItemDeposit", 120)
        record("CalculateCommodityDeposit", 340)
        record("GetAvailablePostCount", 4)
        record("IsSellItemValid", true)
    end

    before_each(function()
        mock.reset()
        ns = {}
        assert(loadfile(manifest.path("AuctionClient")))("Flipside", ns)
        assert(loadfile(manifest.path("ForeverBackend")))("Flipside", ns)
        installPostApi()
    end)

    after_each(function()
        _G.ItemLocation = nil
        mock.teardown()
    end)

    it("can post when the client has every post call", function()
        assert.is_true(ns.AuctionClient.CanPost())
        _G.C_AuctionHouse.PostCommodity = nil
        assert.is_false(ns.AuctionClient.CanPost())
    end)

    it("cannot post without ItemLocation", function()
        _G.ItemLocation = nil
        assert.is_false(ns.AuctionClient.CanPost())
    end)

    it("is off without a backend and on a backend without the calls", function()
        local bare = {}
        assert(loadfile(manifest.path("AuctionClient")))("Flipside", bare)
        assert.is_false(bare.AuctionClient.CanPost())
        assert.is_nil(bare.AuctionClient.Deposit(1, 1, 24, 1, false))
        assert.is_nil(bare.AuctionClient.PostedEvent())
        assert.has_error(function()
            bare.AuctionClient.PostItem(0, 1, 24, 1, nil, 100)
        end, "auction backend has no PostItem")
    end)

    it("posts an item with an ItemLocation, a duration index and a buyout", function()
        assert.is_false(ns.AuctionClient.PostItem(0, 3, 24, 5, nil, 900))
        local call = calls[1]
        assert.are.equal("PostItem", call.name)
        assert.are.same({ bag = 0, slot = 3 }, call.args[1])
        assert.are.equal(3, call.args[2])
        assert.are.equal(5, call.args[3])
        assert.is_nil(call.args[4])
        assert.are.equal(900, call.args[5])
    end)

    it("posts a commodity and gives needsConfirmation", function()
        assert.is_true(ns.AuctionClient.PostCommodity(1, 2, 2, 200, 55))
        local call = calls[1]
        assert.are.equal("PostCommodity", call.name)
        assert.are.equal(1, call.args[2])
        assert.are.equal(200, call.args[3])
        assert.are.equal(55, call.args[4])
    end)

    it("maps 2, 8 and 24 hours to the index 1, 2 and 3", function()
        ns.AuctionClient.PostCommodity(0, 1, 2, 1, 1)
        ns.AuctionClient.PostCommodity(0, 1, 8, 1, 1)
        ns.AuctionClient.PostCommodity(0, 1, 24, 1, 1)
        assert.are.same({ 1, 2, 3 }, { calls[1].args[2], calls[2].args[2], calls[3].args[2] })
    end)

    it("refuses another duration before any call", function()
        assert.has_error(function()
            ns.AuctionClient.PostItem(0, 1, 36, 1, nil, 5)
        end, "duration must be 2, 8 or 24 hours")
        assert.are.equal(0, #calls)
    end)

    it("confirms an item and a commodity post with the same arguments", function()
        ns.AuctionClient.ConfirmPostItem(0, 3, 24, 5, nil, 900)
        ns.AuctionClient.ConfirmPostCommodity(1, 2, 24, 200, 55)
        assert.are.equal("ConfirmPostItem", calls[1].name)
        assert.are.equal(900, calls[1].args[5])
        assert.are.equal("ConfirmPostCommodity", calls[2].name)
        assert.are.equal(55, calls[2].args[4])
    end)

    it("calculates the deposit of a commodity by item id and of an item by location", function()
        assert.are.equal(340, ns.AuctionClient.Deposit(0, 4, 8, 30, true))
        assert.are.equal("CalculateCommodityDeposit", calls[1].name)
        assert.are.equal(1004, calls[1].args[1])
        assert.are.equal(2, calls[1].args[2])
        assert.are.equal(120, ns.AuctionClient.Deposit(0, 4, 8, 3, false))
        assert.are.equal("CalculateItemDeposit", calls[2].name)
        assert.are.same({ bag = 0, slot = 4 }, calls[2].args[1])
    end)

    it("reads the available post count and the valid flag without an error text", function()
        assert.are.equal(4, ns.AuctionClient.AvailablePostCount(0, 2))
        assert.is_true(ns.AuctionClient.IsSellItemValid(0, 2))
        assert.is_false(calls[2].args[2])
    end)

    it("gives the created event", function()
        assert.are.equal("AUCTION_HOUSE_AUCTION_CREATED", ns.AuctionClient.PostedEvent())
    end)

    describe("the throttle gate", function()
        it("follows IsThrottledMessageSystemReady", function()
            mock.throttleReady = true
            assert.is_true(ns.AuctionClient.CanSendPost())
            mock.throttleReady = false
            assert.is_false(ns.AuctionClient.CanSendPost())
        end)

        it("is open on a client with no gate call and open without a backend", function()
            _G.C_AuctionHouse.IsThrottledMessageSystemReady = nil
            assert.is_true(ns.AuctionClient.CanSendPost())
            local bare = {}
            assert(loadfile(manifest.path("AuctionClient")))("Flipside", bare)
            assert.is_true(bare.AuctionClient.CanSendPost())
            assert.is_nil(bare.AuctionClient.PostGateEvents())
        end)

        it("gives the events that change the gate", function()
            local list = {}
            for _, event in ipairs(ns.AuctionClient.PostGateEvents()) do
                list[event] = true
            end
            assert.is_true(list.AUCTION_HOUSE_THROTTLED_SYSTEM_READY)
            assert.is_true(list.AUCTION_HOUSE_THROTTLED_MESSAGE_SENT)
        end)
    end)

    describe("the post error event", function()
        local failures

        before_each(function()
            assert(loadfile(manifest.path("EventBus")))("Flipside", ns)
            ns.bus = ns.EventBus.New({})
            failures = {}
            ns.bus:Subscribe(ns.AuctionClient.MultisellEvent(), "spec", function(_, ...)
                failures[#failures + 1] = { ... }
            end)
            _G.Enum = { AuctionHouseError = { DatabaseError = 10 } }
            _G.ERR_AUCTION_DATABASE_ERROR = "Internal auction house error."
        end)

        after_each(function()
            _G.Enum, _G.ERR_AUCTION_DATABASE_ERROR = nil, nil
        end)

        it("sends a failure with the database error text for AUCTION_HOUSE_SHOW_ERROR", function()
            ns.bus:Emit("AUCTION_HOUSE_SHOW_ERROR", 10)
            assert.are.same({ { "failure", 0, 1, "Internal auction house error." } }, failures)
        end)

        it("sends a failure with the code for another error", function()
            ns.bus:Emit("AUCTION_HOUSE_SHOW_ERROR", 3)
            assert.are.equal("failure", failures[1][1])
            assert.is_truthy(failures[1][4]:find("error 3", 1, true))
        end)

        it("sends a failure for AUCTION_HOUSE_POST_ERROR", function()
            ns.bus:Emit("AUCTION_HOUSE_POST_ERROR")
            assert.are.equal("failure", failures[1][1])
        end)

        it("subscribes once", function()
            ns.AuctionClient.MultisellEvent()
            ns.bus:Emit("AUCTION_HOUSE_POST_ERROR")
            assert.are.equal(1, #failures)
        end)
    end)
end)
