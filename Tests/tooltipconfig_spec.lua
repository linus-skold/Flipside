local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("SettingsDB")))("Flipside", ns)
assert(loadfile(manifest.path("TooltipConfig")))("Flipside", ns)

local function open(saved)
    return ns.SettingsDB.New(saved, { character = "Alice-Realm", schemaVersion = 1 })
end

local function compile(text)
    if text:find("bad", 1, true) then
        return nil, { message = "unknown name", pos = 5 }
    end
    return { text = text }
end

describe("TooltipConfig", function()
    local saved, db, tc, changes, warnings

    local function make()
        tc = ns.TooltipConfig.New(db, {
            compile = compile,
            onChange = function()
                changes = changes + 1
            end,
            onWarning = function(m)
                warnings[#warnings + 1] = m
            end,
        })
    end

    before_each(function()
        saved = {}
        db = open(saved)
        changes, warnings = 0, {}
        make()
    end)

    it("returns defaults and does not save them", function()
        local data = tc:Get()
        assert.are.equal(3, #data.lines)
        assert.are.equal("Market", data.lines[1].label)
        assert.are.equal("scanmarket", data.lines[1].formula)
        assert.is_true(data.lines[1].showAge)
        assert.is_true(data.lines[1].showSamples)
        assert.are.equal("scanlow", data.lines[2].formula)
        assert.is_true(data.lines[2].showAge)
        assert.are.equal("scanhigh", data.lines[3].formula)
        assert.is_true(data.showGroup and data.showOperation and data.showCounts)
        assert.is_nil(db:Get("profile", "tooltip"))
        assert.are.equal(0, changes)
    end)

    it("adds a line", function()
        assert.is_true(tc:AddLine("  Avg ", "scanmarket * 2"))
        local data = tc:Get()
        assert.are.equal(4, #data.lines)
        assert.are.equal("Avg", data.lines[4].label)
        assert.are.equal(4, data.lines[4].id)
        assert.are.equal(5, data.nextID)
        assert.is_not_nil(db:Get("profile", "tooltip"))
        assert.are.equal(1, changes)
    end)

    it("updates a line", function()
        assert.is_true(tc:UpdateLine(1, { label = "Mkt", formula = "scanlow", showAge = false, enabled = false }))
        local line = tc:Get().lines[1]
        assert.are.equal("Mkt", line.label)
        assert.are.equal("scanlow", line.formula)
        assert.is_false(line.showAge)
        assert.is_false(line.enabled)
        local ok, msg = tc:UpdateLine(99, { label = "X" })
        assert.is_nil(ok)
        assert.are.equal("line does not exist", msg)
        assert.is_nil((tc:UpdateLine(1, { colour = "red" })))
        assert.is_nil((tc:UpdateLine(1, { enabled = "yes" })))
    end)

    it("removes a line", function()
        assert.is_true(tc:RemoveLine(2))
        local data = tc:Get()
        assert.are.equal(2, #data.lines)
        assert.are.equal(3, data.lines[2].id)
        assert.is_nil((tc:RemoveLine(2)))
    end)

    it("moves a line and clamps at the ends", function()
        assert.is_true(tc:MoveLine(1, 1))
        local data = tc:Get()
        assert.are.equal(2, data.lines[1].id)
        assert.are.equal(1, data.lines[2].id)
        assert.is_true(tc:MoveLine(1, 10))
        assert.are.equal(1, tc:Get().lines[3].id)
        assert.is_true(tc:MoveLine(1, -10))
        assert.are.equal(1, tc:Get().lines[1].id)
        assert.is_nil((tc:MoveLine(99, 1)))
    end)

    it("rejects an empty or long label", function()
        local ok, msg = tc:AddLine("   ", "scanmarket")
        assert.is_nil(ok)
        assert.are.equal("label must have 1 to 30 characters", msg)
        assert.is_nil((tc:AddLine(string.rep("a", 31), "scanmarket")))
        assert.is_true(tc:AddLine(string.rep("a", 30), "scanmarket"))
        assert.is_nil((tc:UpdateLine(1, { label = "" })))
        assert.are.equal(1, changes)
    end)

    it("rejects a bad formula with its position", function()
        local ok, msg = tc:AddLine("X", "bad formula")
        assert.is_nil(ok)
        assert.are.equal("unknown name (at position 5)", msg)
        ok, msg = tc:UpdateLine(1, { formula = "bad" })
        assert.is_nil(ok)
        assert.are.equal("unknown name (at position 5)", msg)
        assert.is_nil((tc:AddLine("X", "  ")))
        assert.are.equal("scanmarket", tc:Get().lines[1].formula)
        assert.are.equal(0, changes)
    end)

    it("limits the number of lines", function()
        for i = 4, 12 do
            assert.is_true(tc:AddLine("L" .. i, "scanmarket"))
        end
        local ok, msg = tc:AddLine("Extra", "scanmarket")
        assert.is_nil(ok)
        assert.are.equal("a tooltip can have 12 lines at most", msg)
        assert.are.equal(12, #tc:Get().lines)
    end)

    it("sets flags", function()
        assert.is_true(tc:SetFlag("showGroup", false))
        assert.is_false(tc:Get().showGroup)
        assert.is_true(tc:Get().showCounts)
        assert.is_nil((tc:SetFlag("showAll", true)))
        assert.is_nil((tc:SetFlag("showGroup", "no")))
    end)

    it("resets to defaults", function()
        tc:AddLine("Avg", "scanmarket")
        tc:SetFlag("showCounts", false)
        assert.is_true(tc:ResetDefaults())
        local data = tc:Get()
        assert.are.equal(3, #data.lines)
        assert.are.equal(4, data.nextID)
        assert.is_true(data.showCounts)
    end)

    it("refuses changes when the DB is read-only", function()
        local ro = open({ _schema = 99 })
        local store = ns.TooltipConfig.New(ro, { compile = compile })
        local ok, msg = store:AddLine("X", "scanmarket")
        assert.is_nil(ok)
        assert.are.equal("settings are read-only", msg)
        assert.are.equal(3, #store:Get().lines)
    end)

    it("loads invalid stored data read-only with one warning", function()
        saved["p/Default/tooltip"] = { version = 1, nextID = 1, lines = "x" }
        make()
        assert.are.equal(1, #warnings)
        local ok, msg = tc:SetFlag("showGroup", false)
        assert.is_nil(ok)
        assert.are.equal("settings are read-only", msg)
        assert.are.equal(3, #tc:Get().lines)
        assert.are.equal(1, #warnings)
    end)

    it("loads saved data again", function()
        tc:AddLine("Avg", "scanmarket")
        tc:SetFlag("showOperation", false)
        make()
        local data = tc:Get()
        assert.are.equal(4, #data.lines)
        assert.are.equal("Avg", data.lines[4].label)
        assert.is_false(data.showOperation)
        assert.are.equal(0, #warnings)
    end)

    it("does not share tables with the saved data", function()
        tc:SetFlag("showGroup", true)
        local data = tc:Get()
        data.lines[1].label = "Changed"
        data.showGroup = false
        assert.are.equal("Market", tc:Get().lines[1].label)
        assert.are.equal("Market", saved["p/Default/tooltip"].lines[1].label)
        assert.is_true(saved["p/Default/tooltip"].showGroup)
    end)
end)
