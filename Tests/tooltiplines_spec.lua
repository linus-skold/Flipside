local manifest = require("Tests.manifest")
describe("TooltipLines", function()
    local ns, TL, run, store, sources, rules, holdings

    local DAY = 86400
    local TODAY = 20000
    local NOW = TODAY * DAY + 3600 * 6

    local function load(path)
        assert(loadfile(path))("Flipside", ns)
    end

    local function makeRecord(ageHours)
        local r = ns.ScanRecord.New()
        r.latest = { time = NOW - ageHours * 3600, min = 900, market = 124000, qty = 40, auctions = 5, partial = false }
        r.days = {
            { day = TODAY - 3, min = 1, market = 124000, qty = 1, scans = 1 },
            { day = TODAY - 1, min = 1, market = 124000, qty = 1, scans = 1 },
        }
        return r
    end

    local function ctx(extra)
        local c = {
            input = "123",
            config = { lines = { { label = "Market", formula = "scanmarket", enabled = true } } },
            formulaRun = run,
            getRecord = function(key)
                return store:Get(key)
            end,
            now = NOW,
        }
        for k, v in pairs(extra or {}) do
            c[k] = v
        end
        return c
    end

    before_each(function()
        ns = {}
        load(manifest.path("ScanClock"))
        load(manifest.path("ScanRecord"))
        load(manifest.path("ScanSources"))
        load(manifest.path("ScanStore"))
        load(manifest.path("ItemString"))
        load(manifest.path("FormulaParse"))
        load(manifest.path("FormulaFunctions"))
        load(manifest.path("FormulaSources"))
        load(manifest.path("FormulaLookup"))
        load(manifest.path("FormulaEval"))
        load(manifest.path("FormulaRun"))
        load(manifest.path("TooltipLines"))
        TL = ns.TooltipLines

        sources = ns.FormulaSources.New({
            itemCache = {
                Get = function()
                    return nil
                end,
                Request = function() end,
            },
        })
        store = ns.ScanStore.New({}, { region = "EU", ruleset = "standard", schemaVersion = 1 })
        store:Put("123", makeRecord(3))
        run = ns.FormulaRun.New({
            store = store,
            sources = sources,
            serverTime = function()
                return NOW
            end,
        })

        local paths = { [1] = { "Base" }, [2] = { "Base", "Herbs" }, [3] = { "Base", "Herbs", "Rare" } }
        rules = {
            GroupOf = function(_, key)
                return key == "123" and 3 or 1
            end,
            Path = function(_, id)
                return paths[id]
            end,
            EffectiveOperation = function(_, _, opType)
                if opType == "selling" then
                    return 7, 2
                end
            end,
            GetOperation = function(_, id)
                return { id = id, name = "Herb sales", type = "selling" }
            end,
        }
        holdings = {
            Count = function()
                return {
                    total = 42,
                    characters = {
                        { name = "Ann-Realm", total = 20, bags = 15, bank = 5, mail = 0, auctions = 0 },
                        { name = "Bob-Realm", total = 22, bags = 0, bank = 0, mail = 0, auctions = 22 },
                    },
                }
            end,
        }
    end)

    describe("FormatMoney", function()
        it("formats copper, silver and gold", function()
            assert.are.equal("0c", TL.FormatMoney(0))
            assert.are.equal("35c", TL.FormatMoney(35))
            assert.are.equal("99c", TL.FormatMoney(99))
            assert.are.equal("1s", TL.FormatMoney(100))
            assert.are.equal("40s", TL.FormatMoney(4000))
            assert.are.equal("1g", TL.FormatMoney(10000))
            assert.are.equal("12g 40s", TL.FormatMoney(124000))
            assert.are.equal("12g 35c", TL.FormatMoney(120035))
            assert.are.equal("12g 40s 7c", TL.FormatMoney(124007))
            assert.are.equal("3s 25c", TL.FormatMoney(25 * 13))
            assert.are.equal("1g 5c", TL.FormatMoney(10005))
            assert.are.equal("1g 1s 1c", TL.FormatMoney(10101))
            assert.are.equal("2c", TL.FormatMoney(1.5))
            assert.are.equal("-3s 25c", TL.FormatMoney(-325))
            assert.are.equal("-1c", TL.FormatMoney(-1))
            assert.are.equal("1,234g 5s", TL.FormatMoney(12340500))
            assert.are.equal("12,345,678g", TL.FormatMoney(123456780000))
        end)
    end)

    describe("FormatMoney with the client formatter", function()
        local saved, colorblind

        local function sep(n)
            local s = tostring(n)
            local prev
            repeat
                prev = s
                s = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
            until s == prev
            return s
        end

        -- Same rules as the client GetMoneyString in Blizzard_SharedXML/FormattingUtil.lua.
        local function fake(money, separate)
            local g, s, c = math.floor(money / 10000), math.floor((money % 10000) / 100), money % 100
            local gt, st, ct
            if colorblind then
                gt, st, ct = (separate and sep(g) or g) .. "g", s .. "s", c .. "c"
            else
                gt = (separate and sep(g) or g) .. "|Gold|"
                st, ct = s .. "|Silver|", c .. "|Copper|"
            end
            local out = {}
            if g > 0 then out[#out + 1] = gt end
            if s > 0 then out[#out + 1] = st end
            if c > 0 or #out == 0 then out[#out + 1] = ct end
            return table.concat(out, " ")
        end

        before_each(function()
            saved = _G.GetMoneyString
            colorblind = false
            _G.GetMoneyString = fake
        end)

        after_each(function()
            _G.GetMoneyString = saved
        end)

        it("uses coin icons by default", function()
            assert.are.equal("12|Gold| 40|Silver| 7|Copper|", TL.FormatMoney(124007))
            assert.are.equal("1,234|Gold| 5|Silver|", TL.FormatMoney(12340500))
            assert.are.equal("1|Gold| 5|Copper|", TL.FormatMoney(10005))
        end)

        it("uses letters in colorblind mode", function()
            colorblind = true
            assert.are.equal("12g 40s 7c", TL.FormatMoney(124007))
            assert.are.equal("1,234g 5s", TL.FormatMoney(12340500))
            assert.are.equal("1g 5c", TL.FormatMoney(10005))
        end)

        it("follows a change of the setting at run time", function()
            assert.are.equal("3|Silver| 25|Copper|", TL.FormatMoney(325))
            colorblind = true
            assert.are.equal("3s 25c", TL.FormatMoney(325))
            colorblind = false
            assert.are.equal("3|Silver| 25|Copper|", TL.FormatMoney(325))
        end)

        it("handles zero, negative values and rounding in both modes", function()
            assert.are.equal("0|Copper|", TL.FormatMoney(0))
            assert.are.equal("-3|Silver| 25|Copper|", TL.FormatMoney(-325))
            assert.are.equal("2|Copper|", TL.FormatMoney(1.5))
            colorblind = true
            assert.are.equal("0c", TL.FormatMoney(0))
            assert.are.equal("-3s 25c", TL.FormatMoney(-325))
            assert.are.equal("-1c", TL.FormatMoney(-1))
            assert.are.equal("2c", TL.FormatMoney(1.5))
        end)

        it("keeps every coin unit and the Alt stack value in both modes", function()
            for _, mode in ipairs({ false, true }) do
                colorblind = mode
                local single = TL.FormatMoney(10101)
                local stack = TL.FormatMoney(10101 * 5)
                assert.are.equal(3, select(2, single:gsub("%S+", "")))
                assert.are.equal(3, select(2, stack:gsub("%S+", "")))
                assert.are_not.equal(single, stack)
            end
        end)
    end)

    describe("FormatAge", function()
        it("formats hours and days", function()
            assert.are.equal("< 1 h", TL.FormatAge(0.4))
            assert.are.equal("1 h", TL.FormatAge(1))
            assert.are.equal("3 h", TL.FormatAge(2.6))
            assert.are.equal("47 h", TL.FormatAge(47))
            assert.are.equal("2 d", TL.FormatAge(48))
            assert.are.equal("3 d", TL.FormatAge(70))
        end)
    end)

    describe("Build", function()
        it("returns no rows without config", function()
            assert.are.same({}, TL.Build({ input = "123" }))
        end)

        it("shows a plain data line", function()
            local rows = TL.Build(ctx())
            assert.are.equal(1, #rows)
            assert.are.equal("Market", rows[1].left)
            assert.are.equal("12g 40s", rows[1].right)
            assert.are.equal("normal", rows[1].color)
        end)

        it("adds age and samples when the flags are on", function()
            local c = ctx()
            c.config.lines[1].showAge = true
            c.config.lines[1].showSamples = true
            local rows = TL.Build(c)
            assert.are.equal("12g 40s \194\183 3 h old \194\183 2/14 days", rows[1].right)
        end)

        it("shows invalid price for an item without scan data", function()
            local rows = TL.Build(ctx({ input = "999" }))
            assert.are.equal("invalid price", rows[1].right)
            assert.are.equal("dim", rows[1].color)
        end)

        it("shows invalid price for a bad formula", function()
            local c = ctx()
            c.config.lines[1].formula = "((("
            assert.are.equal("invalid price", TL.Build(c)[1].right)
        end)

        it("shows not available yet for a later source without a value", function()
            local c = ctx({ input = "999" })
            c.config.lines[1].formula = "crafting"
            local _, info = run:Evaluate("crafting", "999")
            if info.later and #info.later > 0 then
                assert.are.equal("not available yet", TL.Build(c)[1].right)
            else
                assert.are.equal("invalid price", TL.Build(c)[1].right)
            end
            local fake = {
                Evaluate = function()
                    return nil, { kind = "invalid", later = { "Crafting" }, missing = {} }
                end,
            }
            assert.are.equal("not available yet", TL.Build(ctx({ formulaRun = fake }))[1].right)
        end)

        it("multiplies by the stack count in stack mode", function()
            local rows = TL.Build(ctx({ stackMode = true, stackCount = 5 }))
            assert.are.equal("Market x5", rows[1].left)
            assert.are.equal("62g", rows[1].right)
        end)

        it("ignores the stack count when stack mode is off or the stack is 1", function()
            assert.are.equal("12g 40s", TL.Build(ctx({ stackCount = 5 }))[1].right)
            local rows = TL.Build(ctx({ stackMode = true, stackCount = 1 }))
            assert.are.equal("Market", rows[1].left)
        end)

        it("shows the per-item value in stack mode when altStack is off", function()
            local c = ctx({ stackMode = true, stackCount = 5 })
            c.config.lines[1].altStack = false
            c.config.lines[2] = { label = "Stack", formula = "scanmarket", enabled = true, altStack = true }
            local rows = TL.Build(c)
            assert.are.equal("Market", rows[1].left)
            assert.are.equal("12g 40s", rows[1].right)
            assert.are.equal("Stack x5", rows[2].left)
            assert.are.equal("62g", rows[2].right)
        end)

        it("gives the saved colour of a line to its row and keeps the default without one", function()
            local c = ctx()
            c.config.lines[1].color = { 0.1, 0.2, 0.3 }
            c.config.lines[2] = { label = "Plain", formula = "scanmarket", enabled = true }
            local rows = TL.Build(c)
            assert.are.same({ 0.1, 0.2, 0.3 }, rows[1].rgb)
            assert.is_nil(rows[2].rgb)
        end)

        it("ignores a malformed colour and gives no colour to an invalid price", function()
            local c = ctx()
            c.config.lines[1].color = { 5, 0, 0 }
            assert.is_nil(TL.Build(c)[1].rgb)
            c.config.lines[1].color = { 0.1, 0.2, 0.3 }
            c.formulaRun = { Evaluate = function() return nil, { kind = "invalid", missing = {} } end }
            assert.is_nil(TL.Build(c)[1].rgb)
        end)

        it("keeps the colour in stack mode", function()
            local c = ctx({ stackMode = true, stackCount = 5 })
            c.config.lines[1].color = { 0, 1, 0 }
            local row = TL.Build(c)[1]
            assert.are.equal("Market x5", row.left)
            assert.are.same({ 0, 1, 0 }, row.rgb)
        end)

        it("skips disabled lines", function()
            local c = ctx()
            c.config.lines[2] = { label = "Off", formula = "scanmarket", enabled = false }
            assert.are.equal(1, #TL.Build(c))
        end)

        it("shows group and inherited operation rows", function()
            local c = ctx({ rules = rules })
            c.config.showGroup = true
            c.config.showOperation = true
            local rows = TL.Build(c)
            assert.are.equal("Group: Base > Herbs > Rare", rows[2].left)
            assert.are.equal("Selling: Herb sales (from Herbs)", rows[3].left)
            assert.are.equal(3, #rows)
        end)

        it("omits from when the operation is on the item group", function()
            rules.EffectiveOperation = function()
                return 7, 3
            end
            local c = ctx({ rules = rules })
            c.config.showOperation = true
            local rows = TL.Build(c)
            assert.are.equal("Selling: Herb sales", rows[2].left)
        end)

        it("skips the Base group unless asked", function()
            local c = ctx({ rules = rules, input = "555" })
            c.config.showGroup = true
            assert.are.equal(1, #TL.Build(c))
            c.config.showBaseGroup = true
            assert.are.equal("Group: Base", TL.Build(c)[2].left)
        end)

        it("shows count rows", function()
            local c = ctx({ holdings = holdings })
            c.config.showCounts = true
            local rows = TL.Build(c)
            assert.are.equal("Total: 42", rows[2].left)
            assert.are.equal("|cffffffffAnn|r: 20 (bags 15, bank 5)", rows[3].left)
            assert.are.equal("|cffffffffBob|r: 22 (auctions 22)", rows[4].left)
        end)

        describe("count characters", function()
            local function withHoldings(characters, extra)
                local c = ctx(extra)
                c.holdings = { Count = function() return { total = 99, characters = characters } end }
                c.config.showCounts = true
                return TL.Build(c)
            end
            local mixed = {
                { name = "Ann-Home", total = 20, bags = 20, class = "MAGE" },
                { name = "Bob-Other", total = 5, bank = 5 },
                { name = "Cy-Home", total = 3, mail = 3, class = "ROGUE" },
            }
            local function colors(class)
                return ({ MAGE = "3fc7eb", ROGUE = "fff468" })[class]
            end

            it("shows every realm when the flavour does not limit it", function()
                local rows = withHoldings(mixed, { classColor = colors, realm = "Home" })
                assert.are.equal("Total: 99", rows[2].left)
                assert.are.equal(5, #rows)
            end)

            it("shows and counts only the current realm on a limited flavour", function()
                local rows = withHoldings(mixed, { currentRealmOnly = true, realm = "Home", classColor = colors })
                assert.are.equal("Total: 23", rows[2].left)
                assert.are.equal("|cff3fc7ebAnn|r: 20 (bags 20)", rows[3].left)
                assert.are.equal("|cfffff468Cy|r: 3 (mail 3)", rows[4].left)
                assert.are.equal(4, #rows)
            end)

            it("shows all characters if the realm is not known", function()
                local rows = withHoldings(mixed, { currentRealmOnly = true })
                assert.are.equal(5, #rows)
            end)

            it("never shows the realm after a name", function()
                local rows = withHoldings(mixed, {})
                for i = 3, #rows do
                    assert.is_nil(rows[i].left:find("-", 1, true))
                end
            end)

            it("adds the realm only to names that are the same on two realms", function()
                local rows = withHoldings({
                    { name = "Ann-Home", total = 4, bags = 4 },
                    { name = "Ann-Other", total = 3, bags = 3 },
                    { name = "Bob-Home", total = 2, bags = 2 },
                }, {})
                assert.are.equal("|cffffffffAnn-Home|r: 4 (bags 4)", rows[3].left)
                assert.are.equal("|cffffffffAnn-Other|r: 3 (bags 3)", rows[4].left)
                assert.are.equal("|cffffffffBob|r: 2 (bags 2)", rows[5].left)
            end)

            it("uses white when the class is missing or has no colour", function()
                local rows = withHoldings({
                    { name = "Ann-Home", total = 1, bags = 1, class = "UNKNOWN" },
                    { name = "Bob-Home", total = 1, bags = 1 },
                }, { classColor = colors })
                assert.are.equal("|cffffffffAnn|r: 1 (bags 1)", rows[3].left)
                assert.are.equal("|cffffffffBob|r: 1 (bags 1)", rows[4].left)
            end)
        end)

        it("skips missing services without errors", function()
            local c = ctx({ formulaRun = false, getRecord = false, rules = false, holdings = false })
            c.config.showGroup = true
            c.config.showOperation = true
            c.config.showCounts = true
            c.config.lines[1].showAge = true
            local rows
            assert.has_no.errors(function()
                rows = TL.Build(c)
            end)
            assert.are.equal("invalid price", rows[1].right)
            assert.are.equal(1, #rows)
        end)

        it("builds fast with a warm memo", function()
            local c = ctx({ rules = rules, holdings = holdings })
            c.config.showGroup = true
            c.config.showOperation = true
            c.config.showCounts = true
            c.config.lines[1].showAge = true
            c.config.lines[1].showSamples = true
            c.config.lines[2] = { label = "Min", formula = "scanmin", enabled = true }
            TL.Build(c)
            local start = os.clock()
            for _ = 1, 100 do
                TL.Build(c)
            end
            local ms = (os.clock() - start) * 1000
            print(string.format("100 builds: %.2f ms", ms))
            assert.is_true(ms < 100)
        end)
    end)

    describe("price table", function()
        local S = 1 -- copper per unit; 400 copper show as 4s

        local function snap(minimum, market)
            return { time = NOW - 3600, min = minimum * S, market = market * S, qty = 1, auctions = 1 }
        end

        local function day(offset, minimum, market)
            return { day = TODAY + offset, min = minimum * S, market = market * S, qty = 1, scans = 1 }
        end

        -- Days -20, -5 and -1, and two snapshots today. The latest scan is 2 hours old.
        local function full()
            local r = ns.ScanRecord.New()
            r.days = { day(-20, 100, 1000), day(-5, 200, 2000), day(-1, 300, 3000) }
            r.today = { day = TODAY, snaps = { snap(400, 4000), snap(600, 6000) } }
            r.latest = { time = NOW - 7200, min = 600 * S, market = 6000 * S, qty = 1, auctions = 1, partial = false }
            return r
        end

        local tableLine = { id = 1, kind = "table", label = "Price table", formula = "", enabled = true }

        local function build(record, extra)
            local c = ctx({
                config = { lines = { tableLine } },
                getRecord = function()
                    return record
                end,
            })
            for k, v in pairs(extra or {}) do
                c[k] = v
            end
            return TL.Build(c)
        end

        it("gives min, average, max and market for each window", function()
            local w = TL.Windows(full(), NOW)
            assert.are.equal(4, #w)
            assert.are.same({ 1, "1d" }, { w[1].days, w[1].label })
            -- 1d: the two snapshots of today.
            assert.are.same({ 400 * S, 500 * S, 600 * S, 5000 * S }, { w[1].min, w[1].avg, w[1].max, w[1].market })
            -- 14d: day -5, day -1 and today (daily min 500).
            assert.are.equal(200 * S, w[2].min)
            assert.is_true(math.abs(w[2].avg - 1000 * S / 3) < 1e-6)
            assert.are.equal(500 * S, w[2].max)
            assert.is_true(math.abs(w[2].market - 10000 * S / 3) < 1e-6)
            -- 30d and 60d add day -20.
            assert.are.same({ 100 * S, 275 * S, 500 * S, 2750 * S }, { w[3].min, w[3].avg, w[3].max, w[3].market })
            assert.are.same({ w[3].min, w[3].avg, w[3].max, w[3].market },
                { w[4].min, w[4].avg, w[4].max, w[4].market })
        end)

        it("counts N days including today", function()
            local r = ns.ScanRecord.New()
            r.days = {
                day(-60, 1, 10), day(-59, 5, 50), day(-30, 10, 100), day(-29, 20, 200), day(-14, 50, 500),
                day(-13, 70, 700),
            }
            r.today = { day = TODAY, snaps = { snap(900, 9000) } }
            local w = TL.Windows(r, NOW)
            assert.are.equal(70 * S, w[2].min) -- 14d: day -13 is in, day -14 is out
            assert.are.equal(20 * S, w[3].min) -- 30d: day -29 is in, day -30 is out
            assert.are.equal(5 * S, w[4].min) -- 60d: day -59 is in, day -60 is out
        end)

        it("leaves a window empty where it has no days", function()
            local r = ns.ScanRecord.New()
            r.days = { day(-20, 100, 1000) }
            local w = TL.Windows(r, NOW)
            assert.are.same({}, { w[1].min, w[1].avg, w[1].max, w[1].market })
            assert.is_nil(w[2].min)
            assert.are.equal(100 * S, w[3].min)
            assert.are.equal(100 * S, w[3].max)
            assert.are.equal(1000 * S, w[4].market)
        end)

        it("uses only today when there is no history", function()
            local r = ns.ScanRecord.New()
            r.today = { day = TODAY, snaps = { snap(300, 3000) } }
            local w = TL.Windows(r, NOW)
            for i = 1, 4 do
                assert.are.same({ 300 * S, 300 * S, 300 * S, 3000 * S }, { w[i].min, w[i].avg, w[i].max, w[i].market })
            end
        end)

        it("uses the latest scan for 1d when it is from today and there are no snapshots", function()
            local r = ns.ScanRecord.New()
            r.latest = { time = NOW - 3600, min = 250 * S, market = 2500 * S, qty = 1, auctions = 1, partial = true }
            local w = TL.Windows(r, NOW)
            assert.are.same({ 250 * S, 250 * S, 250 * S, 2500 * S }, { w[1].min, w[1].avg, w[1].max, w[1].market })
            r.latest.time = NOW - DAY
            w = TL.Windows(r, NOW)
            assert.is_nil(w[1].min)
        end)

        it("builds the table model with no header", function()
            local rows = build(full())
            assert.are.equal(1, #rows)
            local model = rows[1]
            assert.are.equal("table", model.kind)
            assert.is_nil(model.header)
            assert.are.same({ "Min", "Avg", "Max", "Market" }, model.columns)
            assert.are.equal(4, #model.rows)
            assert.are.equal("1d", model.rows[1].label)
            assert.are.same({ "4s", "5s", "6s", "50s" }, model.rows[1].cells)
            assert.are.same({ "2s", "3s 33c", "5s", "33s 33c" }, model.rows[2].cells)
            assert.are.equal("60d", model.rows[4].label)
        end)

        it("shows a dash for a cell without data and keeps the shape", function()
            local r = ns.ScanRecord.New()
            r.days = { day(-20, 100, 1000) }
            r.latest = { time = NOW - 3600 * 30, min = 100, market = 1000, qty = 1, auctions = 1, partial = false }
            local model = build(r)[1]
            assert.are.equal(4, #model.rows)
            assert.are.same({ "-", "-", "-", "-" }, model.rows[1].cells)
            assert.are.same({ "-", "-", "-", "-" }, model.rows[2].cells)
            assert.are.same({ "1s", "1s", "1s", "10s" }, model.rows[3].cells)
        end)

        it("gives one invalid price row without any data", function()
            local rows = build(ns.ScanRecord.New())
            assert.are.same({ { left = "Prices", right = "invalid price", color = "dim" } }, rows)
            rows = build(nil)
            assert.are.same({ { left = "Prices", right = "invalid price", color = "dim" } }, rows)
        end)

        it("multiplies the cells by the stack count in Alt mode", function()
            local model = build(full(), { stackMode = true, stackCount = 5 })[1]
            assert.are.same({ "20s", "25s", "30s", "2g 50s" }, model.rows[1].cells)
            model = build(full(), { stackMode = false, stackCount = 5 })[1]
            assert.are.same({ "4s", "5s", "6s", "50s" }, model.rows[1].cells)
            model = build(full(), { stackMode = true, stackCount = 1 })[1]
        end)

        it("shows the per-item cells and the per-item cells when the table altStack is off", function()
            local line =
                { id = 1, kind = "table", label = "Price table", formula = "", enabled = true, altStack = false }
            local model = build(full(), { stackMode = true, stackCount = 5, config = { lines = { line } } })[1]
            assert.are.same({ "4s", "5s", "6s", "50s" }, model.rows[1].cells)
            line.altStack = true
            model = build(full(), { stackMode = true, stackCount = 5, config = { lines = { line } } })[1]
            assert.are.same({ "20s", "25s", "30s", "2g 50s" }, model.rows[1].cells)
        end)

        it("omits the table when its line is off and keeps formula lines below it", function()
            local off = { id = 1, kind = "table", label = "Price table", formula = "", enabled = false }
            local rows = build(full(), {
                config = { lines = { off, { label = "Market", formula = "scanmarket", enabled = true } } },
            })
            assert.are.equal(1, #rows)
            assert.are.equal("Market", rows[1].left)
            rows = build(full(), {
                config = { lines = { { label = "Market", formula = "scanmarket", enabled = true }, tableLine } },
            })
            assert.are.equal("Market", rows[1].left)
            assert.are.equal("table", rows[2].kind)
        end)

        it("does not add the age to the data lines of the default table", function()
            local row = build(full())[1]
            assert.is_nil(row.right)
            assert.is_nil(row.header)
        end)
    end)

    describe("vendor sell price", function()
        local function rowsOf(extra, config)
            local c = ctx(extra)
            c.config = config or { lines = {} }
            return TL.Build(c)
        end

        it("shows the unit price by default", function()
            local rows = rowsOf({ sellPrice = 250 })
            assert.are.equal(1, #rows)
            assert.are.equal("Vendor:", rows[1].left)
            assert.are.equal("2s 50c", rows[1].right)
        end)

        it("colours the row blue", function()
            local rgb = rowsOf({ sellPrice = 250 })[1].rgb
            assert.are.same({ 79 / 255, 163 / 255, 1 }, rgb)
        end)

        it("hides the row for a price of 0 or nil", function()
            assert.are.equal(0, #rowsOf({ sellPrice = 0 }))
            assert.are.equal(0, #rowsOf({}))
        end)

        it("shows the stack total with Alt and a stack", function()
            local rows = rowsOf({ sellPrice = 250, stackMode = true, stackCount = 4 })
            assert.are.equal("Vendor x4:", rows[1].left)
            assert.are.equal("10s", rows[1].right)
        end)

        it("shows the unit price for a stack when Alt is up", function()
            local rows = rowsOf({ sellPrice = 250, stackCount = 4 })
            assert.are.equal("2s 50c", rows[1].right)
        end)

        it("hides the row when the setting is off", function()
            assert.are.equal(0, #rowsOf({ sellPrice = 250 }, { lines = {}, showVendor = false }))
        end)
    end)

    describe("period and stat settings", function()
        local TABLE = { id = 1, kind = "table", label = "Price table", formula = "", enabled = true }

        local function record()
            local r = ns.ScanRecord.New()
            r.days = {
                { day = TODAY - 20, min = 100, market = 1000, qty = 1, scans = 1 },
                { day = TODAY - 1, min = 300, market = 3000, qty = 1, scans = 1 },
            }
            local snap = { time = NOW - 3600, min = 400, market = 4000, qty = 1, auctions = 1 }
            r.today = { day = TODAY, snaps = { snap } }
            r.latest = { time = NOW - 7200, min = 400, market = 4000, qty = 1, auctions = 1, partial = false }
            return r
        end

        local function build(settings, extra)
            local config = { lines = { TABLE } }
            for k, v in pairs(settings or {}) do
                config[k] = v
            end
            local c = ctx({
                config = config,
                getRecord = function()
                    return record()
                end,
            })
            for k, v in pairs(extra or {}) do
                c[k] = v
            end
            return TL.Build(c)
        end

        local function labels(model)
            local out = {}
            for i, row in ipairs(model.rows) do
                out[i] = row.label
            end
            return out
        end

        it("shows every period and stat by default", function()
            local model = build()[1]
            assert.are.same({ "1d", "14d", "30d", "60d" }, labels(model))
            assert.are.same({ "Min", "Avg", "Max", "Market" }, model.columns)
        end)

        for _, label in ipairs({ "1d", "14d", "30d", "60d" }) do
            it("hides the period " .. label, function()
                local periods = { ["1d"] = true, ["14d"] = true, ["30d"] = true, ["60d"] = true }
                periods[label] = false
                local model = build({ periods = periods })[1]
                assert.are.equal(3, #model.rows)
                for _, shown in ipairs(labels(model)) do
                    assert.are_not.equal(label, shown)
                end
            end)
        end

        it("shows no price rows when no period is on", function()
            local rows = build({ periods = { ["1d"] = false, ["14d"] = false, ["30d"] = false, ["60d"] = false } })
            assert.are.equal(0, #rows)
        end)

        it("shows no price rows when no stat is on", function()
            local rows = build({ stats = { min = false, avg = false, max = false, market = false } })
            assert.are.equal(0, #rows)
        end)

        local function only(name)
            local stats = { min = false, avg = false, max = false, market = false }
            stats[name] = true
            return stats
        end

        for _, name in ipairs({ "market", "min", "max", "avg" }) do
            it("shows compact rows for only " .. name, function()
                local rows = build({ stats = only(name) })
                assert.are.equal(4, #rows)
                assert.are.equal("1d " .. name, rows[1].left)
                assert.are.equal("60d " .. name, rows[4].left)
                assert.is_nil(rows[1].kind)
                assert.is_nil(rows[1].header)
                assert.is_nil(rows[2].header)
            end)
        end

        it("shows the right value in a compact row", function()
            local rows = build({ stats = only("market") })
            assert.are.equal("1d market", rows[1].left)
            assert.are.equal("40s", rows[1].right)
        end)

        it("shows Min and Market as two columns in the fixed order", function()
            local model = build({ stats = { min = true, avg = false, max = false, market = true } })[1]
            assert.are.same({ "Min", "Market" }, model.columns)
            assert.are.equal(2, #model.rows[1].cells)
            assert.are.equal("4s", model.rows[1].cells[1])
            assert.are.equal("40s", model.rows[1].cells[2])
        end)

        it("shows all four stats as four columns", function()
            local model = build({ stats = { min = true, avg = true, max = true, market = true } })[1]
            assert.are.equal(4, #model.columns)
        end)

        it("multiplies the compact value by the stack", function()
            local rows = build({ stats = only("market") }, { stackMode = true, stackCount = 2 })
            assert.are.equal("80s", rows[1].right)
        end)
    end)

    describe("guild marker", function()
        local function leftTexts(rows)
            local texts = {}
            for _, row in ipairs(rows) do
                texts[#texts + 1] = row.left
            end
            return texts
        end

        it("adds no guild row when the price comes from guild data", function()
            local rows = TL.Build(ctx({ isGuild = function(key)
                return key == "123"
            end }))
            assert.is_nil(table.concat(leftTexts(rows), "\n"):find("(guild)", 1, true))
        end)
    end)
end)