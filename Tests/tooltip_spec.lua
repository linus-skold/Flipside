local manifest = require("Tests.manifest")
describe("Tooltip", function()
    local ns, registered, now, alt, reports, built, failBuild, callbackDeps

    local function newTooltip(owner)
        local t = { lines = {}, owner = owner }
        function t:AddLine(text, r) self.lines[#self.lines + 1] = { text = text, r = r } end
        function t:AddDoubleLine(l, r, lr) self.lines[#self.lines + 1] = { left = l, right = r, lr = lr } end
        function t:GetOwner() return self.owner end
        return t
    end

    before_each(function()
        ns = {}
        assert(loadfile(manifest.path("Tooltip")))("Flipside", ns)
        registered, now, alt, reports, built, failBuild = {}, 0, false, {}, {}, false
        ns.TooltipLines = {
            Build = function(ctx)
                built[#built + 1] = ctx
                if failBuild then error("build failed") end
                return {
                    { left = "Market", right = "1g", color = "normal" },
                    { left = "Group: A", color = "dim" },
                }
            end,
        }
        callbackDeps = {
            tooltipConfig = { Get = function() return { lines = {} } end },
            now = function() return 1234 end,
            isAltDown = function() return alt end,
            containerItemInfo = function() return { stackCount = 20 } end,
            hook = {
                Install = function(onItem, opts)
                    registered[#registered + 1] = { fn = onItem, opts = opts }
                    return true
                end,
            },
            clock = function() now = now + 2 return now end,
            report = function(message) reports[#reports + 1] = message end,
        }
    end)

    it("installs the hook once", function()
        ns.Tooltip.Attach(callbackDeps)
        assert.are.equal(1, #registered)
    end)

    it("reports a missing hook once", function()
        callbackDeps.hook = nil
        ns.Tooltip.Attach(callbackDeps)
        assert.are.same({ "tooltip hook not available" }, reports)
    end)

    it("gives the hook a report function that reports once", function()
        ns.Tooltip.Attach(callbackDeps)
        registered[1].opts.report("a")
        registered[1].opts.report("b")
        assert.are.same({ "a" }, reports)
    end)

    it("stops when the hook does not install", function()
        callbackDeps.hook.Install = function() return nil end
        assert.is_nil(ns.Tooltip.Attach(callbackDeps))
    end)

    it("handles an item through the shared entry point", function()
        ns.Tooltip.Attach(callbackDeps)
        local tip = newTooltip()
        ns.Tooltip.OnItem(tip, "item:5")
        assert.are.equal("item:5", built[1].input)
        assert.are.equal("Flipside", tip.lines[2].text)
    end)

    it("uses the stack count that the hook gives", function()
        alt = true
        ns.Tooltip.Attach(callbackDeps)
        ns.Tooltip.OnItem(newTooltip(), "item:5", 7)
        assert.are.equal(7, built[1].stackCount)
    end)

    it("ignores the entry point before an attach", function()
        ns.Tooltip.handler = nil
        assert.has_no.errors(function() ns.Tooltip.OnItem(newTooltip(), "item:5") end)
    end)
    it("adds a blank line, the header and the rows", function()
        ns.Tooltip.Attach(callbackDeps)
        local tip = newTooltip()
        registered[1].fn(tip, "item:5")
        assert.are.equal(" ", tip.lines[1].text)
        assert.are.equal("Flipside", tip.lines[2].text)
        assert.are.equal("Market", tip.lines[3].left)
        assert.is_nil(tip.lines[3].lr)
        assert.are.equal(0.6, tip.lines[4].lr)
        assert.are.equal("item:5", built[1].input)
        assert.are.equal(1234, built[1].now)
    end)

    it("adds nothing without a link", function()
        ns.Tooltip.Attach(callbackDeps)
        local tip = newTooltip()
        registered[1].fn(tip, nil)
        assert.are.equal(0, #tip.lines)
        assert.are.equal(0, #built)
    end)

    it("adds nothing to a quest item", function()
        callbackDeps.itemInfoInstant = function() return 5, "Quest", "Quest", "", 1, 12, 0 end
        ns.Tooltip.Attach(callbackDeps)
        local tip = newTooltip()
        registered[1].fn(tip, "item:5")
        assert.are.equal(0, #tip.lines)
        assert.are.equal(0, #built)
    end)

    describe("vendor sell price", function()
        local function run(sellPrice, record)
            ns.ItemString = { ToExactKey = function(link) return link end }
            callbackDeps.itemInfo = function()
                if sellPrice == nil then return nil end
                return "n", "l", 1, 1, 1, "t", "s", 1, "", 1, sellPrice
            end
            callbackDeps.getRecord = function() return record end
            ns.Tooltip.Attach(callbackDeps)
            local tip = newTooltip()
            registered[1].fn(tip, "item:5")
            return #tip.lines
        end

        it("adds nothing for sell price 0 without scan data", function()
            assert.are.equal(0, run(0, nil))
        end)
        it("adds lines for sell price 0 with scan data", function()
            assert.are.equal(4, run(0, { latest = {} }))
        end)
        it("adds lines for a sell price above 0", function()
            assert.are.equal(4, run(10, nil))
        end)
        it("adds lines for an unknown sell price", function()
            assert.are.equal(4, run(nil, nil))
        end)
        it("still adds nothing to a quest item with scan data", function()
            callbackDeps.itemInfoInstant = function() return 5, "Quest", "Quest", "", 1, 12, 0 end
            assert.are.equal(0, run(10, { latest = {} }))
        end)
    end)

    describe("keys and soulbound items", function()
        local bagOwner = { GetBagID = function() return 0 end, GetID = function() return 1 end }
        local function run(opts)
            ns.ItemString = { ToExactKey = function(link) return link end }
            callbackDeps.itemInfoInstant = function() return 5, "n", "t", "", 1, opts.class or 4, 0 end
            callbackDeps.itemInfo = function()
                return "n", "l", 1, 1, 1, "t", "s", 1, "", 1, 10, 4, 0, opts.bind
            end
            callbackDeps.getRecord = function() return { latest = {} } end
            callbackDeps.itemLocation = {
                CreateFromBagAndSlot = function() return "loc" end,
                CreateFromEquipmentSlot = function() return "loc" end,
            }
            callbackDeps.isBound = function() return opts.bound == true end
            ns.Tooltip.Attach(callbackDeps)
            local tip = newTooltip(opts.owner)
            registered[1].fn(tip, "item:5")
            return #tip.lines
        end

        it("adds nothing to a key even with scan data", function()
            assert.are.equal(0, run({ class = 13 }))
        end)
        it("adds nothing to a bind-on-pickup item", function()
            assert.are.equal(0, run({ bind = 1 }))
        end)
        it("adds nothing to a quest-bind item", function()
            assert.are.equal(0, run({ bind = 4 }))
        end)
        it("adds lines to an unbound bind-on-equip item in a bag", function()
            assert.are.equal(4, run({ bind = 2, owner = bagOwner }))
        end)
        it("adds nothing to a bound bind-on-equip item in a bag", function()
            assert.are.equal(0, run({ bind = 2, owner = bagOwner, bound = true }))
        end)
        it("adds nothing to a bound item in an equipment slot", function()
            local slot = { GetID = function() return 3 end, GetName = function() return "CharacterHeadSlot" end }
            assert.are.equal(0, run({ bind = 2, owner = slot, bound = true }))
        end)
        it("adds lines for an unknown bind type", function()
            assert.are.equal(4, run({ bind = nil, owner = bagOwner }))
        end)
        it("adds lines to a bind-on-equip chat link with no owner", function()
            assert.are.equal(4, run({ bind = 2, bound = true }))
        end)
    end)

    it("adds lines to a normal item and to an item with unknown class", function()
        callbackDeps.itemInfoInstant = function() return 5, "Armor", "Cloth", "", 1, 4, 1 end
        ns.Tooltip.Attach(callbackDeps)
        local tip = newTooltip()
        registered[1].fn(tip, "item:5")
        assert.are.equal(4, #tip.lines)
        callbackDeps.itemInfoInstant = function() return nil end
        local tip2 = newTooltip()
        registered[1].fn(tip2, "item:6")
        assert.are.equal(4, #tip2.lines)
    end)

    it("gives the stack count only with Alt", function()
        local owner = { GetBagID = function() return 0 end, GetID = function() return 1 end }
        ns.Tooltip.Attach(callbackDeps)
        registered[1].fn(newTooltip(owner), "item:5")
        assert.is_false(built[1].stackMode)
        assert.is_nil(built[1].stackCount)
        alt = true
        registered[1].fn(newTooltip(owner), "item:5")
        assert.is_true(built[2].stackMode)
        assert.are.equal(20, built[2].stackCount)
        registered[1].fn(newTooltip(), "item:5")
        assert.is_nil(built[3].stackCount)
    end)

    it("keeps the tooltip working when the build fails and reports once", function()
        ns.Tooltip.Attach(callbackDeps)
        failBuild = true
        local tip = newTooltip()
        assert.has_no.errors(function()
            registered[1].fn(tip, "item:5")
            registered[1].fn(tip, "item:5")
        end)
        assert.are.equal(0, #tip.lines)
        assert.are.equal(1, #reports)
    end)

    it("keeps the build time", function()
        ns.Tooltip.Attach(callbackDeps)
        registered[1].fn(newTooltip(), "item:5")
        registered[1].fn(newTooltip(), "item:5")
        assert.are.equal(2, ns.Tooltip.stats.count)
        assert.are.equal(4, ns.Tooltip.stats.total)
        assert.are.equal(2, ns.Tooltip.stats.max)
    end)
end)
