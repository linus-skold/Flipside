describe("InventoryCapture", function()
    local ns, bus, saved, timers, reports, bags, bankSlots, mail, owned, failBags

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
                    itemLink = function(i, a) return mail[i][a] and mail[i][a].link end,
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
        for _, name in ipairs({ "Core/EventBus", "Core/ItemString", "Services/ScanKey", "Services/HoldingsRead",
            "Features/Inventory/InventoryCapture" }) do
            assert(loadfile(name .. ".lua"))("Flipside", ns)
        end
        bus = ns.EventBus.New({})
        saved, timers, reports, failBags = {}, {}, {}, false
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
