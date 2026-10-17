local manifest = require("Tests.manifest")

local PROFILE_GROUPS = "p/Default/groups"
local UNCOMMON, EPIC = 2, 4
local CLOTH, WEAPON = 7, 2

-- A small stand-in for the regex engine: a pattern in /slashes/ or plain, ^ anchors, no other syntax.
local function stubRegex()
    return {
        Compile = function(source)
            if source == "(" then
                return nil, "missing )"
            end
            local body = source:match("^/(.*)/$") or source
            local anchored = body:sub(1, 1) == "^"
            if anchored then
                body = body:sub(2)
            end
            body = body:lower()
            return {
                Match = function(_, name)
                    name = name:lower()
                    if anchored then
                        return name:sub(1, #body) == body
                    end
                    return name:find(body, 1, true) ~= nil
                end,
            }
        end,
    }
end

describe("AutoRules", function()
    local ns, saved, store, linen, uncommonLinen

    local function load()
        ns = {}
        for _, name in ipairs({ "EventBus", "ItemString", "SettingsDB", "GroupTree", "OperationSchema",
            "RulesStore", "MailingPlan", "AutoRules" }) do
            assert(loadfile(manifest.path(name)))("Flipside", ns)
        end
        ns.NameRegex = stubRegex()
    end

    local function newStore()
        local db = ns.SettingsDB.New(saved, { character = "Me", schemaVersion = 1 })
        return ns.RulesStore.New(db, { onWarning = function() end })
    end

    local function item(key, name, quality, class)
        return { key = key, name = name, quality = quality, class = class }
    end

    local function ungrouped()
        return 1
    end

    before_each(function()
        load()
        saved = {}
        store = newStore()
        linen = store:CreateGroup(1, "Linen")
        uncommonLinen = store:CreateGroup(1, "Uncommon Linen")
    end)

    describe("Normalize and Validate", function()
        it("cleans a rule and fills the defaults", function()
            local rule = ns.AutoRules.Normalize({ group = 3, pattern = "  ^Linen ", classes = "4, 2" })
            assert.are.same({ group = 3, pattern = "^Linen", minQuality = 0, maxQuality = 5, classes = "2,4" }, rule)
        end)

        it("clamps the rarity and drops a bad group", function()
            local rule = ns.AutoRules.Normalize({ group = "x", minQuality = -3, maxQuality = 9 })
            assert.is_nil(rule.group)
            assert.are.equal(0, rule.minQuality)
            assert.are.equal(5, rule.maxQuality)
        end)

        it("returns nil for a value that is no table", function()
            assert.is_nil(ns.AutoRules.Normalize("x"))
        end)

        it("refuses a rule with no filter", function()
            local ok, message = ns.AutoRules.Validate({ group = linen })
            assert.is_false(ok)
            assert.is_string(message)
            assert.is_false((ns.AutoRules.Validate({ group = linen, minQuality = 0, maxQuality = 5, classes = "" })))
        end)

        it("accepts one filter of each kind", function()
            assert.is_true((ns.AutoRules.Validate({ pattern = "Linen" })))
            assert.is_true((ns.AutoRules.Validate({ minQuality = 2 })))
            assert.is_true((ns.AutoRules.Validate({ maxQuality = 3 })))
            assert.is_true((ns.AutoRules.Validate({ classes = "7" })))
        end)

        it("refuses a lowest rarity above the highest", function()
            assert.is_false((ns.AutoRules.Validate({ minQuality = 4, maxQuality = 2 })))
        end)

        it("gives the compile error of a bad pattern", function()
            local ok, message = ns.AutoRules.Validate({ pattern = "(" })
            assert.is_false(ok)
            assert.are.equal("missing )", message)
        end)

        it("accepts a pattern when there is no regex engine", function()
            ns.NameRegex = nil
            assert.is_true((ns.AutoRules.Validate({ pattern = "(" })))
        end)
    end)

    describe("Match", function()
        local rules

        before_each(function()
            rules = {
                { group = uncommonLinen, pattern = "^Linen", minQuality = UNCOMMON, maxQuality = 5 },
                { group = linen, pattern = "^Linen" },
            }
        end)

        it("lets the first matching rule win", function()
            local rule, index = ns.AutoRules.Match(rules, item("1", "Linen Cloth", 3, CLOTH))
            assert.are.equal(uncommonLinen, rule.group)
            assert.are.equal(1, index)
            rule, index = ns.AutoRules.Match(rules, item("2", "Linen Cloth", 1, CLOTH))
            assert.are.equal(linen, rule.group)
            assert.are.equal(2, index)
        end)

        it("returns nil when no rule matches", function()
            assert.is_nil(ns.AutoRules.Match(rules, item("3", "Silk Cloth", 3, CLOTH)))
        end)

        it("needs all set filters to match", function()
            local list = { { group = linen, pattern = "cloth", minQuality = 1, maxQuality = 2, classes = "7" } }
            assert.is_not_nil(ns.AutoRules.Match(list, item("1", "Linen Cloth", 1, CLOTH)))
            assert.is_nil(ns.AutoRules.Match(list, item("1", "Linen Cloth", 3, CLOTH)))
            assert.is_nil(ns.AutoRules.Match(list, item("1", "Linen Cloth", 1, WEAPON)))
            assert.is_nil(ns.AutoRules.Match(list, item("1", "Linen Rag", 1, CLOTH)))
        end)

        it("takes any type when the type list is empty", function()
            local list = { { group = linen, minQuality = 1 } }
            assert.is_not_nil(ns.AutoRules.Match(list, item("1", "A", 1, WEAPON)))
            assert.is_not_nil(ns.AutoRules.Match(list, item("1", "A", 1, CLOTH)))
        end)

        it("takes one of many types", function()
            local list = { { group = linen, classes = "2,7" } }
            assert.is_not_nil(ns.AutoRules.Match(list, item("1", "A", 1, WEAPON)))
            assert.is_not_nil(ns.AutoRules.Match(list, item("1", "A", 1, CLOTH)))
            assert.is_nil(ns.AutoRules.Match(list, item("1", "A", 1, 12)))
        end)

        it("has no upper limit for highest rarity 5", function()
            local list = { { group = linen, minQuality = 4, maxQuality = 5 } }
            assert.is_not_nil(ns.AutoRules.Match(list, item("1", "A", 6, CLOTH)))
            list = { { group = linen, minQuality = 4, maxQuality = 4 } }
            assert.is_nil(ns.AutoRules.Match(list, item("1", "A", 6, CLOTH)))
            assert.is_not_nil(ns.AutoRules.Match(list, item("1", "A", EPIC, CLOTH)))
        end)

        it("never matches a rule with no filter", function()
            assert.is_nil(ns.AutoRules.Match({ { group = linen } }, item("1", "A", 1, CLOTH)))
        end)

        it("never matches a pattern rule when there is no regex engine", function()
            ns.NameRegex = nil
            assert.is_nil(ns.AutoRules.Match({ { group = linen, pattern = "Linen" } }, item("1", "Linen", 1, CLOTH)))
        end)

        it("matches a rarity rule when there is no regex engine", function()
            ns.NameRegex = nil
            assert.is_not_nil(ns.AutoRules.Match({ { group = linen, minQuality = 1 } }, item("1", "A", 1, CLOTH)))
        end)

        it("skips a rule with a bad pattern", function()
            local list = { { group = linen, pattern = "(" }, { group = uncommonLinen, minQuality = 1 } }
            local rule = ns.AutoRules.Match(list, item("1", "A", 1, CLOTH))
            assert.are.equal(uncommonLinen, rule.group)
        end)

        it("skips a rule with a deleted group", function()
            local list = { { group = 99, minQuality = 1 }, { group = linen, minQuality = 1 } }
            local rule, index = ns.AutoRules.Match(list, item("1", "A", 1, CLOTH), function(id)
                return store:AutoRuleTarget(id)
            end)
            assert.are.equal(linen, rule.group)
            assert.are.equal(2, index)
        end)

        it("does not match an item with unknown rarity against a rarity filter", function()
            assert.is_nil(ns.AutoRules.Match({ { group = linen, minQuality = 1 } }, item("1", "A", nil, CLOTH)))
        end)
    end)

    describe("Plan", function()
        local rules

        before_each(function()
            rules = {
                { group = uncommonLinen, pattern = "^Linen", minQuality = UNCOMMON },
                { group = linen, pattern = "^Linen" },
            }
        end)

        it("plans each item with the first matching rule, in item order", function()
            local items = {
                item("10", "Linen Cloth", 1, CLOTH),
                item("11", "Bolt of Linen Cloth", 1, CLOTH),
                item("12", "Linen Bandage", 3, 1),
            }
            local plan, unknown = ns.AutoRules.Plan(rules, items, ungrouped)
            assert.are.equal(0, unknown)
            assert.are.same({
                { key = "10", groupID = linen, ruleIndex = 2, name = "Linen Cloth" },
                { key = "12", groupID = uncommonLinen, ruleIndex = 1, name = "Linen Bandage" },
            }, plan)
        end)

        it("never moves an item that is in a group", function()
            local grouped = { ["10"] = linen }
            local plan = ns.AutoRules.Plan(rules, { item("10", "Linen Cloth", 1, CLOTH) }, function(key)
                return grouped[key] or 1
            end)
            assert.are.same({}, plan)
        end)

        it("skips items with unknown data and counts them", function()
            local items = {
                item("10", nil, nil, nil),
                item("11", "Linen Cloth", nil, CLOTH),
                item("12", "Linen Cloth", 1, nil),
                item("13", "Linen Cloth", 1, CLOTH),
            }
            local plan, unknown = ns.AutoRules.Plan(rules, items, ungrouped)
            assert.are.equal(3, unknown)
            assert.are.equal(1, #plan)
            assert.are.equal("13", plan[1].key)
        end)

        it("plans a key once", function()
            local plan = ns.AutoRules.Plan(rules, { item("10", "Linen", 1, 7), item("10", "Linen", 1, 7) }, ungrouped)
            assert.are.equal(1, #plan)
        end)

        it("plans nothing for an empty rule list", function()
            assert.are.same({}, (ns.AutoRules.Plan({}, { item("10", "Linen", 1, 7) }, ungrouped)))
        end)

        it("skips a rule with a deleted group", function()
            store:DeleteGroup(linen)
            local plan = ns.AutoRules.Plan({ { group = linen, pattern = "^Linen" } },
                { item("10", "Linen Cloth", 1, CLOTH) }, ungrouped, function(id)
                    return store:AutoRuleTarget(id)
                end)
            assert.are.same({}, plan)
        end)
    end)

    describe("store", function()
        it("has no rules and the switch on for an old profile", function()
            assert.are.same({}, store:AutoRules())
            assert.is_true(store:AutoRulesEnabled())
        end)

        it("adds, keeps order, saves and reloads", function()
            assert.are.equal(1, store:AddAutoRule({ group = uncommonLinen, pattern = "^Linen", minQuality = 2 }))
            assert.are.equal(2, store:AddAutoRule({ group = linen, pattern = "^Linen" }))
            assert.is_true(ns.GroupTree.Validate(saved[PROFILE_GROUPS]))
            local again = newStore()
            local list = again:AutoRules()
            assert.are.equal(2, #list)
            assert.are.equal(uncommonLinen, list[1].group)
            assert.are.equal(linen, list[2].group)
        end)

        it("refuses an invalid rule and an All bag items target", function()
            local ok, message = store:AddAutoRule({ group = linen })
            assert.is_nil(ok)
            assert.is_string(message)
            local all = store:EnsureAllBagsGroup()
            assert.is_nil((store:AddAutoRule({ group = all, minQuality = 1 })))
            assert.is_nil((store:AddAutoRule({ group = 1, minQuality = 1 })))
            assert.is_nil((store:AddAutoRule({ group = 999, minQuality = 1 })))
            assert.are.same({}, store:AutoRules())
        end)

        it("updates and deletes a rule", function()
            store:AddAutoRule({ group = linen, pattern = "a" })
            assert.is_true(store:UpdateAutoRule(1, { group = uncommonLinen, minQuality = 3 }))
            assert.are.equal(uncommonLinen, store:AutoRules()[1].group)
            assert.is_nil((store:UpdateAutoRule(5, { group = linen, minQuality = 1 })))
            assert.is_true(store:DeleteAutoRule(1))
            assert.are.same({}, store:AutoRules())
            assert.is_nil((store:DeleteAutoRule(1)))
        end)

        it("moves a rule up and down", function()
            store:AddAutoRule({ group = linen, pattern = "a" })
            store:AddAutoRule({ group = linen, pattern = "b" })
            store:AddAutoRule({ group = linen, pattern = "c" })
            assert.are.equal(1, store:MoveAutoRule(2, -1))
            assert.are.equal(2, store:MoveAutoRule(1, 1))
            local order = {}
            for _, rule in ipairs(store:AutoRules()) do
                order[#order + 1] = rule.pattern
            end
            assert.are.same({ "a", "b", "c" }, order)
            store:MoveAutoRule(3, -1)
            order = {}
            for _, rule in ipairs(store:AutoRules()) do
                order[#order + 1] = rule.pattern
            end
            assert.are.same({ "a", "c", "b" }, order)
        end)

        it("does not move past the ends", function()
            store:AddAutoRule({ group = linen, pattern = "a" })
            store:AddAutoRule({ group = linen, pattern = "b" })
            assert.is_nil((store:MoveAutoRule(1, -1)))
            assert.is_nil((store:MoveAutoRule(2, 1)))
        end)

        it("keeps a rule whose group was deleted in the list, and it does not match", function()
            store:AddAutoRule({ group = linen, pattern = "Linen" })
            store:DeleteGroup(linen)
            local list = store:AutoRules()
            assert.are.equal(1, #list)
            assert.is_false(store:AutoRuleTarget(list[1].group))
            assert.are.same({}, (ns.AutoRules.Plan(list, { item("1", "Linen", 1, 7) }, ungrouped, function(id)
                return store:AutoRuleTarget(id)
            end)))
        end)

        it("saves the switch", function()
            assert.is_true(store:SetAutoRulesEnabled(false))
            assert.is_false(newStore():AutoRulesEnabled())
            assert.is_true(store:SetAutoRulesEnabled(true))
            assert.is_true(newStore():AutoRulesEnabled())
        end)

        it("refuses a change when the store is read-only", function()
            saved[PROFILE_GROUPS] = { version = 99 }
            local locked = newStore()
            assert.is_nil((locked:AddAutoRule({ group = 2, minQuality = 1 })))
        end)
    end)

    describe("runner", function()
        local bus, timers, printed, bagEntries, cache

        local function attach()
            return ns.AutoRules.Attach({
                bus = bus,
                rules = store,
                readBags = function()
                    return bagEntries
                end,
                itemCache = cache,
                after = function(seconds, fn)
                    timers[#timers + 1] = { seconds = seconds, fn = fn }
                end,
                print = function(text)
                    printed[#printed + 1] = text
                end,
            })
        end

        local function fire()
            local due = timers
            timers = {}
            for _, timer in ipairs(due) do
                timer.fn()
            end
        end

        before_each(function()
            bus = ns.EventBus.New({})
            timers, printed = {}, {}
            local infos = {
                [10] = { name = "Linen Cloth", quality = 1, classID = CLOTH },
                [11] = { name = "Linen Bandage", quality = 3, classID = 1 },
            }
            cache = {
                requests = {},
                Get = function(_, id)
                    return infos[id]
                end,
                Request = function(self, id)
                    self.requests[#self.requests + 1] = id
                end,
            }
            bagEntries = { { key = "10", itemID = 10 }, { key = "11", itemID = 11 }, { key = "12", itemID = 12 } }
            store:AddAutoRule({ group = uncommonLinen, pattern = "^Linen", minQuality = 2 })
            store:AddAutoRule({ group = linen, pattern = "^Linen" })
        end)

        it("adds matching items of no group after the delay and prints one line", function()
            attach()
            assert.are.equal(0.5, timers[1].seconds)
            fire()
            assert.are.equal(linen, store:GroupOf("10"))
            assert.are.equal(uncommonLinen, store:GroupOf("11"))
            assert.are.same({ "2 items added to groups by the auto rules" }, printed)
        end)

        it("asks the cache to load an unknown item and tries again on the next bag change", function()
            attach()
            fire()
            assert.are.same({ 12 }, cache.requests)
            assert.are.equal(1, store:GroupOf("12"))
            cache.Get = function(_, id)
                if id == 12 then
                    return { name = "Linen Scrap", quality = 0, classID = CLOTH }
                end
                return nil
            end
            bus:Emit("BAG_UPDATE_DELAYED")
            fire()
            assert.are.equal(linen, store:GroupOf("12"))
        end)

        it("runs once for many bag events", function()
            attach()
            fire()
            for _ = 1, 5 do
                bus:Emit("BAG_UPDATE_DELAYED")
            end
            assert.are.equal(1, #timers)
        end)

        it("never moves an item that is in a group", function()
            store:AddItem("10", uncommonLinen)
            attach()
            fire()
            assert.are.equal(uncommonLinen, store:GroupOf("10"))
        end)

        it("does nothing when the switch is off", function()
            store:SetAutoRulesEnabled(false)
            attach()
            fire()
            assert.are.equal(1, store:GroupOf("10"))
            assert.are.same({}, printed)
        end)

        it("prints nothing when no item matches", function()
            bagEntries = { { key = "12", itemID = 12 } }
            attach()
            fire()
            assert.are.same({}, printed)
        end)
    end)

    describe("with the real NameRegex", function()
        before_each(function()
            assert(loadfile(manifest.path("NameRegex")))("Flipside", ns)
        end)

        it("sends the Linen example to the right groups", function()
            local rules = {
                { group = uncommonLinen, pattern = "^Linen", minQuality = UNCOMMON },
                { group = linen, pattern = "^Linen" },
            }
            local plan = ns.AutoRules.Plan(rules, {
                item("10", "Linen Cloth", 1, CLOTH),
                item("11", "Linen Bandage", 3, 1),
                item("12", "Bolt of Linen Cloth", 3, CLOTH),
            }, ungrouped)
            assert.are.same({
                { key = "10", groupID = linen, ruleIndex = 2, name = "Linen Cloth" },
                { key = "11", groupID = uncommonLinen, ruleIndex = 1, name = "Linen Bandage" },
            }, plan)
        end)

        it("matches an alternation with an end anchor", function()
            local rules = { { group = linen, pattern = "(Linen|Wool) Cloth$" } }
            local function matches(name)
                return ns.AutoRules.Match(rules, item("1", name, 1, CLOTH)) ~= nil
            end
            assert.is_true(matches("Linen Cloth"))
            assert.is_true(matches("Bolt of Wool Cloth"))
            assert.is_false(matches("Silk Cloth"))
            assert.is_false(matches("Linen Cloth Bag"))
        end)
    end)

    describe("Apply", function()
        it("adds the planned items to their groups and counts them", function()
            local plan = {
                { key = "10", groupID = linen },
                { key = "11", groupID = uncommonLinen },
                { key = "12", groupID = linen },
            }
            assert.are.equal(3, ns.AutoRules.Apply(store, plan))
            assert.are.equal(linen, store:GroupOf("12"))
            assert.are.equal(uncommonLinen, store:GroupOf("11"))
        end)
    end)
end)
