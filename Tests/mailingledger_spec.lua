local manifest = require("Tests.manifest")

describe("MailingLedger", function()
    local ns, ledger, claims, buffer

    local function load(name)
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end

    before_each(function()
        ns = {}
        load("SettingsDB")
        load("LedgerRecord")
        load("LedgerBuffer")
        load("MailingLedger")
        claims = {}
        local db = ns.SettingsDB.New({}, { character = "Me-Realm", schemaVersion = 1,
            defaults = { account = ns.LedgerRecord.Defaults() } })
        buffer = ns.LedgerBuffer.New(db, {})
        ledger = ns.MailingLedger.New({
            buffer = buffer,
            tracker = { Claim = function(_, amount, direction)
                claims[#claims + 1] = { amount, direction }
            end },
            character = function()
                return "Me-Realm"
            end,
            serverTime = function()
                return 1234
            end,
        })
    end)

    it("claims the postage before the send, so that the money tracker writes no second record", function()
        ledger.Sending({ recipient = "Bank", postage = 30 })
        assert.are.same({ { 30, "out" } }, claims)
    end)

    it("writes the postage of a sent mail as an expense with the recipient", function()
        assert.is_true(ledger.Sent({ recipient = "Bank", postage = 30 }))
        local record = buffer:Peek()[1]
        assert.are.equal("expense", record.type)
        assert.are.equal("mailPostage", record.source)
        assert.are.equal(30, record.money)
        assert.are.equal("Bank", record.counterparty)
        assert.are.equal("Me-Realm", record.char)
        assert.are.equal(1234, record.time)
        assert.is_true(ns.LedgerRecord.Validate(record))
    end)

    it("writes nothing for a mail with no postage", function()
        assert.is_false(ledger.Sent({ recipient = "Bank", postage = 0 }))
        assert.are.equal(0, #buffer:Peek())
    end)
end)
