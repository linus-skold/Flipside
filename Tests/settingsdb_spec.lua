local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("SettingsDB")))("Flipside", ns)
local SettingsDB = ns.SettingsDB

local function Open(saved, extra)
    local opts = { character = "Alice-Realm", schemaVersion = 1 }
    for k, v in pairs(extra or {}) do
        opts[k] = v
    end
    return SettingsDB.New(saved, opts)
end

local function Warnings()
    local list = {}
    list.fn = function(message)
        list[#list + 1] = message
    end
    return list
end

describe("SettingsDB", function()
    describe("other characters", function()
        it("lists characters from the map and key prefixes", function()
            local saved = { _schema = 1, ["c/Bob-Other/x"] = 1, ["c/Cy-Realm/y"] = 2 }
            local db = Open(saved)
            db:SetProfile("P")
            assert.are.same({ "Alice-Realm", "Bob-Other", "Cy-Realm" }, db:ListCharacters())
        end)

        it("reads, writes and removes values of a character", function()
            local saved = {}
            local db = Open(saved)
            assert.is_nil(db:GetFor("Bob-Other", "k"))
            assert.is_true(db:SetFor("Bob-Other", "k", { 1 }))
            assert.are.same({ 1 }, saved["c/Bob-Other/k"])
            assert.are.same({ 1 }, db:GetFor("Bob-Other", "k"))
            db:SetFor("Alice-Realm", "k", 5)
            assert.are.equal(5, db:Get("character", "k"))
            assert.is_true(db:RemoveFor("Bob-Other", "k"))
            assert.is_nil(saved["c/Bob-Other/k"])
        end)

        it("rejects invalid names", function()
            local db = Open({})
            assert.has_error(function() db:GetFor("a/b", "k") end)
            assert.has_error(function() db:SetFor("Bob", "", 1) end)
        end)

        it("does not write when read-only", function()
            local saved = { _schema = 5, ["c/Bob/k"] = 1 }
            local db = Open(saved)
            assert.is_false(db:SetFor("Bob", "k", 2))
            assert.is_false(db:RemoveFor("Bob", "k"))
            assert.are.equal(1, db:GetFor("Bob", "k"))
        end)
    end)

    describe("new DB", function()
        it("sets the schema and the Default profile", function()
            local saved = {}
            local db = Open(saved)
            assert.are.equal(1, saved._schema)
            assert.are.equal(1, db:GetSchemaVersion())
            assert.are.equal("Default", db:GetProfile())
            assert.are.same({ "Default" }, db:ListProfiles())
            assert.are.same({ ["Alice-Realm"] = "Default" }, saved["a/profiles.map"])
            assert.is_false(db:IsReadOnly())
        end)

        it("raises an error if saved is not a table", function()
            assert.has_error(function()
                SettingsDB.New("x", { character = "A", schemaVersion = 1 })
            end)
        end)

        it("validates options", function()
            assert.has_error(function() SettingsDB.New({}, { schemaVersion = 1 }) end)
            assert.has_error(function() SettingsDB.New({}, { character = "A" }) end)
            assert.has_error(function() SettingsDB.New({}, { character = "A", schemaVersion = 0 }) end)
            assert.has_error(function() SettingsDB.New({}, { character = "A", schemaVersion = 1.5 }) end)
        end)
    end)

    describe("get and set", function()
        it("stores keys with exact names in each scope", function()
            local saved = {}
            local db = Open(saved)
            assert.is_true(db:Set("account", "x", 1))
            assert.is_true(db:Set("profile", "y", 2))
            assert.is_true(db:Set("character", "z", 3))
            assert.are.equal(1, saved["a/x"])
            assert.are.equal(2, saved["p/Default/y"])
            assert.are.equal(3, saved["c/Alice-Realm/z"])
            assert.are.equal(1, db:Get("account", "x"))
            assert.are.equal(2, db:Get("profile", "y"))
            assert.are.equal(3, db:Get("character", "z"))
        end)

        it("stores false and tables", function()
            local db = Open({})
            db:Set("account", "f", false)
            db:Set("account", "t", { 1, 2 })
            assert.is_false(db:Get("account", "f"))
            assert.are.same({ 1, 2 }, db:Get("account", "t"))
        end)

        it("removes a key when the value is nil", function()
            local saved = {}
            local db = Open(saved)
            db:Set("account", "x", 1)
            db:Set("account", "x", nil)
            assert.is_nil(saved["a/x"])
            assert.is_nil(db:Get("account", "x"))
        end)

        it("returns defaults and deep copies table defaults", function()
            local defaults = {
                account = { n = 5 },
                profile = { t = { a = 1 } },
                character = { c = "d" },
            }
            local db = Open({}, { defaults = defaults })
            assert.are.equal(5, db:Get("account", "n"))
            assert.are.equal("d", db:Get("character", "c"))
            local t = db:Get("profile", "t")
            t.a = 99
            assert.are.equal(1, defaults.profile.t.a)
            assert.are.equal(1, db:Get("profile", "t").a)
            db:Set("account", "n", 7)
            assert.are.equal(7, db:Get("account", "n"))
        end)

        it("rejects invalid names and scopes", function()
            local db = Open({})
            assert.has_error(function() db:Set("account", "", 1) end)
            assert.has_error(function() db:Set("account", "a/b", 1) end)
            assert.has_error(function() db:Set("account", 5, 1) end)
            assert.has_error(function() db:Get("account", nil) end)
            assert.has_error(function() db:Get("bogus", "x") end)
            assert.has_error(function() db:SetProfile("") end)
            assert.has_error(function() db:SetProfile("a/b") end)
            assert.has_error(function() db:ResetCharacter("a/b") end)
            assert.has_error(function() db:ResetCharacter("") end)
            assert.has_error(function() SettingsDB.New({}, { character = "a/b", schemaVersion = 1 }) end)
        end)

        it("rejects reserved keys in Set", function()
            local db = Open({})
            assert.has_error(function() db:Set("account", "profiles.map", {}) end)
            assert.has_error(function() db:Set("account", "profiles.list", {}) end)
        end)
    end)

    describe("characters and profiles", function()
        it("separates profile values and shares account values", function()
            local saved = {}
            local alice = Open(saved)
            local bob = Open(saved, { character = "Bob-Realm" })
            alice:Set("account", "shared", "yes")
            alice:Set("profile", "opt", "A")
            bob:SetProfile("Bobs")
            bob:Set("profile", "opt", "B")
            assert.are.equal("A", alice:Get("profile", "opt"))
            assert.are.equal("B", bob:Get("profile", "opt"))
            assert.are.equal("yes", bob:Get("account", "shared"))
            assert.are.equal("B", saved["p/Bobs/opt"])
        end)

        it("shares the last full scan time between characters (D9)", function()
            local saved = {}
            local alice = Open(saved)
            alice:Set("account", "lastFullScan", 1791930182)
            local bob = Open(saved, { character = "Bob-Realm" })
            assert.are.equal(1791930182, bob:Get("account", "lastFullScan"))
        end)

        it("keeps character values separate", function()
            local saved = {}
            local alice = Open(saved)
            local bob = Open(saved, { character = "Bob-Realm" })
            alice:Set("character", "k", 1)
            assert.is_nil(bob:Get("character", "k"))
        end)

        it("sets a profile and lists sorted names", function()
            local db = Open({})
            db:SetProfile("Zed")
            db:SetProfile("Alpha")
            assert.are.equal("Alpha", db:GetProfile())
            assert.are.same({ "Alpha", "Default", "Zed" }, db:ListProfiles())
        end)

        it("copies a profile and removes extra keys", function()
            local saved = {}
            local db = Open(saved)
            db:Set("profile", "a", { v = 1 })
            db:Set("profile", "b", 2)
            db:SetProfile("Other")
            db:Set("profile", "extra", true)
            db:Set("profile", "a", "old")
            assert.is_true(db:CopyProfile("Default", "Other"))
            assert.are.same({ v = 1 }, db:Get("profile", "a"))
            assert.are.equal(2, db:Get("profile", "b"))
            assert.is_nil(db:Get("profile", "extra"))
            assert.are_not.equal(saved["p/Default/a"], saved["p/Other/a"])
            assert.are.same({ "Default", "Other" }, db:ListProfiles())
        end)

        it("creates the target on copy and rejects a missing source", function()
            local db = Open({})
            db:Set("profile", "a", 1)
            db:CopyProfile("Default", "New")
            assert.are.same({ "Default", "New" }, db:ListProfiles())
            assert.has_error(function() db:CopyProfile("Nope", "X") end)
        end)

        it("deletes a profile and moves its characters to Default", function()
            local saved = {}
            local alice = Open(saved)
            local bob = Open(saved, { character = "Bob-Realm" })
            alice:SetProfile("Temp")
            bob:SetProfile("Temp")
            alice:Set("profile", "a", 1)
            assert.is_true(alice:DeleteProfile("Temp"))
            assert.are.equal("Default", alice:GetProfile())
            assert.are.equal("Default", bob:GetProfile())
            assert.is_nil(saved["p/Temp/a"])
            assert.are.same({ "Default" }, alice:ListProfiles())
        end)

        it("does not delete Default or a missing profile", function()
            local db = Open({})
            assert.has_error(function() db:DeleteProfile("Default") end)
            assert.has_error(function() db:DeleteProfile("Nope") end)
        end)

        it("resets a character", function()
            local saved = {}
            local alice = Open(saved)
            local bob = Open(saved, { character = "Bob-Realm" })
            alice:Set("character", "k", 1)
            bob:Set("character", "k", 2)
            alice:SetProfile("P")
            assert.is_true(alice:ResetCharacter("Alice-Realm"))
            assert.is_nil(saved["c/Alice-Realm/k"])
            assert.is_nil(saved["a/profiles.map"]["Alice-Realm"])
            assert.are.equal(2, saved["c/Bob-Realm/k"])
            assert.are.equal("Default", alice:GetProfile())
        end)
    end)

    describe("migrations", function()
        local function Mig()
            return {
                function(d) d["a/one"] = 1 end,
                function(d) d["a/two"] = d["a/one"] + 1 end,
            }
        end

        it("runs 0 to 1 to 2 in sequence on legacy data", function()
            local order = {}
            local saved = { ["a/legacy"] = "x" }
            local db = Open(saved, {
                schemaVersion = 2,
                migrations = {
                    function(d) order[#order + 1] = 1; d["a/one"] = 1 end,
                    function(d) order[#order + 1] = 2; d["a/two"] = d["a/one"] + 1 end,
                },
            })
            assert.are.same({ 1, 2 }, order)
            assert.are.equal(2, saved._schema)
            assert.are.equal(2, db:GetSchemaVersion())
            assert.are.equal(2, saved["a/two"])
            assert.are.equal("x", saved["a/legacy"])
            assert.is_false(db:IsReadOnly())
        end)

        it("runs only the missing steps", function()
            local saved = { _schema = 1 }
            Open(saved, { schemaVersion = 2, migrations = {
                function() error("must not run") end,
                function(d) d["a/two"] = 2 end,
            } })
            assert.are.equal(2, saved["a/two"])
        end)

        it("keeps the same saved table object", function()
            local saved = { ["a/legacy"] = 1 }
            local ref = saved
            Open(saved, { schemaVersion = 2, migrations = Mig() })
            assert.are.equal(ref, saved)
            assert.are.equal(2, saved._schema)
        end)

        it("leaves saved unchanged and goes read-only on failure", function()
            local saved = { _schema = 0, ["a/keep"] = { n = 1 } }
            local before = { _schema = 0, ["a/keep"] = { n = 1 } }
            local warnings = Warnings()
            local db = Open(saved, {
                schemaVersion = 2,
                onWarning = warnings.fn,
                migrations = {
                    function(d) d["a/one"] = 1; d["a/keep"].n = 5 end,
                    function() error("boom") end,
                },
            })
            assert.are.same(before, saved)
            assert.is_true(db:IsReadOnly())
            assert.are.equal(0, db:GetSchemaVersion())
            assert.are.equal(1, #warnings)
            assert.is_truthy(warnings[1]:find("2", 1, true))
            assert.is_truthy(warnings[1]:find("boom", 1, true))
            assert.are.equal(1, db:Get("account", "keep").n)
        end)

        it("fails on a missing migration step", function()
            local saved = { _schema = 1, ["a/x"] = 1 }
            local warnings = Warnings()
            local db = Open(saved, { schemaVersion = 3, migrations = {}, onWarning = warnings.fn })
            assert.is_true(db:IsReadOnly())
            assert.are.same({ _schema = 1, ["a/x"] = 1 }, saved)
            assert.are.equal(1, #warnings)
        end)

        it("loads a newer DB read-only with a warning", function()
            local saved = { _schema = 5, ["a/x"] = 1 }
            local warnings = Warnings()
            local db = Open(saved, { schemaVersion = 2, onWarning = warnings.fn })
            assert.is_true(db:IsReadOnly())
            assert.are.equal(5, db:GetSchemaVersion())
            assert.are.equal(1, #warnings)
            assert.is_truthy(warnings[1]:find("5", 1, true))
            assert.is_truthy(warnings[1]:find("2", 1, true))
            assert.are.same({ _schema = 5, ["a/x"] = 1 }, saved)
        end)

        it("returns false from writes in read-only mode and warns once", function()
            local saved = { _schema = 5 }
            local warnings = Warnings()
            local db = Open(saved, { onWarning = warnings.fn })
            assert.are.equal(1, #warnings)
            assert.is_false(db:Set("account", "x", 1))
            assert.are.equal(2, #warnings)
            assert.is_false(db:Set("account", "y", 1))
            assert.is_false(db:SetProfile("P"))
            assert.is_false(db:ResetCharacter("Alice-Realm"))
            assert.are.equal(2, #warnings)
            assert.are.same({ _schema = 5 }, saved)
            assert.is_nil(db:Get("account", "x"))
            assert.are.same({}, db:ListProfiles())
        end)

        it("returns false from profile writes in read-only mode", function()
            local saved = { _schema = 5, ["a/profiles.list"] = { Default = true, P = true } }
            local db = Open(saved)
            assert.is_false(db:CopyProfile("P", "Q"))
            assert.is_false(db:DeleteProfile("P"))
            assert.are.same({ "Default", "P" }, db:ListProfiles())
        end)

        it("keeps unknown keys through load, migration and writes", function()
            local saved = { ["a/mystery"] = { 1 }, ["zzz"] = "odd" }
            local db = Open(saved, { schemaVersion = 2, migrations = Mig() })
            db:Set("account", "x", 1)
            db:SetProfile("P")
            db:DeleteProfile("P")
            assert.are.same({ 1 }, saved["a/mystery"])
            assert.are.equal("odd", saved.zzz)
        end)
    end)
end)
