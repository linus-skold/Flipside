local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("LootSource")))("Flipside", ns)

local LootSource = ns.LootSource

local clock, reads, secrets

local function make(overrides)
    local deps = {
        now = function()
            return clock
        end,
        isSecret = function(value)
            return secrets[value] == true
        end,
        isFishing = function()
            return reads.fishing == true
        end,
        unit = function(token)
            local unit = reads.units[token]
            if unit then
                return unit[1], unit[2]
            end
        end,
        tooltipName = function()
            return reads.tooltip
        end,
        bagItemName = function(bag, slot)
            return reads.bags[bag .. ":" .. slot]
        end,
        formats = {
            split = "Your share of the loot is %s.", gold = "%d Gold", silver = "%d Silver", copper = "%d Copper",
        },
    }
    for name, value in pairs(overrides or {}) do
        deps[name] = value
    end
    return LootSource.New(deps)
end

describe("LootSource", function()
    before_each(function()
        clock, secrets = 100, {}
        reads = { units = {}, bags = {} }
    end)

    describe("Resolve", function()
        it("names a dead creature of the target as a mob", function()
            reads.units.target = { "Boar", "mob" }
            local name, kind = make():Resolve(false)
            assert.are.equal("Boar", name)
            assert.are.equal("mob", kind)
        end)

        it("names a game object under the mouse as an object", function()
            reads.units.mouseover = { "Small Chest", "object" }
            local name, kind = make():Resolve(false)
            assert.are.equal("Small Chest", name)
            assert.are.equal("object", kind)
        end)

        it("prefers the interact unit and the mouse over the target", function()
            reads.units.target = { "Boar", "mob" }
            reads.units.mouseover = { "Wolf", "mob" }
            reads.units.softinteract = { "Copper Vein", "object" }
            assert.are.equal("Copper Vein", (make():Resolve(false)))
            reads.units.softinteract = nil
            assert.are.equal("Wolf", (make():Resolve(false)))
        end)

        it("ignores a unit that is not a mob or an object", function()
            reads.units.target = { "Bob", "player" }
            assert.is_nil((make():Resolve(false)))
        end)

        it("names the world tooltip when no unit gives a name", function()
            reads.tooltip = "Peacebloom"
            local name, kind = make():Resolve(false)
            assert.are.equal("Peacebloom", name)
            assert.is_nil(kind)
        end)

        it("uses the target of a fresh own cast, for a node with no unit and no tooltip", function()
            local source = make()
            source:OnCast("player", "Silverleaf")
            clock = clock + LootSource.CAST_SECONDS - 1
            local name, kind = source:Resolve(false)
            assert.are.equal("Silverleaf", name)
            assert.is_nil(kind)
        end)

        it("ignores an old cast, a cast of another unit and a secret cast target", function()
            local source = make()
            source:OnCast("player", "Silverleaf")
            clock = clock + LootSource.CAST_SECONDS + 1
            assert.is_nil((source:Resolve(false)))
            source:OnCast("pet", "Silverleaf")
            assert.is_nil((source:Resolve(false)))
            secrets.Hidden = true
            source:OnCast("player", "Hidden")
            assert.is_nil((source:Resolve(false)))
        end)

        it("raises no error and keeps no cast for a secret target or a secret unit", function()
            local secret = setmetatable({}, {
                __eq = function() error("compare of a secret value") end,
                __lt = function() error("compare of a secret value") end,
                __le = function() error("compare of a secret value") end,
            })
            secrets[secret] = true
            local source = make()
            source:OnCast("player", "Silverleaf")
            assert.has_no.errors(function()
                source:OnCast("player", secret)
            end)
            assert.is_nil((source:Resolve(false)))
            source:OnCast("player", "Silverleaf")
            assert.has_no.errors(function()
                source:OnCast(secret, "Silverleaf")
            end)
            assert.is_nil((source:Resolve(false)))
        end)

        it("uses a cast only once", function()
            local source = make()
            source:OnCast("player", "Silverleaf")
            assert.are.equal("Silverleaf", (source:Resolve(false)))
            assert.is_nil((source:Resolve(false)))
        end)

        it("names a fishing window Fishing", function()
            reads.fishing = true
            reads.units.target = { "Boar", "mob" }
            local name, kind = make():Resolve(false)
            assert.are.equal("Fishing", name)
            assert.are.equal("fishing", kind)
        end)

        it("names an item window from the last used bag slot", function()
            reads.bags["2:5"] = "Small Lockbox"
            reads.units.target = { "Boar", "mob" }
            local source = make()
            source:OnLock(2, 5)
            local name, kind = source:Resolve(true)
            assert.are.equal("Small Lockbox", name)
            assert.are.equal("item", kind)
        end)

        it("uses the cast target for an item window only with no bag data, and gives no kind", function()
            local source = make()
            source:OnCast("player", "Small Lockbox")
            local name, kind = source:Resolve(true)
            assert.are.equal("Small Lockbox", name)
            assert.is_nil(kind)
            assert.is_nil((source:Resolve(true)))
        end)

        it("prefers the bag lock to the cast target for an item window", function()
            reads.bags["2:5"] = "Footlocker"
            local source = make()
            source:OnLock(2, 5)
            source:OnCast("player", "Small Lockbox")
            local name, kind = source:Resolve(true)
            assert.are.equal("Footlocker", name)
            assert.are.equal("item", kind)
        end)

        it("ignores a cast on the player, such as a self buff", function()
            local source = make({
                playerName = function()
                    return "Tester"
                end,
            })
            source:OnCast("player", "Tester")
            assert.is_nil((source:Resolve(false)))
        end)

        it("uses a dead target before the cast target", function()
            reads.units.target = { "Boar", "mob" }
            local source = make()
            source:OnCast("player", "Fireball Victim")
            local name, kind = source:Resolve(false)
            assert.are.equal("Boar", name)
            assert.are.equal("mob", kind)
        end)

        it("uses the tooltip before the cast target", function()
            reads.tooltip = "Peacebloom"
            local source = make()
            source:OnCast("player", "Silverleaf")
            assert.are.equal("Peacebloom", (source:Resolve(false)))
        end)

        it("does not use an old bag lock", function()
            reads.bags["2:5"] = "Small Lockbox"
            local source = make()
            source:OnLock(2, 5)
            clock = clock + LootSource.LOCK_SECONDS + 1
            assert.is_nil((source:Resolve(true)))
        end)

        it("gives nil when nothing is known", function()
            local name, kind = make():Resolve(false)
            assert.is_nil(name)
            assert.is_nil(kind)
        end)

        it("skips a secret or failing read", function()
            secrets.Hidden = true
            reads.units.mouseover = { "Hidden", "mob" }
            reads.tooltip = "Chest"
            assert.are.equal("Chest", (make():Resolve(false)))
            local source = make({
                unit = function()
                    error("boom")
                end,
            })
            assert.are.equal("Chest", (source:Resolve(false)))
        end)
    end)

    describe("ShareAmount", function()
        it("reads the copper amount of a share message", function()
            local source = make()
            assert.are.equal(10000, source:ShareAmount("Your share of the loot is 1 Gold."))
            assert.are.equal(32050, source:ShareAmount("Your share of the loot is 3 Gold, 20 Silver, 50 Copper."))
            assert.are.equal(7, source:ShareAmount("Your share of the loot is 7 Copper."))
        end)

        it("gives nil for the own loot message and for other text", function()
            local source = make()
            assert.is_nil(source:ShareAmount("You loot 1 Gold."))
            assert.is_nil(source:ShareAmount("Bob loots 1 Gold."))
            assert.is_nil(source:ShareAmount("Your share of the loot is nothing."))
            assert.is_nil(source:ShareAmount(nil))
        end)

        it("reads a format that ends in %s, and the guild variant", function()
            local source = make({
                formats = { split = "Share: %s", gold = "%d Gold", silver = "%d Silver", copper = "%d Copper" },
            })
            assert.are.equal(10005, source:ShareAmount("Share: 1 Gold, 5 Copper"))
            local guild = make({
                formats = {
                    split = "Your share of the loot is %s. (%s deposited to guild bank)", gold = "%d Gold",
                    silver = "%d Silver", copper = "%d Copper",
                },
            })
            local text = "Your share of the loot is 2 Silver, 50 Copper. (5 Silver deposited to guild bank)"
            assert.are.equal(250, guild:ShareAmount(text))
            -- The plain format also reads a guild text.
            assert.are.equal(10000, make():ShareAmount("Your share of the loot is 1 Gold. (3 Silver deposited)"))
        end)

        it("gives nil for a secret message or when the texts are missing", function()
            secrets["Your share of the loot is 1 Gold."] = true
            assert.is_nil(make():ShareAmount("Your share of the loot is 1 Gold."))
            assert.is_nil(make({ formats = {} }):ShareAmount("Your share of the loot is 1 Gold."))
        end)
    end)
end)
