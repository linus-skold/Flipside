describe("FormulaParse", function()
    local FormulaParse

    before_each(function()
        local ns = {}
        assert(loadfile("Services/FormulaParse.lua"))("Flipside", ns)
        FormulaParse = ns.FormulaParse
    end)

    local function num(v) return { kind = "num", value = v } end
    local function name(n, pos) return { kind = "name", name = n, pos = pos } end
    local function bin(op, l, r) return { kind = "bin", op = op, left = l, right = r } end

    local function fails(text, pos, fragment)
        local tree, err = FormulaParse.Parse(text)
        assert.is_nil(tree)
        assert.are.equal(pos, err.pos)
        assert.is_truthy(err.message:find(fragment, 1, true), err.message)
    end

    describe("Tokenize", function()
        local function first(text)
            local tokens = assert(FormulaParse.Tokenize(text))
            return tokens[1]
        end

        it("reads plain numbers and decimals", function()
            assert.are.same({ type = "number", value = 500, pos = 1 }, first("500"))
            assert.are.same({ type = "number", value = 0.25, pos = 1 }, first("0.25"))
            assert.are.same({ type = "number", value = 1.5, pos = 1 }, first("1.5"))
        end)

        it("converts money literals to copper", function()
            assert.are.equal(10000, first("1g").value)
            assert.are.equal(500, first("5s").value)
            assert.are.equal(1270, first("12s70c").value)
            assert.are.equal(15025, first("1g50s25c").value)
            assert.are.equal(100100, first("10g1s").value)
            assert.are.equal(7, first("7c").value)
        end)

        it("reads percent as a fraction", function()
            assert.are.same({ type = "percent", value = 1.5, pos = 1 }, first("150%"))
            assert.are.equal(0.125, first("12.5%").value)
        end)

        it("folds names to lower case", function()
            assert.are.same({ type = "name", value = "scanmarket", pos = 1 }, first("ScanMarket"))
            assert.are.equal("invalid", first("INVALID").value)
        end)

        it("reads operators, brackets, commas and eof with positions", function()
            local tokens = assert(FormulaParse.Tokenize("max(1,\t2) + 3"))
            local types = {}
            for _, t in ipairs(tokens) do
                types[#types + 1] = t.type
            end
            assert.are.same({ "name", "lparen", "number", "comma", "number", "rparen", "op", "number", "eof" }, types)
            assert.are.equal(8, tokens[5].pos)
            assert.are.equal(11, tokens[7].pos)
            assert.are.equal(14, tokens[9].pos)
        end)

        it("rejects an unknown character with its position", function()
            local tokens, err = FormulaParse.Tokenize("1 + $")
            assert.is_nil(tokens)
            assert.are.equal(5, err.pos)
        end)

        it("rejects bad money literals", function()
            for _, text in ipairs({ "5s10g", "10gg", "10g5", "5x", "1.5g" }) do
                local tokens, err = FormulaParse.Tokenize(text)
                assert.is_nil(tokens, text)
                assert.are.equal(1, err.pos)
            end
        end)
    end)

    describe("Parse", function()
        it("parses a number and a name", function()
            assert.are.same(num(10000), FormulaParse.Parse("1g"))
            assert.are.same(name("scanmarket", 1), FormulaParse.Parse("ScanMarket"))
        end)

        it("gives * and / higher precedence than + and -", function()
            assert.are.same(bin("+", num(1), bin("*", num(2), num(3))), FormulaParse.Parse("1 + 2 * 3"))
        end)

        it("is left associative", function()
            assert.are.same(bin("/", bin("/", num(8), num(4)), num(2)), FormulaParse.Parse("8 / 4 / 2"))
            assert.are.same(bin("-", bin("-", num(8), num(4)), num(2)), FormulaParse.Parse("8 - 4 - 2"))
        end)

        it("parses unary minus", function()
            assert.are.same({ kind = "neg", expr = num(5) }, FormulaParse.Parse("-5"))
            assert.are.same({ kind = "neg", expr = bin("+", num(1), num(2)) }, FormulaParse.Parse("-(1+2)"))
            assert.are.same(bin("*", num(2), { kind = "neg", expr = name("scanmin", 6) }),
                FormulaParse.Parse("2 * -scanmin"))
        end)

        it("parses parentheses", function()
            assert.are.same(bin("*", bin("+", num(1), num(2)), num(3)), FormulaParse.Parse("(1 + 2) * 3"))
        end)

        it("multiplies an operand that follows a percent", function()
            assert.are.same(bin("*", num(1.5), name("scanmarket", 6)), FormulaParse.Parse("150% scanmarket"))
            assert.are.same(bin("*", num(0.5), bin("+", num(1), num(2))), FormulaParse.Parse("50% (1 + 2)"))
        end)

        it("keeps a percent alone as a number", function()
            assert.are.same(num(1.5), FormulaParse.Parse("150%"))
            assert.are.same(bin("+", num(1.5), num(1)), FormulaParse.Parse("150% + 1"))
        end)

        it("parses nested calls", function()
            local tree = FormulaParse.Parse("max(scanmin, 2 * avg(scanmarket, scanhistorical))")
            assert.are.equal("call", tree.kind)
            assert.are.equal("max", tree.name)
            assert.are.equal(1, tree.pos)
            assert.are.same(name("scanmin", 5), tree.args[1])
            local mul = tree.args[2]
            assert.are.equal("*", mul.op)
            assert.are.equal("avg", mul.right.name)
            assert.are.equal(2, #mul.right.args)
        end)

        it("parses the default minimum formula", function()
            local text = "check(first(crafting, scanmarket), max(0.25 * avg(crafting, scanmarket, scanhistorical),"
                .. " 1.5 * vendorsell))"
            local tree = assert(FormulaParse.Parse(text))
            assert.are.equal("check", tree.name)
            assert.are.equal(2, #tree.args)
        end)

        it("parses ifgt with invalid", function()
            local tree = assert(FormulaParse.Parse("ifgt(scanage, 72, invalid, scanmarket)"))
            assert.are.equal("ifgt", tree.name)
            assert.are.same(name("invalid", 19), tree.args[3])
        end)

        it("treats a source name followed by ( as a call", function()
            local tree = assert(FormulaParse.Parse("scanmarket(12345)"))
            assert.are.equal("call", tree.kind)
        end)

        describe("errors", function()
            it("rejects an empty formula", function()
                fails("", 1, "empty")
                fails("  \t ", 1, "empty")
            end)

            it("rejects an unexpected token", function()
                fails("1 +", 4, "Unexpected")
                fails("* 2", 1, "Unexpected")
                fails("()", 2, "Unexpected")
            end)

            it("rejects a missing )", function()
                fails("(1 + 2", 7, "Missing ')'")
                fails("max(1, 2", 9, "Missing ')'")
                fails("max(1 2)", 7, "Missing ')'")
            end)

            it("rejects an empty argument", function()
                fails("max(,1)", 5, "Empty argument")
                fails("max(1,)", 7, "Empty argument")
                fails("max()", 5, "Empty argument")
            end)

            it("rejects trailing input", function()
                fails("1 2", 3, "after the end")
                fails("1 + 2)", 6, "after the end")
            end)

            it("rejects bad money and bad characters", function()
                fails("1 + 5s10g", 5, "money")
                fails("10gg", 1, "money")
                fails("1 # 2", 3, "Unexpected character")
            end)
        end)

        describe("limits", function()
            it("accepts 500 characters and rejects 501", function()
                local text = "1" .. string.rep("+1", 249)
                assert.are.equal(499, #text)
                assert.is_truthy(FormulaParse.Parse(text .. " "))
                fails(text .. "  ", 501, "too long")
                assert.is_truthy(FormulaParse.Parse(text .. "1"))
                fails(text .. "11", 501, "too long")
            end)

            it("accepts 16 levels of brackets and rejects 17", function()
                local ok = string.rep("(", 16) .. "1" .. string.rep(")", 16)
                assert.are.same(num(1), FormulaParse.Parse(ok))
                local bad = string.rep("(", 17) .. "1" .. string.rep(")", 17)
                fails(bad, 17, "too deep")
            end)

            it("counts function calls as levels", function()
                local ok = string.rep("f(", 16) .. "1" .. string.rep(")", 16)
                assert.is_truthy(FormulaParse.Parse(ok))
                local bad = string.rep("f(", 17) .. "1" .. string.rep(")", 17)
                fails(bad, 34, "too deep")
                fails(string.rep("f(", 8) .. string.rep("(", 9) .. "1" .. string.rep(")", 17), 25, "too deep")
            end)
        end)
    end)
end)
