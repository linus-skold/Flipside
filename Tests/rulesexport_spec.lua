local ns = {}
assert(loadfile("Core/ItemString.lua"))("Flipside", ns)
assert(loadfile("Core/SettingsDB.lua"))("Flipside", ns)
assert(loadfile("Services/ScanClock.lua"))("Flipside", ns)
assert(loadfile("Services/ScanSources.lua"))("Flipside", ns)
assert(loadfile("Services/FormulaParse.lua"))("Flipside", ns)
assert(loadfile("Services/FormulaFunctions.lua"))("Flipside", ns)
assert(loadfile("Services/FormulaEval.lua"))("Flipside", ns)
assert(loadfile("Services/FormulaSources.lua"))("Flipside", ns)
assert(loadfile("Services/CustomSources.lua"))("Flipside", ns)
assert(loadfile("Services/GroupTree.lua"))("Flipside", ns)
assert(loadfile("Services/OperationSchema.lua"))("Flipside", ns)
assert(loadfile("Services/RulesStore.lua"))("Flipside", ns)
assert(loadfile("Services/RulesExport.lua"))("Flipside", ns)

local function compile(text)
    local tree, err = ns.FormulaParse.Parse(text)
    if not tree then
        return nil, err
    end
    return { tree = tree }
end

local function newEnv()
    local db = ns.SettingsDB.New({}, { character = "Me", schemaVersion = 1 })
    return {
        db = db,
        rules = ns.RulesStore.New(db, { compile = compile }),
        cs = ns.CustomSources.New(db),
    }
end

