describe("FormulaRun", function()
    local ns, run, store, sources, reads, now, infos, parseCalls

    local DAY = 86400
    local TODAY = 20000
    local NOW = TODAY * DAY + 3600 * 6

    local DEFAULT = "check(first(crafting, scanmarket), "
        .. "max(0.25 * avg(crafting, scanmarket, scanhistorical), 1.5 * vendorsell))"

    local function load(path)
        assert(loadfile(path))("Flipside", ns)
    end

    -- Latest age is ageHours; two daily entries of 2000 give market 2000 and history 2000.
    local function makeRecord(ageHours)
        local r = ns.ScanRecord.New()
        r.latest = { time = NOW - ageHours * 3600, min = 900, market = 1000, qty = 40, auctions = 5, partial = false }
        r.days = {
            { day = TODAY - 3, min = 1, market = 2000, qty = 1, scans = 1 },
            { day = TODAY - 1, min = 1, market = 2000, qty = 1, scans = 1 },
        }
        return r
    end

    before_each(function()
        ns = {}
        load("Services/ScanClock.lua")
        load("Services/ScanRecord.lua")
        load("Services/ScanSources.lua")
        load("Services/ScanStore.lua")
        load("Core/ItemString.lua")
        load("Services/FormulaParse.lua")
        load("Services/FormulaFunctions.lua")
        load("Services/FormulaSources.lua")
        load("Services/FormulaLookup.lua")
        load("Services/FormulaEval.lua")
        load("Services/FormulaRun.lua")

        parseCalls = 0
        local parse = ns.FormulaParse.Parse
        ns.FormulaParse.Parse = function(text)
            parseCalls = parseCalls + 1
            return parse(text)
        end

        infos = {}
        local itemCache = {
            Get = function(_, id)
                return infos[id]
            end,
            Request = function() end,
        }
        local real = ns.FormulaSources.New({ itemCache = itemCache })
        reads = 0
        sources = {
            Status = function(_, name)
                return real:Status(name)
            end,
            Read = function(_, name, ctx)
                reads = reads + 1
                return real:Read(name, ctx)
            end,
        }
        store = ns.ScanStore.New({}, { region = "EU", ruleset = "standard", schemaVersion = 1 })
        store:Put("123", makeRecord(2))
        store:Put("456", makeRecord(100))
        now = NOW
        run = ns.FormulaRun.New({
            store = store,
            sources = sources,
            serverTime = function()
                return now
            end,
        })
    end)

    describe("Evaluate", function()
        it("runs the default minimum formula for an item with scan data and a sell price", function()
            infos[123] = { sellPrice = 401 }
            -- crafting is nil, so first = scanmarket = 2000 (valid, above 0).
            -- avg skips crafting: avg(2000, 2000) = 2000, and 0.25 * 2000 = 500.
            -- 1.5 * 401 = 601.5. max = 601.5. Rounded half up = 602.
            local copper, info = run:Evaluate(DEFAULT, "123")
            assert.are.equal(602, copper)
            assert.are.equal("ok", info.kind)
            assert.are.equal("123", info.key)
        end)

        it("skips a missing vendor price in max", function()
            -- No item info: vendorsell is nil, so max(500, nil) = 500.
            local copper, info = run:Evaluate(DEFAULT, "123")
            assert.are.equal(500, copper)
            assert.are.same({ "crafting", "vendorsell" }, info.missing)
        end)

        it("lists the later sources that the formula uses", function()
            infos[123] = { sellPrice = 400 }
            local _, info = run:Evaluate(DEFAULT, "123")
            assert.are.same({ "crafting" }, info.later)
            assert.are.same({ "crafting" }, info.missing)
        end)

        it("accepts an item link, an item string and a digit string", function()
            local link = "|cff0070dd|Hitem:123::::::::80:::::::::|h[Thing]|h|r"
            assert.are.equal(2000, (run:Evaluate("scanmarket", link)))
            assert.are.equal(2000, (run:Evaluate("scanmarket", "item:123")))
            assert.are.equal(2000, (run:Evaluate("scanmarket", 123)))
        end)

        it("gives a value for a fresh item and invalid for a stale item", function()
            local formula = "ifgt(scanage, 72, invalid, scanmarket)"
            local copper, info = run:Evaluate(formula, "123")
            assert.are.equal(2000, copper)
            assert.are.equal("ok", info.kind)
            copper, info = run:Evaluate(formula, "456")
            assert.is_nil(copper)
            assert.are.equal("invalid", info.kind)
            assert.are.same({}, info.missing)
        end)

        it("gives invalid and lists the missing sources for an item without a record", function()
            local copper, info = run:Evaluate("scanmin + scanmarket", "999")
            assert.is_nil(copper)
            assert.are.equal("invalid", info.kind)
            assert.is_nil(info.key)
            assert.are.same({ "scanmarket", "scanmin" }, info.missing)
        end)

        it("rounds half up at the end", function()
            assert.are.equal(3, (run:Evaluate("5 / 2", "123")))
            assert.are.equal(2, (run:Evaluate("4.5 / 3 + 0.4", "123")))
            assert.are.equal(1, (run:Evaluate("0.5", "123")))
            assert.are.equal(0, (run:Evaluate("0.49", "123")))
        end)

        it("gives invalid for division by zero", function()
            local copper, info = run:Evaluate("scanmin / 0", "123")
            assert.is_nil(copper)
            assert.are.equal("invalid", info.kind)
        end)

        it("returns an error for input that is not an item", function()
            local copper, info = run:Evaluate("scanmin", "not an item")
            assert.is_nil(copper)
            assert.are.same({ kind = "error", message = "not an item" }, info)
        end)

        it("passes a compile error through with its position", function()
            local copper, info = run:Evaluate("scanmin + dbmarket", "123")
            assert.is_nil(copper)
            assert.are.equal("error", info.kind)
            assert.are.equal(11, info.pos)
            assert.is_truthy(info.message:find("dbmarket", 1, true))
            copper, info = run:Evaluate("scanmin +", "123")
            assert.is_nil(copper)
            assert.are.equal("error", info.kind)
            assert.is_number(info.pos)
        end)

        it("works without a store", function()
            local noStore = ns.FormulaRun.New({
                sources = sources,
                serverTime = function()
                    return now
                end,
            })
            local copper, info = noStore:Evaluate("scanmin + 1", "123")
            assert.is_nil(copper)
            assert.are.equal("invalid", info.kind)
            assert.are.same({ "scanmin" }, info.missing)
            assert.are.equal(7, (noStore:Evaluate("7", "123")))
        end)
    end)

    describe("Compile", function()
        it("returns the tree, the names and the later names", function()
            local compiled = assert(run:Compile(DEFAULT))
            assert.are.equal(DEFAULT, compiled.text)
            assert.is_table(compiled.tree)
            assert.are.same({ "crafting", "scanhistorical", "scanmarket", "vendorsell" }, compiled.names)
            assert.are.same({ "crafting" }, compiled.later)
        end)

        it("returns an error for an unknown source, an unknown function and a wrong argument count", function()
            local compiled, err = run:Compile("dbmarket")
            assert.is_nil(compiled)
            assert.are.equal(1, err.pos)
            compiled, err = run:Compile("1 + foo(2)")
            assert.is_nil(compiled)
            assert.are.equal(5, err.pos)
            compiled, err = run:Compile("check(1)")
            assert.is_nil(compiled)
            assert.are.equal(1, err.pos)
        end)

        it("caches a compiled formula by exact text", function()
            local first = run:Compile("scanmin + 1")
            local second = run:Compile("scanmin + 1")
            assert.are.equal(first, second)
            assert.are.equal(1, parseCalls)
            run:Compile("scanmin + 2")
            assert.are.equal(2, parseCalls)
        end)

        it("compiles again after ClearCache", function()
            run:Compile("scanmin")
            run:ClearCache()
            run:Compile("scanmin")
            assert.are.equal(2, parseCalls)
        end)
    end)

    describe("result memo", function()
        it("does not call the sources for a repeated evaluation", function()
            run:Evaluate("scanmin + scanqty", "123")
            local before = reads
            assert.is_true(before > 0)
            local copper = run:Evaluate("scanmin + scanqty", "123")
            assert.are.equal(940, copper)
            assert.are.equal(before, reads)
        end)

        it("gives a new result after a store change", function()
            assert.are.equal(900, (run:Evaluate("scanmin", "123")))
            local record = makeRecord(2)
            record.latest.min = 800
            store:Put("123", record)
            local before = reads
            assert.are.equal(800, (run:Evaluate("scanmin", "123")))
            assert.is_true(reads > before)
        end)

        it("gives a new result in a new minute", function()
            run:Evaluate("scanmin", "123")
            local before = reads
            now = now + 30
            run:Evaluate("scanmin", "123")
            assert.are.equal(before, reads)
            now = now + 60
            run:Evaluate("scanmin", "123")
            assert.is_true(reads > before)
        end)

        it("clears the memo when it holds more than 5000 entries", function()
            run:Evaluate("scanmin", "123")
            for i = 1, 5000 do
                run:Evaluate("scanmin", "9" .. i)
            end
            local before = reads
            run:Evaluate("scanmin", "123")
            assert.is_true(reads > before)
            before = reads
            run:Evaluate("scanmin", "123")
            assert.are.equal(before, reads)
        end)

        it("clears the memo with ClearCache", function()
            run:Evaluate("scanmin", "123")
            run:ClearCache()
            local before = reads
            run:Evaluate("scanmin", "123")
            assert.is_true(reads > before)
        end)
    end)

    describe("custom sources", function()
        local texts, version, crun

        before_each(function()
            texts = {}
            version = 1
            local real = ns.FormulaSources.New({ itemCache = {
                Get = function(_, id)
                    return infos[id]
                end,
                Request = function() end,
            } })
            real:SetCustom({
                Get = function(_, name)
                    return texts[name]
                end,
                Version = function()
                    return version
                end,
            })
            crun = ns.FormulaRun.New({
                store = store,
                sources = real,
                serverTime = function()
                    return now
                end,
            })
        end)

        it("accepts a custom name and uses its value", function()
            infos[123] = { sellPrice = 401 }
            texts.myprice = "max(scanmin, 1.5 * vendorsell)"
            local copper, info = crun:Evaluate("myprice * 2", "123")
            assert.are.equal(1800, copper)
            assert.are.equal("ok", info.kind)
        end)

        it("rounds only at the end", function()
            texts.half = "scanmin / 8"
            assert.are.equal(225, (crun:Evaluate("half * 2", "123")))
        end)

        it("resolves nested custom sources", function()
            texts.a = "b + 1"
            texts.b = "scanmin"
            assert.are.equal(901, (crun:Evaluate("a", "123")))
        end)

        it("gives invalid for a loop", function()
            texts.a = "b"
            texts.b = "a"
            local copper, info = crun:Evaluate("a + 1", "123")
            assert.is_nil(copper)
            assert.are.equal("invalid", info.kind)
        end)

        it("gives a compile error for an unknown name", function()
            local copper, info = crun:Evaluate("nothere", "123")
            assert.is_nil(copper)
            assert.are.equal("error", info.kind)
        end)

        it("gives a new result after a change of the version", function()
            texts.myprice = "scanmin"
            assert.are.equal(900, (crun:Evaluate("myprice", "123")))
            texts.myprice = "scanmarket"
            assert.are.equal(900, (crun:Evaluate("myprice", "123")))
            version = 2
            assert.are.equal(2000, (crun:Evaluate("myprice", "123")))
        end)

        it("keeps built-in results unchanged", function()
            assert.are.equal(900, (crun:Evaluate("scanmin", "123")))
        end)
end)
end)
