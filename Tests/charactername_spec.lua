local manifest = require("Tests.manifest")

describe("CharacterName", function()
    local ns, C, store

    -- A small settings DB: GetFor and SetFor on a table.
    local function fakeDb()
        return {
            GetFor = function(_, key, name)
                return store[key .. "/" .. name]
            end,
            SetFor = function(_, key, name, value)
                store[key .. "/" .. name] = value
                return true
            end,
        }
    end

    local function setup(flavour, separator)
        store = {}
        ns = { Flavour = flavour }
        assert(loadfile(manifest.path("CharacterName")))("Flipside", ns)
        C = ns.CharacterName
        C.Setup({ db = fakeDb(), separator = separator })
    end

    describe("on Forever", function()
        before_each(function()
            setup({ usesSurname = true })
        end)

        it("saves the surname of a character key and reads it back", function()
            assert.is_true(C.SaveSurname("Bob-Realm", "Smith"))
            assert.are.equal("Smith", C.Surname("Bob-Realm"))
            assert.are.equal("Smith", store["Bob-Realm/surname"])
        end)

        it("keeps the key as it is and saves no surname for other keys", function()
            C.SaveSurname("Bob-Realm", "Smith")
            assert.is_nil(C.Surname("Alice-Realm"))
        end)

        it("keeps the saved surname when the client gives none", function()
            C.SaveSurname("Bob-Realm", "Smith")
            assert.is_false(C.SaveSurname("Bob-Realm", nil))
            assert.are.equal("Smith", C.Surname("Bob-Realm"))
            assert.is_false(C.SaveSurname("Bob-Realm", ""))
            assert.are.equal("Smith", C.Surname("Bob-Realm"))
        end)

        it("replaces the saved surname with a new one", function()
            C.SaveSurname("Bob-Realm", "Smith")
            assert.is_true(C.SaveSurname("Bob-Realm", "Jones"))
            assert.are.equal("Jones", C.Surname("Bob-Realm"))
        end)

        it("exposes the name of the setting", function()
            assert.are.equal("surname", C.SETTING_KEY)
        end)

        it("shows Name Surname, or Name with no known surname", function()
            C.SaveSurname("Bob-Realm", "Smith")
            assert.are.equal("Bob Smith", C.Display("Bob-Realm"))
            assert.are.equal("Alice", C.Display("Alice-Realm"))
            assert.are.equal("Solo", C.Display("Solo"))
        end)

        it("uses the separator of the client", function()
            setup({ usesSurname = true }, function()
                return "_"
            end)
            C.SaveSurname("Bob-Realm", "Smith")
            assert.are.equal("Bob_Smith", C.Display("Bob-Realm"))
            assert.are.equal("Bob-Realm", C.Resolve("bob_smith", { "Bob-Realm" }))
        end)

        it("uses a space when the client gives no separator", function()
            setup({ usesSurname = true }, function()
                return nil
            end)
            C.SaveSurname("Bob-Realm", "Smith")
            assert.are.equal("Bob Smith", C.Display("Bob-Realm"))
        end)

        describe("Resolve", function()
            local keys

            before_each(function()
                keys = { "Bob-RealmA", "Bob-RealmB", "Eve-RealmA" }
                C.SaveSurname("Bob-RealmA", "Smith")
                C.SaveSurname("Bob-RealmB", "Jones")
            end)

            it("matches Name, Name-Realm and Name Surname", function()
                assert.are.equal("Eve-RealmA", C.Resolve("Eve", keys))
                assert.are.equal("Eve-RealmA", C.Resolve("Eve-RealmA", keys))
                assert.are.equal("Bob-RealmA", C.Resolve("Bob Smith", keys))
                assert.are.equal("Bob-RealmB", C.Resolve("Bob Jones", keys))
            end)

            it("ignores case", function()
                assert.are.equal("Bob-RealmA", C.Resolve("BOB smith", keys))
                assert.are.equal("Eve-RealmA", C.Resolve("eve-realma", keys))
                assert.are.equal("Eve-RealmA", C.Resolve("EVE", keys))
            end)

            it("does not match a character of another realm key with the same name", function()
                assert.is_nil(C.Resolve("Bob-RealmC", keys))
                assert.are.equal("Bob-RealmB", C.Resolve("Bob-RealmB", keys))
                assert.is_nil(C.Resolve("Bob Brown", keys))
            end)

            it("does not match the surname of another character", function()
                assert.is_nil(C.Resolve("Eve Smith", keys))
            end)

            it("does not match an unknown name or an empty text", function()
                assert.is_nil(C.Resolve("Stranger", keys))
                assert.is_nil(C.Resolve("", keys))
                assert.is_nil(C.Resolve(nil, keys))
                assert.is_nil(C.Resolve("Bob", nil))
            end)

            it("matches a key with no realm by name", function()
                assert.are.equal("Solo", C.Resolve("solo-Realm", { "Solo" }))
                assert.are.equal("Solo", C.Resolve("Solo", { "Solo" }))
            end)
        end)

        describe("MailName", function()
            it("gives the plain name of an own character, with no realm and no surname", function()
                C.SaveSurname("Bob-RealmA", "Smith")
                local keys = { "Bob-RealmA" }
                assert.are.equal("Bob", C.MailName("Bob Smith", keys))
                assert.are.equal("Bob", C.MailName("Bob-RealmA", keys))
                assert.are.equal("Bob", C.MailName("bob", keys))
            end)

            it("leaves a text that is not an own character as it is", function()
                assert.are.equal("Stranger Jones", C.MailName("Stranger Jones", { "Bob-RealmA" }))
            end)
        end)
    end)

    describe("on TBC", function()
        before_each(function()
            setup({ usesSurname = false })
        end)

        it("shows the key as it is", function()
            assert.are.equal("Bob-Realm", C.Display("Bob-Realm"))
        end)

        it("saves and reads no surname", function()
            assert.is_false(C.SaveSurname("Bob-Realm", "Smith"))
            assert.is_nil(C.Surname("Bob-Realm"))
            assert.is_nil(next(store))
        end)

        it("matches Name and Name-Realm but not Name Surname", function()
            store["Bob-Realm/surname"] = "Smith"
            assert.are.equal("Bob-Realm", C.Resolve("bob", { "Bob-Realm" }))
            assert.are.equal("Bob-Realm", C.Resolve("BOB-REALM", { "Bob-Realm" }))
            assert.is_nil(C.Resolve("Bob Smith", { "Bob-Realm" }))
            assert.is_nil(C.Resolve("Bob-Other", { "Bob-Realm" }))
        end)

        it("leaves the recipient of a mail as it is", function()
            assert.are.equal("bob", C.MailName("bob", { "Bob-Realm" }))
            assert.are.equal("Bob-Realm", C.MailName("Bob-Realm", { "Bob-Realm" }))
        end)
    end)

    it("shows the key when the flavour table is missing", function()
        setup(nil)
        assert.are.equal("Bob-Realm", C.Display("Bob-Realm"))
    end)

    it("gives the plain name of a key", function()
        setup({ usesSurname = true })
        assert.are.equal("Bob", C.Plain("Bob-Realm"))
        assert.are.equal("Bob", C.Plain("Bob"))
    end)
end)
