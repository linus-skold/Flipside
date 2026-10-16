local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function load(toc, flavour)
    mock.reset({ flavour = flavour })
    mock.playerName = "Tester"
    mock.realmName = "TestRealm"
    local ns = {}
    for _, path in ipairs(manifest.files(toc)) do
        assert(loadfile(path))("Flipside", ns)
    end
    return ns
end

local function ops(settings)
    return { version = 1, nextID = 2, ops = { [1] = { type = "selling", name = "Default", settings = settings } } }
end

describe("TBC post durations", function()
    after_each(function()
        _G.FlipsideDB_TBC = nil
        mock.teardown()
    end)

    it("offers 12, 24 and 48 hours, default 24", function()
        local ns = load("Flipside_TBC.toc", "tbc")
        assert.same({ 12, 24, 48 }, ns.SellingPlan.DURATIONS)
        local field
        for _, f in ipairs(ns.OperationSchema.Fields("selling")) do
            if f.key == "duration" then
                field = f
            end
        end
        assert.equal(24, field.default)
        assert.same({ 12, 24, 48 }, { field.choices[1].value, field.choices[2].value, field.choices[3].value })
        assert.equal("12 hours", field.choices[1].label)
        assert.equal(24, ns.SellingPlan.NormalizeDuration(nil))
    end)

    it("keeps 2, 8 and 24 hours on Forever", function()
        local ns = load("Flipside.toc", "forever")
        assert.same({ 2, 8, 24 }, ns.SellingPlan.DURATIONS)
        assert.equal(24, ns.SellingPlan.NormalizeDuration(nil))
    end)

    it("migrates a saved duration to the same index", function()
        local ns = load("Flipside_TBC.toc", "tbc")
        local saved = {
            _schema = 1,
            ["p/Default/operations"] = ops({ duration = 8, undercut = 5 }),
            ["p/Other/operations"] = ops({ duration = 24 }),
            ["p/Third/operations"] = ops({ duration = 2 }),
            ["p/Fourth/operations"] = ops({}),
        }
        local db = ns.SettingsDB.New(saved, {
            character = "Tester-TestRealm", schemaVersion = 2, migrations = { [2] = ns.MigrateDurations },
        })
        assert.is_not_nil(db)
        assert.equal(24, saved["p/Default/operations"].ops[1].settings.duration)
        assert.equal(5, saved["p/Default/operations"].ops[1].settings.undercut)
        assert.equal(48, saved["p/Other/operations"].ops[1].settings.duration)
        assert.equal(12, saved["p/Third/operations"].ops[1].settings.duration)
        assert.is_nil(saved["p/Fourth/operations"].ops[1].settings.duration)
        assert.equal(2, saved._schema)
    end)

    it("migrates once, on a schema 1 database at login", function()
        _G.FlipsideDB_TBC = { _schema = 1, ["p/Default/operations"] = ops({ duration = 24 }) }
        local ns = load("Flipside_TBC.toc", "tbc")
        _G.FlipsideDB_TBC = { _schema = 1, ["p/Default/operations"] = ops({ duration = 24 }) }
        mock.fire("ADDON_LOADED", "Flipside")
        mock.fire("PLAYER_LOGIN")
        assert.is_table(ns.db)
        assert.equal(48, _G.FlipsideDB_TBC["p/Default/operations"].ops[1].settings.duration)
        assert.equal(2, _G.FlipsideDB_TBC._schema)
    end)

    it("leaves Forever durations unchanged", function()
        local ns = load("Flipside.toc", "forever")
        local saved = { _schema = 1, ["p/Default/operations"] = ops({ duration = 8 }) }
        ns.SettingsDB.New(saved, {
            character = "Tester-TestRealm", schemaVersion = 2, migrations = { [2] = ns.MigrateDurations },
        })
        assert.equal(8, saved["p/Default/operations"].ops[1].settings.duration)
    end)
end)
