local manifest = require("Tests.manifest")
describe("OperationSchema", function()
    local ns, S, compile

    local DEFAULT = "check(first(crafting, scanmarket), "
        .. "max(0.25 * avg(crafting, scanmarket, scanhistorical), 1.5 * vendorsell))"

    local function load(path)
        assert(loadfile(path))("Flipside", ns)
    end

    local function keys(type)
        local out = {}
        for _, f in ipairs(S.Fields(type)) do
            out[#out + 1] = f.key
        end
        return out
    end

    before_each(function()
        ns = {}
        load(manifest.path("ItemString"))
        load(manifest.path("ScanClock"))
        load(manifest.path("ScanSources"))
        load(manifest.path("FormulaParse"))
        load(manifest.path("FormulaFunctions"))
        load(manifest.path("FormulaSources"))
        load(manifest.path("FormulaLookup"))
        load(manifest.path("FormulaEval"))
        load(manifest.path("FormulaRun"))
        load(manifest.path("OperationSchema"))
        S = ns.OperationSchema
        local run = ns.FormulaRun.New({
            sources = ns.FormulaSources.New({}),
            serverTime = function() return 0 end,
        })
        compile = function(text) return run:Compile(text) end
    end)

    it("lists types and labels", function()
        assert.same({ "selling", "buying", "vendoring" }, S.TYPES)
        assert.equal("Selling", S.TypeLabel("selling"))
        assert.equal("Buying", S.TypeLabel("buying"))
        assert.equal("Vendoring", S.TypeLabel("vendoring"))
    end)

    it("lists fields in sequence with safety fields last", function()
        assert.same({ "minPrice", "normalPrice", "maxPrice", "undercut", "duration", "postCap",
            "keepInBags", "belowMin", "aboveMax", "cancelUndercut", "maxDataAgeHours",
            "minSamples" }, keys("selling"))
        assert.same({ "maxPrice", "showAboveMax", "maxDataAgeHours", "minSamples" }, keys("buying"))
        assert.same({ "sellToVendor", "keepInBags", "safetyMultiple",
            "maxDataAgeHours", "minSamples" }, keys("vendoring"))
    end)

    it("errors for an unknown type", function()
        assert.has_error(function() S.Fields("x") end)
        assert.has_error(function() S.Defaults("x") end)
        assert.has_error(function() S.Normalize("x", {}) end)
        assert.has_error(function() S.Validate("x", {}, compile) end)
    end)

    it("gives defaults", function()
        assert.same({
            minPrice = DEFAULT, normalPrice = "scanmarket", maxPrice = "2 * scanmarket", undercut = 1,
            duration = 24, postCap = 0, keepInBags = 0, belowMin = "skip", aboveMax = "postAtMax",
            cancelUndercut = true,
            maxDataAgeHours = 72, minSamples = 3,
        }, S.Defaults("selling"))
        assert.same({ maxPrice = "scanmarket", showAboveMax = false, maxDataAgeHours = 72, minSamples = 3 },
            S.Defaults("buying"))
        assert.same({ sellToVendor = false, keepInBags = 0, safetyMultiple = 2, maxDataAgeHours = 72, minSamples = 3 },
            S.Defaults("vendoring"))
        assert.is_not.equal(S.Defaults("buying"), S.Defaults("buying"))
    end)

    it("compiles all default formulas and validates defaults", function()
        for _, t in ipairs(S.TYPES) do
            local ok, errors = S.Validate(t, S.Defaults(t), compile)
            assert.same({}, errors)
            assert.is_true(ok)
        end
    end)

    it("gives each field a label, help and kind", function()
        for _, t in ipairs(S.TYPES) do
            for _, f in ipairs(S.Fields(t)) do
                assert.is_string(f.label)
                assert.is_string(f.help)
                assert.is_string(f.kind)
            end
        end
    end)

    it("normalizes: fills missing and keeps unknown keys", function()
        local input = { maxPrice = "5", future = 7 }
        local out = S.Normalize("buying", input)
        assert.equal("5", out.maxPrice)
        assert.equal(7, out.future)
        assert.is_false(out.showAboveMax)
        assert.equal(72, out.maxDataAgeHours)
        assert.is_nil(input.showAboveMax)
        assert.equal(3, S.Normalize("buying").minSamples)
    end)

    it("fills keepInBags in old saved settings", function()
        local old = { sellToVendor = true, safetyMultiple = 3 }
        assert.equal(0, S.Normalize("vendoring", old).keepInBags)
        assert.is_nil(old.keepInBags)
        assert.equal(0, S.Normalize("selling", { postCap = 5 }).keepInBags)
        assert.equal(5, S.Normalize("selling", { keepInBags = 5 }).keepInBags)
    end)

    describe("Validate", function()
        local function field(type, key, value)
            return S.ValidateField(type, key, value, compile)
        end

        it("checks numbers at and outside limits", function()
            assert.is_true(field("buying", "minSamples", 1))
            assert.is_true(field("buying", "minSamples", 60))
            assert.is_false(field("buying", "minSamples", 0))
            assert.is_false(field("buying", "minSamples", 61))
            assert.is_true(field("selling", "postCap", 0))
            assert.is_true(field("selling", "postCap", 5000))
            assert.is_false(field("selling", "postCap", 5001))
            assert.is_false(field("selling", "postCap", -1))
        end)

        it("checks keepInBags range", function()
            for _, t in ipairs({ "selling", "vendoring" }) do
                assert.is_true(field(t, "keepInBags", 0))
                assert.is_true(field(t, "keepInBags", 10000))
                assert.is_false(field(t, "keepInBags", -1))
                assert.is_false(field(t, "keepInBags", 10001))
            end
        end)

        it("checks money", function()
            assert.is_true(field("selling", "undercut", 0))
            assert.is_true(field("selling", "undercut", 1000000))
            assert.is_false(field("selling", "undercut", 1000001))
            assert.is_false(field("selling", "undercut", 1.5))
            assert.is_false(field("selling", "undercut", "1"))
        end)

        it("rejects non-integer, NaN and wrong type numbers", function()
            assert.is_false(field("vendoring", "safetyMultiple", 2.5))
            assert.is_false(field("vendoring", "safetyMultiple", 0 / 0))
            assert.is_false(field("vendoring", "safetyMultiple", true))
            assert.is_false(field("vendoring", "safetyMultiple", nil))
        end)

        it("checks choices", function()
            assert.is_true(field("selling", "duration", 48))
            assert.is_false(field("selling", "duration", 36))
            assert.is_false(field("selling", "duration", "24"))
            assert.is_true(field("selling", "belowMin", "postAtMin"))
            assert.is_false(field("selling", "belowMin", "postAtMax"))
            assert.is_true(field("selling", "aboveMax", "postAtNormal"))
        end)

        it("checks bools", function()
            assert.is_true(field("selling", "cancelUndercut", false))
            assert.is_false(field("selling", "cancelUndercut", "true"))
            assert.is_false(field("selling", "cancelUndercut", 1))
        end)

        it("checks formulas", function()
            assert.is_true(field("buying", "maxPrice", "2 * scanmarket"))
            local ok, msg = field("buying", "maxPrice", "")
            assert.is_false(ok)
            assert.is_string(msg)
            assert.is_false(field("buying", "maxPrice", "   "))
            assert.is_false(field("buying", "maxPrice", 5))
            ok, msg = field("buying", "maxPrice", "2 * (")
            assert.is_false(ok)
            assert.matches("position", msg)
        end)

        it("reports unknown field", function()
            assert.is_false(field("buying", "nope", 1))
        end)

        it("returns errors by field key", function()
            local s = S.Defaults("selling")
            s.undercut = -5
            s.maxPrice = ""
            s.cancelUndercut = "x"
            local ok, errors = S.Validate("selling", s, compile)
            assert.is_false(ok)
            assert.is_string(errors.undercut)
            assert.is_string(errors.maxPrice)
            assert.is_string(errors.cancelUndercut)
            assert.is_nil(errors.minPrice)
        end)

        it("flags missing fields", function()
            local ok, errors = S.Validate("buying", {}, compile)
            assert.is_false(ok)
            assert.is_string(errors.maxPrice)
            assert.is_string(errors.showAboveMax)
        end)

        it("passes the compile error message and position", function()
            local ok, errors = S.Validate("buying", { maxPrice = "(", showAboveMax = false,
                maxDataAgeHours = 72, minSamples = 3 }, function() return nil, { message = "bad", pos = 4 } end)
            assert.is_false(ok)
            assert.equal("bad (at position 4)", errors.maxPrice)
        end)
    end)
end)
