local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

-- The character key at login (SPEC 5.5, "Character names on Forever"): a GUID on Forever, Name-Realm on TBC.
local ns
local SMITH, JONES = "Player-1-000000A1", "Player-1-000000B2"
local LEGACY = "Tester-TestRealm"

local function loadAddon(toc)
    local space = {}
    for _, path in ipairs(manifest.files(toc)) do
        assert(loadfile(path))("Flipside", space)
    end
    return space
end

-- One session of the character Tester with the surname and the GUID of options. The saved tables stay.
local function session(options)
    local savedDB, savedLedger = _G.FlipsideDB, _G.FlipsideLedgerDB
    mock.reset()
    mock.playerName, mock.realmName = "Tester", "TestRealm"
    if options.noRealm then
        mock.realmName = nil
    end
    mock.playerSurname, mock.playerGuid = options.surname, options.guid
    mock.money = options.money or 0
    _G.issecretvalue = options.isSecret
    ns = loadAddon("Flipside.toc")
    _G.FlipsideDB, _G.FlipsideLedgerDB = savedDB, savedLedger
    mock.fire("ADDON_LOADED", "Flipside")
    mock.fire("PLAYER_LOGIN")
    mock.advance(0.5)
end

-- A vendor sale in the session: it puts one record in the ledger buffer.
local function sell(copper)
    mock.fire("MERCHANT_SHOW")
    mock.money = mock.money + copper
    mock.fire("PLAYER_MONEY")
    mock.advance(1)
end

