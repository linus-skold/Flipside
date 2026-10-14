local manifest = require("Tests.manifest")
describe("FormulaEval", function()
    local ns, Eval

    before_each(function()
        ns = {}
        assert(loadfile(manifest.path("FormulaParse")))("Flipside", ns)
        assert(loadfile(manifest.path("FormulaFunctions")))("Flipside", ns)
        assert(loadfile(manifest.path("FormulaEval")))("Flipside", ns)
        Eval = ns.FormulaEval
    end)

    local VALUES = { a = 10, b = 4, c = 0 }

    local function run(text, values)
        local tree = assert(ns.FormulaParse.Parse(text))
        local calls = {}
        local value = Eval.Evaluate(tree, function(name)
            calls[name] = (calls[name] or 0) + 1
            return (values or VALUES)[name]
        end)
        return value, calls
    end

    describe("Evaluate", function()
        it("does arithmetic with precedence", function()
            assert.are.equal(14, run("2 + 3 * 4"))
            assert.are.equal(20, run("(2 + 3) * 4"))
            assert.are.equal(5, run("10 - 3 - 2"))
            assert.are.equal(2.5, run("10 / 2 / 2"))
            assert.are.equal(7, run("a - 3"))
        end)

        it("handles unary minus", function()
            assert.are.equal(-10, run("-a"))
            assert.are.equal(6, run("a - -b + 0 - 8"))
            assert.are.equal(-6, run("-(a - b)"))
        end)

        it("reads money literals", function()
            assert.are.equal(15025, run("1g50s25c + 0"))
            assert.are.equal(1270, run("12s70c"))
        end)

        it("reads percent", function()
            assert.are.equal(2.5, run("25% * a"))
            assert.are.equal(2.5, run("25% a"))
            assert.are.equal(0.5, run("50%"))
        end)

        it("gives nil for the word invalid", function()
            assert.is_nil(run("invalid"))
            assert.is_nil(run("invalid + 1"))
            assert.are.equal(4, run("min(invalid, b)"))
        end)

        it("gives nil for a missing source and never counts it as 0", function()
            assert.is_nil(run("missing + 5"))
            assert.is_nil(run("missing * 0"))
            assert.is_nil(run("-missing"))
        end)

        it("gives nil for division by zero", function()
            assert.is_nil(run("a / 0"))
            assert.is_nil(run("a / c"))
            assert.is_nil(run("1 + a / c"))
        end)

        it("runs each function", function()
            assert.are.equal(4, run("min(a, b, 7)"))
            assert.are.equal(10, run("max(a, b, 7)"))
            assert.are.equal(7, run("avg(a, b, 7, missing) - 0"))
            assert.are.equal(4, run("first(missing, b, a)"))
            assert.are.equal(4, run("check(a, b)"))
            assert.is_nil(run("check(c, b)"))
            assert.are.equal(3, run("round(2.5)"))
            assert.are.equal(1, run("ifgt(a, b, 1, 2)"))
            assert.are.equal(2, run("ifgt(b, a, 1, 2)"))
            assert.is_nil(run("ifgt(b, a, 1)"))
            assert.are.equal(1, run("iflt(b, a, 1, 2)"))
            assert.are.equal(1, run("ifeq(a, 10, 1, 2)"))
            assert.are.equal(2, run("ifeq(a, b, 1, 2)"))
        end)

        it("ignores case in function and source names from the parser", function()
            assert.are.equal(10, run("MAX(A, B)"))
        end)

        it("does not evaluate the lazy branch that is not taken", function()
            local value, calls = run("ifgt(a, b, 1, count)", { a = 10, b = 4, count = 9 })
            assert.are.equal(1, value)
            assert.is_nil(calls.count)
            value, calls = run("ifgt(b, a, count, 2)", { a = 10, b = 4, count = 9 })
            assert.are.equal(2, value)
            assert.is_nil(calls.count)
        end)

        it("resolves each source once for each call", function()
            local value, calls = run("a + a * a + max(a, b, a)")
            assert.are.equal(120, value)
            assert.are.equal(1, calls.a)
            assert.are.equal(1, calls.b)
        end)

        it("resolves a missing source once", function()
            local _, calls = run("first(missing, missing, missing)")
            assert.are.equal(1, calls.missing)
        end)
    end)

    describe("Check", function()
        local function known(name)
            return name == "a" or name == "b" or name == "c"
        end

        local function check(text)
            local tree = assert(ns.FormulaParse.Parse(text))
            return Eval.Check(tree, known)
        end

        it("accepts a formula and lists the sorted unique names", function()
            local ok, names = check("max(c, a) + a * b + invalid")
            assert.is_true(ok)
            assert.are.same({ "a", "b", "c" }, names)
        end)

        it("returns an empty list for a formula without sources", function()
            local ok, names = check("1 + 2")
            assert.is_true(ok)
            assert.are.same({}, names)
        end)

        it("reports an unknown source with its position", function()
            local ok, err = check("a + zzz")
            assert.is_false(ok)
            assert.are.equal(5, err.pos)
            assert.is_truthy(err.message:find("zzz", 1, true))
        end)

        it("accepts the word invalid as a source", function()
            assert.is_true((check("invalid")))
        end)

        it("reports an unknown function with its position", function()
            local ok, err = check("a + foo(b)")
            assert.is_false(ok)
            assert.are.equal(5, err.pos)
            assert.is_truthy(err.message:find("foo", 1, true))
        end)

        it("reports a wrong argument count with its position", function()
            local ok, err = check("a + check(b)")
            assert.is_false(ok)
            assert.are.equal(5, err.pos)
            assert.is_truthy(err.message:find("check", 1, true))
            ok, err = check("ifgt(a, b)")
            assert.is_false(ok)
            assert.are.equal(1, err.pos)
            ok = check("round(a, b)")
            assert.is_false(ok)
        end)

        it("finds an error inside nested arguments", function()
            local ok, err = check("max(a, min(b, nope))")
            assert.is_false(ok)
            assert.are.equal(15, err.pos)
        end)
    end)
end)
