local manifest = require("Tests.manifest")

local function load(flavour)
    local ns = { Flavour = flavour }
    for _, name in ipairs({ "SettingsDB", "CharacterKey", "LedgerBuffer", "LedgerStore" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

local FOREVER = { usesSurname = true, characterGuidKey = true }
local GUID_A, GUID_B = "Player-1-0000000A", "Player-1-0000000B"

describe("CharacterKey", function()
    local ns, K, db

    before_each(function()
        ns = load(FOREVER)
        K = ns.CharacterKey
        db = ns.SettingsDB.New({}, { character = "Me-Realm", schemaVersion = 1 })
        K.Setup({ db = db })
    end)

    describe("IsGuid", function()
        it("accepts a player GUID and rejects a Name-Realm key", function()
            assert.is_true(K.IsGuid(GUID_A))
            assert.is_true(K.IsGuid("Player-4440-0123ABCD"))
            assert.is_false(K.IsGuid("Player-Realm"))
            assert.is_false(K.IsGuid("Bob-Realm"))
            assert.is_false(K.IsGuid(nil))
            assert.is_false(K.IsGuid(12))
        end)
    end)

    describe("Compute", function()
        it("gives the GUID and the legacy key on Forever", function()
            local key, legacy = K.Compute("Bob", "Realm", GUID_A)
            assert.are.equal(GUID_A, key)
            assert.are.equal("Bob-Realm", legacy)
        end)

        it("gives Name-Realm and no legacy key if the GUID is nil", function()
            local key, legacy = K.Compute("Bob", "Realm", nil)
            assert.are.equal("Bob-Realm", key)
            assert.is_nil(legacy)
        end)

        it("gives Name-Realm if the GUID is not a player GUID", function()
            assert.are.equal("Bob-Realm", (K.Compute("Bob", "Realm", 5)))
            assert.are.equal("Bob-Realm", (K.Compute("Bob", "Realm", "")))
            assert.are.equal("Bob-Realm", (K.Compute("Bob", "Realm", "Creature-0-1-2-3-4-5")))
        end)

        it("gives Name-Realm if the GUID is a secret value", function()
            local secret = function(value)
                return value == GUID_A
            end
            local key, legacy = K.Compute("Bob", "Realm", GUID_A, secret)
            assert.are.equal("Bob-Realm", key)
            assert.is_nil(legacy)
        end)

        it("gives nil if the name or the realm is missing", function()
            assert.is_nil((K.Compute(nil, "Realm", GUID_A)))
            assert.is_nil((K.Compute("Bob", nil, GUID_A)))
            assert.is_nil((K.Compute("", "Realm", GUID_A)))
            assert.is_nil((K.Compute("Bob", "", GUID_A)))
        end)

        it("keeps Name-Realm on a flavour with no GUID key (TBC)", function()
            local tbc = load({ usesSurname = false, characterGuidKey = false })
            local key, legacy = tbc.CharacterKey.Compute("Bob", "Realm", GUID_A)
            assert.are.equal("Bob-Realm", key)
            assert.is_nil(legacy)
        end)
    end)

    describe("metadata", function()
        it("saves and reads the name and the realm of a GUID key", function()
            assert.is_true(K.SaveMeta(GUID_A, "Bob", "Realm"))
            assert.are.equal("Bob", K.Name(GUID_A))
            assert.are.equal("Realm", K.Realm(GUID_A))
            assert.are.equal("Bob-Realm", K.FullName(GUID_A))
        end)

        it("keeps two characters with the same first name apart", function()
            K.SaveMeta(GUID_A, "Bob", "Realm")
            K.SaveMeta(GUID_B, "Bob", "Realm")
            assert.are_not.equal(GUID_A, GUID_B)
            assert.are.equal("Bob", K.Name(GUID_B))
        end)

        it("replaces the metadata of a key", function()
            K.SaveMeta(GUID_A, "Bob", "Realm")
            K.SaveMeta(GUID_A, "Rob", "Other")
            assert.are.equal("Rob", K.Name(GUID_A))
            assert.are.equal("Other", K.Realm(GUID_A))
        end)

        it("saves nothing for a legacy key or a missing name", function()
            assert.is_false(K.SaveMeta("Bob-Realm", "Bob", "Realm"))
            assert.is_false(K.SaveMeta(GUID_A, nil, "Realm"))
            assert.is_false(K.SaveMeta(GUID_A, "Bob", ""))
            assert.is_nil(K.Meta(GUID_A))
        end)

        it("reads the name and the realm of a legacy key from the key", function()
            assert.are.equal("Bob", K.Name("Bob-Realm"))
            assert.are.equal("Realm", K.Realm("Bob-Realm"))
            assert.are.equal("Bob-Realm", K.FullName("Bob-Realm"))
            assert.are.equal("Solo", K.Name("Solo"))
            assert.is_nil(K.Realm("Solo"))
        end)

        it("never gives a GUID as a name", function()
            assert.are.equal("Unknown", K.Name(GUID_A))
            assert.are.equal("Unknown", K.FullName(GUID_A))
            assert.is_nil(K.Realm(GUID_A))
        end)

        it("removes the metadata of a key and keeps the others", function()
            K.SaveMeta(GUID_A, "Bob", "Realm")
            K.SaveMeta(GUID_B, "Eve", "Realm")
            assert.is_true(K.RemoveMeta(GUID_A))
            assert.is_nil(K.Meta(GUID_A))
            assert.are.equal("Eve", K.Name(GUID_B))
            assert.is_false(K.RemoveMeta(GUID_A))
        end)
    end)

    describe("Claim", function()
        it("gives the legacy key to the first GUID only", function()
            assert.are.equal(GUID_A, K.Claim("Bob-Realm", GUID_A))
            assert.are.equal(GUID_A, K.Claim("Bob-Realm", GUID_B))
            assert.are.equal(GUID_A, K.Claim("Bob-Realm", GUID_A))
            assert.are.same({ ["Bob-Realm"] = GUID_A }, K.Claims())
        end)

        it("gives nothing if the DB is read-only", function()
            local saved = { _schema = 99 }
            K.Setup({ db = ns.SettingsDB.New(saved, { character = "Me-Realm", schemaVersion = 1 }) })
            assert.is_nil(K.Claim("Bob-Realm", GUID_A))
            assert.are.same({}, K.Claims())
        end)
    end)
end)

describe("SettingsDB MoveCharacter", function()
    local ns, db, saved

    before_each(function()
        ns = load(FOREVER)
        saved = {
            _schema = 1,
            ["c/Bob-Realm/holdings"] = { version = 1 },
            ["c/Bob-Realm/ledger.balance"] = { copper = 5, time = 1 },
            ["c/Bob-Realm/ledger.view.char"] = "Bob-Realm",
            ["c/Eve-Realm/ledger.view.char"] = "Bob-Realm",
            ["c/Eve-Realm/other"] = 1,
            ["a/profiles.map"] = { ["Bob-Realm"] = "Mage" },
            ["a/profiles.list"] = { Default = true, Mage = true },
        }
        db = ns.SettingsDB.New(saved, { character = GUID_A, schemaVersion = 1 })
    end)

    it("moves the character settings and removes the old key", function()
        local moved = db:MoveCharacter("Bob-Realm", GUID_A)
        assert.is_true(moved >= 3)
        assert.are.same({ version = 1 }, db:GetFor(GUID_A, "holdings"))
        assert.are.equal(5, db:GetFor(GUID_A, "ledger.balance").copper)
        assert.is_nil(db:GetFor("Bob-Realm", "holdings"))
        for _, name in ipairs(db:ListCharacters()) do
            assert.are_not.equal("Bob-Realm", name)
        end
    end)

    it("moves the profile choice over the Default that a new key got", function()
        db:MoveCharacter("Bob-Realm", GUID_A)
        assert.are.equal("Mage", db:GetProfile())
        assert.is_nil(saved["a/profiles.map"]["Bob-Realm"])
    end)

    it("rewrites the listed values that name the old key, in every character", function()
        db:MoveCharacter("Bob-Realm", GUID_A, { "ledger.view.char" })
        assert.are.equal(GUID_A, db:GetFor(GUID_A, "ledger.view.char"))
        assert.are.equal(GUID_A, db:GetFor("Eve-Realm", "ledger.view.char"))
        assert.are.equal(1, db:GetFor("Eve-Realm", "other"))
    end)

    it("keeps a setting that the new key has and drops the old value", function()
        db:SetFor(GUID_A, "ledger.balance", { copper = 9, time = 2 })
        db:MoveCharacter("Bob-Realm", GUID_A)
        assert.are.equal(9, db:GetFor(GUID_A, "ledger.balance").copper)
        assert.is_nil(db:GetFor("Bob-Realm", "ledger.balance"))
    end)

    it("moves nothing a second time", function()
        db:MoveCharacter("Bob-Realm", GUID_A)
        assert.are.equal(0, db:MoveCharacter("Bob-Realm", GUID_A))
        assert.are.equal(0, db:MoveCharacter(GUID_A, GUID_A))
    end)

    it("moves nothing if the DB is read-only", function()
        local locked = { _schema = 99, ["c/Bob-Realm/holdings"] = { version = 1 } }
        local readOnly = ns.SettingsDB.New(locked, { character = GUID_A, schemaVersion = 1 })
        assert.are.equal(0, readOnly:MoveCharacter("Bob-Realm", GUID_A))
        assert.is_table(locked["c/Bob-Realm/holdings"])
    end)
end)

local function record(time, char)
    return { time = time, char = char, type = "income", source = "quest", money = time }
end

describe("LedgerStore MoveCharacter", function()
    local ns, store, saved

    before_each(function()
        ns = load(FOREVER)
        saved = {
            _schema = 1,
            records = {
                EU = {
                    standard = {
                        ["Bob-Realm"] = { record(1, "Bob-Realm") },
                        [GUID_A] = { record(2, GUID_A) },
                    },
                },
            },
            sums = {
                EU = {
                    standard = {
                        ["Bob-Realm"] = {
                            { day = 1, source = "quest", item = "", count = 2, qty = 0, moneyIn = 5, moneyOut = 0 },
                            { day = 2, source = "quest", item = "", count = 1, qty = 0, moneyIn = 1, moneyOut = 0 },
                        },
                        [GUID_A] = {
                            { day = 1, source = "quest", item = "", count = 1, qty = 0, moneyIn = 3, moneyOut = 0 },
                        },
                    },
                },
            },
        }
        store = ns.LedgerStore.New(saved, { region = "EU", ruleset = "standard" })
    end)

    it("moves the records and rewrites the field char", function()
        assert.are.equal(3, store:MoveCharacter("Bob-Realm", GUID_A))
        local list = saved.records.EU.standard[GUID_A]
        assert.are.equal(2, #list)
        for _, stored in ipairs(list) do
            assert.are.equal(GUID_A, stored.char)
        end
        assert.is_nil(saved.records.EU.standard["Bob-Realm"])
    end)

    it("adds the daily sums of the same day, source and item together", function()
        store:MoveCharacter("Bob-Realm", GUID_A)
        local sums = saved.sums.EU.standard[GUID_A]
        assert.are.equal(2, #sums)
        assert.are.equal(3, sums[1].count)
        assert.are.equal(8, sums[1].moneyIn)
        assert.are.equal(2, sums[2].day)
        assert.is_nil(saved.sums.EU.standard["Bob-Realm"])
    end)

    it("moves nothing a second time and lists no old key", function()
        store:MoveCharacter("Bob-Realm", GUID_A)
        assert.are.equal(0, store:MoveCharacter("Bob-Realm", GUID_A))
        assert.are.same({ GUID_A }, store:Characters())
    end)

    it("moves the data of every region and ruleset", function()
        saved.records.US = { classic = { ["Bob-Realm"] = { record(3, "Bob-Realm") } } }
        assert.are.equal(4, store:MoveCharacter("Bob-Realm", GUID_A))
        assert.are.equal(1, #saved.records.US.classic[GUID_A])
    end)

    it("changes the revision so that a page draws again", function()
        local before = store:Revision()
        store:MoveCharacter("Bob-Realm", GUID_A)
        assert.is_true(store:Revision() > before)
    end)
end)

describe("LedgerBuffer RenameCharacter", function()
    it("changes the field char of the records of the old key only", function()
        local ns = load(FOREVER)
        local db = ns.SettingsDB.New({}, { character = GUID_A, schemaVersion = 1 })
        db:Set("account", "ledger.buffer", {
            { char = "Bob-Realm" }, { char = "Eve-Realm" }, { char = "Bob-Realm" },
        })
        assert.are.equal(2, ns.LedgerBuffer.RenameCharacter(db, "Bob-Realm", GUID_A))
        local list = db:Get("account", "ledger.buffer")
        assert.are.equal(GUID_A, list[1].char)
        assert.are.equal("Eve-Realm", list[2].char)
        assert.are.equal(GUID_A, list[3].char)
        assert.are.equal(0, ns.LedgerBuffer.RenameCharacter(db, "Bob-Realm", GUID_A))
    end)

    it("changes nothing without a buffer", function()
        local ns = load(FOREVER)
        local db = ns.SettingsDB.New({}, { character = GUID_A, schemaVersion = 1 })
        assert.are.equal(0, ns.LedgerBuffer.RenameCharacter(db, "Bob-Realm", GUID_A))
    end)
end)
