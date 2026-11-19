local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local PRICE = "first(scanrecent, scanmarket)"
local OLD_MIN = "check(first(crafting, scanmarket), "
    .. "max(0.25 * avg(crafting, scanmarket, scanhistorical), 1.5 * vendorsell))"
local NEW_MIN = "check(first(crafting, scanrecent, scanmarket), "
    .. "max(0.25 * avg(crafting, scanmarket, scanhistorical), 1.5 * vendorsell))"

local function load()
    mock.reset({ flavour = "forever" })
    mock.playerName = "Tester"
    mock.realmName = "TestRealm"
    local ns = {}
    for _, path in ipairs(manifest.files("Flipside.toc")) do
        assert(loadfile(path))("Flipside", ns)
    end
    return ns
end

local function ops(list)
    local data = { version = 1, nextID = #list + 1, ops = {} }
    for id, op in ipairs(list) do
        data.ops[id] = op
    end
    return data
end

local function selling(settings)
    return { type = "selling", name = "S", settings = settings }
end

local function buying(settings)
    return { type = "buying", name = "B", settings = settings }
end

describe("default price source", function()
    local ns

    local function open(saved)
        return ns.SettingsDB.New(saved, {
            character = "Tester-TestRealm",
            schemaVersion = 3,
            migrations = { [2] = ns.MigrateDurations, [3] = ns.MigrateDefaultPrices },
        })
    end

    before_each(function()
        ns = load()
    end)

    after_each(function()
        _G.FlipsideDB = nil
        mock.teardown()
    end)

    describe("new defaults", function()
        it("use the latest scan with the average as fallback", function()
            local defaults = ns.OperationSchema.Defaults("selling")
            assert.equal(NEW_MIN, defaults.minPrice)
            assert.equal(PRICE, defaults.normalPrice)
            assert.equal("2 * " .. PRICE, defaults.maxPrice)
            assert.equal(PRICE, ns.OperationSchema.Defaults("buying").maxPrice)
        end)

        it("compile as formulas", function()
            local run = ns.FormulaRun.New({
                sources = ns.FormulaSources.New({}),
                serverTime = function() return 0 end,
            })
            for _, text in ipairs({ NEW_MIN, PRICE, "2 * " .. PRICE }) do
                assert.is_truthy((run:Compile(text)))
            end
        end)

        it("give a new profile operation the new texts", function()
            local saved = {}
            local db = open(saved)
            local rules = ns.RulesStore.New(db, { compile = function(text) return { text = text } end })
            local id = rules:CreateOperation("selling", "Mine")
            assert.equal(PRICE, rules:GetOperation(id).settings.normalPrice)
            assert.equal("2 * " .. PRICE, rules:GetOperation(id).settings.maxPrice)
        end)
    end)

    describe("migration", function()
        it("rewrites an untouched default and keeps an edited formula", function()
            local saved = {
                _schema = 2,
                ["p/Default/operations"] = ops({
                    selling({
                        minPrice = OLD_MIN, normalPrice = "scanmarket", maxPrice = "2 * scanmarket", undercut = 5,
                    }),
                    selling({ normalPrice = "scanmarket * 0.9", maxPrice = "3 * scanmarket" }),
                    buying({ maxPrice = "scanmarket", showAboveMax = true }),
                    buying({ maxPrice = "" }),
                }),
            }
            open(saved)
            local list = saved["p/Default/operations"].ops
            assert.equal(NEW_MIN, list[1].settings.minPrice)
            assert.equal(PRICE, list[1].settings.normalPrice)
            assert.equal("2 * " .. PRICE, list[1].settings.maxPrice)
            assert.equal(5, list[1].settings.undercut)
            assert.equal("scanmarket * 0.9", list[2].settings.normalPrice)
            assert.equal("3 * scanmarket", list[2].settings.maxPrice)
            assert.equal(PRICE, list[3].settings.maxPrice)
            assert.is_true(list[3].settings.showAboveMax)
            assert.equal("", list[4].settings.maxPrice)
            assert.equal(3, saved._schema)
        end)

        it("matches the old default with other spaces and letter case", function()
            local saved = {
                _schema = 2,
                ["p/Default/operations"] = ops({
                    selling({ normalPrice = "  ScanMarket ", maxPrice = "2*SCANMARKET" }),
                    buying({ maxPrice = "\tscanMarket\n" }),
                }),
            }
            open(saved)
            local list = saved["p/Default/operations"].ops
            assert.equal(PRICE, list[1].settings.normalPrice)
            assert.equal("2 * " .. PRICE, list[1].settings.maxPrice)
            assert.equal(PRICE, list[2].settings.maxPrice)
        end)

        it("does not change a vendoring or mailing operation or a missing setting", function()
            local saved = {
                _schema = 2,
                ["p/Default/operations"] = ops({
                    { type = "vendoring", name = "V", settings = { maxPrice = "scanmarket" } },
                    { type = "mailing", name = "M", settings = { maxPrice = "scanmarket" } },
                    selling({}),
                }),
            }
            open(saved)
            local list = saved["p/Default/operations"].ops
            assert.equal("scanmarket", list[1].settings.maxPrice)
            assert.equal("scanmarket", list[2].settings.maxPrice)
            assert.is_nil(list[3].settings.normalPrice)
        end)

        it("covers the operations of every profile", function()
            local saved = {
                _schema = 2,
                ["p/Default/operations"] = ops({ selling({ normalPrice = "scanmarket" }) }),
                ["p/Other/operations"] = ops({ buying({ maxPrice = "scanmarket" }) }),
                ["p/Third/operations"] = ops({ selling({ normalPrice = "scanmarket + 1" }) }),
            }
            open(saved)
            assert.equal(PRICE, saved["p/Default/operations"].ops[1].settings.normalPrice)
            assert.equal(PRICE, saved["p/Other/operations"].ops[1].settings.maxPrice)
            assert.equal("scanmarket + 1", saved["p/Third/operations"].ops[1].settings.normalPrice)
        end)

        it("is idempotent", function()
            local saved = {
                _schema = 2,
                ["p/Default/operations"] = ops({
                    selling({ minPrice = OLD_MIN, normalPrice = "scanmarket", maxPrice = "2 * scanmarket" }),
                    buying({ maxPrice = "scanmarket" }),
                }),
            }
            open(saved)
            local first = saved["p/Default/operations"].ops
            local copy = {
                minPrice = first[1].settings.minPrice, normalPrice = first[1].settings.normalPrice,
                maxPrice = first[1].settings.maxPrice, buy = first[2].settings.maxPrice,
            }
            ns.MigrateDefaultPrices(saved)
            open(saved)
            assert.same(copy, {
                minPrice = first[1].settings.minPrice, normalPrice = first[1].settings.normalPrice,
                maxPrice = first[1].settings.maxPrice, buy = first[2].settings.maxPrice,
            })
            assert.equal(PRICE, first[2].settings.maxPrice)
        end)

        it("skips a malformed operation list", function()
            local saved = {
                _schema = 2,
                ["p/Default/operations"] = { version = 1, nextID = 1, ops = { "bad", { type = "selling" } } },
                ["p/Other/operations"] = "bad",
            }
            local db = open(saved)
            assert.is_false(db:IsReadOnly())
            assert.equal(3, saved._schema)
        end)

        it("does not touch a read-only database", function()
            local saved = {
                _schema = 99,
                ["p/Default/operations"] = ops({ selling({ normalPrice = "scanmarket" }) }),
            }
            local db = open(saved)
            assert.is_true(db:IsReadOnly())
            assert.equal("scanmarket", saved["p/Default/operations"].ops[1].settings.normalPrice)
            assert.equal(99, saved._schema)
        end)

        it("runs once at login on a schema 2 database", function()
            local function old()
                local settings = { normalPrice = "scanmarket", maxPrice = "2 * scanmarket" }
                return { _schema = 2, ["p/Default/operations"] = ops({ selling(settings) }) }
            end
            _G.FlipsideDB = old()
            ns = load()
            _G.FlipsideDB = old()
            mock.fire("ADDON_LOADED", "Flipside")
            mock.fire("PLAYER_LOGIN")
            assert.is_table(ns.db)
            local settings = _G.FlipsideDB["p/Default/operations"].ops[1].settings
            assert.equal(PRICE, settings.normalPrice)
            assert.equal("2 * " .. PRICE, settings.maxPrice)
            assert.equal(3, _G.FlipsideDB._schema)
        end)
    end)
end)
