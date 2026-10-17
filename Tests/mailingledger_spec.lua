local manifest = require("Tests.manifest")

describe("MailingLedger", function()
    local ns, ledger, buffer, tracker, form, now, bus, calls

    local function load(name)
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end

    -- A fake tracker with the real claim rules is in ledgermoney_spec; this one records the calls.
    local function newTracker()
        return {
            ClaimGroup = function(_, parts, direction, seconds)
                local group = { parts = parts, direction = direction, seconds = seconds }
                calls[#calls + 1] = group
                return group
            end,
            ReleaseClaims = function(_, group)
                group.released = true
            end,
        }
    end

    before_each(function()
        ns = {}
        load("EventBus")
        load("SettingsDB")
        load("LedgerRecord")
        load("LedgerBuffer")
        load("MailingLedger")
        calls, now = {}, 100
        form = { items = {}, money = 0, price = 0 }
        local db = ns.SettingsDB.New({}, { character = "Me-Realm", schemaVersion = 1,
            defaults = { account = ns.LedgerRecord.Defaults() } })
        buffer = ns.LedgerBuffer.New(db, {})
        bus = ns.EventBus.New({})
        tracker = newTracker()
        ledger = ns.MailingLedger.New({
            buffer = buffer,
            tracker = tracker,
            bus = bus,
            character = function()
                return "Me-Realm"
            end,
            serverTime = function()
                return 1234
            end,
            now = function()
                return now
            end,
            itemKey = function(itemID)
                return tostring(itemID)
            end,
            api = {
                item = function(index)
                    local item = form.items[index]
                    if item == "error" then
                        error("boom")
                    end
                    if item then
                        return item.name, item.itemID, "texture", item.count
                    end
                end,
                money = function()
                    return form.money
                end,
                price = function()
                    return form.price
                end,
            },
        })
    end)

    it("claims the postage and the gold before the money leaves, as a group with a total", function()
        form.price, form.money = 30, 500
        form.items = { { name = "Linen Cloth", itemID = 2589, count = 20 } }
        assert.is_true(ledger.OnSendMail("Bank"))
        assert.are.same({ 30, 500 }, calls[1].parts)
        assert.are.equal("out", calls[1].direction)
        assert.are.equal(ns.MailingLedger.CLAIM_SECONDS, calls[1].seconds)
    end)

    it("writes the postage, the sent gold and one row for each attachment after MAIL_SEND_SUCCESS", function()
        form.price, form.money = 60, 500
        form.items = {
            { name = "Linen Cloth", itemID = 2589, count = 20 }, nil, { name = "Wool", itemID = 2592, count = 5 },
        }
        ledger.OnSendMail("Bank")
        assert.are.equal(0, #buffer:Peek())
        bus:Emit("MAIL_SEND_SUCCESS")
        local records = buffer:Peek()
        assert.are.equal(4, #records)
        for _, record in ipairs(records) do
            assert.are.equal("expense", record.type)
            assert.are.equal("Bank", record.counterparty)
            assert.are.equal("Me-Realm", record.char)
            assert.is_true(ns.LedgerRecord.Validate(record))
        end
        assert.are.equal("mailPostage", records[1].source)
        assert.are.equal(60, records[1].money)
        assert.are.equal("mailMoneySent", records[2].source)
        assert.are.equal(500, records[2].money)
        assert.are.equal("mailSent", records[3].source)
        assert.are.equal("2589", records[3].item)
        assert.are.equal(20, records[3].qty)
        assert.are.equal(0, records[3].money)
    end)

    it("writes the attachments of a mail that has no postage and no gold", function()
        form.items = { { name = "Linen Cloth", itemID = 2589, count = 3 } }
        ledger.OnSendMail("Bank")
        assert.are.equal(1, ledger.Sent())
        assert.are.equal("mailSent", buffer:Peek()[1].source)
    end)

    it("writes two mails that follow one another in order, one record set for each", function()
        form.price = 30
        form.items = { { name = "A", itemID = 1, count = 1 } }
        ledger.OnSendMail("One")
        form.items = { { name = "B", itemID = 2, count = 2 } }
        ledger.OnSendMail("Two")
        bus:Emit("MAIL_SEND_SUCCESS")
        bus:Emit("MAIL_SEND_SUCCESS")
        local records = buffer:Peek()
        assert.are.equal(4, #records)
        assert.are.equal("One", records[2].counterparty)
        assert.are.equal("Two", records[4].counterparty)
        assert.are.equal("2", records[4].item)
    end)

    it("writes nothing and releases the claims after MAIL_FAILED", function()
        form.price = 30
        form.items = { { name = "A", itemID = 1, count = 1 } }
        ledger.OnSendMail("Bank")
        bus:Emit("MAIL_FAILED")
        bus:Emit("MAIL_SEND_SUCCESS")
        assert.are.equal(0, #buffer:Peek())
        assert.is_true(calls[1].released)
    end)

    it("drops a send that gets no result in time and releases its claims", function()
        form.price = 30
        form.items = { { name = "A", itemID = 1, count = 1 } }
        ledger.OnSendMail("Bank")
        now = now + ns.MailingLedger.PENDING_SECONDS + 1
        bus:Emit("MAIL_SEND_SUCCESS")
        assert.are.equal(0, #buffer:Peek())
        assert.is_true(calls[1].released)
    end)

    it("does nothing for an empty form and for an empty recipient name", function()
        assert.is_false(ledger.OnSendMail("Bank"))
        form.price = 30
        assert.is_true(ledger.OnSendMail(nil))
        ledger.Sent()
        assert.is_nil(buffer:Peek()[1].counterparty)
    end)

    it("does not fail when an API errors or gives nil", function()
        form.items = { "error", { name = "A", itemID = 1, count = nil } }
        form.price = nil
        form.money = "x"
        assert.is_true(ledger.OnSendMail("Bank"))
        ledger.Sent()
        local record = buffer:Peek()[1]
        assert.are.equal("mailSent", record.source)
        assert.are.equal(1, record.qty)
    end)

    it("works without a tracker", function()
        local plain = ns.MailingLedger.New({
            buffer = buffer, character = function() return "Me-Realm" end, serverTime = function() return 1 end,
            now = function() return 1 end, itemKey = tostring,
            api = { item = function() end, money = function() return 0 end, price = function() return 30 end },
        })
        assert.is_true(plain.OnSendMail("Bank"))
        assert.are.equal(1, plain.Sent())
    end)
end)