describe("Init character key", function()
    after_each(function()
        _G.FlipsideDB_TBC = nil
        mock.teardown()
    end)

    describe("on Forever", function()
        it("uses the GUID as the key and saves the name and the realm of it", function()
            session({ surname = "Smith", guid = SMITH })
            assert.are.equal("Smith", ns.db:GetFor(SMITH, "surname"))
            assert.is_nil(ns.db:GetFor(LEGACY, "surname"))
            assert.are.equal("Tester", ns.CharacterKey.Name(SMITH))
            assert.are.equal("TestRealm", ns.CharacterKey.Realm(SMITH))
            assert.are.equal("Tester Smith", ns.CharacterName.Display(SMITH))
            assert.are.equal("Default", _G.FlipsideDB["a/profiles.map"][SMITH])
            assert.is_nil(_G.FlipsideDB["a/profiles.map"][LEGACY])
        end)

        it("keeps two characters with the same first name and realm apart", function()
            session({ surname = "Smith", guid = SMITH, money = 0 })
            sell(150)
            session({ surname = "Jones", guid = JONES, money = 0 })
            sell(250)
            local db = ns.db
            assert.are.equal("Smith", db:GetFor(SMITH, "surname"))
            assert.are.equal("Jones", db:GetFor(JONES, "surname"))
            assert.are.equal(150, ns.LedgerBalance.ReadSnapshot(db, SMITH).copper)
            assert.are.equal(250, ns.LedgerBalance.ReadSnapshot(db, JONES).copper)
            assert.are.equal("Tester Smith", ns.CharacterName.Display(SMITH))
            assert.are.equal("Tester Jones", ns.CharacterName.Display(JONES))
            local chars = ns.holdings:Characters()
            assert.are.same({ SMITH, JONES }, { chars[1], chars[2] })
            assert.are.equal(2, #chars)
            local buffer = ns.ledgerBuffer:Peek()
            assert.are.equal(2, #buffer)
            assert.are.equal(SMITH, buffer[1].char)
            assert.are.equal(JONES, buffer[2].char)
        end)

        describe("legacy Name-Realm data", function()
            local function legacy()
                return {
                    _schema = 2,
                    ["c/" .. LEGACY .. "/example"] = 7,
                    ["a/ledger.buffer"] = { { time = 1, char = LEGACY, type = "income", source = "quest", money = 1 } },
                }
            end

            it("moves to the GUID of the first character that logs in", function()
                _G.FlipsideDB = legacy()
                session({ surname = "Smith", guid = SMITH })
                assert.are.equal(7, ns.db:GetFor(SMITH, "example"))
                assert.is_nil(ns.db:GetFor(LEGACY, "example"))
                assert.are.equal(SMITH, ns.ledgerBuffer:Peek()[1].char)
                assert.are.equal(SMITH, ns.CharacterKey.Claims()[LEGACY])
                for _, name in ipairs(ns.db:ListCharacters()) do
                    assert.are_not.equal(LEGACY, name)
                end
            end)

            it("uses the saved realm for the claim and the move if the client gives no realm", function()
                session({ surname = "Smith", guid = SMITH })
                _G.FlipsideDB["c/" .. LEGACY .. "/example"] = 7
                session({ surname = "Smith", guid = SMITH, noRealm = true })
                assert.are.equal("TestRealm", ns.CharacterKey.Realm(SMITH))
                assert.are.equal(7, ns.db:GetFor(SMITH, "example"))
                assert.is_nil(ns.db:GetFor(LEGACY, "example"))
            end)

            it("claims and moves nothing if no realm is known", function()
                _G.FlipsideDB = legacy()
                session({ surname = "Smith", guid = SMITH, noRealm = true })
                assert.is_table(ns.db)
                assert.is_nil(ns.CharacterKey.Realm(SMITH))
                assert.are.same({}, ns.CharacterKey.Claims())
                assert.is_nil(ns.db:GetFor(SMITH, "example"))
                assert.are.equal(7, ns.db:GetFor(LEGACY, "example"))
            end)

            it("moves once: a second login of the same character changes nothing", function()
                _G.FlipsideDB = legacy()
                session({ surname = "Smith", guid = SMITH })
                session({ surname = "Smith", guid = SMITH })
                assert.are.equal(7, ns.db:GetFor(SMITH, "example"))
                assert.is_nil(ns.db:GetFor(LEGACY, "example"))
                assert.are.equal(1, #ns.ledgerBuffer:Peek())
            end)

            it("stays with the first character if a second one with the same first name logs in", function()
                _G.FlipsideDB = legacy()
                session({ surname = "Smith", guid = SMITH })
                -- Data that a session with no GUID wrote under the legacy key stays there for the first character.
                _G.FlipsideDB["c/" .. LEGACY .. "/late"] = 1
                session({ surname = "Jones", guid = JONES })
                assert.is_nil(ns.db:GetFor(JONES, "example"))
                assert.is_nil(ns.db:GetFor(JONES, "late"))
                assert.are.equal(1, ns.db:GetFor(LEGACY, "late"))
                assert.are.equal(SMITH, ns.CharacterKey.Claims()[LEGACY])
                session({ surname = "Smith", guid = SMITH })
                assert.are.equal(1, ns.db:GetFor(SMITH, "late"))
                assert.is_nil(ns.db:GetFor(LEGACY, "late"))
                assert.are.equal(7, ns.db:GetFor(SMITH, "example"))
            end)

            it("keeps the settings of the GUID key if both keys have a setting", function()
                _G.FlipsideDB = legacy()
                _G.FlipsideDB["c/" .. SMITH .. "/example"] = 9
                session({ surname = "Smith", guid = SMITH })
                assert.are.equal(9, ns.db:GetFor(SMITH, "example"))
                assert.is_nil(ns.db:GetFor(LEGACY, "example"))
            end)
        end)

        describe("with no usable GUID", function()
            local function check()
                assert.are.equal(7, ns.db:GetFor(LEGACY, "example"))
                assert.are.equal("Default", _G.FlipsideDB["a/profiles.map"][LEGACY])
                assert.are.same({}, ns.CharacterKey.Claims())
                assert.is_nil(_G.FlipsideDB["a/characters.meta"])
                local chars = ns.holdings:Characters()
                assert.are.same({ LEGACY }, chars)
            end

            it("uses Name-Realm and moves nothing if UnitGUID gives nil", function()
                _G.FlipsideDB = { _schema = 2, ["c/" .. LEGACY .. "/example"] = 7 }
                session({ surname = "Smith", guid = false })
                check()
            end)

            it("uses Name-Realm and moves nothing if UnitGUID gives a secret value", function()
                _G.FlipsideDB = { _schema = 2, ["c/" .. LEGACY .. "/example"] = 7 }
                session({
                    surname = "Smith", guid = SMITH,
                    isSecret = function(value)
                        return value == SMITH
                    end,
                })
                check()
            end)

            it("uses Name-Realm and moves nothing if UnitGUID gives a text that is not a GUID", function()
                _G.FlipsideDB = { _schema = 2, ["c/" .. LEGACY .. "/example"] = 7 }
                session({ surname = "Smith", guid = "not a guid" })
                check()
            end)
        end)
    end)

    describe("on TBC", function()
        it("keeps Name-Realm as the key and saves no metadata", function()
            mock.reset({ flavour = "tbc" })
            mock.playerName, mock.realmName = "Tester", "TestRealm"
            ns = loadAddon("Flipside_TBC.toc")
            _G.FlipsideDB_TBC = { _schema = 2, ["c/" .. LEGACY .. "/example"] = 7 }
            mock.fire("ADDON_LOADED", "Flipside")
            mock.fire("PLAYER_LOGIN")
            assert.are.equal(7, ns.db:GetFor(LEGACY, "example"))
            assert.are.equal("Default", _G.FlipsideDB_TBC["a/profiles.map"][LEGACY])
            assert.is_nil(_G.FlipsideDB_TBC["a/characters.meta"])
            assert.is_nil(_G.FlipsideDB_TBC["a/characters.claims"])
            assert.are.equal(LEGACY, ns.CharacterName.Display(LEGACY))
        end)
    end)
end)
