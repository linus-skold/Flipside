local manifest = require("Tests.manifest")

local ARMOR, WEAPON = 4, 2
local CLOTH, PLATE, MISC_ARMOR = 1, 4, 0
local SWORD_2H, STAFF = 8, 10

describe("DestroyRules", function()
    local Rules, config

    -- A green plate chest by default: required level 20.
    local function item(fields)
        local base = { quality = 2, classID = ARMOR, subclassID = PLATE, minLevel = 20, equipLoc = "INVTYPE_CHEST" }
        for key, value in pairs(fields or {}) do
            base[key] = value
        end
        return base
    end

    before_each(function()
        local ns = {}
        assert(loadfile(manifest.path("DestroyRules")))("Flipside", ns)
        Rules = ns.DestroyRules
        config = Rules.Defaults()
    end)

    describe("defaults", function()
        it("are Uncommon to Epic, level gap 1, both sub-rules on", function()
            assert.are.same({
                minQuality = 2, maxQuality = 4, levelRule = true, levelGap = 1, unequippableRule = true,
            }, Rules.Defaults())
        end)

        it("fill a missing or bad saved config", function()
            assert.are.same(Rules.Defaults(), Rules.Normalize(nil))
            assert.are.same(Rules.Defaults(), Rules.Normalize({ minQuality = "x", levelGap = 0 / 0 }))
        end)

        it("keep the quality range inside Uncommon to Epic", function()
            local normal = Rules.Normalize({ minQuality = 0, maxQuality = 5 })
            assert.are.equal(2, normal.minQuality)
            assert.are.equal(4, normal.maxQuality)
        end)

        it("raise the maximum to the minimum if the range is upside down", function()
            local normal = Rules.Normalize({ minQuality = 4, maxQuality = 2 })
            assert.are.equal(4, normal.maxQuality)
        end)

        it("keep an off switch and a gap of 0", function()
            local normal = Rules.Normalize({ levelRule = false, levelGap = 0, unequippableRule = false })
            assert.is_false(normal.levelRule)
            assert.are.equal(0, normal.levelGap)
            assert.is_false(normal.unequippableRule)
        end)
    end)

    describe("quality", function()
        before_each(function()
            config.levelRule, config.unequippableRule = false, false
        end)

        it("matches inside the range", function()
            for quality = 2, 4 do
                assert.is_true(Rules.Matches(item({ quality = quality }), config, { level = 60, class = "MAGE" }))
            end
        end)

        it("does not match below or above the range", function()
            config.minQuality, config.maxQuality = 3, 3
            assert.is_false(Rules.Matches(item({ quality = 2 }), config, { level = 60, class = "MAGE" }))
            assert.is_false(Rules.Matches(item({ quality = 4 }), config, { level = 60, class = "MAGE" }))
            assert.is_true(Rules.Matches(item({ quality = 3 }), config, { level = 60, class = "MAGE" }))
        end)

        it("never matches Poor, Common or Legendary", function()
            for _, quality in ipairs({ 0, 1, 5, 6 }) do
                assert.is_false(Rules.Matches(item({ quality = quality }), config, { level = 60, class = "MAGE" }))
            end
        end)

        it("never matches Legendary even if the config asks for it", function()
            config.maxQuality = 5
            assert.is_false(Rules.Matches(item({ quality = 5 }), config, { level = 60, class = "MAGE" }))
        end)
    end)

    describe("level rule", function()
        before_each(function()
            config.unequippableRule = false
        end)

        it("matches when the required level is at most the player level minus the gap", function()
            assert.is_true(Rules.Matches(item({ minLevel = 19 }), config, { level = 20, class = "MAGE" }))
            assert.is_false(Rules.Matches(item({ minLevel = 20 }), config, { level = 20, class = "MAGE" }))
        end)

        it("uses the gap from the config", function()
            config.levelGap = 5
            assert.is_false(Rules.Matches(item({ minLevel = 16 }), config, { level = 20, class = "MAGE" }))
            assert.is_true(Rules.Matches(item({ minLevel = 15 }), config, { level = 20, class = "MAGE" }))
            config.levelGap = 0
            assert.is_true(Rules.Matches(item({ minLevel = 20 }), config, { level = 20, class = "MAGE" }))
        end)

        it("treats a missing required level as 0", function()
            assert.is_true(Rules.Matches(item({ minLevel = false }), config, { level = 5, class = "MAGE" }))
        end)

        it("does not match without a player level", function()
            assert.is_false(Rules.Matches(item({ minLevel = 1 }), config, { class = "MAGE" }))
        end)
    end)

    describe("unequippable rule", function()
        before_each(function()
            config.levelRule = false
        end)

        it("matches plate for a mage", function()
            assert.is_true(Rules.Matches(item(), config, { level = 10, class = "MAGE" }))
        end)

        it("does not match plate for a warrior", function()
            assert.is_false(Rules.Matches(item(), config, { level = 10, class = "WARRIOR" }))
        end)

        it("does not match cloth for a warrior or a mage", function()
            local cloth = item({ subclassID = CLOTH })
            assert.is_false(Rules.Matches(cloth, config, { level = 10, class = "WARRIOR" }))
            assert.is_false(Rules.Matches(cloth, config, { level = 10, class = "MAGE" }))
        end)

        it("does not match rings, necks and trinkets for any class", function()
            local ring = item({ subclassID = MISC_ARMOR, equipLoc = "INVTYPE_FINGER" })
            assert.is_false(Rules.Matches(ring, config, { level = 10, class = "PRIEST" }))
        end)

        it("checks weapons by weapon type", function()
            local sword = item({ classID = WEAPON, subclassID = SWORD_2H, equipLoc = "INVTYPE_2HWEAPON" })
            local staff = item({ classID = WEAPON, subclassID = STAFF, equipLoc = "INVTYPE_2HWEAPON" })
            assert.is_true(Rules.Matches(sword, config, { level = 10, class = "PRIEST" }))
            assert.is_false(Rules.Matches(sword, config, { level = 10, class = "WARRIOR" }))
            assert.is_false(Rules.Matches(staff, config, { level = 10, class = "PRIEST" }))
        end)

        it("does not match when the class is not known", function()
            assert.is_false(Rules.Matches(item(), config, { level = 10, class = "NEWCLASS" }))
            assert.is_nil(Rules.CanEquip("NEWCLASS", ARMOR, PLATE))
            assert.is_nil(Rules.CanEquip(nil, ARMOR, PLATE))
        end)
    end)

    describe("combination", function()
        local player = { level = 20, class = "WARRIOR" }

        it("matches if only the level rule matches", function()
            assert.is_true(Rules.Matches(item({ minLevel = 5 }), config, player))
        end)

        it("matches if only the unequippable rule matches", function()
            assert.is_true(Rules.Matches(item({ minLevel = 20, subclassID = 7 }), config, player))
        end)

        it("matches if both sub-rules match", function()
            assert.is_true(Rules.Matches(item({ minLevel = 5, subclassID = 7 }), config, player))
        end)

        it("does not match if no sub-rule matches", function()
            assert.is_false(Rules.Matches(item({ minLevel = 20 }), config, player))
        end)

        it("needs the quality in range even if a sub-rule matches", function()
            config.minQuality, config.maxQuality = 3, 4
            assert.is_false(Rules.Matches(item({ minLevel = 1, quality = 2 }), config, player))
        end)

        it("ignores a sub-rule that is off", function()
            config.levelRule = false
            assert.is_false(Rules.Matches(item({ minLevel = 1 }), config, player))
            config.levelRule, config.unequippableRule = true, false
            assert.is_false(Rules.Matches(item({ minLevel = 20, subclassID = 7 }), config, player))
        end)

        it("lets the quality decide if both sub-rules are off", function()
            config.levelRule, config.unequippableRule = false, false
            assert.is_true(Rules.Matches(item({ minLevel = 60 }), config, player))
            assert.is_false(Rules.Matches(item({ quality = 1 }), config, player))
        end)
    end)

    describe("item class", function()
        local player = { level = 60, class = "MAGE" }

        it("excludes items that are not armor or weapons", function()
            assert.is_false(Rules.Matches(item({ classID = 0 }), config, player))
            assert.is_false(Rules.Matches(item({ classID = 3 }), config, player))
            assert.is_false(Rules.Matches(item({ classID = 7 }), config, player))
            assert.is_false(Rules.Matches(item({ classID = false }), config, player))
        end)

        it("excludes shirts, tabards, cosmetic armor and fishing poles", function()
            assert.is_false(Rules.Matches(item({ equipLoc = "INVTYPE_BODY" }), config, player))
            assert.is_false(Rules.Matches(item({ equipLoc = "INVTYPE_TABARD" }), config, player))
            assert.is_false(Rules.Matches(item({ subclassID = 5 }), config, player))
            assert.is_false(Rules.Matches(item({ classID = WEAPON, subclassID = 20 }), config, player))
        end)

        it("does not match a missing item", function()
            assert.is_false(Rules.Matches(nil, config, player))
        end)
    end)

    describe("Rows", function()
        local player = { level = 60, class = "MAGE" }
        local infos, stacks

        local function infoOf(itemID)
            return infos[itemID]
        end

        before_each(function()
            infos = {
                [100] = item({ name = "Plate One", icon = 1 }),
                [200] = item({ name = "Plate Two", icon = 2, quality = 3 }),
                [300] = item({ name = "Potion", classID = 0 }),
            }
            stacks = {
                { bag = 1, slot = 3, itemID = 200, link = "link200" },
                { bag = 0, slot = 5, itemID = 100, link = "link100" },
                { bag = 0, slot = 1, itemID = 300, link = "link300" },
                { bag = 0, slot = 9, itemID = 400, link = "link400" },
            }
        end)

        it("lists the matching stacks by bag and slot", function()
            local rows, pending = Rules.Rows(stacks, infoOf, config, player, {}, {})
            assert.are.equal(2, #rows)
            assert.are.equal("Plate One", rows[1].name)
            assert.are.equal(0, rows[1].bag)
            assert.are.equal(5, rows[1].slot)
            assert.are.equal("link100", rows[1].link)
            assert.are.equal("Plate Two", rows[2].name)
            assert.are.same({ [400] = true }, pending)
        end)

        it("lists two stacks of the same item", function()
            stacks[#stacks + 1] = { bag = 2, slot = 1, itemID = 100, link = "link100" }
            local rows = Rules.Rows(stacks, infoOf, config, player, {}, {})
            assert.are.equal(3, #rows)
            assert.are_not.equal(rows[1].key, rows[3].key)
        end)

        it("leaves out an ignored item, in all its stacks", function()
            stacks[#stacks + 1] = { bag = 2, slot = 1, itemID = 100, link = "link100" }
            local rows = Rules.Rows(stacks, infoOf, config, player, { [100] = true }, {})
            assert.are.equal(1, #rows)
            assert.are.equal(200, rows[1].itemID)
        end)

        it("leaves out a skipped stack and keeps the other stacks of the item", function()
            stacks[#stacks + 1] = { bag = 2, slot = 1, itemID = 100, link = "link100" }
            local skipped = { [Rules.SkipKey(0, 5, 100)] = true }
            local rows = Rules.Rows(stacks, infoOf, config, player, {}, skipped)
            assert.are.equal(2, #rows)
            assert.are.equal(2, rows[2].bag)
        end)

        it("accepts nil for the ignore set and the skip set", function()
            local rows = Rules.Rows(stacks, infoOf, config, player, nil, nil)
            assert.are.equal(2, #rows)
        end)

        it("does not ask for the info of an ignored item", function()
            local asked = {}
            Rules.Rows(stacks, function(itemID)
                asked[itemID] = true
                return infos[itemID]
            end, config, player, { [400] = true }, {})
            assert.is_nil(asked[400])
        end)
    end)

    describe("store", function()
        local db, store

        before_each(function()
            local saved = {}
            db = {
                Get = function(_, scope, key)
                    assert.are.equal("account", scope)
                    return saved[key]
                end,
                Set = function(_, scope, key, value)
                    assert.are.equal("account", scope)
                    saved[key] = value
                    return true
                end,
            }
            store = Rules.NewStore(db)
        end)

        it("gives the default rules at first", function()
            assert.are.same(Rules.Defaults(), store.Config())
        end)

        it("saves the rules and normalises them", function()
            config.minQuality, config.maxQuality, config.levelGap = 3, 3, 4
            assert.is_true(store.SetConfig(config))
            assert.are.same(config, store.Config())
            store.SetConfig({ minQuality = 4, maxQuality = 2 })
            assert.are.equal(4, store.Config().maxQuality)
        end)

        it("ignores and un-ignores an item", function()
            assert.are.same({}, store.Ignored())
            store.SetIgnored(100, true)
            store.SetIgnored(50, true)
            assert.are.same({ [100] = true, [50] = true }, store.Ignored())
            assert.are.same({ 50, 100 }, Rules.IgnoredIDs(store.Ignored()))
            store.SetIgnored(100, false)
            assert.are.same({ [50] = true }, store.Ignored())
        end)

        it("gives a copy of the ignore set", function()
            store.SetIgnored(100, true)
            store.Ignored()[100] = nil
            assert.is_true(store.Ignored()[100])
        end)

        it("reports a read-only database", function()
            db.Set = function()
                return false
            end
            assert.is_false(store.SetIgnored(100, true))
        end)
    end)
end)
