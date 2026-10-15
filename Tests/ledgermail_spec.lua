local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("EventBus")))("Flipside", ns)
assert(loadfile(manifest.path("LedgerRecord")))("Flipside", ns)
assert(loadfile(manifest.path("LedgerBalance")))("Flipside", ns)
assert(loadfile(manifest.path("LedgerMoney")))("Flipside", ns)
assert(loadfile(manifest.path("LedgerMail")))("Flipside", ns)

local bus, clock, money, records, timers, subscribed, secrets, tracker, mail, inbox, fps, calls

local function after(seconds, fn)
    timers[#timers + 1] = { at = clock + seconds, fn = fn }
end

local function advance(seconds)
    clock = clock + seconds
    local due, rest = {}, {}
    for _, timer in ipairs(timers) do
        table.insert(timer.at <= clock and due or rest, timer)
    end
    timers = rest
    for _, timer in ipairs(due) do
        timer.fn()
    end
end

local function change(delta)
    money = money + delta
    bus:Emit("PLAYER_MONEY")
end

local STRINGS = {
    AUCTION_SOLD_MAIL_SUBJECT = "Sold: %s",
    AUCTION_EXPIRED_MAIL_SUBJECT = "Expired: %s",
    AUCTION_REMOVED_MAIL_SUBJECT = "Cancelled: %s",
    AUCTION_OUTBID_MAIL_SUBJECT = "Outbid: %s",
    AUCTION_WON_MAIL_SUBJECT = "Won: %s",
}

local function saleMail(buyer, bid, deposit, cut, count)
    return {
        sender = "AH", subject = "Sold: Linen Cloth", money = bid + deposit - cut, itemCount = 0,
        invoice = { type = "seller", itemName = "Linen Cloth", player = buyer, bid = bid, buyout = bid,
            deposit = deposit, consignment = cut, count = count or 20 },
    }
end

local function attach(overrides)
    local deps = {
        bus = bus,
        buffer = {
            Add = function(_, record)
                local ok, message = ns.LedgerRecord.Validate(record)
                if not ok then
                    return false, message
                end
                records[#records + 1] = record
                return true
            end,
        },
        tracker = tracker,
        api = {
            numItems = function()
                return #inbox
            end,
            header = function(index)
                return inbox[index]
            end,
            invoice = function(index)
                calls.invoice = calls.invoice + 1
                return inbox[index].invoice
            end,
        },
        now = function()
            return clock
        end,
        serverTime = function()
            return 1700000000 + math.floor(clock)
        end,
        character = function()
            return "Tester-Realm"
        end,
        after = after,
        isSecret = function(value)
            return secrets[value] == true
        end,
        strings = function(name)
            return STRINGS[name]
        end,
        itemKey = function(link)
            return "k:" .. tostring(link)
        end,
        itemKeyByName = function(name)
            return name == "Linen Cloth" and "2589" or nil
        end,
        fingerprints = fps,
    }
    for name, value in pairs(overrides or {}) do
        deps[name] = value
    end
    return ns.LedgerMail.Attach(deps)
end

local function newTracker()
    return ns.LedgerMoney.Attach({
        bus = bus,
        buffer = {
            Add = function(_, record)
                records[#records + 1] = record
                return true
            end,
        },
        getMoney = function()
            return money
        end,
        now = function()
            return clock
        end,
        serverTime = function()
            return 1700000000 + math.floor(clock)
        end,
        character = function()
            return "Tester-Realm"
        end,
        after = after,
        setting = function()
            return false
        end,
        itemKey = function(input)
            return tostring(input)
        end,
    })
end

local function bySource(source)
    local list = {}
    for _, record in ipairs(records) do
        if record.source == source then
            list[#list + 1] = record
        end
    end
    return list
end

local function open()
    bus:Emit("MAIL_SHOW")
    advance(0.2)
end

describe("LedgerMail", function()
    before_each(function()
        subscribed = {}
        bus = ns.EventBus.New({
            onFirstSubscriber = function(event)
                subscribed[#subscribed + 1] = event
            end,
        })
        clock, money, records, timers, secrets, inbox, fps = 100, 100000, {}, {}, {}, {}, {}
        calls = { invoice = 0 }
        tracker = newTracker()
        mail = attach()
    end)

    describe("an invoice that needs the mail text", function()
        local textCalls

        -- The invoice shows only after text(index), as in the client. The subject matches no pattern.
        local function hiddenMail(invoice)
            textCalls = 0
            local entry = { sender = "AH", subject = "Mystery", money = 9050, itemCount = 0, hidden = invoice }
            inbox[1] = entry
            mail = attach({
                api = {
                    numItems = function()
                        return #inbox
                    end,
                    header = function(index)
                        return inbox[index]
                    end,
                    invoice = function(index)
                        return inbox[index].invoice
                    end,
                    text = function(index)
                        textCalls = textCalls + 1
                        inbox[index].invoice = inbox[index].hidden
                    end,
                },
            })
        end

        it("gives an ahSale record when the invoice is there after the text read", function()
            hiddenMail({ type = "seller", itemName = "Linen Cloth", player = "Rich", bid = 9500, buyout = 9500,
                deposit = 100, consignment = 550, count = 20 })
            open()
            assert.are.equal(1, textCalls)
            inbox[1].money = 0
            change(9050)
            advance(2)
            assert.are.equal(1, #records)
            assert.are.equal("ahSale", records[1].source)
            assert.are.equal(9050, records[1].money)
            assert.are.equal("Rich", records[1].counterparty)
            assert.are.equal(0, #bySource("mailMoney"))
        end)

        it("still gives mailMoney when there is no invoice and no subject match", function()
            hiddenMail(nil)
            open()
            assert.is_true(textCalls >= 1)
            inbox[1].money = 0
            change(9050)
            advance(2)
            assert.are.equal(0, #bySource("ahSale"))
            assert.are.equal(1, #bySource("mailMoney"))
        end)

        it("does not read the text of a mail without money", function()
            hiddenMail({ type = "seller", itemName = "Linen Cloth", player = "Rich" })
            inbox[1].money = 0
            open()
            assert.are.equal(0, textCalls)
        end)
    end)

    describe("a sale invoice", function()
        it("gives one ahSale record and no mailMoney when the update comes first", function()
            inbox[1] = saleMail("Rich", 9500, 100, 550)
            open()
            bus:Emit("MAIL_SHOW")
            inbox[1].money = 0
            bus:Emit("MAIL_INBOX_UPDATE")
            advance(0.2)
            change(9050)
            advance(2)
            assert.are.equal(1, #records)
            local sale = records[1]
            assert.are.equal("ahSale", sale.source)
            assert.are.equal("sale", sale.type)
            assert.are.equal(9050, sale.money)
            assert.are.equal(9500, sale.bid)
            assert.are.equal(550, sale.cut)
            assert.are.equal(100, sale.deposit)
            assert.are.equal("Rich", sale.counterparty)
            assert.are.equal("2589", sale.item)
            assert.are.equal(20, sale.qty)
            assert.are.equal("seller", sale.invoiceType)
            assert.is_truthy(sale.fp)
            assert.are.equal(0, #bySource("mailMoney"))
        end)

        it("gives the same result when the money change comes first", function()
            inbox[1] = saleMail("Rich", 9500, 100, 550)
            open()
            change(9050)
            assert.are.equal(0, #records)
            inbox[1].money = 0
            bus:Emit("MAIL_INBOX_UPDATE")
            advance(0.2)
            advance(2)
            assert.are.equal(1, #records)
            assert.are.equal("ahSale", records[1].source)
            assert.are.equal(9050, records[1].money)
        end)

        it("matches the update that is read at the money change", function()
            inbox[1] = saleMail("Rich", 9500, 100, 550)
            open()
            inbox[1].money = 0
            change(9050)
            assert.are.equal(1, #records)
            assert.are.equal("ahSale", records[1].source)
            advance(3)
            assert.are.equal(1, #records)
        end)

        it("counts the sale once in the balance graph at the real value", function()
            inbox[1] = saleMail("Rich", 9500, 100, 550)
            open()
            inbox[1].money = 0
            change(9050)
            advance(2)
            local store = {
                Records = function()
                    return {}
                end,
                Sums = function()
                    return {}
                end,
            }
            for _, record in ipairs(records) do
                record.char = "Tester-Realm"
            end
            local events = ns.LedgerBalance.Events(store, "Tester-Realm", nil, records)
            local total = 0
            for _, event in ipairs(events) do
                total = total + event.delta
            end
            assert.are.equal(9050, total)
            assert.are.equal(1, #events)
        end)

        it("pays two sales taken at once with one money change", function()
            inbox[1] = saleMail("Rich", 9500, 100, 550)
            inbox[2] = saleMail("Poor", 2000, 50, 100)
            open()
            inbox[1].money, inbox[2].money = 0, 0
            change(9050 + 1950)
            advance(2)
            assert.are.equal(2, #bySource("ahSale"))
            assert.are.equal(0, #bySource("mailMoney"))
        end)

        it("writes a sale from the mail money when the client gives no invoice", function()
            inbox[1] = { sender = "AH", subject = "Sold: Linen Cloth", money = 800, itemCount = 0 }
            open()
            inbox[1].money = 0
            change(800)
            assert.are.equal(1, #records)
            assert.are.equal("ahSale", records[1].source)
            assert.are.equal(800, records[1].money)
            assert.are.equal("2589", records[1].item)
            assert.are.equal(1, mail:Stats().noInvoice)
        end)

        it("keeps the item name when no key is found", function()
            local item = saleMail("Rich", 100, 10, 5)
            item.invoice.itemName = "Strange Thing"
            inbox[1] = item
            open()
            inbox[1].money = 0
            change(105)
            assert.are.equal("Strange Thing", records[1].itemName)
            assert.is_nil(records[1].item)
        end)

        it("writes a late sale and claims the money after 10 seconds", function()
            inbox[1] = saleMail("Rich", 9500, 100, 550)
            open()
            inbox[1].money = 0
            bus:Emit("MAIL_INBOX_UPDATE")
            advance(0.2)
            advance(11)
            assert.are.equal(1, #bySource("ahSale"))
            bus:Emit("MAIL_SHOW")
            change(9050)
            advance(3)
            assert.are.equal(0, #bySource("mailMoney"))
            assert.are.equal(1, #records)
        end)
    end)

    describe("duplicates", function()
        it("writes no second record after an index shift", function()
            inbox[1] = saleMail("Rich", 9500, 100, 550)
            inbox[2] = saleMail("Poor", 2000, 50, 100)
            open()
            inbox[1].money = 0
            change(9050)
            table.remove(inbox, 1)
            bus:Emit("MAIL_INBOX_UPDATE")
            advance(0.2)
            advance(2)
            bus:Emit("MAIL_INBOX_UPDATE")
            advance(0.2)
            assert.are.equal(1, #records)
        end)

        it("writes no second record after a reload", function()
            inbox[1] = { sender = "AH", subject = "Expired: Linen Cloth", money = 0, itemCount = 1, itemQuantity = 5,
                itemLink = "linen" }
            open()
            assert.are.equal(1, #bySource("ahExpired"))
            bus = ns.EventBus.New()
            tracker = newTracker()
            mail = attach()
            open()
            assert.are.equal(1, #bySource("ahExpired"))
            assert.are.equal(1, mail:Stats().duplicates)
        end)

        it("does not write the sale again when the paid mail stays after a reload", function()
            inbox[1] = saleMail("Rich", 9500, 100, 550)
            open()
            inbox[1].money = 0
            change(9050)
            bus = ns.EventBus.New()
            tracker = newTracker()
            mail = attach()
            open()
            advance(2)
            assert.are.equal(1, #records)
        end)

        it("removes fingerprints older than 31 days", function()
            local now = 1700000000 + 100
            fps = { old = now - 32 * 86400, fresh = now - 30 * 86400 }
            bus = ns.EventBus.New()
            tracker = newTracker()
            mail = attach()
            assert.is_nil(fps.old)
            assert.is_truthy(fps.fresh)
        end)
    end)

    describe("other Auction House mail", function()
        it("records an expired auction once, without money", function()
            inbox[1] = { sender = "AH", subject = "Expired: Linen Cloth", money = 0, itemCount = 1, itemQuantity = 5,
                itemLink = "linen" }
            open()
            bus:Emit("MAIL_INBOX_UPDATE")
            advance(0.2)
            assert.are.equal(1, #records)
            assert.are.equal("expired", records[1].type)
            assert.are.equal("ahExpired", records[1].source)
            assert.are.equal(0, records[1].money)
            assert.are.equal("k:linen", records[1].item)
            assert.are.equal(5, records[1].qty)
        end)

        it("records a cancelled auction", function()
            inbox[1] = { sender = "AH", subject = "Cancelled: Linen Cloth", money = 0, itemCount = 1, itemQuantity = 5,
                itemLink = "linen" }
            open()
            assert.are.equal("ahCancelled", records[1].source)
            assert.are.equal("cancelled", records[1].type)
        end)

        it("gives a buyer invoice no money record", function()
            inbox[1] = { sender = "AH", subject = "Won: Linen Cloth", money = 0, itemCount = 1, itemQuantity = 20,
                itemLink = "linen", invoice = { type = "buyer", itemName = "Linen Cloth", player = "Seller",
                    bid = 9000, buyout = 9000, deposit = 0, consignment = 0, count = 20 } }
            open()
            table.remove(inbox, 1)
            bus:Emit("MAIL_INBOX_UPDATE")
            advance(0.2)
            advance(3)
            assert.are.equal(0, #records)
        end)

        it("gives a pending sale invoice no record", function()
            inbox[1] = { sender = "AH", subject = "Sold: Linen Cloth", money = 0, itemCount = 0,
                invoice = { type = "seller_temp_invoice", itemName = "Linen Cloth", player = "Rich", bid = 5,
                    buyout = 5, deposit = 1, consignment = 1, count = 1 } }
            open()
            assert.are.equal(0, #records)
        end)

        it("records an outbid refund as ahOutbidRefund", function()
            inbox[1] = { sender = "AH", subject = "Outbid: Linen Cloth", money = 700, itemCount = 0 }
            open()
            inbox[1].money = 0
            change(700)
            assert.are.equal(1, #records)
            assert.are.equal("ahOutbidRefund", records[1].source)
            assert.are.equal("income", records[1].type)
        end)
    end)

    describe("money from players", function()
        it("stays mailMoney when the update comes first", function()
            inbox[1] = { sender = "Friend", subject = "Gift", money = 300, itemCount = 0 }
            open()
            inbox[1].money = 0
            change(300)
            advance(2)
            assert.are.equal(1, #records)
            assert.are.equal("mailMoney", records[1].source)
            assert.are.equal(300, records[1].money)
        end)

        it("stays mailMoney when no update comes", function()
            inbox[1] = { sender = "Friend", subject = "Gift", money = 300, itemCount = 0 }
            open()
            change(300)
            advance(2)
            assert.are.equal(1, #records)
            assert.are.equal("mailMoney", records[1].source)
        end)
    end)

    describe("safety", function()
        it("skips a mail with a secret value", function()
            secrets["Secret Sender"] = true
            inbox[1] = { sender = "Secret Sender", subject = "Gift", money = 300, itemCount = 0 }
            open()
            assert.is_true(mail:Stats().skipped >= 1)
            change(300)
            advance(2)
            assert.are.equal("mailMoney", records[1].source)
        end)

        it("listens only to mail events and installs no hook", function()
            local original = _G.hooksecurefunc
            _G.hooksecurefunc = function()
                error("hook installed")
            end
            inbox[1] = saleMail("Rich", 9500, 100, 550)
            open()
            _G.hooksecurefunc = original
            local allowed = {}
            for _, event in ipairs(ns.LedgerMail.EVENTS) do
                allowed[event] = true
            end
            for _, event in ipairs(subscribed) do
                if event:find("MAIL", 1, true) then
                    assert.is_true(allowed[event], event)
                end
                assert.are_not.equal("COMBAT_LOG_EVENT_UNFILTERED", event)
            end
        end)

        it("has no hook and no GetInboxText call in the code", function()
            local handle = assert(io.open(manifest.path("LedgerMail"), "rb"))
            local source = handle:read("*a")
            handle:close()
            local code = {}
            for line in source:gmatch("[^\n]+") do
                if not line:match("^%s*%-%-") then
                    code[#code + 1] = line
                end
            end
            local joined = table.concat(code, "\n")
            assert.is_nil(joined:find("hooksecurefunc", 1, true))
            assert.is_nil(joined:find("GetInboxText", 1, true))
            assert.is_nil(joined:find("RegisterEvent", 1, true))
        end)

        it("reads no invoice when the flavour turns it off and still finds a sale", function()
            bus = ns.EventBus.New()
            tracker = newTracker()
            mail = attach({ invoices = false })
            inbox[1] = saleMail("Rich", 9500, 100, 550)
            open()
            inbox[1].money = 0
            change(9050)
            assert.are.equal(0, calls.invoice)
            assert.are.equal("ahSale", records[1].source)
        end)

        it("makes the pattern from a client format text", function()
            assert.are.equal("Axe (x)", ("Won: Axe (x)"):match(ns.LedgerMail.FormatToPattern("Won: %s")))
            assert.is_nil(ns.LedgerMail.FormatToPattern(nil))
        end)
    end)
end)
