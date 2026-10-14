describe("BagItems", function()
    local ns, BagItems, bags, failBag, failSlot, resolver

    local function link(id, suffix)
        return "|cff1eff00|Hitem:" .. id .. "::::::" .. (suffix or "") .. "::::::|h[x]|h|r"
    end

    local function api()
        return {
            numSlots = function(bag)
                if bag == failBag then error("bag") end
                return bags[bag] and #bags[bag] or 0
            end,
            itemInfo = function(bag, slot)
                if bag == failSlot[1] and slot == failSlot[2] then error("slot") end
                return bags[bag][slot] or nil
            end,
        }
    end

    before_each(function()
        ns = {}
        for _, name in ipairs({ "Core/ItemString", "Services/ScanKey", "Services/BagItems" }) do
            assert(loadfile(name .. ".lua"))("Flipside", ns)
        end
        BagItems = ns.BagItems
        failBag, failSlot = nil, {}
        resolver = ns.ScanKey.New({
            clientIsCommodity = function(id)
                if id == 10 then return true end
                if id == 20 then return false end
                return nil
            end,
        })
        bags = {
            [0] = {
                { hyperlink = link(10), itemID = 10, stackCount = 20, itemName = "Herb" },
                { hyperlink = link(20, "-37"), itemID = 20, stackCount = 1, itemName = "Sword" },
                false,
                { hyperlink = "|Hbattlepet:1:2|h[Pet]|h", itemID = 82800, stackCount = 1, itemName = "Pet" },
            },
            [1] = {
                { hyperlink = link(10), itemID = 10, stackCount = 5, itemName = "Herb" },
                { hyperlink = link(30), itemID = 30, stackCount = 2, itemName = "Apple" },
                { hyperlink = link(40), itemID = 40, stackCount = 1, itemName = "Bound", isBound = true },
            },
        }
    end)

    it("sums stacks, uses the right key and sorts by name", function()
        local list, stats = BagItems.Read(api(), resolver)
        assert.are.equal(3, #list)
        assert.are.equal("Apple", list[1].name)
        assert.are.equal("30", list[1].key)
        assert.are.equal(2, list[1].count)
        assert.are.equal("Herb", list[2].name)
        assert.are.equal("10", list[2].key)
        assert.are.equal(25, list[2].count)
        assert.are.equal("Sword", list[3].name)
        assert.are.equal(ns.ItemString.ToExactKey(link(20, "-37")), list[3].key)
        assert.are.equal(0, stats.errors)
        assert.are.equal(7, stats.slots)
        assert.are.equal(3, stats.skipped)
    end)

    it("uses the exact key when no resolver is given", function()
        local list = BagItems.Read(api(), nil)
        assert.are.equal(ns.ItemString.ToExactKey(link(10)), list[2].key)
    end)

    it("drops bound items by default and keeps them with the option", function()
        local list = BagItems.Read(api(), resolver)
        for _, e in ipairs(list) do assert.are_not.equal("Bound", e.name) end
        list = BagItems.Read(api(), resolver, { includeBound = true })
        assert.are.equal(4, #list)
        assert.are.equal("Bound", list[2].name)
        assert.is_true(list[2].bound)
    end)

    it("marks a key bound if any slot is bound", function()
        bags[1][1].isBound = true
        local list = BagItems.Read(api(), resolver, { includeBound = true })
        for _, e in ipairs(list) do
            if e.name == "Herb" then assert.is_true(e.bound) end
        end
    end)

    it("skips and counts a failing slot and a failing bag", function()
        failSlot = { 0, 1 }
        failBag = 1
        local list, stats = BagItems.Read(api(), resolver)
        assert.are.equal(1, #list)
        assert.are.equal("Sword", list[1].name)
        assert.are.equal(2, stats.errors)
    end)
end)
