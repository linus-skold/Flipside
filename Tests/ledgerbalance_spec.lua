local manifest = require("Tests.manifest")

local DAY = 86400
local NOW = 400 * DAY + 7200
local ME, ALT = "Me-Realm", "Alt-Realm"

local function load()
    local ns = {}
    for _, name in ipairs({ "LedgerRecord", "LedgerStore", "LedgerBalance" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

describe("LedgerBalance", function()
    local ns, LB

    -- records and sums: char -> list. Returns a real store.
    local function newStore(records, sums)
        local saved = { records = { EU = { standard = records or {} } }, sums = { EU = { standard = sums or {} } } }
        return ns.LedgerStore.New(saved, { region = "EU", ruleset = "standard" })
    end

    local function rec(time, kind, source, money, char)
        return { time = time, char = char or ME, type = kind, source = source, money = money, item = "", qty = 0 }
    end

    local function ys(series)
        local out = {}
        for _, point in ipairs(series.points) do
            out[#out + 1] = point.y
        end
        return out
    end

    before_each(function()
        ns = load()
        LB = ns.LedgerBalance
    end)

    describe("Delta", function()
        it("is plus for money in and minus for money out", function()
            assert.are.equal(500, LB.Delta(rec(1, "sale", "ahSale", 500)))
            assert.are.equal(70, LB.Delta(rec(1, "loot", "loot", 70)))
            assert.are.equal(40, LB.Delta(rec(1, "income", "mailMoney", 40)))
            assert.are.equal(-300, LB.Delta(rec(1, "purchase", "ahPurchase", 300)))
            assert.are.equal(-25, LB.Delta(rec(1, "expense", "repair", 25)))
        end)

        it("counts a record with the source unknown", function()
            assert.are.equal(15, LB.Delta(rec(1, "income", "unknown", 15)))
            assert.are.equal(-15, LB.Delta(rec(1, "expense", "unknown", 15)))
        end)

        it("is 0 for a record without a money flow", function()
            assert.are.equal(0, LB.Delta(rec(1, "post", "ahPost", 0)))
            assert.are.equal(0, LB.Delta(rec(1, "expired", "ahExpired", 0)))
            assert.are.equal(0, LB.Delta({ time = 1, char = ME, type = "log", money = 99 }))
        end)

        it("gives the net of a daily sum", function()
            assert.are.equal(-30, LB.SumDelta({ moneyIn = 20, moneyOut = 50 }))
        end)
    end)

    describe("Curve", function()
        it("walks back from a live anchor", function()
            local events = { { time = 10, delta = 100 }, { time = 20, delta = -30 } }
            local curve = LB.Curve(events, { copper = 1000, time = 30 })
            assert.are.equal(1000, curve(30))
            assert.are.equal(1000, curve(20))
            assert.are.equal(1030, curve(19))
            assert.are.equal(930, curve(9))
        end)

        it("walks forward from an old anchor", function()
            local events = { { time = 10, delta = 100 }, { time = 20, delta = -30 } }
            local curve = LB.Curve(events, { copper = 500, time = 10 })
            assert.are.equal(500, curve(10))
            assert.are.equal(470, curve(20))
            assert.are.equal(400, curve(9))
        end)

        it("never goes below 0", function()
            local curve = LB.Curve({ { time = 10, delta = 500 } }, { copper = 100, time = 20 })
            assert.are.equal(0, curve(9))
        end)
    end)

    describe("Series", function()
        local function args(store, extra)
            local a = {
                store = store, characters = { ME }, live = { char = ME, copper = 5000 }, now = NOW,
                rangeKey = "7", rangeStart = 394 * DAY,
            }
            for k, v in pairs(extra or {}) do
                a[k] = v
            end
            return a
        end

        local function myStore()
            return newStore({ [ME] = {
                rec(NOW - 3600, "income", "quest", 1000),
                rec(NOW - DAY, "expense", "unknown", 300),
                rec(NOW - 2 * DAY, "sale", "ahSale", 500),
                rec(NOW - 2 * DAY, "post", "ahPost", 0),
            } })
        end

        it("gives one point for each day, the last one equal to the live money", function()
            local series = LB.Series(args(myStore()))
            assert.are.equal("days", series.mode)
            assert.are.same({ 3800, 3800, 3800, 3800, 4300, 4000, 5000 }, ys(series))
            assert.are.equal(394 * DAY, series.points[1].x)
            assert.are.equal(400 * DAY, series.points[7].x)
            assert.are.equal(400, series.points[7].day)
        end)

        it("includes records with the source unknown", function()
            local store = newStore({ [ME] = { rec(NOW - 100, "expense", "unknown", 200) } })
            local series = LB.Series(args(store, { rangeKey = "today", rangeStart = 400 * DAY }))
            assert.are.same({ 5200, 5000, 5000 }, ys(series))
        end)

        it("uses the daily sums for old days", function()
            local store = newStore({ [ME] = { rec(NOW - 3600, "income", "quest", 1000) } }, {
                [ME] = {
                    { day = 397, source = "ahSale", item = "", count = 2, qty = 0, moneyIn = 700, moneyOut = 100 },
                },
            })
            local series = LB.Series(args(store))
            assert.are.same({ 3400, 3400, 3400, 4000, 4000, 4000, 5000 }, ys(series))
        end)

        it("uses the records that are still in the buffer", function()
            local store = newStore({ [ME] = {} })
            local series = LB.Series(args(store, { buffered = { rec(NOW - 60, "income", "loot", 40) } }))
            assert.are.equal(4960, series.points[6].y)
            assert.are.equal(5000, series.points[7].y)
        end)

        it("gives a point for each record for Today, from the start of the day to now", function()
            local store = newStore({ [ME] = {
                rec(400 * DAY + 100, "income", "loot", 50),
                rec(400 * DAY + 200, "expense", "repair", 20),
                rec(399 * DAY + 100, "expense", "repair", 7),
            } })
            local series = LB.Series(args(store, { rangeKey = "today", rangeStart = 400 * DAY }))
            assert.are.equal("records", series.mode)
            assert.are.same({ 4970, 5020, 5000, 5000 }, ys(series))
            assert.are.equal(400 * DAY, series.points[1].x)
            assert.are.equal(NOW, series.points[4].x)
            assert.is_nil(series.points[1].day)
        end)

        it("keeps one point for records at the same second", function()
            local store = newStore({ [ME] = {
                rec(400 * DAY + 100, "income", "loot", 50),
                rec(400 * DAY + 100, "income", "loot", 25),
            } })
            local series = LB.Series(args(store, { rangeKey = "today", rangeStart = 400 * DAY }))
            assert.are.same({ 4925, 5000, 5000 }, ys(series))
        end)

        it("starts \"All\" at the first day with money", function()
            local store = newStore({ [ME] = { rec(395 * DAY + 5, "income", "loot", 100) } })
            local series = LB.Series(args(store, { rangeKey = "all", rangeStart = false }))
            assert.are.equal(6, #series.points)
            assert.are.equal(395 * DAY, series.points[1].x)
            assert.are.equal(5000, series.points[1].y)
        end)

        it("gives one point at the live balance if there are no records", function()
            local series = LB.Series(args(newStore({}), { rangeKey = "all", rangeStart = false }))
            assert.are.same({ 5000 }, ys(series))
        end)

        it("thins a long series", function()
            local store = newStore({ [ME] = { rec(NOW - 700 * DAY + 5, "income", "loot", 100) } })
            local series = LB.Series(args(store, { rangeKey = "all", rangeStart = false }))
            assert.are.equal(LB.MAX_POINTS, #series.points)
            assert.are.equal(5000, series.points[#series.points].y)
        end)

        describe("anchors", function()
            local store
            before_each(function()
                store = newStore({
                    [ME] = { rec(NOW - DAY, "income", "loot", 300) },
                    [ALT] = { rec(NOW - 2 * DAY, "sale", "ahSale", 1000, ALT) },
                })
            end)

            it("uses the saved balance of another character", function()
                local series = LB.Series(args(store, {
                    characters = { ALT }, live = { char = ME, copper = 5000 },
                    snapshot = function(name)
                        return name == ALT and { copper = 2000, time = NOW - 100 } or nil
                    end,
                }))
                assert.are.same({ 1000, 1000, 1000, 1000, 2000, 2000, 2000 }, ys(series))
                assert.are.same({ ALT }, series.included)
            end)

            it("leaves out a character that has no balance and lists it", function()
                local series = LB.Series(args(store, { characters = { ALT }, snapshot = function() end }))
                assert.are.same({}, series.points)
                assert.are.same({ ALT }, series.omitted)
            end)

            it("adds the characters for \"All\"", function()
                local series = LB.Series(args(store, {
                    characters = { ALT, ME },
                    snapshot = function(name)
                        return name == ALT and { copper = 2000, time = NOW - 100 } or nil
                    end,
                }))
                assert.are.same({ 5700, 5700, 5700, 5700, 6700, 7000, 7000 }, ys(series))
                assert.are.same({}, series.omitted)
            end)

            it("leaves out only the character without a balance for \"All\"", function()
                local series = LB.Series(args(store, { characters = { ALT, ME }, snapshot = function() end }))
                assert.are.same({ 4700, 4700, 4700, 4700, 4700, 5000, 5000 }, ys(series))
                assert.are.same({ ALT }, series.omitted)
                assert.are.same({ ME }, series.included)
            end)

            it("uses the saved balance of the current character if there is no live money", function()
                local series = LB.Series(args(store, {
                    live = false,
                    snapshot = function()
                        return { copper = 4000, time = NOW - 2 * DAY }
                    end,
                }))
                -- The loot of 300 came after the snapshot.
                assert.are.equal(4300, series.points[7].y)
            end)
        end)
    end)

    describe("snapshot", function()
        local function fakeDb()
            local data = {}
            return {
                Set = function(_, scope, key, value)
                    data[scope .. key] = value
                    return true
                end,
                GetFor = function(_, character, key)
                    return data["character" .. key] and character == ME and data["character" .. key] or nil
                end,
            }
        end

        it("saves and reads a balance", function()
            local db = fakeDb()
            assert.is_true(LB.WriteSnapshot(db, 1234, NOW))
            assert.are.same({ copper = 1234, time = NOW }, LB.ReadSnapshot(db, ME))
            assert.is_nil(LB.ReadSnapshot(db, ALT))
        end)

        it("saves nothing for a bad value", function()
            local db = fakeDb()
            assert.is_false(LB.WriteSnapshot(db, nil, NOW))
            assert.is_false(LB.WriteSnapshot(db, "x", NOW))
            assert.is_false(LB.WriteSnapshot(db, -1, NOW))
            assert.is_nil(LB.ReadSnapshot(db, ME))
        end)
    end)

    describe("MoneyScale", function()
        it("starts at 0 and has a clean maximum above the value", function()
            local scale = LB.MoneyScale(12345678)
            assert.are.equal(0, scale.ticks[1])
            assert.is_true(scale.max >= 12345678)
            assert.are.equal(scale.max, scale.ticks[#scale.ticks])
            assert.are.equal("g", scale.unit)
        end)

        it("gives 3 to 5 labels and a maximum of at most the next clean step", function()
            for _, value in ipairs({ 0, 1, 2, 3, 7, 99, 100, 199, 200, 450, 999, 1234, 19999, 20000, 33333, 100000,
                987654, 5000000, 123456789 }) do
                local scale = LB.MoneyScale(value)
                assert.is_true(#scale.ticks >= 3 and #scale.ticks <= 5, value)
                assert.is_true(scale.max >= value, value)
                assert.is_true(scale.max < math.max(value, 2) + scale.step, value)
                assert.are.equal(0, scale.ticks[1])
            end
        end)

        it("uses a step of 1, 2 or 5 times a power of 10 in the unit", function()
            for _, value in ipairs({ 50, 640, 7300, 88000, 450000, 12000000 }) do
                local scale = LB.MoneyScale(value)
                local steps = scale.step / scale.unitSize
                while steps >= 10 do
                    steps = steps / 10
                end
                assert.is_true(steps == 1 or steps == 2 or steps == 5, value)
            end
        end)

        it("switches the unit from copper to silver to gold", function()
            assert.are.equal("c", LB.MoneyScale(0).unit)
            assert.are.equal("c", LB.MoneyScale(199).unit)
            assert.are.equal("s", LB.MoneyScale(200).unit)
            assert.are.equal("s", LB.MoneyScale(19999).unit)
            assert.are.equal("g", LB.MoneyScale(20000).unit)
        end)

        it("gives known scales", function()
            assert.are.same({ 0, 50, 100, 150, 200 }, LB.MoneyScale(199).ticks)
            assert.are.same({ 0, 100, 200 }, LB.MoneyScale(200).ticks)
            assert.are.same({ 0, 20000, 40000, 60000 }, LB.MoneyScale(50000).ticks)
            assert.are.same({ 0, 1, 2 }, LB.MoneyScale(0).ticks)
        end)
    end)

    describe("labels", function()
        local function money(copper)
            return copper .. "c"
        end

        it("shows the UTC day for day points and the local time for record points", function()
            assert.are.equal("1970-01-02", LB.AxisText(DAY, "days", os.date))
            assert.are.equal(os.date("%H:%M", 5000), LB.AxisText(5000, "records", os.date))
        end)

        it("gives the date and the balance for the hover", function()
            local lines = LB.HoverLines({ x = 400 * DAY, y = 1234 }, "days", os.date, money)
            assert.are.same({ os.date("!%Y-%m-%d", 400 * DAY), "Balance: 1234c" }, lines)
            lines = LB.HoverLines({ x = NOW, y = 9 }, "records", os.date, money)
            assert.are.same({ os.date("%Y-%m-%d %H:%M", NOW), "Balance: 9c" }, lines)
        end)
    end)
end)
