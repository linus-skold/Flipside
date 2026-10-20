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

-- Version 2 data with the three formula lines of the old defaults and no price table.
local function formulaData()
    return {
        version = 2,
        nextID = 4,
        showGroup = true,
        showOperation = true,
        showCounts = true,
        lines = {
            { id = 1, label = "Market", formula = "scanmarket", showAge = true, showSamples = true, enabled = true },
            { id = 2, label = "Min", formula = "scanlow", showAge = true, showSamples = false, enabled = true },
            { id = 3, label = "Max", formula = "scanhigh", showAge = false, showSamples = false, enabled = true },
        },
    }
end

local function customLine(id, label)
    return { id = id, label = label, formula = "scanmarket", showAge = false, showSamples = false, enabled = true }
end

local function tableLine(id)
    return {
        id = id, kind = "table", label = "Price table", formula = "", showAge = false, showSamples = false,
        enabled = true,
    }
end

-- Version 1 data as the old build stored it; lines are the three old defaults.
local function v1Data()
    local data = formulaData()
    data.version = 1
    return data
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
        saved["p/Default/tooltip"] = formulaData()
        make()
    end)

    it("returns defaults and does not save them", function()
        saved["p/Default/tooltip"] = nil
        make()
        local data = tc:Get()
        assert.are.equal(2, data.version)
        assert.are.equal(1, #data.lines)
        assert.are.equal("table", data.lines[1].kind)
        assert.are.equal("Price table", data.lines[1].label)
        assert.is_true(data.lines[1].enabled)
        assert.are.equal(2, data.nextID)
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

    describe("line colour", function()
        it("has no colour by default", function()
            assert.is_nil(tc:Get().lines[1].color)
            assert.is_nil(ns.TooltipConfig.New(open({})):Get().lines[1].color)
        end)

        it("saves a colour for one line", function()
            assert.is_true(tc:UpdateLine(2, { color = { 0.1, 0.5, 1 } }))
            assert.are.same({ 0.1, 0.5, 1 }, tc:Get().lines[2].color)
            assert.are.same({ 0.1, 0.5, 1 }, saved["p/Default/tooltip"].lines[2].color)
            assert.is_nil(tc:Get().lines[1].color)
        end)

        it("copies the colour table", function()
            local color = { 0.1, 0.5, 1 }
            tc:UpdateLine(2, { color = color })
            color[1] = 0
            assert.are.equal(0.1, tc:Get().lines[2].color[1])
        end)

        it("restores the old colour or removes the colour with false", function()
            tc:UpdateLine(2, { color = { 0.1, 0.5, 1 } })
            tc:UpdateLine(2, { color = { 1, 0, 0 } })
            tc:UpdateLine(2, { color = { 0.1, 0.5, 1 } })
            assert.are.same({ 0.1, 0.5, 1 }, tc:Get().lines[2].color)
            assert.is_true(tc:UpdateLine(2, { color = false }))
            assert.is_nil(tc:Get().lines[2].color)
        end)

        it("refuses a colour that is not valid", function()
            assert.is_nil((tc:UpdateLine(2, { color = { 2, 0, 0 } })))
            assert.is_nil((tc:UpdateLine(2, { color = { 1, 0 } })))
            assert.is_nil((tc:UpdateLine(2, { color = "red" })))
            assert.is_nil(tc:Get().lines[2].color)
        end)

        it("keeps the colour over a reload and drops a malformed stored colour", function()
            tc:UpdateLine(2, { color = { 0.2, 0.3, 0.4 } })
            saved["p/Default/tooltip"].lines[3].color = "red"
            make()
            assert.are.same({ 0.2, 0.3, 0.4 }, tc:Get().lines[2].color)
            assert.is_nil(tc:Get().lines[3].color)
        end)
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
        assert.are.equal(1, #data.lines)
        assert.are.equal("table", data.lines[1].kind)
        assert.are.equal(2, data.nextID)
        assert.is_true(data.showCounts)
    end)

    it("refuses changes when the DB is read-only", function()
        local ro = open({ _schema = 99 })
        local store = ns.TooltipConfig.New(ro, { compile = compile })
        local ok, msg = store:AddLine("X", "scanmarket")
        assert.is_nil(ok)
        assert.are.equal("settings are read-only", msg)
        assert.are.equal(1, #store:Get().lines)
    end)

    it("loads invalid stored data read-only with one warning", function()
        saved["p/Default/tooltip"] = { version = 2, nextID = 1, lines = "x" }
        make()
        assert.are.equal(1, #warnings)
        local ok, msg = tc:SetFlag("showGroup", false)
        assert.is_nil(ok)
        assert.are.equal("settings are read-only", msg)
        assert.are.equal(1, #tc:Get().lines)
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

    describe("price table line", function()
        it("can be turned off and moved but not edited or removed", function()
            saved["p/Default/tooltip"] = nil
            make()
            local id = tc:Get().lines[1].id
            assert.is_true(tc:UpdateLine(id, { enabled = false }))
            assert.is_false(tc:Get().lines[1].enabled)
            local ok, msg = tc:UpdateLine(id, { formula = "scanlow" })
            assert.is_nil(ok)
            assert.are.equal("the price table has only an on/off setting and an Alt setting", msg)
            assert.is_nil((tc:UpdateLine(id, { label = "X" })))
            ok, msg = tc:RemoveLine(id)
            assert.is_nil(ok)
            assert.are.equal("the price table cannot be removed; turn it off", msg)
            assert.is_true(tc:AddLine("Avg", "scanmarket"))
            assert.is_true(tc:MoveLine(id, 1))
            assert.are.equal("Avg", tc:Get().lines[1].label)
            assert.are.equal("table", tc:Get().lines[2].kind)
        end)

        it("does not count against the 12 custom lines", function()
            saved["p/Default/tooltip"] = nil
            make()
            for i = 1, 12 do
                assert.is_true(tc:AddLine("L" .. i, "scanmarket"))
            end
            assert.are.equal(13, #tc:Get().lines)
            assert.is_nil((tc:AddLine("Extra", "scanmarket")))
        end)

        it("is rejected twice in stored data", function()
            local data = formulaData()
            data.lines = {
                tableLine(1),
                tableLine(2),
            }
            saved["p/Default/tooltip"] = data
            make()
            assert.are.equal(1, #warnings)
            assert.is_true(tc:IsReadOnly())
        end)
    end)

    describe("altStack", function()
        it("is true for a new line and the price table", function()
            assert.is_true(tc:AddLine("New", "scanmarket"))
            local lines = tc:Get().lines
            assert.is_true(lines[#lines].altStack)
            saved["p/Default/tooltip"] = nil
            make()
            assert.is_true(tc:Get().lines[1].altStack)
        end)

        it("gives stored lines without the field the default true", function()
            saved["p/Default/tooltip"] = formulaData()
            make()
            for _, line in ipairs(tc:Get().lines) do
                assert.is_true(line.altStack)
            end
            assert.are.equal(0, #warnings)
            assert.is_nil(saved["p/Default/tooltip"].lines[1].altStack)
            saved["p/Default/tooltip"] = v1Data()
            make()
            assert.is_true(tc:Get().lines[1].altStack)
        end)

        it("saves a change for a formula line and for the price table", function()
            assert.is_true(tc:UpdateLine(1, { altStack = false }))
            assert.is_false(tc:Get().lines[1].altStack)
            assert.is_false(saved["p/Default/tooltip"].lines[1].altStack)
            saved["p/Default/tooltip"] = nil
            make()
            assert.is_true(tc:UpdateLine(1, { altStack = false }))
            assert.is_false(tc:Get().lines[1].altStack)
            assert.is_nil((tc:UpdateLine(1, { altStack = "no" })))
            make()
            assert.is_false(tc:Get().lines[1].altStack)
        end)
    end)

    describe("migration from version 1", function()
        it("replaces the untouched default lines by the price table", function()
            saved["p/Default/tooltip"] = v1Data()
            make()
            local data = tc:Get()
            assert.are.equal(2, data.version)
            assert.are.equal(1, #data.lines)
            assert.are.equal("table", data.lines[1].kind)
            assert.are.equal(4, data.lines[1].id)
            assert.are.equal(5, data.nextID)
            assert.are.equal(0, #warnings)
            assert.are.equal(1, saved["p/Default/tooltip"].version)
            assert.are.equal(0, changes)
        end)

        it("keeps custom, changed and turned-off lines below the table", function()
            local data = v1Data()
            data.lines[2].formula = "scanlow * 2"
            data.lines[3].enabled = false
            data.lines[#data.lines + 1] = customLine(4, "Mine")
            data.nextID = 5
            saved["p/Default/tooltip"] = data
            make()
            local lines = tc:Get().lines
            assert.are.equal("table", lines[1].kind)
            assert.are.equal("Min", lines[2].label)
            assert.are.equal("Max", lines[3].label)
            assert.is_false(lines[3].enabled)
            assert.are.equal("Mine", lines[4].label)
            assert.are.equal(4, #lines)
            assert.are.equal(6, tc:Get().nextID)
        end)

        it("saves the new version on the next change", function()
            saved["p/Default/tooltip"] = v1Data()
            make()
            assert.is_true(tc:SetFlag("showGroup", false))
            assert.are.equal(2, saved["p/Default/tooltip"].version)
            assert.are.equal("table", saved["p/Default/tooltip"].lines[1].kind)
        end)

        it("accepts 12 custom lines next to the table", function()
            local data = v1Data()
            data.lines = {}
            for i = 1, 12 do
                data.lines[i] = customLine(i, "L" .. i)
            end
            data.nextID = 13
            saved["p/Default/tooltip"] = data
            make()
            assert.are.equal(13, #tc:Get().lines)
            assert.are.equal(0, #warnings)
        end)
    end)

    describe("vendor, period and stat settings", function()
        it("gives the defaults to a stored config without the new keys", function()
            local data = tc:Get()
            assert.is_true(data.showVendor)
            assert.are.same({ ["1d"] = true, ["14d"] = true, ["30d"] = true, ["60d"] = true }, data.periods)
            assert.are.same({ min = true, avg = true, max = true, market = true }, data.stats)
            assert.are.equal(3, #data.lines)
        end)

        it("gives the defaults to a config from version 1", function()
            saved["p/Default/tooltip"] = v1Data()
            make()
            assert.is_true(tc:Get().showVendor)
            assert.is_true(tc:Get().stats.market)
        end)

        it("keeps stored values and fills only the missing ones", function()
            local data = formulaData()
            data.showVendor = false
            data.periods = { ["14d"] = false }
            saved["p/Default/tooltip"] = data
            make()
            assert.is_false(tc:Get().showVendor)
            assert.is_false(tc:Get().periods["14d"])
            assert.is_true(tc:Get().periods["1d"])
        end)

        it("saves the vendor flag", function()
            assert.is_true(tc:SetFlag("showVendor", false))
            assert.is_false(saved["p/Default/tooltip"].showVendor)
        end)

        it("saves a period and a stat", function()
            assert.is_true(tc:SetPeriod("30d", false))
            assert.is_true(tc:SetStat("avg", false))
            assert.is_false(tc:Get().periods["30d"])
            assert.is_false(saved["p/Default/tooltip"].stats.avg)
        end)

        it("refuses an unknown name or a value that is not a boolean", function()
            assert.is_nil(tc:SetPeriod("7d", false))
            assert.is_nil(tc:SetStat("median", true))
            assert.is_nil(tc:SetStat("min", "no"))
        end)

        it("restores the settings with the defaults", function()
            tc:SetStat("min", false)
            tc:SetFlag("showVendor", false)
            assert.is_true(tc:ResetDefaults())
            assert.is_true(tc:Get().stats.min)
            assert.is_true(tc:Get().showVendor)
        end)
    end)end)
