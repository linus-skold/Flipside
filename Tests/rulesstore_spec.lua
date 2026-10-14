local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("ItemString")))("Flipside", ns)
assert(loadfile(manifest.path("SettingsDB")))("Flipside", ns)
assert(loadfile(manifest.path("GroupTree")))("Flipside", ns)
assert(loadfile(manifest.path("OperationSchema")))("Flipside", ns)
assert(loadfile(manifest.path("RulesStore")))("Flipside", ns)

local PROFILE_GROUPS = "p/Default/groups"
local PROFILE_OPS = "p/Default/operations"

describe("RulesStore", function()
    local saved, warnings, changes, db, store

    local function newDB(data)
        return ns.SettingsDB.New(data, { character = "Me", schemaVersion = 1 })
    end

    local function newStore(options)
        options = options or {}
        options.onWarning = options.onWarning or function(m) warnings[#warnings + 1] = m end
        options.onChange = options.onChange or function(k) changes[#changes + 1] = k end
        return ns.RulesStore.New(db, options)
    end

    before_each(function()
        saved, warnings, changes = {}, {}, {}
        db = newDB(saved)
        store = newStore()
    end)

    describe("saving", function()
        it("saves nothing for a new profile until the first change", function()
            assert.is_nil(saved[PROFILE_GROUPS])
            assert.is_nil(saved[PROFILE_OPS])
            assert.are.same({}, store:Children(2))
            assert.are.equal("Base", store:Name(1))
            assert.is_nil(saved[PROFILE_GROUPS])
        end)

        it("writes the groups key on a group change", function()
            local id = store:CreateGroup(1, "Herbs")
            assert.is_table(saved[PROFILE_GROUPS])
            assert.are.equal("Herbs", saved[PROFILE_GROUPS].nodes[id].name)
            assert.is_true(ns.GroupTree.Validate(saved[PROFILE_GROUPS]))
        end)

        it("writes the operations key on an operation change", function()
            local id = store:CreateOperation("selling", "Main")
            assert.are.equal("Main", saved[PROFILE_OPS].ops[id].name)
            assert.are.equal("selling", saved[PROFILE_OPS].ops[id].type)
        end)

        it("saves a copy, not the working data", function()
            local id = store:CreateGroup(1, "Herbs")
            local snapshot = saved[PROFILE_GROUPS]
            store:RenameGroup(id, "Ore")
            assert.are.equal("Herbs", snapshot.nodes[id].name)
            assert.are_not.equal(snapshot, saved[PROFILE_GROUPS])
            saved[PROFILE_GROUPS].nodes[id].name = "Tampered"
            assert.are.equal("Ore", store:Name(id))
        end)

        it("returns copies from GetOperation and the list calls", function()
            local id = store:CreateOperation("selling", "Main")
            local op = store:GetOperation(id)
            op.settings.postCap = 999
            op.name = "Other"
            assert.are.equal(0, store:GetOperation(id).settings.postCap)
            assert.are.equal("Main", store:GetOperation(id).name)
            assert.are.equal(0, saved[PROFILE_OPS].ops[id].settings.postCap)
            local path = store:Path(1)
            path[1] = "X"
            assert.are.equal("Base", store:Name(1))
        end)

        it("does not save when a change fails", function()
            local ok, message = store:CreateGroup(1, "")
            assert.is_nil(ok)
            assert.is_string(message)
            assert.is_nil(saved[PROFILE_GROUPS])
            assert.are.same({}, changes)
        end)
    end)

    describe("read-only", function()
        it("rolls back and returns the message when the DB is read-only", function()
            local roSaved = { _schema = 9 }
            local roDB = newDB(roSaved)
            local ro = ns.RulesStore.New(roDB, { onChange = function(k) changes[#changes + 1] = k end })
            assert.is_true(ro:IsReadOnly())
            local id, message = ro:CreateGroup(1, "Herbs")
            assert.is_nil(id)
            assert.are.equal("settings are read-only", message)
            assert.are.same({}, ro:Children(1))
            assert.are.same({}, changes)
            local op, opMessage = ro:CreateOperation("selling", "A")
            assert.is_nil(op)
            assert.are.equal("settings are read-only", opMessage)
        end)

        it("rolls back when Set returns false", function()
            local id = store:CreateGroup(1, "Herbs")
            changes = {}
            local realSet = db.Set
            db.Set = function() return false end
            local ok, message = store:RenameGroup(id, "Ore")
            db.Set = realSet
            assert.is_nil(ok)
            assert.are.equal("settings are read-only", message)
            assert.are.equal("Herbs", store:Name(id))
            assert.are.same({}, changes)
        end)

        it("loads invalid groups data read-only with one warning and keeps it", function()
            local bad = { version = 7, nodes = {} }
            saved[PROFILE_GROUPS] = bad
            local s = newStore()
            assert.is_true(s:IsReadOnly())
            assert.are.equal(1, #warnings)
            local ok, message = s:CreateGroup(1, "Herbs")
            assert.is_nil(ok)
            assert.are.equal("settings are read-only", message)
            assert.are.equal(bad, saved[PROFILE_GROUPS])
            assert.are.same({ version = 7, nodes = {} }, saved[PROFILE_GROUPS])
        end)

        it("loads malformed operations data read-only with one warning", function()
            local bad = { version = 1, nextID = 3, ops = { [1] = { type = "nope", name = "A", settings = {} } } }
            saved[PROFILE_OPS] = bad
            local s = newStore()
            assert.is_true(s:IsReadOnly())
            assert.are.equal(1, #warnings)
            assert.is_nil(s:CreateOperation("selling", "B"))
            assert.are.equal(bad, saved[PROFILE_OPS])
            assert.is_nil(saved[PROFILE_GROUPS])
        end)

        it("warns once when both keys are invalid", function()
            saved[PROFILE_GROUPS] = "x"
            saved[PROFILE_OPS] = "y"
            newStore()
            assert.are.equal(1, #warnings)
        end)
    end)

    describe("groups", function()
        it("wraps the group calls", function()
            local herbs = store:CreateGroup(1, "Herbs")
            local flowers = store:CreateGroup(herbs, "Flowers")
            assert.are.same({ herbs }, store:Children(1))
            assert.are.same({ "Base", "Herbs", "Flowers" }, store:Path(flowers))
            assert.is_true(store:MoveGroup(flowers, 1))
            assert.are.same({ flowers, herbs }, store:Children(1))
            assert.is_true(store:RenameGroup(flowers, "Blooms"))
            assert.are.equal("Blooms", store:Name(flowers))
            assert.is_true(store:AddItem("100", herbs))
            assert.are.equal(herbs, store:GroupOf("100"))
            assert.are.same({ "100" }, store:ItemsIn(herbs))
            assert.are.equal(1, store:CountItems(herbs))
            assert.are.equal(1, store:CountItems(1, true))
            assert.is_true(store:RemoveItem("100"))
            assert.are.equal(1, store:GroupOf("100"))
            local seen = {}
            store:Walk(function(id, depth) seen[#seen + 1] = id .. "@" .. depth end)
            assert.are.same({ "1@0", flowers .. "@1", herbs .. "@1" }, seen)
            assert.is_true(store:DeleteGroup(herbs))
            assert.is_false(ns.GroupTree.Exists(saved[PROFILE_GROUPS], herbs))
        end)

        it("returns the message of a refused change", function()
            local ok, message = store:RenameGroup(1, "Top")
            assert.is_nil(ok)
            assert.are.equal("the Base group cannot be renamed", message)
        end)

        it("saves a batch of items once", function()
            local herbs = store:CreateGroup(1, "Herbs")
            local writes, realSet = 0, db.Set
            db.Set = function(...)
                writes = writes + 1
                return realSet(...)
            end
            changes = {}
            local added = store:AddItems({ "100", "200", "bad key", "300" }, herbs)
            db.Set = realSet
            assert.are.equal(3, added)
            assert.are.equal(1, writes)
            assert.are.same({ "groups" }, changes)
            assert.are.same({ "100", "200", "300" }, store:ItemsIn(herbs))
            assert.is_nil(store:AddItems({ "400" }, 99))
        end)
    end)

    describe("operations", function()
        it("creates operations with defaults", function()
            local id = store:CreateOperation("buying", "Cheap")
            local op = store:GetOperation(id)
            assert.are.equal("buying", op.type)
            assert.are.equal("Cheap", op.name)
            assert.are.same(ns.OperationSchema.Defaults("buying"), op.settings)
            assert.is_nil(store:GetOperation(99))
        end)

        it("rejects an unknown type", function()
            local id, message = store:CreateOperation("flying", "A")
            assert.is_nil(id)
            assert.is_string(message)
        end)

        it("trims names and checks the length", function()
            local id = store:CreateOperation("selling", "  Main  ")
            assert.are.equal("Main", store:GetOperation(id).name)
            assert.is_nil(store:CreateOperation("selling", "   "))
            assert.is_nil(store:CreateOperation("selling", string.rep("a", 41)))
            assert.is_number(store:CreateOperation("selling", string.rep("a", 40)))
            assert.is_nil(store:CreateOperation("selling", 5))
        end)

        it("keeps names unique per type, ignoring case", function()
            local a = store:CreateOperation("selling", "Main")
            local ok, message = store:CreateOperation("selling", "MAIN")
            assert.is_nil(ok)
            assert.is_string(message)
            assert.is_number(store:CreateOperation("buying", "Main"))
            local b = store:CreateOperation("selling", "Other")
            assert.is_nil(store:RenameOperation(b, "main"))
            assert.is_true(store:RenameOperation(a, "MAIN"))
            assert.are.equal("MAIN", store:GetOperation(a).name)
            assert.is_nil(store:RenameOperation(99, "X"))
        end)

        it("fixes the type after creation", function()
            local id = store:CreateOperation("selling", "Main")
            store:RenameOperation(id, "Renamed")
            assert.are.equal("selling", store:GetOperation(id).type)
            assert.is_nil(store.SetType)
        end)

        it("duplicates an operation without a link", function()
            local id = store:CreateOperation("selling", "Main")
            assert.is_true(store:SetSetting(id, "postCap", 5))
            local copy = store:DuplicateOperation(id, "Main copy")
            assert.are_not.equal(id, copy)
            assert.are.equal(5, store:GetOperation(copy).settings.postCap)
            assert.are.equal("selling", store:GetOperation(copy).type)
            assert.is_true(store:SetSetting(copy, "postCap", 9))
            assert.are.equal(5, store:GetOperation(id).settings.postCap)
            assert.is_nil(store:DuplicateOperation(id, "main COPY"))
            assert.is_nil(store:DuplicateOperation(99, "Z"))
        end)

        it("lists operations sorted by name", function()
            local b = store:CreateOperation("selling", "beta")
            local a = store:CreateOperation("selling", "Alpha")
            local c = store:CreateOperation("buying", "Cheap")
            assert.are.same({
                { id = a, name = "Alpha", type = "selling" },
                { id = b, name = "beta", type = "selling" },
            }, store:ListOperations("selling"))
            assert.are.equal(3, #store:ListOperations())
            assert.are.equal(c, store:ListOperations("buying")[1].id)
            assert.are.same({}, store:ListOperations("vendoring"))
        end)

        it("deletes an operation and detaches it from all groups", function()
            local herbs = store:CreateGroup(1, "Herbs")
            local ore = store:CreateGroup(1, "Ore")
            local id = store:CreateOperation("selling", "Main")
            store:AttachOperation(herbs, "selling", id)
            store:AttachOperation(ore, "selling", id)
            assert.are.same({ herbs, ore }, store:GroupsUsing(id))
            changes = {}
            assert.is_true(store:DeleteOperation(id))
            assert.is_nil(store:GetOperation(id))
            assert.are.same({}, store:GroupsUsing(id))
            assert.is_nil(store:EffectiveOperation(herbs, "selling"))
            assert.is_nil(saved[PROFILE_OPS].ops[id])
            assert.is_nil(saved[PROFILE_GROUPS].attach[herbs])
            assert.are.same({ "operations", "groups" }, changes)
            assert.is_nil(store:DeleteOperation(id))
        end)
    end)

    describe("SetSetting", function()
        local id

        before_each(function()
            store = newStore({ compile = function(text)
                if text:find("bad") then
                    return nil, { message = "bad formula", pos = 1 }
                end
                return {}
            end })
            id = store:CreateOperation("selling", "Main")
        end)

        it("accepts a valid number and saves it", function()
            assert.is_true(store:SetSetting(id, "postCap", 12))
            assert.are.equal(12, saved[PROFILE_OPS].ops[id].settings.postCap)
        end)

        it("refuses a number out of range", function()
            local ok, message = store:SetSetting(id, "postCap", 99999)
            assert.is_nil(ok)
            assert.is_string(message)
            assert.are.equal(0, store:GetOperation(id).settings.postCap)
        end)

        it("checks choices", function()
            assert.is_true(store:SetSetting(id, "duration", 48))
            assert.is_nil(store:SetSetting(id, "duration", 7))
            assert.are.equal(48, store:GetOperation(id).settings.duration)
        end)

        it("compiles formulas", function()
            assert.is_true(store:SetSetting(id, "minPrice", "scanmarket"))
            local ok, message = store:SetSetting(id, "minPrice", "bad")
            assert.is_nil(ok)
            assert.is_truthy(message:find("bad formula"))
            assert.are.equal("scanmarket", store:GetOperation(id).settings.minPrice)
        end)

        it("accepts a non-empty formula without a compile function", function()
            local plain = newStore()
            local op = plain:CreateOperation("buying", "Plain")
            assert.is_true(plain:SetSetting(op, "maxPrice", "bad"))
            assert.is_nil(plain:SetSetting(op, "maxPrice", "  "))
        end)

        it("refuses an unknown key and an unknown operation", function()
            assert.is_nil(store:SetSetting(id, "nothing", 1))
            assert.is_nil(store:SetSetting(99, "postCap", 1))
        end)

        it("normalizes missing settings when reading", function()
            saved[PROFILE_OPS].ops[id].settings.postCap = nil
            local s = newStore()
            assert.are.equal(0, s:GetOperation(id).settings.postCap)
        end)
    end)

    describe("attachments", function()
        it("refuses a type mismatch", function()
            local id = store:CreateOperation("buying", "Cheap")
            local ok, message = store:AttachOperation(1, "selling", id)
            assert.is_nil(ok)
            assert.is_string(message)
            assert.is_nil(store:EffectiveOperation(1, "selling"))
            assert.is_nil(store:AttachOperation(1, "buying", 99))
            assert.is_nil(store:AttachOperation(99, "buying", id))
        end)

        it("finds the effective operation through the parents", function()
            local herbs = store:CreateGroup(1, "Herbs")
            local flowers = store:CreateGroup(herbs, "Flowers")
            local main = store:CreateOperation("selling", "Main")
            local special = store:CreateOperation("selling", "Special")
            assert.is_true(store:AttachOperation(1, "selling", main))
            local op, from = store:EffectiveOperation(flowers, "selling")
            assert.are.equal(main, op)
            assert.are.equal(1, from)
            assert.is_true(store:AttachOperation(herbs, "selling", special))
            op, from = store:EffectiveOperation(flowers, "selling")
            assert.are.equal(special, op)
            assert.are.equal(herbs, from)
            assert.is_true(store:DetachOperation(herbs, "selling"))
            assert.are.equal(main, (store:EffectiveOperation(flowers, "selling")))
            assert.is_nil(store:EffectiveOperation(flowers, "buying"))
            assert.are.same({ 1 }, store:GroupsUsing(main))
        end)

        it("allows one operation in many groups, one per type in a group", function()
            local herbs = store:CreateGroup(1, "Herbs")
            local ore = store:CreateGroup(1, "Ore")
            local a = store:CreateOperation("selling", "A")
            local b = store:CreateOperation("selling", "B")
            store:AttachOperation(herbs, "selling", a)
            store:AttachOperation(ore, "selling", a)
            store:AttachOperation(herbs, "selling", b)
            assert.are.equal(b, (store:EffectiveOperation(herbs, "selling")))
            assert.are.same({ ore }, store:GroupsUsing(a))
        end)

        it("refuses to detach from an unknown group", function()
            assert.is_nil(store:DetachOperation(99, "selling"))
        end)
    end)

    describe("onChange", function()
        it("reports the kind of each change", function()
            local g = store:CreateGroup(1, "Herbs")
            local op = store:CreateOperation("selling", "Main")
            store:SetSetting(op, "postCap", 3)
            store:AttachOperation(g, "selling", op)
            store:DetachOperation(g, "selling")
            store:RenameOperation(op, "Main 2")
            assert.are.same(
                { "groups", "operations", "operations", "groups", "groups", "operations" },
                changes
            )
        end)

        it("does not report a refused change", function()
            store:CreateOperation("selling", "Main")
            changes = {}
            store:CreateOperation("selling", "main")
            store:SetSetting(1, "postCap", -1)
            assert.are.same({}, changes)
        end)

        it("works without callbacks", function()
            local quiet = ns.RulesStore.New(newDB({}), {})
            assert.is_number(quiet:CreateGroup(1, "A"))
        end)
    end)

    describe("reload", function()
        it("lets a second store see the saved data", function()
            local herbs = store:CreateGroup(1, "Herbs")
            local op = store:CreateOperation("selling", "Main")
            store:SetSetting(op, "postCap", 7)
            store:AttachOperation(herbs, "selling", op)
            store:AddItem("100", herbs)

            local again = ns.RulesStore.New(newDB(saved), { onWarning = function(m) warnings[#warnings + 1] = m end })
            assert.are.same({}, warnings)
            assert.is_false(again:IsReadOnly())
            assert.are.equal("Herbs", again:Name(herbs))
            assert.are.equal(herbs, again:GroupOf("100"))
            assert.are.equal(7, again:GetOperation(op).settings.postCap)
            assert.are.equal(op, (again:EffectiveOperation(herbs, "selling")))
            local next = again:CreateOperation("selling", "Next")
            assert.are.equal(op + 1, next)
        end)
    end)
end)
