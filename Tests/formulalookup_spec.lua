describe("FormulaLookup", function()
    local ns, Find

    before_each(function()
        ns = {}
        assert(loadfile("Core/ItemString.lua"))("Flipside", ns)
        assert(loadfile("Services/ScanRecord.lua"))("Flipside", ns)
        assert(loadfile("Services/ScanStore.lua"))("Flipside", ns)
        assert(loadfile("Services/FormulaLookup.lua"))("Flipside", ns)
        Find = ns.FormulaLookup.Find
    end)

    local function record(min)
        local r = ns.ScanRecord.New()
        r.latest = { time = 1760000000, min = min, market = 5200, qty = 40, auctions = 6, partial = false }
        return r
    end

    local function fakeStore(records)
        return {
            Get = function(_, key)
                return records[key]
            end,
        }
    end

    local link = "|cff0070dd|Hitem:123::::::::80:::::::::|h[Thing]|h|r"
    local bonusLink = "|cff0070dd|Hitem:123::::::::80::::1:4000:::::|h[Thing]|h|r"

    it("reads the exact record first for a link", function()
        local exact, base = record(1), record(2)
        local key = ns.ItemString.ToExactKey(bonusLink)
        local r, k, id = Find(fakeStore({ [key] = exact, ["123"] = base }), bonusLink)
        assert.equals(exact, r)
        assert.equals(key, k)
        assert.equals(123, id)
    end)

    it("falls back to the base record for a link", function()
        local base = record(2)
        local r, k, id = Find(fakeStore({ ["123"] = base }), bonusLink)
        assert.equals(base, r)
        assert.equals("123", k)
        assert.equals(123, id)
    end)

    it("handles a link whose exact key equals the base key", function()
        local base = record(2)
        local r, k, id = Find(fakeStore({ ["123"] = base }), link)
        assert.equals(base, r)
        assert.equals("123", k)
        assert.equals(123, id)
    end)

    it("reads a bare item string", function()
        local base = record(2)
        local r, k = Find(fakeStore({ ["123"] = base }), "item:123")
        assert.equals(base, r)
        assert.equals("123", k)
    end)

    it("reads the base key only for a number", function()
        local exact, base = record(1), record(2)
        local r, k, id = Find(fakeStore({ ["123#b4000"] = exact, ["123"] = base }), 123)
        assert.equals(base, r)
        assert.equals("123", k)
        assert.equals(123, id)
    end)

    it("reads the base key only for a digit string", function()
        local base = record(2)
        local r, k, id = Find(fakeStore({ ["123"] = base }), "123")
        assert.equals(base, r)
        assert.equals("123", k)
        assert.equals(123, id)
    end)

    it("returns the item id when no record exists", function()
        local r, k, id = Find(fakeStore({}), bonusLink)
        assert.is_nil(r)
        assert.is_nil(k)
        assert.equals(123, id)
        local _, _, id2 = Find(fakeStore({}), 77)
        assert.equals(77, id2)
    end)

    it("returns nil for input that is not an item", function()
        local store = fakeStore({})
        assert.is_nil(Find(store, nil))
        assert.is_nil(Find(store, {}))
        assert.is_nil(Find(store, ""))
        assert.is_nil(Find(store, "hello"))
        assert.is_nil(Find(store, 0))
    end)

    it("works with a real ScanStore", function()
        local store = ns.ScanStore.New({}, { region = "EU", ruleset = "standard", schemaVersion = 1 })
        local exactRec, baseRec = record(1), record(2)
        store:Put("123", baseRec)
        local r, k = Find(store, bonusLink)
        assert.equals(baseRec, r)
        assert.equals("123", k)
        local key = ns.ItemString.ToExactKey(bonusLink)
        store:Put(key, exactRec)
        r, k = Find(store, bonusLink)
        assert.equals(exactRec, r)
        assert.equals(key, k)
        assert.is_nil(Find(store, "hello"))
    end)
end)
