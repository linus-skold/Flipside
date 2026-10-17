local manifest = require("Tests.manifest")

describe("NameRegex", function()
    local R

    before_each(function()
        local ns = {}
        assert(loadfile(manifest.path("NameRegex")))("Flipside", ns)
        R = ns.NameRegex
    end)

    local function m(pattern, name)
        local matcher, err = R.Compile(pattern)
        assert.is_nil(err)
        return matcher:Match(name)
    end

    it("anchors at the start", function()
        assert.is_true(m("^Linen", "Linen Cloth"))
        assert.is_true(m("^Linen", "linen cloth"))
        assert.is_false(m("^Linen", "Bolt of Linen Cloth"))
    end)

    it("searches unanchored and anchors at the end", function()
        assert.is_true(m("Linen", "Bolt of Linen Cloth"))
        assert.is_true(m("Cloth$", "Linen Cloth"))
        assert.is_false(m("Cloth$", "Cloth Bolt"))
    end)

    it("handles alternation in a group", function()
        assert.is_true(m("(Linen|Wool) Cloth$", "Linen Cloth"))
        assert.is_true(m("(Linen|Wool) Cloth$", "Wool Cloth"))
        assert.is_false(m("(Linen|Wool) Cloth$", "Silk Cloth"))
    end)

    it("handles top-level alternation", function()
        assert.is_true(m("^ore|bar$", "Copper Bar"))
        assert.is_true(m("^ore|bar$", "Ore of Doom"))
        assert.is_false(m("^ore|bar$", "Copper Cloth"))
    end)

    it("handles classes and ranges", function()
        assert.is_true(m("^[abc]x", "bx"))
        assert.is_false(m("^[abc]x", "dx"))
        assert.is_true(m("^[a-z]+$", "abc"))
        assert.is_false(m("^[a-z]+$", "ab1"))
        assert.is_true(m("^[A-C]", "b"))
        assert.is_true(m("^[^a]", "b"))
        assert.is_false(m("^[^a]", "A"))
    end)

    it("handles quantifiers on characters", function()
        assert.is_true(m("^colou?r$", "color"))
        assert.is_true(m("^colou?r$", "colour"))
        assert.is_false(m("^colou?r$", "colouur"))
        assert.is_true(m("^ab*c$", "ac"))
        assert.is_true(m("^ab*c$", "abbbc"))
        assert.is_false(m("^ab+c$", "ac"))
        assert.is_true(m("^ab+c$", "abc"))
    end)

    it("handles quantifiers on groups", function()
        assert.is_true(m("^(ab)+$", "ababab"))
        assert.is_false(m("^(ab)+$", "aba"))
        assert.is_true(m("^(ab)*$", ""))
        assert.is_true(m("^x(ab)?y$", "xy"))
        assert.is_true(m("^x(ab)?y$", "xaby"))
        assert.is_false(m("^x(ab)?y$", "xababy"))
    end)

    it("handles dot and escapes", function()
        assert.is_true(m("^a.c$", "abc"))
        assert.is_true(m("a\\.c", "a.c"))
        assert.is_false(m("a\\.c", "abc"))
        assert.is_true(m("\\(x\\)", "a (x) b"))
        assert.is_true(m("\\[x\\]", "[x]"))
        assert.is_true(m("a\\\\b", "a\\b"))
        assert.is_true(m("a\\+", "a+"))
    end)

    it("handles class escapes", function()
        assert.is_true(m("^\\d+$", "123"))
        assert.is_false(m("^\\d+$", "12a"))
        assert.is_true(m("^\\w+\\s\\w+$", "Linen Cloth"))
        assert.is_true(m("^[\\d_]+$", "1_2"))
    end)

    it("matches non-ASCII bytes literally", function()
        assert.is_true(m("^\195\169p\195\169e$", "\195\169p\195\169e"))
        assert.is_false(m("^\195\169$", "e"))
    end)

    it("strips one pair of slashes", function()
        assert.is_true(m("/^Linen/", "Linen Cloth"))
        assert.is_false(m("/^Linen/", "Bolt of Linen"))
    end)

    it("reports errors", function()
        for _, bad in ipairs({ "(abc", "abc)", "[abc", "*abc", "+a", "a**", "a{2}", "a\\", "[]", "[z-a]", "", "//",
        }) do
            local matcher, err = R.Compile(bad)
            assert.is_nil(matcher, bad)
            assert.is_string(err, bad)
        end
    end)

    it("does not hang on a pathological pattern", function()
        local matcher = assert(R.Compile("(a*)*b"))
        assert.is_false(matcher:Match(string.rep("a", 60)))
    end)

    it("Test compiles and matches", function()
        assert.is_true(R.Test("^linen", "Linen Cloth"))
        assert.is_true(R.Test("^linen", "Linen Cloth"))
        local result, err = R.Test("(x", "x")
        assert.is_nil(result)
        assert.is_string(err)
    end)
end)
