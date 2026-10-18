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
            assert.are.same({ "trade", "loot", "ah", "merchant", "mail", "taxi", "trainer", "stable", "bank",
                "guildbank", "barber" }, M.PRIORITY)
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

        it("takes the item and the quantity of a buy in Blizzard's own tab from the bid hook", function()
            tracker:OnBid(9)
            change(-500)
            bus:Emit("AUCTION_HOUSE_PURCHASE_COMPLETED", 9)
            assert.are.equal(1, #records)
            assert.are.equal("ahPurchase", last().source)
            assert.are.equal("e:link9", last().item)
            assert.are.equal(3, last().qty)
            assert.are.equal(500, last().money)
        end)

        it("writes one record for a buy of the Buying tab when the call and the bid hook both come", function()
            calls("BuyItemAuction", 9, 500)
            tracker:OnBid(9)
            change(-500)
            bus:Emit("AUCTION_HOUSE_PURCHASE_COMPLETED", 9)
            tracker:OnBid(9)
            advance(M.HINT_SECONDS + 1)
            assert.are.equal(1, #records)
            assert.are.equal("e:link9", last().item)
        end)

        it("writes the record of the hook buy when the money change comes first", function()
            change(-500)
            assert.are.equal(0, #records)
            tracker:OnBid(9)
            assert.are.equal(1, #records)
            assert.are.equal("e:link9", last().item)
        end)

        it("gives two bids in a row two records", function()
            tracker:OnBid(9)
            change(-500)
            tracker:OnBid(9)
            change(-700)
            assert.are.equal(2, #records)
            assert.are.equal(700, records[2].money)
            assert.are.equal("e:link9", records[2].item)
        end)

        it("does not fail when the bid hook finds no auction data or a secret ID", function()
            secrets[77] = true
            tracker:OnBid(77)
            tracker:OnBid(nil)
            tracker:OnBid("x")
            assert.are.equal(3, tracker:Stats().skipped)
            change(-500)
            advance(M.QUEST_WINDOW_SECONDS)
            assert.are.equal(1, #records)
            assert.are.equal("unknown", last().source)
        end)

        describe("with an owner in the auction data (the seller)", function()
            local info

            before_each(function()
                info = { itemLink = "link9", quantity = 3, owner = "Poor" }
                bus = ns.EventBus.New({})
                timers = {}
                tracker = attach({
                    auctionInfo = function()
                        return info
                    end,
                })
                bus:Emit("AUCTION_HOUSE_SHOW")
            end)

            it("writes the owner as the counterparty of the bid hook buy", function()
                tracker:OnBid(9)
                change(-500)
                assert.are.equal("Poor", last().counterparty)
                assert.are.equal("e:link9", last().item)
            end)

            it("writes the owner as the counterparty of a buy of the Buying tab", function()
                calls("BuyItemAuction", 9, 500)
                change(-500)
                assert.are.equal("Poor", last().counterparty)
            end)

            it("keeps the owner when the call and the bid hook both come", function()
                info.owner = nil
                calls("BuyItemAuction", 9, 500)
                info.owner = "Poor"
                tracker:OnBid(9)
                change(-500)
                assert.are.equal(1, #records)
                assert.are.equal("Poor", last().counterparty)
            end)

            it("writes no counterparty when the data has no owner", function()
                info.owner = nil
                tracker:OnBid(9)
                change(-500)
                assert.is_nil(last().counterparty)
            end)

            it("writes no counterparty for a secret owner or an empty owner", function()
                secrets.Poor = true
                tracker:OnBid(9)
                change(-500)
                assert.is_nil(last().counterparty)
                info.owner = ""
                tracker:OnBid(9)
                change(-500)
                assert.is_nil(last().counterparty)
            end)

            it("writes no counterparty for a post deposit", function()
                calls("PostItem", 0, 1, 2, 5, 100, 200)
                change(-40)
                assert.are.equal("ahDeposit", last().source)
                assert.is_nil(last().counterparty)
            end)
        end)

        describe("with Forever auction data (no quantity, a nilable link)", function()
            local info

            before_each(function()
                info = { itemKey = { itemID = 4306 }, itemLink = nil, buyoutAmount = 500 }
                bus = ns.EventBus.New({})
                timers = {}
                tracker = attach({
                    auctionInfo = function()
                        return info
                    end,
                })
                bus:Emit("AUCTION_HOUSE_SHOW")
            end)

            it("takes the item from the item key and one item as the quantity", function()
                tracker:OnBid(5)
                change(-500)
                assert.are.equal("e:4306", last().item)
                assert.are.equal(1, last().qty)
            end)

            it("takes the item from the link when the link exists", function()
                info.itemLink = "linkX"
                tracker:OnBid(5)
                change(-500)
                assert.are.equal("e:linkX", last().item)
            end)

            it("writes a purchase with no item when the auction is gone", function()
                info = nil
                tracker:OnBid(5)
                change(-500)
                assert.are.equal("ahPurchase", last().source)
                assert.is_nil(last().item)
            end)
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

    describe("service contexts", function()
        local cases = {
            { "TRAINER_SHOW", "TRAINER_CLOSED", -50, "training", "expense" },
            { "PET_STABLE_SHOW", "PET_STABLE_CLOSED", -50, "stable", "expense" },
            { "BANKFRAME_OPENED", "BANKFRAME_CLOSED", -50, "bankSlot", "expense" },
            { "BARBER_SHOP_OPEN", "BARBER_SHOP_CLOSE", -50, "barber", "expense" },
            { "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED", -50, "guildBank", "expense" },
            { "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED", 50, "guildBank", "income" },
            { "TAXIMAP_OPENED", "TAXIMAP_CLOSED", -50, "flight", "expense" },
            { "TRAINER_SHOW", "TRAINER_CLOSED", 50, "unknown", "income" },
            { "TAXIMAP_OPENED", "TAXIMAP_CLOSED", 50, "unknown", "income" },
        }
        for _, case in ipairs(cases) do
            it(string.format("%s with %d gives %s", case[1], case[3], case[4]), function()
                bus:Emit(case[1])
                change(case[3])
                advance(M.QUEST_WINDOW_SECONDS)
                assert.are.equal(1, #records)
                assert.are.equal(case[4], last().source)
                assert.are.equal(case[5], last().type)
                assert.are.equal(math.abs(case[3]), last().money)
            end)
        end

        it("gives the records of one window the same context", function()
            bus:Emit("TRAINER_SHOW")
            change(-10)
            change(-20)
            assert.are.equal(records[1].ctx, records[2].ctx)
        end)

        it("gives unknown after the window closes", function()
            bus:Emit("TRAINER_SHOW")
            bus:Emit("TRAINER_CLOSED")
            change(-50)
            assert.are.equal("unknown", last().source)
        end)
    end)

    describe("flight path", function()
        local nodes

        before_each(function()
            nodes = {
                { name = "Orgrimmar, Durotar", cost = 1200 },
                { name = "Crossroads, The Barrens", cost = 300 },
                { name = "Sen'jin Village, Durotar", cost = 300 },
            }
            bus = ns.EventBus.New({})
            timers = {}
            tracker = attach({
                taxiNodes = function()
                    return nodes
                end,
            })
        end)

        it("labels a spend after the map closes as a flight with the destination", function()
            bus:Emit("TAXIMAP_OPENED")
            bus:Emit("TAXIMAP_CLOSED")
            clock = clock + 1
            change(-1200)
            assert.are.equal("flight", last().source)
            assert.are.equal("Orgrimmar, Durotar", last().place)
        end)

        it("labels a spend while the map is open", function()
            bus:Emit("TAXIMAP_OPENED")
            change(-1200)
            assert.are.equal("flight", last().source)
            assert.are.equal("Orgrimmar, Durotar", last().place)
        end)

        it("leaves the destination out when two nodes have the cost", function()
            bus:Emit("TAXIMAP_OPENED")
            bus:Emit("TAXIMAP_CLOSED")
            change(-300)
            assert.are.equal("flight", last().source)
            assert.is_nil(last().place)
        end)

        it("leaves the destination out when no node has the cost", function()
            bus:Emit("TAXIMAP_OPENED")
            change(-777)
            assert.are.equal("flight", last().source)
            assert.is_nil(last().place)
        end)

        it("gives unknown after the tail ends", function()
            bus:Emit("TAXIMAP_OPENED")
            bus:Emit("TAXIMAP_CLOSED")
            clock = clock + M.TAXI_TAIL_SECONDS + 1
            change(-1200)
            assert.are.equal("unknown", last().source)
        end)

        it("still labels a flight when the node read fails", function()
            tracker = attach({
                taxiNodes = function()
                    error("no taxi data")
                end,
            })
            bus:Emit("TAXIMAP_OPENED")
            change(-300)
            assert.are.equal("flight", last().source)
            assert.is_nil(last().place)
        end)

        it("labels a flight when the client has no node read", function()
            tracker = attach()
            bus:Emit("TAXIMAP_OPENED")
            change(-300)
            assert.are.equal("flight", last().source)
        end)
    end)

    describe("talent reset", function()
        it("labels a spend of the confirmed cost", function()
            bus:Emit("CONFIRM_TALENT_WIPE", 50000, 1)
            clock = clock + 20
            change(-50000)
            assert.are.equal("talentReset", last().source)
            assert.are.equal("expense", last().type)
            assert.are.equal(50000, last().money)
        end)

        it("labels the spend once", function()
            bus:Emit("CONFIRM_TALENT_WIPE", 50000, 1)
            change(-50000)
            change(-50000)
            assert.are.equal("unknown", last().source)
        end)

        it("does not label a spend of another amount", function()
            bus:Emit("CONFIRM_TALENT_WIPE", 50000, 1)
            change(-40)
            assert.are.equal("unknown", last().source)
        end)

        it("does not label a spend after the wait ends", function()
            bus:Emit("CONFIRM_TALENT_WIPE", 50000, 1)
            clock = clock + M.WIPE_SECONDS + 1
            change(-50000)
            assert.are.equal("unknown", last().source)
        end)

        it("skips a secret cost and a cost of zero", function()
            secrets[50000] = true
            bus:Emit("CONFIRM_TALENT_WIPE", 50000, 1)
            bus:Emit("CONFIRM_TALENT_WIPE", 0, 1)
            change(-50000)
            assert.are.equal("unknown", last().source)
            assert.are.equal(1, tracker:Stats().skipped)
        end)
    end)

    describe("trade partner", function()
        it("writes the partner as the counterparty of a trade", function()
            tracker = attach({
                tradePartner = function()
                    return "Bob-Realm"
                end,
            })
            bus:Emit("TRADE_SHOW")
            change(-50)
            assert.are.equal("trade", last().source)
            assert.are.equal("Bob-Realm", last().counterparty)
            change(70)
            assert.are.equal("Bob-Realm", last().counterparty)
        end)

        it("writes no counterparty when the partner is not readable", function()
            tracker = attach({
                tradePartner = function()
                    error("no unit")
                end,
            })
            bus:Emit("TRADE_SHOW")
            change(-50)
            assert.are.equal("trade", last().source)
            assert.is_nil(last().counterparty)
        end)

        it("ends the partner with the window", function()
            tracker = attach({
                tradePartner = function()
                    return "Bob"
                end,
            })
            bus:Emit("TRADE_SHOW")
            bus:Emit("TRADE_CLOSED")
            bus:Emit("TRADE_SHOW")
            change(-5)
            assert.are.equal("Bob", last().counterparty)
            bus:Emit("TRADE_CLOSED")
            change(-5)
            assert.are.equal("unknown", last().source)
            assert.is_nil(last().counterparty)
        end)
    end)

    describe("events", function()
        it("registers no restricted event and only known events", function()
            local known = {
                PLAYER_MONEY = true, MERCHANT_SHOW = true, MERCHANT_CLOSED = true, LOOT_OPENED = true,
                LOOT_CLOSED = true, TRADE_SHOW = true, TRADE_CLOSED = true, MAIL_SHOW = true, MAIL_CLOSED = true,
                QUEST_TURNED_IN = true, AUCTION_HOUSE_SHOW = true, AUCTION_HOUSE_CLOSED = true,
                AUCTION_HOUSE_PURCHASE_COMPLETED = true, COMMODITY_PURCHASE_SUCCEEDED = true,
                COMMODITY_PURCHASED = true, AUCTION_HOUSE_AUCTION_CREATED = true, CONFIRM_TALENT_WIPE = true,
                TAXIMAP_OPENED = true, TAXIMAP_CLOSED = true, TRAINER_SHOW = true, TRAINER_CLOSED = true,
                PET_STABLE_SHOW = true, PET_STABLE_CLOSED = true, BANKFRAME_OPENED = true, BANKFRAME_CLOSED = true,
                GUILDBANKFRAME_OPENED = true, GUILDBANKFRAME_CLOSED = true, BARBER_SHOP_OPEN = true,
                BARBER_SHOP_CLOSE = true,
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
