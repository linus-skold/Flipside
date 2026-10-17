local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("EventBus")))("Flipside", ns)
assert(loadfile(manifest.path("LedgerRecord")))("Flipside", ns)
assert(loadfile(manifest.path("LedgerMoney")))("Flipside", ns)

local M = ns.LedgerMoney

local bus, clock, money, records, timers, subscribed, settings, secrets, calls, tracker, reports

local function after(seconds, fn)
    timers[#timers + 1] = { at = clock + seconds, fn = fn }
end

-- Move the clock and run the timers that are due.
local function advance(seconds)
    clock = clock + seconds
    local due = {}
    local rest = {}
    for _, timer in ipairs(timers) do
        table.insert(timer.at <= clock and due or rest, timer)
    end
    timers = rest
    for _, timer in ipairs(due) do
        timer.fn()
    end
end

-- Change the money and fire PLAYER_MONEY.
local function change(delta)
    money = money + delta
    bus:Emit("PLAYER_MONEY")
end

local client = {
    OpenEvent = function()
        return "AUCTION_HOUSE_SHOW"
    end,
    CloseEvent = function()
        return "AUCTION_HOUSE_CLOSED"
    end,
    BuyEvents = function()
        return {
            commoditySucceeded = "COMMODITY_PURCHASE_SUCCEEDED", itemCompleted = "AUCTION_HOUSE_PURCHASE_COMPLETED",
        }
    end,
    PostedEvent = function()
        return "AUCTION_HOUSE_AUCTION_CREATED"
    end,
    OnCall = function(fn)
        calls = fn
    end,
}

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
        report = function(message)
            reports[#reports + 1] = message
        end,
        isSecret = function(value)
            return secrets[value] == true
        end,
        setting = function(key)
            return settings[key]
        end,
        itemKey = function(input, isCommodity)
            if input == nil then
                return nil
            end
            return (isCommodity and "c:" or "e:") .. tostring(input)
        end,
        client = client,
        commodityMarket = true,
        auctionInfo = function(auctionID)
            return { itemLink = "link" .. auctionID, buyoutAmount = 500, quantity = 3 }
        end,
        bagLink = function(bag, slot)
            return "bag" .. bag .. "." .. slot
        end,
        deposit = function()
            return 40
        end,
    }
    for name, value in pairs(overrides or {}) do
        deps[name] = value
    end
    return M.Attach(deps)
end

local function last()
    return records[#records]
end

describe("LedgerMoney", function()
    before_each(function()
        bus = ns.EventBus.New({
            onFirstSubscriber = function(event)
                subscribed[#subscribed + 1] = event
            end,
        })
        clock, money, records, timers, settings, secrets, reports = 100, 10000, {}, {}, {}, {}, {}
        subscribed = {}
        calls = nil
        tracker = attach()
    end)

    describe("context labels", function()
        local cases = {
            { "MERCHANT_SHOW", "MERCHANT_CLOSED", 50, "vendorSale", "income" },
            { "MERCHANT_SHOW", "MERCHANT_CLOSED", -50, "vendorPurchase", "expense" },
            { "LOOT_OPENED", "LOOT_CLOSED", 50, "loot", "loot" },
            { "TRADE_SHOW", "TRADE_CLOSED", 50, "trade", "income" },
            { "TRADE_SHOW", "TRADE_CLOSED", -50, "trade", "expense" },
            { "MAIL_SHOW", "MAIL_CLOSED", 50, "mailMoney", "income" },
            { "MAIL_SHOW", "MAIL_CLOSED", -50, "unknown", "expense" },
            { "LOOT_OPENED", "LOOT_CLOSED", -50, "unknown", "expense" },
        }
        for _, case in ipairs(cases) do
            it(string.format("%s with %d gives %s", case[1], case[3], case[4]), function()
                bus:Emit(case[1])
                change(case[3])
                assert.are.equal(1, #records)
                assert.are.equal(case[4], last().source)
                assert.are.equal(case[5], last().type)
                assert.are.equal(math.abs(case[3]), last().money)
                assert.are.equal("Tester-Realm", last().char)
                assert.are.equal(1700000100, last().time)
                assert.is_truthy(last().ctx:match("^%a+:%d+$"))
            end)
        end

        it("records an unknown change in an open Auction House with no hint after the hold time", function()
            bus:Emit("AUCTION_HOUSE_SHOW")
            change(-30)
            assert.are.equal(0, #records)
            advance(M.QUEST_WINDOW_SECONDS)
            assert.are.equal("unknown", last().source)
            assert.are.equal(1, tracker:Stats().unpaired)
            local positive = #records
            change(30)
            assert.are.equal(positive + 1, #records)
            assert.are.equal("income", last().type)
        end)

        it("gives the source unknown when no context is open", function()
            change(-70)
            assert.are.equal("unknown", last().source)
            assert.are.equal("expense", last().type)
            change(70)
            assert.are.equal(1, #records)
            advance(M.QUEST_WINDOW_SECONDS)
            assert.are.equal("unknown", last().source)
            assert.are.equal("income", last().type)
            assert.are.equal(70, last().money)
        end)

        it("writes no record when the money does not change", function()
            bus:Emit("MERCHANT_SHOW")
            bus:Emit("PLAYER_MONEY")
            assert.are.equal(0, #records)
        end)

        it("stops labelling after the context closes", function()
            bus:Emit("MERCHANT_SHOW")
            bus:Emit("MERCHANT_CLOSED")
            change(-5)
            assert.are.equal("unknown", last().source)
        end)

        it("gives the records of one context the same ctx and a new context a new ctx", function()
            bus:Emit("MERCHANT_SHOW")
            change(5)
            change(6)
            local first = records[1].ctx
            assert.are.equal(first, records[2].ctx)
            assert.are.equal(first, tracker:Context("merchant"))
            bus:Emit("MERCHANT_CLOSED")
            bus:Emit("MERCHANT_SHOW")
            change(7)
            assert.are_not.equal(first, records[3].ctx)
        end)
    end)

    describe("the loot tail", function()
        it("labels money that arrives after LOOT_CLOSED inside the tail", function()
            bus:Emit("LOOT_OPENED")
            bus:Emit("LOOT_CLOSED")
            advance(M.LOOT_TAIL_SECONDS - 0.1)
            change(25)
            assert.are.equal("loot", last().source)
        end)

        it("labels money after the tail as unknown", function()
            bus:Emit("LOOT_OPENED")
            bus:Emit("LOOT_CLOSED")
            advance(M.LOOT_TAIL_SECONDS + 0.1)
            change(-25)
            assert.are.equal("unknown", last().source)
        end)

        it("gives the tail the id of the loot window", function()
            bus:Emit("LOOT_OPENED")
            local id = tracker:Context("loot")
            bus:Emit("LOOT_CLOSED")
            change(25)
            assert.are.equal(id, last().ctx)
        end)
    end)

    describe("quest rewards", function()
        it("matches a reward event before the money change", function()
            bus:Emit("QUEST_TURNED_IN", 77, 100, 250)
            change(250)
            assert.are.equal(1, #records)
            assert.are.equal("quest", last().source)
            assert.are.equal("income", last().type)
            assert.is_truthy(last().ctx:match("^quest:"))
        end)

        it("matches a reward event after the money change", function()
            change(250)
            assert.are.equal(0, #records)
            bus:Emit("QUEST_TURNED_IN", 77, 100, 250)
            assert.are.equal(1, #records)
            assert.are.equal("quest", last().source)
            advance(M.QUEST_WINDOW_SECONDS)
            assert.are.equal(1, #records)
        end)

        it("does not match a different amount", function()
            bus:Emit("QUEST_TURNED_IN", 77, 100, 250)
            change(251)
            advance(M.QUEST_WINDOW_SECONDS)
            assert.are.equal("unknown", last().source)
        end)

        it("does not match a reward that is too old", function()
            bus:Emit("QUEST_TURNED_IN", 77, 100, 250)
            advance(M.QUEST_WINDOW_SECONDS + 0.5)
            change(250)
            advance(M.QUEST_WINDOW_SECONDS)
            assert.are.equal("unknown", last().source)
        end)

        it("ignores a reward of 0 copper", function()
            bus:Emit("QUEST_TURNED_IN", 77, 100, 0)
            change(10)
            advance(M.QUEST_WINDOW_SECONDS)
            assert.are.equal("unknown", last().source)
        end)

        it("wins over an open context when the amount matches", function()
            bus:Emit("MERCHANT_SHOW")
            bus:Emit("QUEST_TURNED_IN", 77, 100, 250)
            change(250)
            assert.are.equal("quest", last().source)
        end)
    end)

    describe("the context priority", function()
        it("lists the rule", function()
            assert.are.same({ "trade", "loot", "ah", "merchant", "mail" }, M.PRIORITY)
        end)

        it("prefers trade over loot, loot over ah, ah over merchant and merchant over mail", function()
            bus:Emit("MAIL_SHOW")
            bus:Emit("MERCHANT_SHOW")
            change(10)
            assert.are.equal("vendorSale", last().source)
            bus:Emit("AUCTION_HOUSE_SHOW")
            change(10)
            assert.are.equal("unknown", last().source)
            assert.is_truthy(last().ctx:match("^ah:"))
            bus:Emit("LOOT_OPENED")
            change(10)
            assert.are.equal("loot", last().source)
            bus:Emit("TRADE_SHOW")
            change(10)
            assert.are.equal("trade", last().source)
            bus:Emit("TRADE_CLOSED")
            change(10)
            assert.are.equal("loot", last().source)
        end)

        it("ranks a loot tail above an open merchant window", function()
            bus:Emit("LOOT_OPENED")
            bus:Emit("LOOT_CLOSED")
            bus:Emit("MERCHANT_SHOW")
            change(10)
            assert.are.equal("loot", last().source)
            advance(M.LOOT_TAIL_SECONDS + 0.1)
            change(10)
            assert.are.equal("vendorSale", last().source)
        end)
    end)

    describe("Auction House records", function()
        before_each(function()
            bus:Emit("AUCTION_HOUSE_SHOW")
        end)

        it("writes one purchase record for a commodity buy with the item and the quantity", function()
            calls("ConfirmCommodityPurchase", 1234, 20)
            change(-900)
            bus:Emit("COMMODITY_PURCHASE_SUCCEEDED")
            bus:Emit("COMMODITY_PURCHASED", 1234, 20)
            advance(M.HINT_SECONDS + 1)
            assert.are.equal(1, #records)
            assert.are.equal("ahPurchase", last().source)
            assert.are.equal("purchase", last().type)
            assert.are.equal(900, last().money)
            assert.are.equal("c:1234", last().item)
            assert.are.equal(20, last().qty)
            assert.is_truthy(last().ctx:match("^ah:"))
        end)

        it("writes one record when the money change comes before the event of an outside buy", function()
            change(-900)
            assert.are.equal(0, #records)
            bus:Emit("COMMODITY_PURCHASE_SUCCEEDED")
            assert.are.equal(1, #records)
            assert.are.equal("ahPurchase", last().source)
            assert.are.equal(900, last().money)
            advance(M.QUEST_WINDOW_SECONDS)
            bus:Emit("COMMODITY_PURCHASED", 55, 4)
            advance(M.HINT_SECONDS)
            assert.are.equal(1, #records)
        end)

        it("writes one purchase record for an item auction with the item from the auction", function()
            calls("BuyItemAuction", 9, 500)
            bus:Emit("AUCTION_HOUSE_PURCHASE_COMPLETED", 9)
            change(-500)
            assert.are.equal(1, #records)
            assert.are.equal("ahPurchase", last().source)
            assert.are.equal("e:link9", last().item)
            assert.are.equal(3, last().qty)
            assert.are.equal(500, last().money)
        end)

        it("uses the real money change and not a quote", function()
            calls("ConfirmCommodityPurchase", 1234, 20)
            change(-950)
            assert.are.equal(950, last().money)
        end)

        it("does not double count two buys in a row", function()
            calls("ConfirmCommodityPurchase", 1, 1)
            change(-10)
            bus:Emit("COMMODITY_PURCHASE_SUCCEEDED")
            calls("ConfirmCommodityPurchase", 2, 2)
            change(-20)
            bus:Emit("COMMODITY_PURCHASE_SUCCEEDED")
            assert.are.equal(2, #records)
            assert.are.equal("c:1", records[1].item)
            assert.are.equal("c:2", records[2].item)
        end)

        it("writes a post record and a deposit expense for a post", function()
            calls("PostItem", 0, 3, 24, 2, nil, 800)
            bus:Emit("AUCTION_HOUSE_AUCTION_CREATED", 321)
            change(-40)
            assert.are.equal(2, #records)
            local post, deposit = records[1], records[2]
            assert.are.equal("ahPost", post.source)
            assert.are.equal("post", post.type)
            assert.are.equal("e:bag0.3", post.item)
            assert.are.equal(2, post.qty)
            assert.are.equal(800, post.buyout)
            assert.are.equal(40, post.deposit)
            assert.are.equal(0, post.money)
            assert.are.equal("ahDeposit", deposit.source)
            assert.are.equal("expense", deposit.type)
            assert.are.equal(40, deposit.money)
            assert.are.equal("e:bag0.3", deposit.item)
            assert.are.equal(post.ctx, deposit.ctx)
        end)

        it("writes one post record and one deposit for each stack of a multi-stack post", function()
            calls("PostItem", 0, 3, 24, 20, nil, 800, 11, nil, 3)
            for id = 1, 3 do
                bus:Emit("AUCTION_HOUSE_AUCTION_CREATED", id)
                change(-40)
            end
            local posts, deposits = 0, 0
            for _, record in ipairs(records) do
                if record.source == "ahPost" then
                    posts = posts + 1
                    assert.are.equal(20, record.qty)
                    assert.are.equal(800, record.buyout)
                    assert.are.equal("e:bag0.3", record.item)
                elseif record.source == "ahDeposit" then
                    deposits = deposits + 1
                    assert.are.equal(40, record.money)
                end
            end
            assert.are.equal(3, posts)
            assert.are.equal(3, deposits)
        end)

        it("writes only the stacks that the client created", function()
            calls("PostItem", 0, 3, 24, 20, nil, 800, 11, nil, 3)
            bus:Emit("AUCTION_HOUSE_AUCTION_CREATED", 1)
            bus:Emit("AUCTION_HOUSE_AUCTION_CREATED", 2)
            local posts = 0
            for _, record in ipairs(records) do
                if record.source == "ahPost" and record.item == "e:bag0.3" then
                    posts = posts + 1
                end
            end
            assert.are.equal(2, posts)
        end)

        it("replaces the stack hints by the confirm call", function()
            calls("PostItem", 0, 3, 24, 20, nil, 800, 11, nil, 3)
            calls("ConfirmPostItem", 0, 3, 24, 20, nil, 800, 11, nil, 3)
            for id = 1, 3 do
                bus:Emit("AUCTION_HOUSE_AUCTION_CREATED", id)
            end
            local posts = 0
            for _, record in ipairs(records) do
                if record.source == "ahPost" and record.item == "e:bag0.3" then
                    posts = posts + 1
                end
            end
            assert.are.equal(3, posts)
        end)
        it("takes the commodity price as the unit price times the quantity", function()
            calls("PostCommodity", 1, 1, 12, 5, 30)
            bus:Emit("AUCTION_HOUSE_AUCTION_CREATED", 1)
            assert.are.equal("c:bag1.1", last().item)
            assert.are.equal(150, last().buyout)
        end)

        it("uses the deposit money change when it comes before the event", function()
            calls("PostItem", 0, 3, 24, 1, nil, 800)
            change(-41)
            assert.are.equal(1, #records)
            assert.are.equal("ahDeposit", last().source)
            assert.are.equal(41, last().money)
            bus:Emit("AUCTION_HOUSE_AUCTION_CREATED", 321)
            assert.are.equal(2, #records)
            assert.are.equal("ahPost", last().source)
            assert.are.equal(records[1].ctx, last().ctx)
        end)

        it("replaces the post call by the confirm call", function()
            calls("PostItem", 0, 3, 24, 2, nil, 800)
            calls("ConfirmPostItem", 0, 3, 24, 2, nil, 800)
            bus:Emit("AUCTION_HOUSE_AUCTION_CREATED", 321)
            change(-40)
            assert.are.equal(2, #records)
        end)

        it("reads a post from another tab with the auction data", function()
            bus:Emit("AUCTION_HOUSE_AUCTION_CREATED", 7)
            assert.are.equal("ahPost", last().source)
            assert.are.equal("e:link7", last().item)
            assert.are.equal(500, last().buyout)
            change(-12)
            assert.are.equal("ahDeposit", last().source)
            assert.are.equal(12, last().money)
        end)

        it("ignores a call that has no ledger meaning", function()
            calls("Other")
            change(-5)
            advance(M.QUEST_WINDOW_SECONDS)
            assert.are.equal("unknown", last().source)
        end)
    end)

    describe("claims", function()
        it("writes no record for a change that another module claimed", function()
            bus:Emit("MAIL_SHOW")
            assert.is_true(tracker:Claim(300, "in"))
            change(300)
            assert.are.equal(0, #records)
            assert.are.equal(1, tracker:Stats().claimed)
            change(300)
            assert.are.equal(1, #records)
        end)

        it("keeps a claim of the other direction", function()
            tracker:Claim(300, "out")
            change(300)
            advance(M.QUEST_WINDOW_SECONDS)
            assert.are.equal(1, #records)
        end)

        it("drops a claim after the claim time", function()
            tracker:Claim(300, "in")
            advance(M.CLAIM_SECONDS + 1)
            bus:Emit("MAIL_SHOW")
            change(300)
            assert.are.equal(1, #records)
        end)

        it("refuses a bad claim", function()
            assert.is_false(tracker:Claim(0, "in"))
            assert.is_false(tracker:Claim(5, "sideways"))
        end)

        it("lets a claim last for the seconds that the caller gives", function()
            tracker:Claim(300, "out", 30)
            advance(M.CLAIM_SECONDS + 1)
            bus:Emit("MAIL_SHOW")
            change(-300)
            assert.are.equal(0, #records)
        end)

        describe("groups", function()
            before_each(function()
                bus:Emit("MAIL_SHOW")
            end)

            it("claims the total change of the parts", function()
                assert.is_not_nil(tracker:ClaimGroup({ 30, 500 }, "out"))
                change(-530)
                assert.are.equal(0, #records)
                -- The parts end with the total.
                change(-30)
                change(-500)
                assert.are.equal(2, #records)
            end)

            it("claims each part and then ends the total", function()
                tracker:ClaimGroup({ 30, 500 }, "out")
                change(-30)
                change(-500)
                assert.are.equal(0, #records)
                change(-530)
                assert.are.equal(1, #records)
            end)

            it("claims a group of one amount without a total", function()
                tracker:ClaimGroup({ 30, 0 }, "out")
                change(-30)
                assert.are.equal(0, #records)
            end)

            it("gives no handle for nothing to claim", function()
                assert.is_nil(tracker:ClaimGroup({ 0 }, "out"))
                assert.is_nil(tracker:ClaimGroup({ 5 }, "sideways"))
            end)

            it("releases the claims of a group", function()
                local group = tracker:ClaimGroup({ 30, 500 }, "out")
                tracker:Claim(30, "out")
                tracker:ReleaseClaims(group)
                change(-500)
                assert.are.equal(1, #records)
                change(-30)
                assert.are.equal(1, #records)
            end)
        end)
    end)

    describe("secret values", function()
        it("skips the change when the money value is secret", function()
            secrets[money + 10] = true
            bus:Emit("MERCHANT_SHOW")
            change(10)
            assert.are.equal(0, #records)
            assert.are.equal(1, tracker:Stats().skipped)
            change(5)
            assert.are.equal(0, #records)
        end)

        it("skips a quest reward that is secret", function()
            secrets[250] = true
            bus:Emit("QUEST_TURNED_IN", 1, 1, 250)
            assert.are.equal(1, tracker:Stats().skipped)
        end)

        it("skips a purchase event with a secret payload", function()
            secrets[44] = true
            bus:Emit("AUCTION_HOUSE_PURCHASE_COMPLETED", 44)
            assert.are.equal(1, tracker:Stats().skipped)
        end)

        it("works when the client has no secret check", function()
            tracker = attach({ isSecret = false })
            bus:Emit("MERCHANT_SHOW")
            change(5)
            assert.are.equal(1, #records)
        end)
    end)

    describe("rejected records", function()
        it("counts a record that the buffer rejects and reports once", function()
            local rejecting = attach({
                buffer = {
                    Add = function()
                        return false, "nope"
                    end,
                },
            })
            bus:Emit("MERCHANT_SHOW")
            change(5)
            change(5)
            assert.are.equal(2, rejecting:Stats().rejected)
            assert.are.equal(1, #reports)
        end)

        it("skips a record when the character is not known", function()
            tracker = attach({
                character = function()
                    return nil
                end,
            })
            bus:Emit("MERCHANT_SHOW")
            change(5)
            assert.are.equal(0, #records)
            assert.is_true(tracker:Stats().skipped >= 1)
        end)
    end)

    describe("the debug ring", function()
        it("stays empty while the setting is off", function()
            bus:Emit("MERCHANT_SHOW")
            change(5)
            assert.are.same({}, tracker:DebugLines(30))
        end)

        it("keeps the event order with times when the setting is on", function()
            settings["ledger.debug"] = true
            bus:Emit("LOOT_OPENED")
            clock = clock + 0.5
            change(5)
            local lines = tracker:DebugLines(30)
            assert.are.equal("100.000 LOOT_OPENED", lines[1])
            assert.are.equal("100.500 PLAYER_MONEY", lines[2])
            assert.is_truthy(lines[3]:find("delta 5", 1, true))
            assert.is_truthy(lines[4]:find("record loot loot 5", 1, true))
        end)

        it("keeps only the last 200 entries", function()
            settings["ledger.debug"] = true
            for i = 1, 250 do
                clock = clock + 1
                bus:Emit("MERCHANT_SHOW")
                money = money + i
            end
            local lines = tracker:DebugLines(1000)
            assert.are.equal(M.RING_SIZE, #lines)
            assert.are.equal(M.RING_SIZE, #tracker:DebugLines())
            local first = tracker:DebugLines()[1]
            assert.is_truthy(first:find("151.000", 1, true))
            assert.are.equal(30, #tracker:DebugLines(30))
        end)

        it("does not print a secret value", function()
            settings["ledger.debug"] = true
            secrets[44] = true
            bus:Emit("AUCTION_HOUSE_PURCHASE_COMPLETED", 44)
            local text = table.concat(tracker:DebugLines(30), "\n")
            assert.is_truthy(text:find("<secret>", 1, true))
            assert.is_nil(text:find("44", 1, true))
        end)
    end)

    describe("events", function()
        it("registers no restricted event and only known events", function()
            local known = {
                PLAYER_MONEY = true, MERCHANT_SHOW = true, MERCHANT_CLOSED = true, LOOT_OPENED = true,
                LOOT_CLOSED = true, TRADE_SHOW = true, TRADE_CLOSED = true, MAIL_SHOW = true, MAIL_CLOSED = true,
                QUEST_TURNED_IN = true, AUCTION_HOUSE_SHOW = true, AUCTION_HOUSE_CLOSED = true,
                AUCTION_HOUSE_PURCHASE_COMPLETED = true, COMMODITY_PURCHASE_SUCCEEDED = true,
                COMMODITY_PURCHASED = true, AUCTION_HOUSE_AUCTION_CREATED = true,
            }
            assert.is_true(#subscribed > 0)
            for _, event in ipairs(subscribed) do
                assert.is_nil(M.RESTRICTED[event], event)
                assert.is_nil(({ COMBAT_LOG_EVENT_UNFILTERED = true })[event], event)
                assert.is_true(known[event], "unexpected event " .. event)
            end
            assert.is_true(M.RESTRICTED.COMBAT_LOG_EVENT_UNFILTERED)
        end)

        it("refuses to subscribe to a restricted event", function()
            local original = M.RESTRICTED
            M.RESTRICTED = { MAIL_SHOW = true }
            assert.has_error(function()
                attach()
            end)
            M.RESTRICTED = original
        end)

        it("registers only the events that the client gives on a client without the Forever AH events", function()
            subscribed = {}
            bus = ns.EventBus.New({
                onFirstSubscriber = function(event)
                    subscribed[#subscribed + 1] = event
                end,
            })
            attach({
                client = {
                    OpenEvent = function()
                        return "AUCTION_HOUSE_SHOW"
                    end,
                    CloseEvent = function()
                        return "AUCTION_HOUSE_CLOSED"
                    end,
                },
                commodityMarket = false,
            })
            local set = {}
            for _, event in ipairs(subscribed) do
                set[event] = true
            end
            assert.is_true(set.AUCTION_HOUSE_SHOW)
            assert.is_nil(set.COMMODITY_PURCHASED)
            assert.is_nil(set.COMMODITY_PURCHASE_SUCCEEDED)
            assert.is_nil(set.AUCTION_HOUSE_AUCTION_CREATED)
        end)

        it("works with no client", function()
            attach({ client = false })
        end)
    end)
end)
