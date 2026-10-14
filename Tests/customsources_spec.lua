local ns = {}
assert(loadfile("Core/SettingsDB.lua"))("Flipside", ns)
assert(loadfile("Services/ScanClock.lua"))("Flipside", ns)
assert(loadfile("Services/ScanSources.lua"))("Flipside", ns)
assert(loadfile("Services/FormulaParse.lua"))("Flipside", ns)
assert(loadfile("Services/FormulaFunctions.lua"))("Flipside", ns)
assert(loadfile("Services/FormulaEval.lua"))("Flipside", ns)
assert(loadfile("Services/FormulaSources.lua"))("Flipside", ns)
assert(loadfile("Services/CustomSources.lua"))("Flipside", ns)

local function open(saved)
    return ns.SettingsDB.New(saved, { character = "Alice-Realm", schemaVersion = 1 })
end

local function compiler()
    local calls = {}
    local function compile(text)
        calls[#calls + 1] = text
        local tree, err = ns.FormulaParse.Parse(text)
        if not tree then
            return nil, err
        end
        return { tree = tree }
    end
    return compile, calls
end

describe("CustomSources", function()
    local saved, db, cs, compile, changes, warnings

    before_each(function()
        saved = {}
        db = open(saved)
        changes, warnings = 0, {}
        compile = compiler()
        cs = ns.CustomSources.New(db, {
            onChange = function()
                changes = changes + 1
            end,
            onWarning = function(m)
                warnings[#warnings + 1] = m
            end,
        })
    end)

    describe("names", function()
        it("accepts a valid name and stores it in lower case", function()
            assert.is_true(cs:Set("MyPrice_2", "scanmin", compile))
            assert.are.equal("scanmin", cs:Get("myprice_2"))
            assert.are.equal("scanmin", cs:Get("MYPRICE_2"))
            assert.are.same({ { name = "myprice_2", text = "scanmin" } }, cs:List())
        end)

        it("refuses bad names", function()
            for _, name in ipairs({ "a", "2ab", "_ab", "a b", "a-b", "ab.c", "", string.rep("a", 33) }) do
                local ok, message = cs:Set(name, "1", compile)
                assert.is_nil(ok, name)
                assert.is_string(message)
            end
            assert.is_true(cs:Set(string.rep("a", 32), "1", compile))
            assert.is_true(cs:Set("ab", "1", compile))
            assert.is_nil((cs:Set(nil, "1", compile)))
        end)

        it("refuses built-in source, function and invalid names", function()
            for _, name in ipairs({ "scanmin", "VendorSell", "crafting", "max", "avg", "invalid" }) do
                local ok, message = cs:Set(name, "1", compile)
                assert.is_nil(ok, name)
                assert.is_truthy(message:find("built%-in"))
            end
            assert.are.equal(0, #cs:List())
        end)

        it("uses an injected built-in check", function()
            local custom = ns.CustomSources.New(db, {
                isBuiltin = function(name)
                    return name == "zzz"
                end,
            })
            assert.is_nil((custom:Set("zzz", "1", compile)))
            assert.is_true(custom:Set("scanmin", "1", compile))
        end)
    end)

    describe("save", function()
        it("refuses text that does not compile", function()
            local ok, message = cs:Set("bad", "1 +", compile)
            assert.is_nil(ok)
            assert.is_string(message)
            assert.is_nil(cs:Get("bad"))
        end)

        it("returns the message of the injected compile", function()
            local ok, message = cs:Set("bad", "1", function()
                return nil, { message = "Unknown source 'x'." }
            end)
            assert.is_nil(ok)
            assert.are.equal("Unknown source 'x'.", message)
        end)

        it("refuses a direct loop and names the chain", function()
            local ok, message = cs:Set("aa", "aa + 1", compile)
            assert.is_nil(ok)
            assert.are.equal("loop: aa -> aa", message)
        end)

        it("refuses an indirect loop and names the chain", function()
            assert.is_true(cs:Set("bb", "scanmin", compile))
            assert.is_true(cs:Set("aa", "bb + 1", compile))
            local ok, message = cs:Set("bb", "aa * 2", compile)
            assert.is_nil(ok)
            assert.are.equal("loop: bb -> aa -> bb", message)
            assert.are.equal("scanmin", cs:Get("bb"))
        end)

        it("refuses a loop of three", function()
            assert.is_true(cs:Set("cc", "1", compile))
            assert.is_true(cs:Set("bb", "cc", compile))
            assert.is_true(cs:Set("aa", "bb", compile))
            local _, message = cs:Set("cc", "max(1, aa)", compile)
            assert.are.equal("loop: cc -> aa -> bb -> cc", message)
        end)

        it("counts a change and calls onChange", function()
            local v = cs:Version()
            assert.is_true(cs:Set("aa", "1", compile))
            assert.is_true(cs:Version() > v)
            assert.are.equal(1, changes)
            local v2 = cs:Version()
            assert.is_nil((cs:Set("aa", "1 +", compile)))
            assert.are.equal(v2, cs:Version())
            assert.are.equal(1, changes)
        end)

        it("stores the versioned table in the profile", function()
            cs:Set("aa", "scanmin", compile)
            assert.are.same({ version = 1, sources = { aa = "scanmin" } }, db:Get("profile", "customSources"))
        end)

        it("copies on write", function()
            cs:Set("aa", "scanmin", compile)
            local before = db:Get("profile", "customSources")
            cs:Set("bb", "aa", compile)
            assert.are.same({ version = 1, sources = { aa = "scanmin" } }, before)
            assert.are_not.equal(before, db:Get("profile", "customSources"))
            assert.are_not.equal(before.sources, db:Get("profile", "customSources").sources)
        end)
    end)

    describe("delete", function()
        it("deletes an unused source", function()
            cs:Set("aa", "1", compile)
            local v = cs:Version()
            assert.is_true(cs:Delete("AA"))
            assert.is_nil(cs:Get("aa"))
            assert.is_true(cs:Version() > v)
        end)

        it("refuses when another source uses it", function()
            cs:Set("aa", "1", compile)
            cs:Set("bb", "aa + 1", compile)
            cs:Set("cc", "min(aa, 2)", compile)
            local ok, message = cs:Delete("aa")
            assert.is_nil(ok)
            assert.is_truthy(message:find("bb, cc", 1, true))
            assert.are.equal("1", cs:Get("aa"))
        end)

        it("refuses an unknown name", function()
            assert.is_nil((cs:Delete("nothere")))
        end)
    end)

    describe("storage", function()
        it("reloads from the saved table", function()
            cs:Set("aa", "scanmin", compile)
            cs:Set("bb", "aa * 2", compile)
            local again = ns.CustomSources.New(open(saved))
            assert.are.equal("aa * 2", again:Get("bb"))
            assert.are.equal(2, #again:List())
            assert.are.equal("aa", again:List()[1].name)
        end)

        it("is empty without saved data", function()
            assert.are.same({}, cs:List())
            assert.is_nil(cs:Get("aa"))
            assert.is_nil(cs:Get(nil))
        end)

        it("is read-only when the DB is read-only", function()
            local ro = open({ _schema = 99 })
            local custom = ns.CustomSources.New(ro, {
                onWarning = function(m)
                    warnings[#warnings + 1] = m
                end,
            })
            assert.is_true(custom:IsReadOnly())
            local ok, message = custom:Set("aa", "1", compile)
            assert.is_nil(ok)
            assert.is_truthy(message:find("read-only", 1, true))
            assert.are.equal(1, #warnings)
            assert.are.equal(0, #custom:List())
            assert.is_false(cs:IsReadOnly())
        end)

        it("bumps the version when the stored table changes under it", function()
            cs:Set("aa", "1", compile)
            local v = cs:Version()
            db:Set("profile", "customSources", { version = 1, sources = {} })
            assert.is_true(cs:Version() > v)
        end)
    end)

    describe("with FormulaSources", function()
        it("works as the custom set", function()
            local sources = ns.FormulaSources.New()
            sources:SetCustom(cs)
            cs:Set("aa", "scanmin * 2", compile)
            assert.are.equal("custom", sources:Status("aa"))
            local record = { latest = { time = 1, min = 50, market = 60, qty = 1, partial = false }, days = {} }
            assert.are.equal(100, sources:Read("aa", { record = record, now = 100 }))
        end)
    end)
end)
