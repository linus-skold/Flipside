local manifest = require("Tests.manifest")

local DAY = 86400
local NOW = 400 * DAY + 7200
local ME, ALT, OTHER = "Me-Realm", "Alt-Realm", "Far-Other"
local GEAR = "5|1:100"
local PLAIN = "100"

describe("LedgerItemTotal", function()
    local ns

    before_each(function()
        ns = {}
        for _, name in ipairs({ "LedgerRecord", "LedgerStore", "LedgerItemTotal" }) do
            assert(loadfile(manifest.path(name)))("Flipside", ns)
        end
    end)

    local function rec(fields)
        fields.char = fields.char or ME
        fields.time = fields.time or NOW - 60
        return fields
    end

    describe("Compute", function()
        it("counts a sale with its cut and shows the cut without a second subtraction", function()
            local total = ns.LedgerItemTotal.Compute({
                rec({ type = "sale", source = "ahSale", item = PLAIN, qty = 2, money = 950, cut = 50, deposit = 10 }),
            }, nil, PLAIN)
            assert.are.equal(2, total.soldQty)
            assert.are.equal(950, total.soldMoney)
            assert.are.equal(50, total.cut)
            assert.are.equal(950, total.net)
        end)

        it("subtracts a purchase", function()
            local total = ns.LedgerItemTotal.Compute({
                rec({ type = "sale", source = "ahSale", item = PLAIN, qty = 1, money = 1000 }),
                rec({ type = "purchase", source = "ahPurchase", item = PLAIN, qty = 3, money = 400 }),
            }, nil, PLAIN)
            assert.are.equal(3, total.boughtQty)
            assert.are.equal(400, total.boughtMoney)
            assert.are.equal(600, total.net)
        end)

        it("counts the deposit once, from the deposit expense and not from the post record", function()
            local total = ns.LedgerItemTotal.Compute({
                rec({ type = "post", source = "ahPost", item = PLAIN, qty = 1, buyout = 9000, deposit = 50 }),
                rec({ type = "expense", source = "ahDeposit", item = PLAIN, qty = 1, money = 50 }),
            }, nil, PLAIN)
            assert.are.equal(0, total.deposits)
            assert.are.equal(50, total.activeDeposits)
            assert.are.equal(-50, total.net)
        end)

        describe("outcomes", function()
            local function post(time, qty, deposit)
                return rec({ type = "post", source = "ahPost", item = PLAIN, qty = qty, deposit = deposit,
                    time = time })
            end
            local function paid(time, money)
                return rec({ type = "expense", source = "ahDeposit", item = PLAIN, qty = 1, money = money,
                    time = time })
            end
            local function compute(records)
                return ns.LedgerItemTotal.Compute(records, nil, PLAIN)
            end

            it("takes the returned deposit out of a sale", function()
                local total = compute({
                    post(100, 1, 50), paid(100, 50),
                    rec({ type = "sale", source = "ahSale", item = PLAIN, qty = 1, money = 940, cut = 110,
                        deposit = 50, bid = 1000, time = 200 }),
                })
                assert.are.equal(890, total.soldMoney)
                assert.are.equal(0, total.deposits)
                assert.are.equal(0, total.activeDeposits)
                assert.are.equal(890, total.net)
                assert.are.equal(1, total.postedQty)
                assert.are.equal(1, total.soldQty)
            end)

            it("counts the deposit of an expired auction as lost", function()
                local total = compute({
                    post(100, 1, 50), paid(100, 50),
                    rec({ type = "expired", source = "ahExpired", item = PLAIN, qty = 1, time = 300 }),
                })
                assert.are.equal(50, total.deposits)
                assert.are.equal(0, total.activeDeposits)
                assert.are.equal(-50, total.net)
                assert.are.equal(1, total.expiredQty)
            end)

            it("counts the deposit of a cancelled auction as lost", function()
                local total = compute({
                    post(100, 2, 80), paid(100, 80),
                    rec({ type = "cancelled", source = "ahCancelled", item = PLAIN, qty = 2, time = 150 }),
                })
                assert.are.equal(80, total.deposits)
                assert.are.equal(2, total.cancelledQty)
                assert.are.equal(-80, total.net)
            end)

            it("keeps the deposit of a repost after an expiry: one lost, one active", function()
                local total = compute({
                    post(100, 1, 50), paid(100, 50),
                    rec({ type = "expired", source = "ahExpired", item = PLAIN, qty = 1, time = 300 }),
                    post(400, 1, 60), paid(400, 60),
                })
                assert.are.equal(2, total.postedQty)
                assert.are.equal(1, total.expiredQty)
                assert.are.equal(50, total.deposits)
                assert.are.equal(60, total.activeDeposits)
                assert.are.equal(-110, total.net)
            end)

            it("shows the deposit of a running auction as active, not lost", function()
                local total = compute({ post(100, 3, 90), paid(100, 90) })
                assert.are.equal(0, total.deposits)
                assert.are.equal(90, total.activeDeposits)
                assert.are.equal(-90, total.net)
            end)

            it("takes only the open units of a part sale", function()
                local total = compute({
                    post(100, 4, 80), paid(100, 80),
                    rec({ type = "sale", source = "ahSale", item = PLAIN, qty = 1, money = 120, deposit = 20,
                        cut = 5, time = 200 }),
                })
                assert.are.equal(60, total.activeDeposits)
                assert.are.equal(0, total.deposits)
                assert.are.equal(100, total.soldMoney)
                assert.are.equal(40, total.net)
            end)

            it("caps the deposit back at the deposit paid in the range (post before the range)", function()
                local total = compute({
                    rec({ type = "sale", source = "ahSale", item = PLAIN, qty = 1, money = 1000, deposit = 50,
                        time = 200 }),
                })
                assert.are.equal(1000, total.soldMoney)
                assert.are.equal(0, total.deposits)
                assert.are.equal(0, total.activeDeposits)
                assert.are.equal(1000, total.net)
                assert.are.equal(0, total.postedQty)
            end)

            it("keeps the net equal to payouts - bought - deposits paid", function()
                local total = compute({
                    post(100, 2, 100), paid(100, 100),
                    rec({ type = "sale", source = "ahSale", item = PLAIN, qty = 1, money = 480, deposit = 50,
                        cut = 20, time = 200 }),
                    rec({ type = "purchase", source = "ahPurchase", item = PLAIN, qty = 1, money = 30, time = 250 }),
                })
                assert.are.equal(480 - 30 - 100, total.net)
            end)

            it("gives nil counts when a record has no quantity, and 0 when no record exists", function()
                local total = compute({
                    rec({ type = "post", source = "ahPost", item = PLAIN, deposit = 10 }),
                    rec({ type = "sale", source = "ahSale", item = PLAIN, money = 5 }),
                })
                assert.is_nil(total.postedQty)
                assert.is_nil(total.soldQty)
                assert.are.equal(0, total.expiredQty)
                assert.are.equal(0, total.cancelledQty)
            end)

            it("keeps the whole payout in Sold if the sale has no deposit field", function()
                local total = compute({
                    paid(100, 50),
                    rec({ type = "sale", source = "ahSale", item = PLAIN, qty = 1, money = 700, time = 200 }),
                })
                assert.are.equal(700, total.soldMoney)
                assert.are.equal(50, total.deposits)
                assert.are.equal(650, total.net)
            end)
        end)

        it("lets a deposit refund and an outbid refund reduce the costs", function()
            local total = ns.LedgerItemTotal.Compute({
                rec({ type = "expense", source = "ahDeposit", item = PLAIN, money = 50 }),
                rec({ type = "income", source = "ahDepositRefund", item = PLAIN, money = 20 }),
                rec({ type = "purchase", source = "ahPurchase", item = PLAIN, qty = 1, money = 300 }),
                rec({ type = "income", source = "ahOutbidRefund", item = PLAIN, money = 300 }),
            }, nil, PLAIN)
            assert.are.equal(30, total.deposits)
            assert.are.equal(0, total.boughtMoney)
            assert.are.equal(-30, total.net)
        end)

        it("gives no money for cancelled, expired, post and log records", function()
            local total = ns.LedgerItemTotal.Compute({
                rec({ type = "cancelled", source = "ahCancelled", item = PLAIN, qty = 1 }),
                rec({ type = "expired", source = "ahExpired", item = PLAIN, qty = 1 }),
                rec({ type = "post", source = "ahPost", item = PLAIN, qty = 1, deposit = 50 }),
                rec({ type = "log", item = PLAIN, qty = 1, money = 99 }),
            }, nil, PLAIN)
            assert.are.equal(0, total.net)
            assert.are.equal(0, total.count)
        end)

        it("matches the exact item key: a gear variant is not the plain item", function()
            local records = {
                rec({ type = "sale", source = "ahSale", item = GEAR, qty = 1, money = 700 }),
                rec({ type = "sale", source = "ahSale", item = PLAIN, qty = 1, money = 100 }),
                rec({ type = "sale", source = "ahSale", item = "200", qty = 1, money = 5 }),
            }
            assert.are.equal(700, ns.LedgerItemTotal.Compute(records, nil, GEAR).net)
            assert.are.equal(100, ns.LedgerItemTotal.Compute(records, nil, PLAIN).net)
        end)

        it("gives an empty total for a missing item key", function()
            local records = { rec({ type = "sale", source = "ahSale", item = PLAIN, money = 5 }) }
            local total = ns.LedgerItemTotal.Compute(records, nil, "")
            assert.are.equal(0, total.net)
        end)

        it("sets hasSums only if daily sums exist", function()
            assert.is_false(ns.LedgerItemTotal.Compute({}, {}, PLAIN).hasSums)
            assert.is_true(ns.LedgerItemTotal.Compute({}, { { day = 1 } }, PLAIN).hasSums)
        end)
    end)

    describe("ForStore", function()
        local store

        before_each(function()
            local saved = {
                records = { EU = { standard = {
                    [ME] = {
                        rec({ type = "sale", source = "ahSale", item = PLAIN, qty = 1, money = 100,
                            time = NOW - 3600 }),
                        rec({ type = "sale", source = "ahSale", item = PLAIN, qty = 1, money = 10,
                            time = NOW - 50 * DAY }),
                    },
                    [ALT] = {
                        rec({ type = "sale", source = "ahSale", item = PLAIN, qty = 1, money = 1000, char = ALT,
                            time = NOW - 3600 }),
                    },
                    [OTHER] = {
                        rec({ type = "sale", source = "ahSale", item = PLAIN, qty = 1, money = 5000, char = OTHER,
                            time = NOW - 3600 }),
                    },
                } } },
                sums = { EU = { standard = {
                    [ME] = {
                        { day = 300, source = "ahSale", item = "", count = 4, qty = 4, moneyIn = 40, moneyOut = 0 },
                    },
                } } },
            }
            store = ns.LedgerStore.New(saved, { region = "EU", ruleset = "standard" })
        end)

        it("filters by character", function()
            local total = ns.LedgerItemTotal.ForStore(store, { char = ME }, PLAIN)
            assert.are.equal(110, total.net)
            assert.are.equal(1000, ns.LedgerItemTotal.ForStore(store, { char = ALT }, PLAIN).net)
        end)

        it("filters by date", function()
            local total = ns.LedgerItemTotal.ForStore(store, { char = ME, fromTime = NOW - 7 * DAY }, PLAIN)
            assert.are.equal(100, total.net)
        end)

        it("counts all characters, or only the characters of one server", function()
            assert.are.equal(6110, ns.LedgerItemTotal.ForStore(store, {}, PLAIN).net)
            local total = ns.LedgerItemTotal.ForStore(store, {}, PLAIN, function(char)
                return char:match("%-(.+)$") == "Realm"
            end)
            assert.are.equal(1110, total.net)
        end)

        it("reports the daily sums of the range and leaves them out of the money", function()
            local total = ns.LedgerItemTotal.ForStore(store, { char = ME }, PLAIN)
            assert.is_true(total.hasSums)
            assert.are.equal(110, total.net)
            local recent = ns.LedgerItemTotal.ForStore(store, { char = ME, fromTime = 350 * DAY }, PLAIN)
            assert.is_false(recent.hasSums)
        end)
    end)
end)
