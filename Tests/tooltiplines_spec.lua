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
            assert.are.equal("12g", TL.FormatMoney(120035))
            assert.are.equal("1,234g 5s", TL.FormatMoney(12340500))
            assert.are.equal("12,345,678g", TL.FormatMoney(123456780000))
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
            assert.are.equal("Market (stack of 5)", rows[1].left)
            assert.are.equal("62g", rows[1].right)
        end)

        it("ignores the stack count when stack mode is off or the stack is 1", function()
            assert.are.equal("12g 40s", TL.Build(ctx({ stackCount = 5 }))[1].right)
            local rows = TL.Build(ctx({ stackMode = true, stackCount = 1 }))
            assert.are.equal("Market", rows[1].left)
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
            assert.are.equal("Ann-Realm: 20 (bags 15, bank 5)", rows[3].left)
            assert.are.equal("Bob-Realm: 22 (auctions 22)", rows[4].left)
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
end)
