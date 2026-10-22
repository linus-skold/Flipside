local manifest = require("Tests.manifest")

describe("BagSnapshot", function()
    local ns, bus, apiCalls, bags, snapshot

    before_each(function()
        ns = {}
        for _, name in ipairs({ "EventBus", "BagSnapshot" }) do
            assert(loadfile(manifest.path(name)))("Flipside", ns)
        end
        bus = ns.EventBus.New({})
        apiCalls = 0
        bags = { [0] = { { itemID = 1 }, false } }
        snapshot = ns.BagSnapshot.New({
            numSlots = function(bag)
                apiCalls = apiCalls + 1
                return bags[bag] and #bags[bag] or nil
            end,
            itemInfo = function(bag, slot)
                apiCalls = apiCalls + 1
                return bags[bag][slot] or nil
            end,
        }, bus)
    end)

    -- Three readers walk the same bag, as the capture, the auto rules and the mailing view do.
    local function readerPass()
        local seen = {}
        for slot = 1, snapshot.numSlots(0) do
            seen[#seen + 1] = snapshot.itemInfo(0, slot) and snapshot.itemInfo(0, slot).itemID or false
        end
        return seen
    end

    it("calls the client once for all readers of one burst", function()
        local first = readerPass()
        local calls = apiCalls
        assert.are.equal(3, calls, "one numSlots call and one itemInfo call for each slot")
        assert.are.same(first, readerPass())
        assert.are.same(first, readerPass())
        assert.are.equal(calls, apiCalls)
        assert.are.same({ 1, false }, first)
    end)

    it("returns 0 slots for a bag the client does not know, and caches it", function()
        assert.are.equal(0, snapshot.numSlots(9))
        assert.are.equal(0, snapshot.numSlots(9))
        assert.are.equal(1, apiCalls)
    end)

    it("reads the client again after BAG_UPDATE_DELAYED", function()
        readerPass()
        bags[0][1] = { itemID = 2 }
        bus:Emit("BAG_UPDATE_DELAYED")
        assert.are.same({ 2, false }, readerPass())
    end)

    it("reads the client again after ITEM_LOCK_CHANGED", function()
        readerPass()
        bags[0][2] = { itemID = 3 }
        bus:Emit("ITEM_LOCK_CHANGED")
        assert.are.same({ 1, 3 }, readerPass())
    end)

    it("reads the client again after Invalidate", function()
        readerPass()
        local calls = apiCalls
        snapshot.Invalidate()
        readerPass()
        assert.are.equal(calls * 2, apiCalls)
    end)
end)