local function snapshot(rules, id)
    local out = { name = rules:Name(id), items = rules:ItemsIn(id), ops = {}, children = {} }
    for _, opType in ipairs(ns.OperationSchema.TYPES) do
        local opID, from = rules:EffectiveOperation(id, opType)
        if opID and from == id then
            out.ops[opType] = rules:GetOperation(opID)
            out.ops[opType].id = nil
        end
    end
    for _, childID in ipairs(rules:Children(id)) do
        out.children[#out.children + 1] = snapshot(rules, childID)
    end
    return out
end

describe("RulesExport", function()
    local env, rules, cs

    before_each(function()
        env = newEnv()
        rules, cs = env.rules, env.cs
    end)

    -- Builds Herbs (selling op, custom source) with Flowers (buying op) and Roots, plus items.
    local function buildTree()
        local herbs = assert(rules:CreateGroup(1, "Herbs"))
        local flowers = assert(rules:CreateGroup(herbs, "Flowers"))
        assert(rules:CreateGroup(herbs, "Roots"))
        assert(rules:AddItem("100", herbs))
        assert(rules:AddItem("200", flowers))
        assert(cs:Set("mybase", "scanmarket * 2", compile))
        assert(cs:Set("mytop", "mybase + 1", compile))
        local sell = assert(rules:CreateOperation("selling", "Fast sell"))
        assert(rules:SetSetting(sell, "minPrice", "mytop"))
        assert(rules:SetSetting(sell, "undercut", 25))
        assert(rules:SetSetting(sell, "duration", 48))
        assert(rules:SetSetting(sell, "cancelUndercut", false))
        local buy = assert(rules:CreateOperation("buying", "Cheap"))
        assert(rules:SetSetting(buy, "maxPrice", "mybase / 2"))
        assert(rules:AttachOperation(herbs, "selling", sell))
        assert(rules:AttachOperation(flowers, "buying", buy))
        return herbs
    end

    it("round trips a tree into an empty profile", function()
        local herbs = buildTree()
        local text = assert(ns.RulesExport.Export(rules, cs, herbs))
        assert.are.equal("FLIPSIDE-RULES 1", text:match("^[^\n]*"))

        local other = newEnv()
        local data = assert(ns.RulesExport.Parse(text))
        local ok, summary = ns.RulesExport.Apply(other.rules, other.cs, data, 1, compile)
        assert.is_true(ok, summary)
        local imported = other.rules:Children(1)[1]
        assert.are.same(snapshot(rules, herbs), snapshot(other.rules, imported))
        assert.are.equal("scanmarket * 2", other.cs:Get("mybase"))
        assert.are.equal("mybase + 1", other.cs:Get("mytop"))
        local sellID = other.rules:EffectiveOperation(imported, "selling")
        assert.are.equal("mytop", other.rules:GetOperation(sellID).settings.minPrice)
        local flowers = other.rules:Children(imported)[1]
        assert.are.equal(sellID, other.rules:EffectiveOperation(flowers, "selling"))
        assert.are.equal(3, summary.groups)
        assert.are.equal(2, summary.items)
        assert.are.equal(2, summary.operationsNew)
        assert.are.equal(2, summary.customNew)
    end)

    it("exports the same text again after an import", function()
        local herbs = buildTree()
        local text = ns.RulesExport.Export(rules, cs, herbs)
        local other = newEnv()
        assert(ns.RulesExport.Apply(other.rules, other.cs, ns.RulesExport.Parse(text), 1, compile))
        assert.are.equal(text, ns.RulesExport.Export(other.rules, other.cs, other.rules:Children(1)[1]))
    end)

    it("keeps an operation inherited from outside the exported group", function()
        local top = assert(rules:CreateGroup(1, "Top"))
        local inner = assert(rules:CreateGroup(top, "Inner"))
        local op = assert(rules:CreateOperation("vendoring", "Vend"))
        assert(rules:AttachOperation(top, "vendoring", op))
        local text = ns.RulesExport.Export(rules, cs, inner)
        local other = newEnv()
        assert(ns.RulesExport.Apply(other.rules, other.cs, ns.RulesExport.Parse(text), 1, compile))
        local imported = other.rules:Children(1)[1]
        local opID = other.rules:EffectiveOperation(imported, "vendoring")
        assert.are.equal("Vend", other.rules:GetOperation(opID).name)
    end)

    it("keeps separators, quotes, backslashes and line breaks in names and formulas", function()
        local group = assert(rules:CreateGroup(1, "A|B \"q\"\n\\ x"))
        local op = assert(rules:CreateOperation("selling", "Pipe|Name\r\n\\n"))
        assert(rules:SetSetting(op, "normalPrice", "scanmarket\t+  1"))
        assert(rules:AttachOperation(group, "selling", op))
        local text = ns.RulesExport.Export(rules, cs, group)
        local other = newEnv()
        local data = assert(ns.RulesExport.Parse(text))
        assert(ns.RulesExport.Apply(other.rules, other.cs, data, 1, compile))
        local imported = other.rules:Children(1)[1]
        assert.are.equal("A|B \"q\"\n\\ x", other.rules:Name(imported))
        local imp = other.rules:GetOperation(other.rules:EffectiveOperation(imported, "selling"))
        assert.are.equal("Pipe|Name\r\n\\n", imp.name)
        assert.are.equal("scanmarket\t+  1", imp.settings.normalPrice)
    end)

    it("reads text with Windows line endings", function()
        local herbs = buildTree()
        local text = ns.RulesExport.Export(rules, cs, herbs):gsub("\n", "\r\n")
        assert.is_table(ns.RulesExport.Parse(text))
    end)

    it("adds (2) and (3) to a group name that exists", function()
        local herbs = buildTree()
        local data = ns.RulesExport.Parse(ns.RulesExport.Export(rules, cs, herbs))
        local ok, first = ns.RulesExport.Apply(rules, cs, data, 1, compile)
        assert.is_true(ok)
        assert.are.equal("Herbs (2)", rules:Name(first.groupID))
        local _, second = ns.RulesExport.Apply(rules, cs, data, 1, compile)
        assert.are.equal("Herbs (3)", rules:Name(second.groupID))
        assert.are.same({ { kind = "group", from = "Herbs", to = "Herbs (3)" } },
            (function()
                local list = {}
                for _, r in ipairs(second.renames) do
                    if r.kind == "group" then
                        list[#list + 1] = r
                    end
                end
                return list
            end)())
    end)

    it("reuses an operation with the same type, name and settings", function()
        local herbs = buildTree()
        local data = ns.RulesExport.Parse(ns.RulesExport.Export(rules, cs, herbs))
        local before = #rules:ListOperations()
        local ok, summary = ns.RulesExport.Apply(rules, cs, data, 1, compile)
        assert.is_true(ok)
        assert.are.equal(2, summary.operationsReused)
        assert.are.equal(0, summary.operationsNew)
        assert.are.equal(2, summary.customReused)
        assert.are.equal(before, #rules:ListOperations())
    end)

    it("imports a copy named (imported) when the settings differ", function()
        local herbs = buildTree()
        local data = ns.RulesExport.Parse(ns.RulesExport.Export(rules, cs, herbs))
        local sell = rules:ListOperations("selling")[1].id
        assert(rules:SetSetting(sell, "undercut", 99))
        local ok, summary = ns.RulesExport.Apply(rules, cs, data, 1, compile)
        assert.is_true(ok)
        assert.are.equal(1, summary.operationsNew)
        local names = {}
        for _, entry in ipairs(rules:ListOperations("selling")) do
            names[#names + 1] = entry.name
        end
        assert.are.same({ "Fast sell", "Fast sell (imported)" }, names)
        local copy = rules:ListOperations("selling")[2]
        assert.are.equal(25, rules:GetOperation(copy.id).settings.undercut)
        assert(rules:SetSetting(sell, "undercut", 98))
        local _, third = ns.RulesExport.Apply(rules, cs, data, 1, compile)
        assert.are.equal(1, third.operationsNew)
        assert.are.equal("Fast sell (imported 2)", third.renames[#third.renames].to)
    end)

    it("uses (imported 2) when the first copy name is taken", function()
        local herbs = buildTree()
        local data = ns.RulesExport.Parse(ns.RulesExport.Export(rules, cs, herbs))
        local sell = rules:ListOperations("selling")[1].id
        assert(rules:SetSetting(sell, "undercut", 99))
        assert(rules:CreateOperation("selling", "Fast sell (imported)"))
        assert(ns.RulesExport.Apply(rules, cs, data, 1, compile))
        local found = false
        for _, entry in ipairs(rules:ListOperations("selling")) do
            found = found or entry.name == "Fast sell (imported 2)"
        end
        assert.is_true(found)
    end)

    it("reuses a custom source with the same text and renames one with other text", function()
        local herbs = buildTree()
        local data = ns.RulesExport.Parse(ns.RulesExport.Export(rules, cs, herbs))
        local other = newEnv()
        assert(other.cs:Set("mybase", "scanmarket * 3", compile))
        assert(other.cs:Set("mytop", "mybase + 1", compile))
        local preview = ns.RulesExport.Preview(other.rules, other.cs, data, 1)
        assert.are.equal(2, preview.customNew)
        assert.are.equal(0, preview.customReused)
        local ok, summary = ns.RulesExport.Apply(other.rules, other.cs, data, 1, compile)
        assert.is_true(ok, summary)
        assert.are.equal("scanmarket * 3", other.cs:Get("mybase"))
        assert.are.equal("scanmarket * 2", other.cs:Get("mybase_imported"))
        assert.are.equal("mybase_imported + 1", other.cs:Get("mytop_imported"))
        local sell = other.rules:ListOperations("selling")[1]
        assert.are.equal("mytop_imported", other.rules:GetOperation(sell.id).settings.minPrice)
        local buy = other.rules:ListOperations("buying")[1]
        assert.are.equal("mybase_imported / 2", other.rules:GetOperation(buy.id).settings.maxPrice)
    end)

    it("counts items that move out of another group", function()
        local herbs = buildTree()
        local data = ns.RulesExport.Parse(ns.RulesExport.Export(rules, cs, herbs))
        local other = newEnv()
        local old = assert(other.rules:CreateGroup(1, "Old"))
        assert(other.rules:AddItem("100", old))
        local preview = ns.RulesExport.Preview(other.rules, other.cs, data, 1)
        assert.are.equal(2, preview.items)
        assert.are.equal(1, preview.itemsMoved)
        assert(ns.RulesExport.Apply(other.rules, other.cs, data, 1, compile))
        assert.are.same({}, other.rules:ItemsIn(old))
    end)

    it("reports a clear message when the depth limit is hit", function()
        local herbs = buildTree()
        local data = ns.RulesExport.Parse(ns.RulesExport.Export(rules, cs, herbs))
        local other = newEnv()
        local parent = 1
        for i = 1, 7 do
            parent = assert(other.rules:CreateGroup(parent, "L" .. i))
        end
        local preview, message = ns.RulesExport.Preview(other.rules, other.cs, data, parent)
        assert.is_nil(preview)
        assert.is_truthy(message:find("too deep"))
        local ok, applyMessage = ns.RulesExport.Apply(other.rules, other.cs, data, parent, compile)
        assert.is_nil(ok)
        assert.is_truthy(applyMessage:find("too deep"))
        assert.are.same({}, other.rules:Children(parent))
    end)

    it("changes nothing in Preview", function()
        local herbs = buildTree()
        local data = ns.RulesExport.Parse(ns.RulesExport.Export(rules, cs, herbs))
        local other = newEnv()
        assert(other.cs:Set("mybase", "scanmarket * 3", compile))
        local before = {}
        for k, v in pairs(other.db:Get("profile", "groups") or {}) do
            before[k] = v
        end
        local ops = #other.rules:ListOperations()
        local summary = ns.RulesExport.Preview(other.rules, other.cs, data, 1)
        assert.are.equal(3, summary.groups)
        assert.are.equal(0, #other.rules:Children(1))
        assert.are.equal(ops, #other.rules:ListOperations())
        assert.is_nil(other.cs:Get("mybase_imported"))
        assert.is_nil(other.db:Get("profile", "groups"))
        assert.are.same({}, before)
    end)

    it("refuses a TSM-like string, random text and empty text", function()
        for _, text in ipairs({ "^1^T^SNAME^SFoo^t^^", "hello", "", "FLIPSIDE-RULES", "FLIPSIDE-RULES x" }) do
            local data, message = ns.RulesExport.Parse(text)
            assert.is_nil(data)
            assert.is_truthy(message:find("not a Flipside rules export"))
        end
        assert.is_nil(ns.RulesExport.Parse(nil))
    end)

    it("refuses a newer version with a message", function()
        local data, message = ns.RulesExport.Parse("FLIPSIDE-RULES 2\ngroup|1||X\n")
        assert.is_nil(data)
        assert.is_truthy(message:find("version 2"))
        assert.is_truthy(message:find("Update Flipside"))
    end)

    it("refuses bad records with a line number", function()
        local cases = {
            "FLIPSIDE-RULES 1\ngroup|1||X\nitem|1|not a key\n",
            "FLIPSIDE-RULES 1\ngroup|1||X\ngroup|2|9|Y\n",
            "FLIPSIDE-RULES 1\ngroup|1||X\nwhat|1\n",
            "FLIPSIDE-RULES 1\ngroup|1||X\ngroup|2|1|bad\\q\n",
            "FLIPSIDE-RULES 1\ngroup|1||X\nop|1|selling|O\nset|1|undercut|n|-5\n",
            "FLIPSIDE-RULES 1\nitem|1|100\n",
        }
        for _, text in ipairs(cases) do
            local data, message = ns.RulesExport.Parse(text)
            assert.is_nil(data)
            assert.is_truthy(message:find("^Line %d+") or message:find("no group"), message)
        end
    end)

    it("stops with the step name when a step fails", function()
        local herbs = buildTree()
        local data = ns.RulesExport.Parse(ns.RulesExport.Export(rules, cs, herbs))
        local other = newEnv()
        local ok, message = ns.RulesExport.Apply(other.rules, other.cs, data, 1, function()
            return nil, "no"
        end)
        assert.is_nil(ok)
        assert.is_truthy(message:find("Import stopped at step 'custom source mybase'", 1, true))
    end)
end)
