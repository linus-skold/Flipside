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
            it("gives the full name of an own character with a saved surname", function()
                C.SaveSurname("Bob-RealmA", "Smith")
                local keys = { "Bob-RealmA" }
                assert.are.equal("Bob Smith", C.MailName("Bob Smith", keys))
                assert.are.equal("Bob Smith", C.MailName("Bob-RealmA", keys))
                assert.are.equal("Bob Smith", C.MailName("bob", keys))
            end)

            it("uses the separator of the client in the full name", function()
                setup({ usesSurname = true }, function()
                    return "|"
                end)
                C.SaveSurname("Bob-RealmA", "Smith")
                assert.are.equal("Bob|Smith", C.MailName("bob", { "Bob-RealmA" }))
                assert.are.equal("Stranger|Jones", C.MailName("Stranger-Jones", { "Bob-RealmA" }))
            end)

            it("gives nil and a reason for an own character with no saved surname", function()
                local name, reason = C.MailName("Bob", { "Bob-RealmA" })
                assert.is_nil(name)
                assert.is_truthy(reason:find("log in to Bob once", 1, true))
            end)

            it("sets the separator in a two-part text that is not an own character", function()
                local keys = { "Bob-RealmA" }
                assert.are.equal("Stranger Jones", C.MailName("Stranger Jones", keys))
                assert.are.equal("Stranger Jones", C.MailName("Stranger-Jones", keys))
            end)

            it("leaves another text as it is", function()
                assert.are.equal("Stranger", C.MailName("Stranger", { "Bob-RealmA" }))
                assert.are.equal("A B C", C.MailName("A B C", { "Bob-RealmA" }))
            end)
        end)
    end)

    describe("with GUID keys (Forever)", function()
        local A, B = "Player-1-0000000A", "Player-1-0000000B"

        before_each(function()
            store = {}
            local account = {}
            ns = { Flavour = { usesSurname = true, characterGuidKey = true } }
            assert(loadfile(manifest.path("CharacterKey")))("Flipside", ns)
            assert(loadfile(manifest.path("CharacterName")))("Flipside", ns)
            local db = fakeDb()
            function db.Get(_, _, key)
                return account[key]
            end
            function db.Set(_, _, key, value)
                account[key] = value
                return true
            end
            function db.IsReadOnly()
                return false
            end
            ns.CharacterKey.Setup({ db = db })
            C = ns.CharacterName
            C.Setup({ db = db })
            ns.CharacterKey.SaveMeta(A, "Bob", "RealmA")
            ns.CharacterKey.SaveMeta(B, "Bob", "RealmA")
            C.SaveSurname(A, "Smith")
            C.SaveSurname(B, "Jones")
        end)

        it("shows Name Surname of each key and never a GUID", function()
            assert.are.equal("Bob Smith", C.Display(A))
            assert.are.equal("Bob Jones", C.Display(B))
            assert.are.equal("Bob", C.Plain(A))
            assert.are.equal("Unknown", C.Display("Player-1-000000FF"))
        end)

        it("shows the name alone for a key with no saved surname", function()
            ns.CharacterKey.SaveMeta("Player-1-0000000C", "Eve", "RealmA")
            assert.are.equal("Eve", C.Display("Player-1-0000000C"))
        end)

        it("matches Name Surname to the right character of the same first name", function()
            local keys = { A, B }
            assert.are.equal(A, C.Resolve("Bob Smith", keys))
            assert.are.equal(B, C.Resolve("bob JONES", keys))
            assert.is_nil(C.Resolve("Bob Brown", keys))
            assert.is_nil(C.Resolve("Bob-RealmZ", keys))
        end)

        it("gives no key and an ambiguous result for a name that two characters have", function()
            local keys = { A, B }
            for _, text in ipairs({ "Bob", "bob-realma", "Bob-RealmA" }) do
                local key, problem, name = C.Resolve(text, keys)
                assert.is_nil(key)
                assert.are.equal("ambiguous", problem)
                assert.are.equal("Bob", name)
            end
        end)

        it("gives the key for a name that only one character has", function()
            ns.CharacterKey.SaveMeta("Player-1-0000000C", "Eve", "RealmA")
            assert.are.equal("Player-1-0000000C", C.Resolve("Eve", { A, B, "Player-1-0000000C" }))
            assert.are.equal(A, C.Resolve("Bob", { A }))
        end)

        it("gives no mail name and a reason for an ambiguous name, and a full name for Name Surname", function()
            local name, reason = C.MailName("Bob", { A, B })
            assert.is_nil(name)
            assert.is_truthy(reason:find("more than one of your characters is named Bob; type Name Surname", 1, true))
            assert.is_nil((C.MailName("Bob-RealmA", { A, B })))
            assert.are.equal("Bob Smith", C.MailName("Bob Smith", { A, B }))
        end)

        it("gives the full name of an own character for the mail call", function()
            assert.are.equal("Bob Jones", C.MailName("Bob Jones", { A, B }))
            assert.are.equal("Bob Smith", C.MailName("Bob Smith", { B, A }))
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
