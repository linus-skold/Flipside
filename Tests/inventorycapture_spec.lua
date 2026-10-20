local manifest = require("Tests.manifest")
describe("InventoryCapture", function()
    local ns, bus, saved, timers, reports, bags, bankSlots, mail, owned, failBags, attachmentReads

    local function link(id)
        return "|cff1eff00|Hitem:" .. id .. "::::::::60:::::|h[x]|h|r"
    end

    local function attach()
        local holdings = {
            SetLocation = function(_, location, items)
                saved[#saved + 1] = { location = location, items = items }
                return true
            end,
        }
        return ns.InventoryCapture.Attach({
            bus = bus,
            holdings = holdings,
            holdingsRead = ns.HoldingsRead,
            api = {
                container = {
                    numSlots = function(bag)
                        if failBags then error("boom") end
                        local list = bag >= 6 and bankSlots[bag] or bags[bag]
                        return list and #list or 0
                    end,
                    itemInfo = function(bag, slot)
                        return (bag >= 6 and bankSlots[bag] or bags[bag])[slot]
                    end,
                },
                mail = {
                    numItems = function() return #mail end,
                    header = function(i)
                        local m = mail[i]
                        return "pkg", "stat", "Sender" .. i, "Subject" .. i, m.money or 0, 0, 3, #m
                    end,
                    itemLink = function(i, a)
                        attachmentReads = attachmentReads + 1
                        return mail[i][a] and mail[i][a].link
                    end,
                    itemInfo = function(i, a) return "n", 0, "t", mail[i][a].count end,
                },
                auctions = { owned = function() return owned end },
            },
            resolver = ns.ScanKey.New({}),
            after = function(seconds, fn)
                timers[#timers + 1] = { seconds = seconds, fn = fn }
            end,
            report = function(message) reports[#reports + 1] = message end,
        })
    end

    local function run()
        local due = timers
        timers = {}
        for _, t in ipairs(due) do t.fn() end
    end

    local function last(location)
        for i = #saved, 1, -1 do
            if saved[i].location == location then return saved[i].items end
        end
    end

    before_each(function()
        ns = {}
        for _, name in ipairs({ "EventBus", "ItemString", "ScanKey", "HoldingsRead",
            "InventoryCapture" }) do
            assert(loadfile(manifest.path(name)))("Flipside", ns)
        end
        bus = ns.EventBus.New({})
        saved, timers, reports, failBags, attachmentReads = {}, {}, {}, false, 0
        bags = { [0] = { { itemID = 10, hyperlink = link(10), stackCount = 4 } } }
        bankSlots = { [6] = { { itemID = 20, hyperlink = link(20), stackCount = 2 } } }
        mail = { { { link = link(30), count = 5 } } }
        owned = { { itemLink = link(40), quantity = 7, status = 0 } }
        attach()
    end)

    it("reads the bags once at login after the delay", function()
        assert.are.equal(0.5, timers[1].seconds)
        assert.are.equal(0, #saved)
        run()
        assert.are.equal(1, #saved)
        assert.are.equal(4, last("bags")["10"])
    end)

    it("reads the bags once for a burst of events", function()
        run()
        saved = {}
        for _ = 1, 5 do bus:Emit("BAG_UPDATE_DELAYED") end
        assert.are.equal(1, #timers)
        run()
        assert.are.equal(1, #saved)
        bags[0][1].stackCount = 9
        bus:Emit("BAG_UPDATE_DELAYED")
        run()
        assert.are.equal(9, last("bags")["10"])
    end)

    it("reads the bank only while it is open", function()
        bus:Emit("PLAYERBANKSLOTS_CHANGED")
        run()
        assert.is_nil(last("bank"))
        bus:Emit("BANKFRAME_OPENED")
        assert.are.equal(2, last("bank")["20"])
        bankSlots[6][1].stackCount = 3
        bus:Emit("PLAYERBANKSLOTS_CHANGED")
        run()
        assert.are.equal(3, last("bank")["20"])
        bus:Emit("BANKFRAME_CLOSED")
        saved = {}
        bus:Emit("PLAYERBANKSLOTS_CHANGED")
        run()
        assert.are.equal(0, #saved)
    end)

    it("reads mail and own auctions", function()
        bus:Emit("MAIL_INBOX_UPDATE")
        bus:Emit("OWNED_AUCTIONS_UPDATED")
        run()
        assert.are.equal(5, last("mail")["30"])
        assert.are.equal(7, last("auctions")["40"])
    end)

    it("skips the attachment read and the save when the inbox headers do not change", function()
        bus:Emit("MAIL_INBOX_UPDATE")
        run()
        local reads = attachmentReads
        assert.is_true(reads > 0)
        saved = {}
        bus:Emit("MAIL_INBOX_UPDATE")
        run()
        assert.are.equal(reads, attachmentReads, "no attachment read")
        assert.is_nil(last("mail"), "no SetLocation call")
        mail[1].money = 50
        bus:Emit("MAIL_INBOX_UPDATE")
        run()
        assert.are.equal(5, last("mail")["30"], "a changed header makes a new read")
        saved = {}
        mail[2] = { { link = link(31), count = 2 } }
        bus:Emit("MAIL_INBOX_UPDATE")
        run()
        assert.are.equal(2, last("mail")["31"], "a new mail makes a new read")
    end)

    it("reads the mail again after a read with errors", function()
        local info = ns.HoldingsRead.Mail
        local calls = 0
        ns.HoldingsRead.Mail = function(...)
            calls = calls + 1
            local items = info(...)
            return items, { errors = 1 }
        end
        bus:Emit("MAIL_INBOX_UPDATE")
        run()
        bus:Emit("MAIL_INBOX_UPDATE")
        run()
        ns.HoldingsRead.Mail = info
        assert.are.equal(2, calls)
    end)

    it("reports a failing read once", function()
        failBags = true
        run()
        bus:Emit("BAG_UPDATE_DELAYED")
        run()
        assert.is_true(#reports >= 1)
        local first = #reports
        bus:Emit("BAG_UPDATE_DELAYED")
        run()
        assert.are.equal(first, #reports)
    end)
end)
