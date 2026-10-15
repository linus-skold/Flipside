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

    describe("saving", function()
        it("keeps the lists in the profile after a reload", function()
            local id = lists:Create("Saved", { { itemID = 7, name = "Seven" } })
            local again = ns.SearchLists.New(open(saved))
            assert.same({ { id = id, name = "Saved", count = 1 } }, again:List())
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
