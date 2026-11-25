local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local ns

local function loadAddon()
    local space = {}
    for _, path in ipairs(manifest.files()) do
        assert(loadfile(path))("Flipside", space)
    end
    return space
end

local function login()
    mock.fire("ADDON_LOADED", "Flipside")
    mock.fire("PLAYER_LOGIN")
end

-- The character key of the mocked Forever character Tester is its GUID.
local function key()
    return mock.guidFor("Tester")
end

local function rec(n, char)
    return { time = n, char = char or key(), type = "income", source = "quest", money = n }
end

describe("Init ledger", function()
    before_each(function()
        mock.reset()
        mock.playerName = "Tester"
        mock.realmName = "TestRealm"
        ns = loadAddon()
    end)

    after_each(function()
        mock.teardown()
    end)

    it("creates the buffer and the loader at login with no message", function()
        login()
        assert.is_table(ns.ledgerBuffer)
        assert.is_table(ns.ledgerLoader)
        assert.are.equal(500, ns.ledgerBuffer:Cap())
        assert.are.equal(500, ns.db:Get("account", "ledger.bufferCap"))
        assert.are.equal(2000, ns.db:Get("account", "ledger.hardLimit"))
        assert.are.equal(180, ns.db:Get("account", "ledger.retentionDays"))
        assert.are.equal(60, ns.db:Get("account", "ledger.mobWindow"))
        assert.are.equal(30, ns.db:Get("account", "ledger.logDays"))
        for _, msg in ipairs(mock.messages) do
            assert.is_nil(msg:find("ledger", 1, true), msg)
        end
    end)

    it("loads the ledger addon at the cap and moves the buffer into the ledger DB", function()
        login()
        ns.db:Set("account", "ledger.bufferCap", 2)
        ns.ledgerBuffer:Add(rec(1))
        ns.ledgerBuffer:Add(rec(2))
        mock.advance(0)
        -- The cap flush is a Scheduler job: tick it to the end.
        local frames = 0
        while not ns.scheduler:IsIdle() and frames < 100 do
            ns.scheduler:Tick()
            frames = frames + 1
        end
        assert.are.same({ "Flipside_Ledger" }, mock.addOnLoads)
        assert.are.equal(0, ns.ledgerBuffer:Count())
        local region = next(_G.FlipsideLedgerDB.records)
        assert.are.equal(2, #_G.FlipsideLedgerDB.records[region].standard[key()])
        assert.is_nil(_G.FlipsideLedgerDB.records[region].standard["Tester-TestRealm"])
    end)

    describe("legacy Name-Realm data", function()
        local function legacySums()
            return { { day = 10, source = "quest", item = "", count = 1, qty = 0, moneyIn = 5, moneyOut = 0 } }
        end

        it("moves the legacy ledger store entries to the GUID that claimed the name, when the store opens", function()
            _G.FlipsideLedgerDB = {
                _schema = 1,
                records = { EU = { standard = { ["Tester-TestRealm"] = { rec(1, "Tester-TestRealm") } } } },
                sums = { EU = { standard = { ["Tester-TestRealm"] = legacySums() } } },
            }
            login()
            assert.are.equal(0, #mock.addOnLoads)
            assert.is_true(ns.ledgerLoader:Ensure())
            local standard = _G.FlipsideLedgerDB.records.EU.standard
            assert.is_nil(standard["Tester-TestRealm"])
            assert.are.equal(1, #standard[key()])
            assert.are.equal(key(), standard[key()][1].char)
            assert.are.equal(1, #_G.FlipsideLedgerDB.sums.EU.standard[key()])
            assert.is_nil(_G.FlipsideLedgerDB.sums.EU.standard["Tester-TestRealm"])
        end)

        it("gives the ledger entries to the first character that logged in, not to a later one", function()
            _G.FlipsideLedgerDB = {
                _schema = 1,
                records = { EU = { standard = { ["Tester-TestRealm"] = { rec(1, "Tester-TestRealm") } } } },
            }
            local smith, jones = "Player-1-000000A1", "Player-1-000000B2"
            mock.playerSurname, mock.playerGuid = "Smith", smith
            login()
            -- The store did not open in this session. A second character with the same first name logs in next.
            local savedDB, savedLedger = _G.FlipsideDB, _G.FlipsideLedgerDB
            mock.reset()
            mock.playerName, mock.playerSurname, mock.playerGuid = "Tester", "Jones", jones
            mock.realmName = "TestRealm"
            ns = loadAddon()
            _G.FlipsideDB, _G.FlipsideLedgerDB = savedDB, savedLedger
            login()
            assert.is_true(ns.ledgerLoader:Ensure())
            local standard = _G.FlipsideLedgerDB.records.EU.standard
            assert.are.equal(1, #standard[smith])
            assert.is_nil(standard[jones])
            assert.is_nil(standard["Tester-TestRealm"])
        end)

        it("rewrites the buffered records and moves the settings of the claimant", function()
            _G.FlipsideDB = {
                _schema = 2,
                ["a/ledger.buffer"] = { rec(1, "Tester-TestRealm"), rec(2, "Other-TestRealm") },
                ["c/Tester-TestRealm/ledger.balance"] = { copper = 700, time = 5 },
                ["c/Tester-TestRealm/example"] = 7,
                ["c/Tester-TestRealm/ledger.view.char"] = "Tester-TestRealm",
            }
            login()
            local buffer = ns.ledgerBuffer:Peek()
            assert.are.equal(key(), buffer[1].char)
            assert.are.equal("Other-TestRealm", buffer[2].char)
            assert.are.equal(7, ns.db:GetFor(key(), "example"))
            assert.are.equal(key(), ns.db:GetFor(key(), "ledger.view.char"))
            assert.is_nil(ns.db:GetFor("Tester-TestRealm", "ledger.balance"))
            assert.is_nil(ns.db:GetFor("Tester-TestRealm", "example"))
        end)
    end)

    it("loads the ledger addon at login when the buffer is not empty", function()
        _G.FlipsideDB = { _schema = 1, ["a/ledger.buffer"] = { rec(1) } }
        login()
        assert.are.equal(0, #mock.addOnLoads)
        mock.fire("PLAYER_ENTERING_WORLD")
        assert.are.same({ "Flipside_Ledger" }, mock.addOnLoads)
        assert.are.equal(0, ns.ledgerBuffer:Count())
    end)

    it("shows one chat line when the ledger addon does not load", function()
        mock.addOnLoadResult = { false, "MISSING" }
        login()
        mock.messages = {}
        ns.ledgerBuffer:Add(rec(1))
        assert.is_false((ns.ledgerLoader:Ensure()))
        assert.are.equal(1, #mock.messages)
        assert.is_truthy(mock.messages[1]:find("did not load: MISSING", 1, true))
        assert.are.equal(1, ns.ledgerBuffer:Count())
    end)

    it("creates the money tracker at login and prints the debug ring with the slash command", function()
        login()
        assert.is_table(ns.ledgerMoney)
        ns.db:Set("account", "ledger.debug", true)
        mock.fire("MERCHANT_SHOW")
        mock.money = 150
        mock.fire("PLAYER_MONEY")
        -- A vendor sale waits one second for its buyback entry.
        mock.advance(1)
        mock.messages = {}
        ns.HandleSlash("ledgerdebug")
        local text = table.concat(mock.messages, "\n")
        assert.is_truthy(text:find("1 records", 1, true))
        assert.is_truthy(text:find("MERCHANT_SHOW", 1, true))
        assert.is_truthy(text:find("record vendorSale income 150", 1, true))
        assert.are.equal(1, ns.ledgerBuffer:Count())
    end)

    it("registers no restricted event for the money tracker", function()
        login()
        for _, frame in ipairs(mock.frames or {}) do
            assert.is_nil(frame.events and frame.events.COMBAT_LOG_EVENT_UNFILTERED)
        end
    end)

    it("records a mail sale through the real wiring without GetInboxText or a hook", function()
        mock.money = 1000
        login()
        assert.is_table(ns.ledgerMail)
        mock.mail[1] = {
            attachments = {},
            header = { sender = "AH", subject = "Auction successful: Linen", money = 9050, itemCount = 0 },
            invoice = { type = "seller", itemName = "Linen", player = "Rich", bid = 9500, buyout = 9500,
                deposit = 100, consignment = 550, count = 5 },
        }
        mock.fire("MAIL_SHOW")
        mock.advance(0.5)
        mock.mail[1].header.money = 0
        mock.money = 10050
        mock.fire("PLAYER_MONEY")
        mock.advance(3)
        assert.are.equal(1, ns.ledgerBuffer:Count())
        local record = ns.ledgerBuffer:Peek()[1]
        assert.are.equal("ahSale", record.source)
        assert.are.equal(9050, record.money)
        assert.are.equal(0, mock.inboxTextCalls)
        assert.are.equal(0, #mock.hookCalls)
        assert.is_true(mock.isRegistered("MAIL_INBOX_UPDATE"))
        ns.db:Set("account", "ledger.debug", true)
        mock.messages = {}
        ns.HandleSlash("ledgerdebug")
        assert.is_truthy(table.concat(mock.messages, "\n"):find("ledger mail: 1 sales", 1, true))
    end)

    it("saves the gold balance at PLAYER_ENTERING_WORLD and on PLAYER_MONEY, not at login or logout", function()
        local function saved()
            return ns.LedgerBalance.ReadSnapshot(ns.db, key())
        end
        mock.money = 4200
        login()
        assert.is_nil(saved())
        mock.fire("PLAYER_MONEY")
        assert.is_nil(saved())
        mock.fire("PLAYER_ENTERING_WORLD")
        assert.are.equal(4200, saved().copper)
        assert.are.equal(mock.serverBase, saved().time)
        mock.money = 5000
        mock.fire("PLAYER_ENTERING_WORLD")
        assert.are.equal(5000, saved().copper)
        mock.money = 9900
        mock.fire("PLAYER_MONEY")
        assert.are.equal(9900, saved().copper)
        -- GetMoney() gives 0 at logout on TBC Anniversary: no write there.
        mock.money = 0
        mock.fire("PLAYER_LOGOUT")
        assert.are.equal(9900, saved().copper)
    end)

    describe("gold reconcile", function()
        -- The loader can flush the buffer at PLAYER_ENTERING_WORLD, so the spec records each Add call.
        local added
        local function reconciles()
            local list = {}
            for _, record in ipairs(added) do
                if record.source == "reconcile" then
                    list[#list + 1] = record
                end
            end
            return list
        end

        local function start(savedCopper, money)
            mock.money = money
            login()
            added = {}
            local buffer = ns.ledgerBuffer
            local add = buffer.Add
            buffer.Add = function(self, fields)
                added[#added + 1] = fields
                return add(self, fields)
            end
            if savedCopper then
                ns.LedgerBalance.WriteSnapshot(ns.db, savedCopper, 1)
            end
            mock.fire("PLAYER_ENTERING_WORLD")
        end

        it("writes no record on the first login", function()
            start(nil, 4200)
            assert.are.equal(0, #reconciles())
        end)

        it("writes no record when the gold did not change", function()
            start(4200, 4200)
            assert.are.equal(0, #reconciles())
        end)

        it("writes one record for a gain and none at a later PLAYER_ENTERING_WORLD", function()
            start(4000, 4200)
            local list = reconciles()
            assert.are.equal(1, #list)
            assert.are.equal("income", list[1].type)
            assert.are.equal(200, list[1].money)
            assert.are.equal(key(), list[1].char)
            mock.fire("PLAYER_ENTERING_WORLD")
            assert.are.equal(1, #reconciles())
        end)

        it("writes one record for a loss", function()
            start(5000, 4200)
            local list = reconciles()
            assert.are.equal(1, #list)
            assert.are.equal("expense", list[1].type)
            assert.are.equal(800, list[1].money)
        end)

        it("writes no record when GetMoney() gives 0 and a balance was saved", function()
            start(5000, 0)
            assert.are.equal(0, #reconciles())
        end)
    end)
end)
