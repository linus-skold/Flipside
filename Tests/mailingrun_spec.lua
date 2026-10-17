local manifest = require("Tests.manifest")

describe("MailingRun", function()
    local ns, bus, client, timers, now, run, result, progress, sending, sent

    local function load(name)
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end

    local function advance(seconds)
        now = now + seconds
        local due, rest = {}, {}
        for _, timer in ipairs(timers) do
            table.insert(timer.at <= now and due or rest, timer)
        end
        timers = rest
        table.sort(due, function(a, b)
            return a.at < b.at
        end)
        for _, timer in ipairs(due) do
            timer.fn()
        end
    end

    -- A fake client. truth is the real bag state; view is what the client reports until BAG_UPDATE_DELAYED.
    local function makeClient(bags)
        local c = { truth = bags, attachments = {}, attaches = {}, sends = {}, cleared = {}, money = 100000,
            used = {}, failSend = false }
        c.view = {}
        function c.refresh()
            c.view = {}
            for _, slot in ipairs(c.truth) do
                c.view[#c.view + 1] = { key = slot.key, bag = slot.bag, slot = slot.slot, count = slot.count,
                    locked = slot.locked }
            end
        end
        c.refresh()
        function c.ReadSlots()
            return c.view
        end
        function c.Attach(bag, slot, index)
            c.attaches[#c.attaches + 1] = bag .. ":" .. slot
            for _, s in ipairs(c.view) do
                if s.bag == bag and s.slot == slot then
                    c.attachments[index] = { index = index, name = s.key, itemID = 1, count = s.count, bag = bag,
                        slot = slot }
                    return true
                end
            end
            return false
        end
        function c.Attachment(index)
            return c.attachments[index]
        end
        function c.Attachments()
            local list = {}
            for index = 1, 12 do
                list[#list + 1] = c.attachments[index]
            end
            return list
        end
        function c.ClearSlot(index)
            c.cleared[#c.cleared + 1] = index
            c.attachments[index] = nil
        end
        function c.ClearAll()
            c.attachments = {}
            c.clearAllCalls = (c.clearAllCalls or 0) + 1
        end
        function c.Postage()
            local n = 0
            for _ in pairs(c.attachments) do
                n = n + 1
            end
            return n * 30
        end
        function c.Money()
            return c.money
        end
        function c.Send(recipient, subject)
            if c.failSend then
                error("send failed")
            end
            local items = {}
            for _, item in pairs(c.attachments) do
                items[#items + 1] = item
                for i, s in ipairs(c.truth) do
                    if s.bag == item.bag and s.slot == item.slot then
                        table.remove(c.truth, i)
                        break
                    end
                end
            end
            c.sends[#c.sends + 1] = { recipient = recipient, subject = subject, items = items }
            c.attachments = {}
        end
        return c
    end

    local function slot(key, bag, index, count, locked)
        return { key = key, bag = bag, slot = index, count = count, locked = locked }
    end

    local function mail(recipient, ...)
        local attachments = {}
        for _, a in ipairs({ ... }) do
            attachments[#attachments + 1] = { key = a[1], bag = a[2], slot = a[3], count = a[4] }
        end
        return { recipient = recipient, attachments = attachments }
    end

    -- Start a run. The settle time is 0.2, the bag wait 5 and the delay 0.5.
    local function start(bags, mails, skipped)
        client = makeClient(bags)
        run = ns.MailingRun.New({
            client = client, bus = bus, delay = 0.5, bagWait = 5,
            after = function(seconds, fn)
                timers[#timers + 1] = { at = now + seconds, fn = fn }
            end,
            onProgress = function(status)
                progress[#progress + 1] = status.state
            end,
            onSending = function(info)
                sending[#sending + 1] = info
            end,
            onSent = function(info)
                sent[#sent + 1] = info
            end,
            onDone = function(r)
                result = r
            end,
        })
        assert.is_true(run:Start({ mails = mails, skipped = skipped or {} }))
    end

    -- Let a mail pass the settle time, so that the send call happens.
    local function settle()
        advance(0.2)
    end

    -- MAIL_SEND_SUCCESS, then the bag update that the client sends after it.
    local function succeed()
        bus:Emit("MAIL_SEND_SUCCESS")
        client.refresh()
        bus:Emit("BAG_UPDATE_DELAYED")
    end

    before_each(function()
        ns = {}
        for _, name in ipairs({ "EventBus", "MailingRun" }) do
            load(name)
        end
        bus = ns.EventBus.New()
        timers, now, result, progress, sending, sent = {}, 0, nil, {}, {}, {}
    end)

    it("sends three mails in order and waits for the bag update and the delay between them", function()
        start({ slot("A", 0, 1, 5), slot("B", 0, 2, 5), slot("C", 0, 3, 5) },
            { mail("Alt", { "A", 0, 1, 5 }), mail("Alt", { "B", 0, 2, 5 }), mail("Bank", { "C", 0, 3, 5 }) })
        settle()
        assert.are.equal(1, #client.sends)
        assert.are.equal("Alt", client.sends[1].recipient)

        bus:Emit("MAIL_SEND_SUCCESS")
        advance(3)
        assert.are.equal(1, #client.attaches, "no attach before BAG_UPDATE_DELAYED")
        client.refresh()
        bus:Emit("BAG_UPDATE_DELAYED")
        advance(0.4)
        assert.are.equal(1, #client.attaches, "no attach inside the delay")
        advance(0.2)
        assert.are.equal(2, #client.attaches)
        settle()
        assert.are.equal(2, #client.sends)

        succeed()
        advance(0.6)
        settle()
        assert.are.equal(3, #client.sends)
        assert.are.equal("Bank", client.sends[3].recipient)
        bus:Emit("MAIL_SEND_SUCCESS")
        assert.are.equal(3, result.sent)
        assert.is_nil(result.stopped)
        assert.are.equal(90, result.postage)
        assert.is_false(run:IsRunning())
    end)

    it("reports items per recipient and the postage of each mail", function()
        start({ slot("A", 0, 1, 5), slot("B", 0, 2, 7) }, { mail("Alt", { "A", 0, 1, 5 }, { "B", 0, 2, 7 }) })
        settle()
        bus:Emit("MAIL_SEND_SUCCESS")
        assert.are.equal(1, #sending)
        assert.are.equal(60, sending[1].postage)
        assert.are.equal(1, #sent)
        assert.are.same({ { name = "Alt", mails = 1, units = 12 } }, result.recipients)
        assert.are.equal(60, result.postage)
    end)

    it("never attaches a slot twice or a stale slot of a sent mail", function()
        start({ slot("A", 0, 1, 5), slot("A", 0, 2, 5) },
            { mail("Alt", { "A", 0, 1, 5 }), mail("Alt", { "A", 0, 1, 5 }) })
        settle()
        succeed()
        advance(0.5)
        -- The planned slot 0:1 is empty now. The second mail takes the item from 0:2.
        assert.are.equal("0:2", client.attaches[2])
        settle()
        assert.are.equal(2, #client.sends)
    end)

    it("does not use a locked slot", function()
        start({ slot("A", 0, 1, 5, true), slot("A", 0, 2, 5) }, { mail("Alt", { "A", 0, 1, 5 }) })
        assert.are.same({ "0:2" }, client.attaches)
    end)

    it("skips an item that is not in the bags any more", function()
        start({ slot("A", 0, 1, 5) }, { mail("Alt", { "A", 0, 1, 5 }, { "Z", 0, 2, 3 }) }, {
            { key = "Q", count = 1, reason = "soulbound" } })
        settle()
        bus:Emit("MAIL_SEND_SUCCESS")
        assert.are.equal("soulbound", result.skipped[1].reason)
        assert.are.equal("item not found in the bags", result.skipped[2].reason)
        assert.are.equal("Z", result.skipped[2].key)
    end)

    it("stops when the mailbox closes", function()
        start({ slot("A", 0, 1, 5), slot("B", 0, 2, 5) },
            { mail("Alt", { "A", 0, 1, 5 }), mail("Alt", { "B", 0, 2, 5 }) })
        bus:Emit("MAIL_CLOSED")
        assert.are.equal("mailbox closed", result.stopped)
        assert.are.equal(1, client.clearAllCalls)
        advance(10)
        assert.are.equal(0, #client.sends)
        assert.is_false(bus:HasSubscribers("MAIL_SEND_SUCCESS"))
    end)

    it("stops at once on Stop between two mails", function()
        start({ slot("A", 0, 1, 5), slot("B", 0, 2, 5) },
            { mail("Alt", { "A", 0, 1, 5 }), mail("Alt", { "B", 0, 2, 5 }) })
        settle()
        bus:Emit("MAIL_SEND_SUCCESS")
        run:Stop()
        assert.are.equal("stopped", result.stopped)
        advance(10)
        assert.are.equal(1, #client.sends)
        assert.are.equal(1, result.sent)
    end)

    it("lets a mail in flight finish when Stop comes", function()
        start({ slot("A", 0, 1, 5), slot("B", 0, 2, 5) },
            { mail("Alt", { "A", 0, 1, 5 }), mail("Alt", { "B", 0, 2, 5 }) })
        settle()
        run:Stop()
        assert.is_nil(result)
        bus:Emit("MAIL_SEND_SUCCESS")
        assert.are.equal("stopped", result.stopped)
        assert.are.equal(1, result.sent)
    end)

    it("stops when the gold does not cover the postage", function()
        start({ slot("A", 0, 1, 5) }, { mail("Alt", { "A", 0, 1, 5 }) })
        client.money = 10
        settle()
        assert.are.equal(0, #client.sends)
        assert.are.equal("not enough money for the postage", result.stopped)
        assert.are.equal(1, client.clearAllCalls)
    end)

    it("skips an item that needs a confirm, clears it and sends the rest", function()
        start({ slot("A", 0, 1, 5), slot("B", 0, 2, 5) }, { mail("Alt", { "A", 0, 1, 5 }, { "B", 0, 2, 5 }) })
        bus:Emit("MAIL_LOCK_SEND_ITEMS", 2, "link")
        settle()
        assert.are.same({ 2 }, client.cleared)
        assert.are.equal(1, #client.sends[1].items)
        bus:Emit("MAIL_SEND_SUCCESS")
        assert.are.equal(1, #result.skipped)
        assert.is_truthy(result.skipped[1].reason:find("confirm"))
        assert.are.equal(5, result.recipients[1].units)
    end)

    it("does not send a mail whose items all need a confirm", function()
        start({ slot("A", 0, 1, 5) }, { mail("Alt", { "A", 0, 1, 5 }) })
        bus:Emit("MAIL_LOCK_SEND_ITEMS", 1, "link")
        settle()
        assert.are.equal(0, #client.sends)
        assert.is_nil(result.stopped)
        assert.are.equal(0, result.sent)
    end)

    it("skips the rest of a recipient when a mail fails, and goes on with the next recipient", function()
        start({ slot("A", 0, 1, 5), slot("B", 0, 2, 5), slot("C", 0, 3, 5) },
            { mail("Nobody", { "A", 0, 1, 5 }), mail("nobody", { "B", 0, 2, 5 }), mail("Bank", { "C", 0, 3, 5 }) })
        settle()
        bus:Emit("UI_ERROR_MESSAGE", 1, "No player named Nobody")
        bus:Emit("MAIL_FAILED")
        advance(0.5)
        settle()
        assert.are.equal(2, #client.sends)
        assert.are.equal("Bank", client.sends[#client.sends].recipient)
        bus:Emit("MAIL_SEND_SUCCESS")
        assert.are.equal(1, result.sent)
        assert.are.equal(2, #result.skipped)
        assert.are.equal("mail failed: No player named Nobody", result.skipped[1].reason)
        assert.are.equal("mail failed: No player named Nobody", result.skipped[2].reason)
    end)

    it("treats a missing result as a failed mail after the time-out", function()
        start({ slot("A", 0, 1, 5) }, { mail("Alt", { "A", 0, 1, 5 }) })
        settle()
        advance(11)
        advance(1)
        assert.are.equal(0, result.sent)
        assert.are.equal("mail failed", result.skipped[1].reason)
    end)

    it("goes on after the bag wait when BAG_UPDATE_DELAYED does not come", function()
        start({ slot("A", 0, 1, 5), slot("B", 0, 2, 5) },
            { mail("Alt", { "A", 0, 1, 5 }), mail("Alt", { "B", 0, 2, 5 }) })
        settle()
        bus:Emit("MAIL_SEND_SUCCESS")
        client.refresh()
        advance(4.9)
        assert.are.equal(1, #client.attaches)
        advance(0.2)
        advance(0.5)
        assert.are.equal(2, #client.attaches)
    end)

    it("stops if the send call raises an error", function()
        start({ slot("A", 0, 1, 5) }, { mail("Alt", { "A", 0, 1, 5 }) })
        client.failSend = true
        settle()
        assert.are.equal("the send call failed", result.stopped)
    end)

    it("refuses a second start while it runs, and an empty plan", function()
        start({ slot("A", 0, 1, 5) }, { mail("Alt", { "A", 0, 1, 5 }) })
        assert.is_false(run:Start({ mails = { mail("Alt", { "A", 0, 1, 5 }) } }))
        run:Abort("test")
        assert.is_false(run:Start({ mails = {} }))
    end)
end)
