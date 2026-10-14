describe("FormulaFunctions", function()
    local F
    local huge = math.huge

    before_each(function()
        local ns = {}
        assert(loadfile("Services/FormulaFunctions.lua"))("Flipside", ns)
        F = ns.FormulaFunctions
    end)

    local function call(name, ...)
        return F.Call(name, { n = select("#", ...), ... })
    end

    local function lazy(name, values)
        local calls = {}
        local function getArg(i)
            calls[#calls + 1] = i
            return values[i]
        end
        return F.CallLazy(name, getArg, values.n or #values), calls
    end

    describe("min and max", function()
        it("use valid values", function()
            assert.are.equal(1, call("min", 3, 1, 2))
            assert.are.equal(3, call("max", 3, 1, 2))
        end)

        it("skip invalid values", function()
            assert.are.equal(2, call("min", nil, 2, nil, 5))
            assert.are.equal(5, call("max", nil, 2, nil, 5))
        end)

        it("give invalid when all are invalid", function()
            assert.is_nil(call("min", nil, nil))
            assert.is_nil(call("max", nil, nil))
        end)

        it("ignore case", function()
            assert.are.equal(1, call("MIN", 1, 2))
        end)
    end)

    describe("avg", function()
        it("averages valid values", function()
            assert.are.equal(2, call("avg", 1, 2, 3))
        end)

        it("skips invalid values", function()
            assert.are.equal(4, call("avg", 2, nil, 6))
        end)

        it("gives invalid when all are invalid", function()
            assert.is_nil(call("avg", nil, nil, nil))
        end)
    end)

    describe("first", function()
        it("returns the first valid value", function()
            assert.are.equal(7, call("first", nil, 7, 9))
            assert.are.equal(4, call("first", 4, 9))
        end)

        it("gives invalid when all are invalid", function()
            assert.is_nil(call("first", nil, nil))
        end)
    end)

    describe("check", function()
        it("returns b when a is above 0", function()
            assert.are.equal(9, call("check", 1, 9))
        end)

        it("gives invalid when a is 0, negative or invalid", function()
            assert.is_nil(call("check", 0, 9))
            assert.is_nil(call("check", -1, 9))
            assert.is_nil(call("check", nil, 9))
        end)

        it("gives invalid when b is invalid", function()
            assert.is_nil(call("check", 1, nil))
        end)
    end)

    describe("round", function()
        it("rounds half up", function()
            assert.are.equal(3, call("round", 2.5))
            assert.are.equal(2, call("round", 2.49))
            assert.are.equal(-2, call("round", -2.5))
        end)

        it("keeps invalid", function()
            assert.is_nil(call("round", nil))
            assert.is_nil(F.RoundCopper(nil))
            assert.are.equal(3, F.RoundCopper(2.5))
        end)
    end)

    describe("nil-safe args.n", function()
        it("counts a nil in the middle", function()
            local args = { 5, nil, 1, n = 3 }
            assert.are.equal(1, F.Call("min", args))
            assert.are.equal(5, F.Call("first", args))
        end)

        it("counts a trailing nil", function()
            assert.are.equal(6, F.Call("max", { 6, nil, n = 2 }))
        end)
    end)

    describe("ifgt, iflt, ifeq", function()
        it("choose by the test", function()
            assert.are.equal(10, lazy("ifgt", { 5, 1, 10, 20 }))
            assert.are.equal(20, lazy("ifgt", { 1, 5, 10, 20 }))
            assert.are.equal(10, lazy("iflt", { 1, 5, 10, 20 }))
            assert.are.equal(20, lazy("iflt", { 5, 1, 10, 20 }))
            assert.are.equal(10, lazy("ifeq", { 5, 5, 10, 20 }))
            assert.are.equal(20, lazy("ifeq", { 5, 6, 10, 20 }))
        end)

        it("treat equal values as not greater and not less", function()
            assert.are.equal(20, lazy("ifgt", { 5, 5, 10, 20 }))
            assert.are.equal(20, lazy("iflt", { 5, 5, 10, 20 }))
        end)

        it("give invalid without else when the test fails", function()
            assert.is_nil(lazy("ifgt", { 1, 5, 10, n = 3 }))
            assert.are.equal(10, lazy("ifgt", { 5, 1, 10, n = 3 }))
        end)

        it("give invalid when value or limit is invalid", function()
            assert.is_nil(lazy("ifgt", { nil, 1, 10, 20, n = 4 }))
            assert.is_nil(lazy("iflt", { 1, nil, 10, 20, n = 4 }))
            assert.is_nil(lazy("ifeq", { nil, nil, 10, 20, n = 4 }))
        end)

        it("return invalid from the chosen branch", function()
            assert.is_nil(lazy("ifgt", { 5, 1, nil, 20, n = 4 }))
        end)

        it("evaluate only the chosen branch", function()
            local _, calls = lazy("ifgt", { 5, 1, 10, 20 })
            assert.are.same({ 1, 2, 3 }, calls)
            _, calls = lazy("ifgt", { 1, 5, 10, 20 })
            assert.are.same({ 1, 2, 4 }, calls)
            _, calls = lazy("ifgt", { 1, 5, 10, n = 3 })
            assert.are.same({ 1, 2 }, calls)
        end)

        it("do not evaluate branches when the test is invalid", function()
            local _, calls = lazy("ifeq", { nil, 1, 10, 20, n = 4 })
            assert.are.same({ 1, 2 }, calls)
        end)
    end)

    describe("Arith", function()
        it("computes", function()
            assert.are.equal(5, F.Arith("+", 2, 3))
            assert.are.equal(-1, F.Arith("-", 2, 3))
            assert.are.equal(6, F.Arith("*", 2, 3))
            assert.are.equal(2.5, F.Arith("/", 5, 2))
            assert.are.equal(-4, F.Negate(4))
        end)

        it("gives invalid for invalid input", function()
            for _, op in ipairs({ "+", "-", "*", "/" }) do
                assert.is_nil(F.Arith(op, nil, 1))
                assert.is_nil(F.Arith(op, 1, nil))
                assert.is_nil(F.Arith(op, nil, nil))
            end
            assert.is_nil(F.Negate(nil))
        end)

        it("gives invalid for division by zero", function()
            assert.is_nil(F.Arith("/", 5, 0))
            assert.is_nil(F.Arith("/", 0, 0))
        end)

        it("gives invalid for inf and nan", function()
            assert.is_nil(F.Arith("*", 1e308, 1e308))
            assert.is_nil(F.Arith("+", huge, 1))
            assert.is_nil(F.Arith("+", 0 / 0, 1))
            assert.is_nil(F.Negate(huge))
        end)

        it("gives invalid for an unknown operator", function()
            assert.is_nil(F.Arith("^", 2, 3))
        end)
    end)

    describe("IsKnown and CheckArity", function()
        it("know all functions, ignoring case", function()
            for name in pairs(F.SPECS) do
                assert.is_true(F.IsKnown(name))
            end
            assert.is_true(F.IsKnown("IfGt"))
            assert.is_false(F.IsKnown("nope"))
        end)

        it("mark the lazy functions", function()
            assert.is_true(F.SPECS.ifgt.lazy)
            assert.is_true(F.SPECS.iflt.lazy)
            assert.is_true(F.SPECS.ifeq.lazy)
            assert.is_false(F.SPECS.min.lazy)
        end)

        it("check arity limits", function()
            assert.is_false(F.CheckArity("min", 0))
            assert.is_true(F.CheckArity("min", 1))
            assert.is_true(F.CheckArity("min", 50))
            assert.is_false(F.CheckArity("check", 1))
            assert.is_true(F.CheckArity("check", 2))
            assert.is_false(F.CheckArity("check", 3))
            assert.is_false(F.CheckArity("round", 2))
            assert.is_false(F.CheckArity("ifgt", 2))
            assert.is_true(F.CheckArity("ifgt", 3))
            assert.is_true(F.CheckArity("ifgt", 4))
            assert.is_false(F.CheckArity("ifgt", 5))
        end)

        it("give a message on failure", function()
            local ok, msg = F.CheckArity("check", 3)
            assert.is_false(ok)
            assert.is_string(msg)
            ok, msg = F.CheckArity("nope", 1)
            assert.is_false(ok)
            assert.is_string(msg)
        end)
    end)
end)
