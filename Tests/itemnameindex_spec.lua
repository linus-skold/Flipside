local function load()
    local ns = {}
    for _, name in ipairs({ "Core/ItemString", "Services/ItemNameIndex" }) do
        assert(loadfile(name .. ".lua"))("Flipside", ns)
    end
    return ns
end

describe("ItemNameIndex", function()
    local ns, store, cache, index, keys, version, names, state, requests

    before_each(function()
        ns = load()
        keys, version, names, state, requests = {}, 1, {}, {}, {}
        store = {
            Keys = function()
                return keys
            end,
            GetVersion = function()
                return version
            end,
        }
        cache = {
            Get = function(_, id)
                if names[id] then
                    return { name = names[id] }, "loaded"
                end
                return nil, state[id] or "unknown"
            end,
            Request = function(_, id)
                requests[id] = (requests[id] or 0) + 1
            end,
        }
        index = ns.ItemNameIndex.New({ store = store, itemCache = cache })
    end)

    local function setItems(map)
        keys = {}
        for id, name in pairs(map) do
            table.insert(keys, tostring(id))
            names[id] = name
        end
        table.sort(keys)
    end

    local function ids(matches)
        local out = {}
        for _, match in ipairs(matches) do
            table.insert(out, match.key)
        end
        return out
    end

    it("orders exact, then prefix, then contains, alphabetical in each group", function()
        setItems({
            [1] = "Heavy Linen", [2] = "Linen Cloth", [3] = "Linen", [4] = "Linen Bandage", [5] = "Bolt of Linen",
        })
        local matches = index:Find("linen")
        assert.are.same({ "3", "4", "2", "5", "1" }, ids(matches))
        assert.are.equal("Linen", matches[1].name)
        assert.are.equal(3, matches[1].itemID)
    end)

    it("ignores case and outer spaces", function()
        setItems({ [1] = "Linen Cloth" })
        assert.are.same({ "1" }, ids((index:Find("  LiNeN cloth  "))))
    end)

    it("needs 2 characters", function()
        setItems({ [1] = "Linen Cloth" })
        assert.are.same({}, (index:Find("l")))
        assert.are.same({}, (index:Find("   ")))
        assert.are.same({ "1" }, ids((index:Find("li"))))
    end)

    it("applies the limit", function()
        setItems({ [1] = "Ore A", [2] = "Ore B", [3] = "Ore C" })
        assert.are.equal(2, #index:Find("ore", 2))
        assert.are.equal(3, #index:Find("ore"))
    end)

    it("gives one match for each stored key of an item", function()
        names[12345] = "Crimson Sword"
        keys = { "12345", "12345#b1,2", "12345#s-34" }
        local matches = index:Find("crimson")
        assert.are.same({ "12345", "12345#b1,2", "12345#s-34" }, ids(matches))
        assert.are.equal(12345, matches[3].itemID)
    end)

    it("counts items without a name and requests each one once", function()
        keys = { "1", "2", "3" }
        names[1] = "Linen"
        local matches, pending = index:Find("linen")
        assert.are.equal(1, #matches)
        assert.are.equal(2, pending)
        index:Find("linen")
        assert.are.same({ [2] = 1, [3] = 1 }, requests)
    end)

    it("uses names that arrive later", function()
        keys = { "1", "2" }
        names[1] = "Linen"
        local _, pending = index:Find("linen")
        assert.are.equal(1, pending)
        names[2] = "Linen Cloth"
        local matches
        matches, pending = index:Find("linen")
        assert.are.equal(0, pending)
        assert.are.same({ "1", "2" }, ids(matches))
    end)

    it("does not count items that failed to load", function()
        keys = { "1", "2" }
        names[1] = "Linen"
        state[2] = "failed"
        local _, pending = index:Find("linen")
        assert.are.equal(0, pending)
        assert.is_nil(requests[2])
    end)

    it("rebuilds when the store version changes", function()
        setItems({ [1] = "Linen" })
        assert.are.equal(1, #index:Find("linen"))
        names[2] = "Linen Cloth"
        keys = { "1", "2" }
        assert.are.equal(1, #index:Find("linen"))
        version = 2
        assert.are.equal(2, #index:Find("linen"))
    end)

    it("skips keys that are not valid", function()
        names[1] = "Linen"
        keys = { "1", "bad", "1#x" }
        assert.are.same({ "1" }, ids((index:Find("linen"))))
    end)

    describe("Resolve", function()
        it("passes links, item strings and ids through", function()
            setItems({ [1] = "Linen" })
            local link = "|cff0070dd|Hitem:123::::::::80:::::::::|h[Thing]|h|r"
            assert.are.same({ kind = "item", input = link }, index:Resolve(link))
            assert.are.same({ kind = "item", input = "item:55" }, index:Resolve("item:55"))
            assert.are.same({ kind = "item", input = "2589" }, index:Resolve("2589"))
            assert.are.same({ kind = "item", input = 2589 }, index:Resolve(2589))
        end)

        it("finds names", function()
            setItems({ [1] = "Linen" })
            local result = index:Resolve("linen")
            assert.are.equal("name", result.kind)
            assert.are.equal(0, result.pendingCount)
            assert.are.same({ "1" }, ids(result.matches))
        end)

        it("reports a short query", function()
            local result = index:Resolve(" a ")
            assert.are.equal("error", result.kind)
            assert.is_string(result.message)
        end)
    end)

    describe("helpers", function()
        it("describes a base key and a variant", function()
            assert.are.equal("Linen (1)", ns.ItemNameIndex.Describe({ itemID = 1, name = "Linen", key = "1" }))
            assert.are.equal("Sword (variant 5#s-34)",
                ns.ItemNameIndex.Describe({ itemID = 5, name = "Sword", key = "5#s-34" }))
        end)

        it("turns a key into an input that gives the same key", function()
            assert.are.equal("2589", ns.ItemNameIndex.ToInput("2589"))
            for _, key in ipairs({ "12345#s-34", "12345#b1,2", "12345#s7#b10,20,30" }) do
                local input = ns.ItemNameIndex.ToInput(key)
                assert.are.equal(key, ns.ItemString.ToExactKey(input))
            end
            assert.is_nil(ns.ItemNameIndex.ToInput("bad"))
        end)
    end)
end)
