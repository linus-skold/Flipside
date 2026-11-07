local manifest = require("Tests.manifest")

describe("MailContacts", function()
    local ns, Contacts, Compose

    before_each(function()
        ns = {}
        assert(loadfile(manifest.path("MailCompose")))("Flipside", ns)
        assert(loadfile(manifest.path("MailContacts")))("Flipside", ns)
        Contacts, Compose = ns.MailContacts, ns.MailCompose
    end)

    local function titles(groups)
        local list = {}
        for _, group in ipairs(groups) do
            list[#list + 1] = group.title
        end
        return list
    end

    describe("Merge", function()
        it("groups the sources in the fixed order and sorts each group without regard to case", function()
            local groups = Contacts.Merge({
                manual = { "zed", "Alpha" },
                guild = { "gamma", "Beta" },
                friends = { "frank", "Anna" },
                own = { "Wolf", "bear" },
            })
            assert.are.same({ "Own characters", "Friends", "Guild", "Contacts" }, titles(groups))
            assert.are.same({ "bear", "Wolf" }, groups[1].names)
            assert.are.same({ "Anna", "frank" }, groups[2].names)
            assert.are.same({ "Beta", "gamma" }, groups[3].names)
            assert.are.same({ "Alpha", "zed" }, groups[4].names)
            assert.are.same({ "own", "friends", "guild", "manual" }, {
                groups[1].key, groups[2].key, groups[3].key, groups[4].key })
        end)

        it("leaves out a group with no name", function()
            local groups = Contacts.Merge({ friends = { "Anna" }, guild = {} })
            assert.are.same({ "Friends" }, titles(groups))
            assert.are.same({}, Contacts.Merge(nil))
        end)

        it("keeps a name that two sources hold in the first group only, case does not matter", function()
            local groups = Contacts.Merge({
                own = { "Anna" },
                friends = { "anna", "Bob" },
                guild = { "BOB", "Cleo", "cleo" },
                manual = { "CLEO", "Dave" },
            })
            assert.are.same({ "Anna" }, groups[1].names)
            assert.are.same({ "Bob" }, groups[2].names)
            assert.are.same({ "Cleo" }, groups[3].names)
            assert.are.same({ "Dave" }, groups[4].names)
        end)

        it("leaves out the current character, whatever its case", function()
            local groups = Contacts.Merge({
                own = { "Anna", "Me" },
                friends = { "ME", "Bob" },
                guild = { "me-Realm", "Cleo" },
            }, { "me", "Me-Realm" })
            assert.are.same({ "Anna" }, groups[1].names)
            assert.are.same({ "Bob" }, groups[2].names)
            assert.are.same({ "Cleo" }, groups[3].names)
        end)

        it("drops empty and bad entries and trims the names", function()
            local groups = Contacts.Merge({ friends = { "  Anna ", "", "   ", 5, false } })
            assert.are.same({ "Anna" }, groups[1].names)
        end)
    end)

    describe("Flat and the autocomplete", function()
        local groups = function()
            return Contacts.Merge({
                own = { "Boris" },
                friends = { "Bella" },
                guild = { "Bruno", "Cara" },
                manual = { "Bianca", "Dora" },
            })
        end

        it("lists the names of all groups in the order of the groups", function()
            assert.are.same({ "Boris", "Bella", "Bruno", "Cara", "Bianca", "Dora" }, Contacts.Flat(groups()))
            assert.are.same({}, Contacts.Flat(nil))
        end)

        it("lets MailCompose.Complete find a name of each source", function()
            local names = Contacts.Flat(groups())
            assert.are.equal("Boris", Compose.Complete("Bor", names))
            assert.are.equal("Bella", Compose.Complete("bel", names))
            assert.are.equal("Cara", Compose.Complete("Ca", names))
            assert.are.equal("Dora", Compose.Complete("D", names))
            assert.are.equal("Bianca", Compose.Complete("Bi", names))
            assert.is_nil(Compose.Complete("Zed", names))
        end)
    end)

    describe("MenuItems", function()
        it("starts with the placeholder and puts a header before each group", function()
            local items = Contacts.MenuItems(Contacts.Merge({ friends = { "Anna" }, manual = { "Zed" } }), "Contacts")
            assert.are.same({
                { value = "", text = "Contacts" },
                { value = "", text = "Friends", header = true },
                { value = "Anna", text = "Anna" },
                { value = "", text = "Contacts", header = true },
                { value = "Zed", text = "Zed" },
            }, items)
        end)

        it("gives only the placeholder with no group", function()
            assert.are.same({ { value = "", text = "Contacts" } }, Contacts.MenuItems({}, "Contacts"))
        end)
    end)

    describe("the manual list", function()
        it("adds a name and does not change the old list", function()
            local old = { "Anna" }
            local list, added = Contacts.Add(old, "  Bob ")
            assert.is_true(added)
            assert.are.same({ "Anna", "Bob" }, list)
            assert.are.same({ "Anna" }, old)
        end)

        it("refuses an empty name", function()
            for _, text in ipairs({ "", "   ", "\t" }) do
                local list, added, reason = Contacts.Add({ "Anna" }, text)
                assert.is_false(added)
                assert.are.same({ "Anna" }, list)
                assert.are.equal("Enter a name first", reason)
            end
            local _, added = Contacts.Add({}, nil)
            assert.is_false(added)
        end)

        it("refuses a name that is in the list, case does not matter", function()
            local list, added, reason = Contacts.Add({ "Anna" }, "ANNA")
            assert.is_false(added)
            assert.are.same({ "Anna" }, list)
            assert.are.equal("ANNA is already a contact", reason)
        end)

        it("removes a name, case does not matter, and does not change the old list", function()
            local old = { "Anna", "Bob" }
            local list, removed = Contacts.Remove(old, "bob")
            assert.is_true(removed)
            assert.are.same({ "Anna" }, list)
            assert.are.same({ "Anna", "Bob" }, old)
        end)

        it("reports a name that is not in the list or is empty", function()
            local list, removed = Contacts.Remove({ "Anna" }, "Zed")
            assert.is_false(removed)
            assert.are.same({ "Anna" }, list)
            assert.is_false((select(2, Contacts.Remove({ "Anna" }, ""))))
            assert.is_false((select(2, Contacts.Remove(nil, "Anna"))))
        end)

        it("tells if a name is in the list", function()
            assert.is_true(Contacts.Has({ "Anna" }, " anna "))
            assert.is_false(Contacts.Has({ "Anna" }, "Bob"))
            assert.is_false(Contacts.Has({ "Anna" }, ""))
            assert.is_false(Contacts.Has(nil, "Anna"))
        end)

        it("cleans a stored list", function()
            assert.are.same({ "Anna", "Bob" }, Contacts.Clean({ "Anna", "anna", " Bob ", "", 3 }))
            assert.are.same({}, Contacts.Clean("x"))
        end)
    end)

    describe("the account setting", function()
        local function fakeDb(canWrite)
            local values = {}
            return {
                values = values,
                Get = function(_, scope, key)
                    return values[scope .. "/" .. key]
                end,
                Set = function(_, scope, key, value)
                    if canWrite == false then
                        return false
                    end
                    values[scope .. "/" .. key] = value
                    return true
                end,
            }
        end

        it("reads an empty list when nothing is saved or there is no DB", function()
            assert.are.same({}, Contacts.Load(fakeDb()))
            assert.are.same({}, Contacts.Load(nil))
        end)

        it("saves the list in the account scope under mail.contacts", function()
            local db = fakeDb()
            assert.is_true(Contacts.Save(db, { "Anna", "anna", "Bob" }))
            assert.are.same({ "Anna", "Bob" }, db.values["account/mail.contacts"])
            assert.are.same({ "Anna", "Bob" }, Contacts.Load(db))
        end)

        it("returns false if the DB cannot write or is missing", function()
            assert.is_false(Contacts.Save(fakeDb(false), { "Anna" }))
            assert.is_false(Contacts.Save(nil, { "Anna" }))
        end)
    end)

    describe("the client reads", function()
        local saved = {}

        local function set(name, value)
            if saved[name] == nil then
                saved[name] = { old = rawget(_G, name) }
            end
            rawset(_G, name, value)
        end

        after_each(function()
            for name, entry in pairs(saved) do
                rawset(_G, name, entry.old)
            end
            saved = {}
        end)

        it("reads the friends, online and offline", function()
            local infos = { { name = "Anna", connected = true }, { name = "Bob", connected = false } }
            set("C_FriendList", {
                GetNumFriends = function()
                    return #infos
                end,
                GetFriendInfoByIndex = function(index)
                    return infos[index]
                end,
            })
            assert.are.same({ "Anna", "Bob" }, Contacts.Friends())
        end)

        it("gives an empty list when the friend API is missing or fails", function()
            set("C_FriendList", nil)
            assert.are.same({}, Contacts.Friends())
            set("C_FriendList", {
                GetNumFriends = function()
                    error("not ready")
                end,
                GetFriendInfoByIndex = function() end,
            })
            assert.are.same({}, Contacts.Friends())
        end)

        it("reads the guild members from the guild club", function()
            local members = { { name = "Cara" }, { name = "Dora" }, {} }
            set("C_Club", {
                GetGuildClubId = function()
                    return 7
                end,
                GetClubMembers = function(clubId)
                    assert.are.equal(7, clubId)
                    return { 1, 2, 3, 4 }
                end,
                GetMemberInfo = function(clubId, memberId)
                    assert.are.equal(7, clubId)
                    return members[memberId]
                end,
            })
            assert.are.same({ "Cara", "Dora" }, Contacts.GuildMembers())
        end)

        it("gives no guild member without a guild or without the API", function()
            set("C_Club", {
                GetGuildClubId = function()
                    return nil
                end,
                GetClubMembers = function()
                    error("must not run")
                end,
                GetMemberInfo = function() end,
            })
            assert.are.same({}, Contacts.GuildMembers())
            set("C_Club", nil)
            assert.are.same({}, Contacts.GuildMembers())
        end)

        it("asks for new friend and guild data at most once in the wait time", function()
            local calls = { friends = 0, guild = 0 }
            set("C_FriendList", {
                ShowFriends = function()
                    calls.friends = calls.friends + 1
                end,
            })
            set("C_GuildInfo", {
                GuildRoster = function()
                    calls.guild = calls.guild + 1
                end,
            })
            assert.is_true(Contacts.Request(100))
            assert.is_false(Contacts.Request(100 + Contacts.REQUEST_WAIT - 1))
            assert.is_true(Contacts.Request(100 + Contacts.REQUEST_WAIT))
            assert.are.same({ friends = 2, guild = 2 }, calls)
        end)
    end)
end)
