local manifest = require("Tests.manifest")
local ns = {}
for _, name in ipairs({ "EventBus", "SettingsDB", "ItemString", "SearchLists" }) do
    assert(loadfile(manifest.path(name)))("Flipside", ns)
end

local function open(saved)
    return ns.SettingsDB.New(saved, { character = "Alice-Realm", schemaVersion = 1 })
end

describe("SearchLists", function()
    local saved, db, lists, bus, changes, ahOpen

    local function make()
        db = open(saved)
        lists = ns.SearchLists.New(db, { bus = bus, isAuctionHouseOpen = function() return ahOpen end })
    end

    before_each(function()
        saved = {}
        bus = ns.EventBus.New({})
        changes = 0
        ahOpen = false
        bus:Subscribe("Flipside.SearchListsChanged", "test", function()
            changes = changes + 1
        end)
        make()
    end)

    it("needs a db", function()
        assert.has_error(function() ns.SearchLists.New(nil) end)
    end)

    describe("Create, List and Get", function()
        it("starts empty", function()
            assert.same({}, lists:List())
            assert.is_nil(lists:Get(1))
        end)

        it("makes a list with clean items and sorts the list by name", function()
            local b = lists:Create("Bravo", { { itemID = 10, name = "Linen" }, { itemID = 10 }, { key = "20#s-44" } })
            local a = lists:Create("  alpha ", {})
            assert.is_number(b)
            assert.same({ { id = a, name = "alpha", count = 0 }, { id = b, name = "Bravo", count = 2 } }, lists:List())
            local got = lists:Get(b)
            assert.are.equal("Bravo", got.name)
            assert.same({
                { itemID = 10, key = "10", name = "Linen" },
                { itemID = 20, key = "20#s-44" },
            }, got.items)
            assert.are.equal(2, changes)
        end)

        it("gives a copy, so a change of the result does not change the list", function()
            local id = lists:Create("A", { { itemID = 1 } })
            lists:Get(id).items[1].itemID = 99
            assert.are.equal(1, lists:Get(id).items[1].itemID)
        end)

        it("refuses an empty, long or taken name", function()
            assert.is_nil((lists:Create("   ")))
            assert.is_nil((lists:Create(string.rep("x", 41))))
            assert.is_number(lists:Create("Herbs"))
            local id, err = lists:Create("HERBS")
            assert.is_nil(id)
            assert.is_string(err)
            assert.are.equal(1, #lists:List())
        end)

        it("drops items without an item ID", function()
            local id = lists:Create("A", { { name = "x" }, "bad", { key = "bad key" }, { itemID = 0 }, { itemID = 5 } })
            assert.are.equal(1, #lists:Get(id).items)
        end)
    end)

    describe("Upsert", function()
        it("makes a list, then replaces the items of the list with the same name", function()
            local id = lists:Upsert("Recipe", { { itemID = 1 }, { itemID = 2 } })
            local again = lists:Upsert("recipe", { { itemID = 3 } })
            assert.are.equal(id, again)
            assert.are.equal(1, #lists:List())
            assert.same({ { itemID = 3, key = "3" } }, lists:Get(id).items)
            assert.are.equal("Recipe", lists:Get(id).name)
            assert.are.equal(2, changes)
        end)

        it("refuses an empty name", function()
            assert.is_nil((lists:Upsert("", {})))
        end)
    end)

    describe("Rename and Delete", function()
        it("renames a list and refuses a taken name", function()
            local a, b = lists:Create("A", {}), lists:Create("B", {})
            assert.is_true(lists:Rename(a, "Zed"))
            assert.are.equal("Zed", lists:Get(a).name)
            assert.is_nil((lists:Rename(a, "b")))
            assert.is_true(lists:Rename(b, "B"))
            assert.is_nil((lists:Rename(99, "X")))
            assert.is_nil((lists:Rename(a, "")))
        end)

        it("deletes a list", function()
            local a = lists:Create("A", {})
            assert.is_true(lists:Delete(a))
            assert.same({}, lists:List())
            assert.is_nil((lists:Delete(a)))
        end)

        it("does not reuse the id of a deleted list", function()
            local a = lists:Create("A", {})
            lists:Delete(a)
            assert.is_true(lists:Create("B", {}) > a)
        end)
    end)

    describe("AddItem and RemoveItem", function()
        local id
        before_each(function()
            id = lists:Create("A", { { itemID = 1 } })
            changes = 0
        end)

        it("adds an item once", function()
            assert.is_true(lists:AddItem(id, { itemID = 2, name = "Two" }))
            local ok, err = lists:AddItem(id, { itemID = 2 })
            assert.is_nil(ok)
            assert.is_string(err)
            assert.is_true(lists:AddItem(id, { key = "2#b5" }))
            assert.are.equal(3, #lists:Get(id).items)
            assert.are.equal(2, changes)
        end)

        it("refuses an item that is not valid and a list that does not exist", function()
            assert.is_nil((lists:AddItem(id, { name = "x" })))
            assert.is_nil((lists:AddItem(99, { itemID = 5 })))
            assert.are.equal(0, changes)
        end)

        it("removes an item by place", function()
            lists:AddItem(id, { itemID = 2 })
            assert.is_true(lists:RemoveItem(id, 1))
            assert.same({ { itemID = 2, key = "2" } }, lists:Get(id).items)
            assert.is_nil((lists:RemoveItem(id, 5)))
            assert.is_nil((lists:RemoveItem(id, 0)))
            assert.is_nil((lists:RemoveItem(99, 1)))
        end)
    end)

    describe("count", function()
        it("stores a whole count above 0 and drops any other value", function()
            local id = lists:Create("Recipe", {
                { itemID = 1, count = 4 }, { itemID = 2, count = 0 }, { itemID = 3, count = 1.5 },
                { itemID = 4, count = "9" }, { itemID = 5 },
            })
            local items = lists:Get(id).items
            assert.are.equal(4, items[1].count)
            assert.is_nil(items[2].count)
            assert.is_nil(items[3].count)
            assert.is_nil(items[4].count)
            assert.is_nil(items[5].count)
        end)

        it("keeps the count after a reload and when an item is added", function()
            local id = lists:Create("Recipe", { { itemID = 1, count = 4 } })
            assert.is_true(lists:AddItem(id, { itemID = 2, count = 7 }))
            local again = ns.SearchLists.New(open(saved))
            assert.are.equal(4, again:Get(id).items[1].count)
            assert.are.equal(7, again:Get(id).items[2].count)
        end)

        it("loads an old list with no count", function()
            local id = lists:Create("Old", { { itemID = 1, name = "One" } })
            local data = db:Get("profile", "searchLists")
            assert.is_nil(data.lists[id].items[1].count)
            local again = ns.SearchLists.New(open(saved))
            assert.same({ itemID = 1, key = "1", name = "One" }, again:Get(id).items[1])
        end)

        it("sets, changes and clears the count of an item", function()
            local id = lists:Create("Recipe", { { itemID = 1 }, { itemID = 2 } })
            assert.is_true(lists:SetCount(id, 2, 6))
            assert.are.equal(6, lists:Get(id).items[2].count)
            assert.is_nil(lists:Get(id).items[1].count)
            assert.is_true(lists:SetCount(id, 2, 3))
            assert.are.equal(3, lists:Get(id).items[2].count)
            assert.is_true(lists:SetCount(id, 2, nil))
            assert.is_nil(lists:Get(id).items[2].count)
            assert.are.equal(4, changes)
        end)

        it("refuses a count for a list or a place that does not exist", function()
            local id = lists:Create("Recipe", { { itemID = 1 } })
            assert.is_nil(lists:SetCount(99, 1, 2))
            local ok, err = lists:SetCount(id, 5, 2)
            assert.is_nil(ok)
            assert.is_string(err)
        end)
    end)

    describe("craft lists", function()
        local id

        before_each(function()
            id = lists:Create("Pants", { { itemID = 2996, count = 4 } }, "craft")
        end)

        it("makes a craft list with the materials and no results", function()
            local list = lists:Get(id)
            assert.are.equal("craft", list.kind)
            assert.are.equal(4, list.items[1].count)
            assert.same({}, list.results)
            assert.are.equal("craft", lists:List()[1].kind)
        end)

        it("makes a search list when the kind is missing or is not craft", function()
            local plain = lists:Create("Plain", {})
            local other = lists:Create("Other", {}, "junk")
            assert.are.equal("search", lists:Get(plain).kind)
            assert.are.equal("search", lists:Get(other).kind)
            assert.is_nil(db:Get("profile", "searchLists").lists[plain].kind)
        end)

        it("loads an old list with no kind as a search list with no results", function()
            db:Set("profile", "searchLists", {
                version = 1, nextID = 2, lists = { [1] = { name = "Old", items = { { itemID = 1, key = "1" } } } },
            })
            local old = lists:Get(1)
            assert.are.equal("search", old.kind)
            assert.same({}, old.results)
            assert.are.equal(1, #old.items)
        end)

        it("adds a result with a clean copy of the item and the amounts", function()
            assert.is_true(lists:AddResult(id, { itemID = 10940, name = "Strange Dust", min = 1, max = 2 }))
            assert.same({ { itemID = 10940, key = "10940", name = "Strange Dust", min = 1, max = 2 } },
                lists:Get(id).results)
        end)

        it("uses the min amount as the max amount when there is no max", function()
            assert.is_true(lists:AddResult(id, { itemID = 10940, min = 3 }))
            assert.are.equal(3, lists:Get(id).results[1].max)
        end)

        it("accepts a key with a suffix and a min of 0", function()
            assert.is_true(lists:AddResult(id, { key = "25320#s-44", min = 0, max = 1 }))
            local result = lists:Get(id).results[1]
            assert.are.equal(25320, result.itemID)
            assert.are.equal(0, result.min)
        end)

        it("refuses amounts that are not whole numbers, a negative min and a max below the min", function()
            local bad = {
                { min = -1, max = 2 }, { min = 1.5, max = 2 }, { min = 1, max = 2.5 }, { min = 3, max = 2 },
                { min = "1", max = 2 }, { min = 1, max = "2" }, { max = 2 }, {},
            }
            for _, amounts in ipairs(bad) do
                local ok, err = lists:AddResult(id, { itemID = 5, min = amounts.min, max = amounts.max })
                assert.is_nil(ok)
                assert.is_string(err)
            end
            assert.same({}, lists:Get(id).results)
        end)

        it("refuses a result with no item, and the same result twice", function()
            assert.is_nil(lists:AddResult(id, { min = 1, max = 1 }))
            assert.is_nil(lists:AddResult(id, "junk"))
            assert.is_true(lists:AddResult(id, { itemID = 5, min = 1, max = 1 }))
            local ok, err = lists:AddResult(id, { itemID = 5, min = 2, max = 3 })
            assert.is_nil(ok)
            assert.is_string(err)
            assert.are.equal(1, #lists:Get(id).results)
        end)

        it("refuses a result for a search list or a list that does not exist", function()
            local plain = lists:Create("Plain", {})
            local ok, err = lists:AddResult(plain, { itemID = 5, min = 1, max = 1 })
            assert.is_nil(ok)
            assert.matches("not a craft list", err)
            assert.is_nil(lists:AddResult(99, { itemID = 5, min = 1, max = 1 }))
            assert.same({}, lists:Get(plain).results)
        end)

        it("changes the amounts of a result and checks them", function()
            lists:AddResult(id, { itemID = 5, min = 1, max = 1 })
            assert.is_true(lists:SetResult(id, 1, 2, 5))
            assert.are.equal(2, lists:Get(id).results[1].min)
            assert.are.equal(5, lists:Get(id).results[1].max)
            assert.is_true(lists:SetResult(id, 1, 4))
            assert.are.equal(4, lists:Get(id).results[1].max)
            assert.is_nil(lists:SetResult(id, 1, 5, 4))
            assert.is_nil(lists:SetResult(id, 1, -1, 4))
            assert.is_nil(lists:SetResult(id, 1, 1.5, 4))
            assert.is_nil(lists:SetResult(id, 2, 1, 1))
            assert.are.equal(4, lists:Get(id).results[1].min)
        end)

        it("removes a result", function()
            lists:AddResult(id, { itemID = 5, min = 1, max = 1 })
            lists:AddResult(id, { itemID = 6, min = 1, max = 1 })
            assert.is_true(lists:RemoveResult(id, 1))
            assert.are.equal(6, lists:Get(id).results[1].itemID)
            assert.is_nil(lists:RemoveResult(id, 5))
        end)

        it("keeps the kind and the results after a reload and when the materials change", function()
            lists:AddResult(id, { itemID = 5, min = 1, max = 2 })
            assert.is_true(lists:AddItem(id, { itemID = 7, count = 2 }))
            assert.is_true(lists:SetCount(id, 2, 3))
            assert.is_true(lists:RemoveItem(id, 1))
            assert.is_number(lists:Upsert("Pants", { { itemID = 8 } }))
            local again = ns.SearchLists.New(open(saved))
            local list = again:Get(id)
            assert.are.equal("craft", list.kind)
            assert.are.equal(8, list.items[1].itemID)
            assert.are.equal(5, list.results[1].itemID)
            assert.is_true(again:Rename(id, "Pants 2"))
            assert.are.equal("craft", again:Get(id).kind)
        end)

        it("drops a damaged result when it loads", function()
            local data = db:Get("profile", "searchLists")
            data.lists[id].results = { { itemID = 5, min = 3, max = 1 }, "junk", { itemID = 6, min = 1, max = 2 } }
            db:Set("profile", "searchLists", data)
            local results = lists:Get(id).results
            assert.are.equal(1, #results)
            assert.are.equal(6, results[1].itemID)
        end)

        it("sends the changed event for each result change", function()
            local before = changes
            lists:AddResult(id, { itemID = 5, min = 1, max = 1 })
            lists:SetResult(id, 1, 1, 2)
            lists:RemoveResult(id, 1)
            assert.are.equal(before + 3, changes)
        end)

        it("refuses a result change when the data is read-only", function()
            saved = { _schema = 99 }
            make()
            local ok, err = lists:AddResult(1, { itemID = 5, min = 1, max = 1 })
            assert.is_nil(ok)
            assert.is_string(err)
        end)
    end)

    describe("saving", function()
        it("keeps the lists in the profile after a reload", function()
            local id = lists:Create("Saved", { { itemID = 7, name = "Seven" } })
            local again = ns.SearchLists.New(open(saved))
            assert.same({ { id = id, name = "Saved", count = 1, kind = "search" } }, again:List())
            assert.are.equal("Seven", again:Get(id).items[1].name)
            assert.is_true(again:Create("Next", {}) > id)
        end)

        it("ignores a damaged value", function()
            db:Set("profile", "searchLists", "junk")
            assert.same({}, lists:List())
            assert.is_number(lists:Create("A", {}))
        end)

        it("refuses a change when the data is read-only, and sends no event", function()
            saved = { _schema = 99 }
            make()
            assert.is_true(db:IsReadOnly())
            local id, err = lists:Create("A", {})
            assert.is_nil(id)
            assert.matches("read%-only", err)
            assert.are.equal(0, changes)
        end)
    end)

    describe("open requests", function()
        it("records a request that comes while the Auction House is closed", function()
            local id = lists:Create("A", {})
            bus:Emit("Flipside.SearchListOpen", id, true)
            assert.same({ id = id, autoSearch = true }, lists:Requested())
            lists:ClearRequested()
            assert.is_nil(lists:Requested())
        end)

        it("records nothing while the Auction House is open", function()
            local id = lists:Create("A", {})
            ahOpen = true
            bus:Emit("Flipside.SearchListOpen", id, true)
            assert.is_nil(lists:Requested())
        end)

        it("forgets a request for a deleted list", function()
            local id = lists:Create("A", {})
            bus:Emit("Flipside.SearchListOpen", id, false)
            lists:Delete(id)
            assert.is_nil(lists:Requested())
        end)
    end)
end)
