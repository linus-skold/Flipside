local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("AuctionClient")))("Flipside", ns)

describe("AuctionClient.OnCall", function()
    local seen, order

    before_each(function()
        seen, order = {}, {}
        ns.AuctionClient.OnCall(function(name, ...)
            seen[#seen + 1] = { name = name, ... }
            order[#order + 1] = "listener"
        end)
        ns.AuctionClient.Use({
            ConfirmCommodityPurchase = function(itemID, quantity)
                order[#order + 1] = "backend"
                return itemID + quantity
            end,
            PostItem = function()
                error("boom")
            end,
        })
    end)

    it("tells the listener the name and the arguments before the backend call and keeps the result", function()
        assert.are.equal(30, ns.AuctionClient.ConfirmCommodityPurchase(10, 20))
        assert.are.equal("ConfirmCommodityPurchase", seen[1].name)
        assert.are.equal(10, seen[1][1])
        assert.are.equal(20, seen[1][2])
        assert.are.same({ "listener", "backend" }, order)
    end)

    it("does not stop a call when the listener fails", function()
        ns.AuctionClient.OnCall(function()
            error("listener failed")
        end)
        assert.are.equal(3, ns.AuctionClient.ConfirmCommodityPurchase(1, 2))
    end)

    it("passes a backend error on and keeps the missing-function error", function()
        assert.has_error(function()
            ns.AuctionClient.PostItem()
        end)
        assert.has_error(function()
            ns.AuctionClient.BuyItemAuction(1, 2)
        end, "auction backend has no BuyItemAuction")
    end)

    it("refuses a listener that is not a function", function()
        assert.has_error(function()
            ns.AuctionClient.OnCall("x")
        end)
    end)
end)
