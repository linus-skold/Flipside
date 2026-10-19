local manifest = require("Tests.manifest")

describe("CraftPanel", function()
    local ns, bus, panel

    before_each(function()
        ns = {}
        assert(loadfile(manifest.path("EventBus")))("Flipside", ns)
        assert(loadfile(manifest.path("CraftCost")))("Flipside", ns)
        assert(loadfile(manifest.path("CraftClient")))("Flipside", ns)
        assert(loadfile(manifest.path("CraftPanel")))("Flipside", ns)
        bus = ns.EventBus.New()
        panel = ns.CraftPanel
    end)

    describe("PriceFunction", function()
        it("gives the copper of the formula for the item", function()
            local seen
            local run = { Evaluate = function(_, text, itemID) seen = { text, itemID } return 120 end }
            local price = panel.PriceFunction(run, function() return "scanmin" end)
            assert.are.equal(120, price(7))
            assert.are.same({ "scanmin", 7 }, seen)
        end)

        it("gives nil for an invalid formula result, a zero price, no runner and an error", function()
            local value
            local run = { Evaluate = function() return value end }
            local price = panel.PriceFunction(run, function() return "x" end)
            assert.is_nil(price(1))
            value = 0
            assert.is_nil(price(1))
            assert.is_nil(panel.PriceFunction(nil, function() return "x" end)(1))
            run.Evaluate = function() error("boom") end
            assert.is_nil(price(1))
        end)
    end)

    describe("SummaryLines", function()
        local function format(copper) return copper .. "c" end

        local function base()
            return { cost = 100, partial = false, hasItem = true, made = 1, value = 300, cutAmount = 15,
                profit = 185, percent = 185 }
        end

        it("shows the profit as good with its percent", function()
            local lines = panel.SummaryLines(base(), format)
            assert.are.same({ "Craft cost: 100c" }, lines[1])
            assert.are.same({ "Item value: 300c" }, lines[2])
            assert.are.same({ "AH cut: -15c" }, lines[3])
            assert.are.same({ "Profit: 185c", "good" }, lines[4])
            assert.are.same({ "Profit of cost: 185%", "good" }, lines[5])
        end)

        it("shows a loss as bad", function()
            local result = base()
            result.profit, result.percent = -50, -50
            assert.are.equal("bad", panel.SummaryLines(result, format)[4][2])
        end)

        it("says at least for a partial cost and shows the made count", function()
            local result = base()
            result.partial, result.made = true, 1.5
            local lines = panel.SummaryLines(result, format)
            assert.are.equal("Craft cost: at least 100c", lines[1][1])
            assert.are.equal("Item value: 300c (1.5 made)", lines[2][1])
            assert.are.equal("Profit: at most 185c", lines[4][1])
        end)

        it("says no price when the item has no price", function()
            local result = { cost = 100, partial = false, hasItem = true, made = 1 }
            assert.are.equal("Item value: no price", panel.SummaryLines(result, format)[2][1])
        end)

        it("says no item to sell for a recipe with no item", function()
            local lines = panel.SummaryLines({ cost = 100, partial = false, hasItem = false }, format)
            assert.are.equal(2, #lines)
            assert.are.equal("No item to sell", lines[2][1])
        end)
    end)

    describe("driver", function()
        local client, view, driver, host, hostShown

        local function fakeClient()
            local c = {
                key = 1,
                supported = true,
                Supported = function(self) return self.supported end,
                Read = function(self) return self.key and { key = self.key } or nil end,
                SelectionKey = function(self) return self.key end,
                Host = function() return host end,
                Events = function() return { "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_CLOSE" } end,
            }
            return c
        end

        before_each(function()
            hostShown = true
            host = { IsShown = function() return hostShown end }
            client = fakeClient()
            view = {
                shown = false,
                renders = {},
                Show = function(self) self.shown = true end,
                Hide = function(self) self.shown = false end,
                IsShown = function(self) return self.shown end,
                Render = function(self, state) self.renders[#self.renders + 1] = state end,
            }
            driver = panel.NewDriver({
                client = client,
                view = view,
                bus = bus,
                interval = 0.2,
                compute = function() return { cost = 1 } end,
            })
            driver:Start()
        end)

        it("shows and draws on TRADE_SKILL_SHOW and hides on TRADE_SKILL_CLOSE", function()
            bus:Emit("TRADE_SKILL_SHOW")
            assert.is_true(view.shown)
            assert.are.equal(1, #view.renders)
            assert.are.equal(1, view.renders[1].recipe.key)
            bus:Emit("TRADE_SKILL_CLOSE")
            assert.is_false(view.shown)
        end)

        it("draws again on TRADE_SKILL_UPDATE only while shown", function()
            bus:Emit("TRADE_SKILL_UPDATE")
            assert.are.equal(0, #view.renders)
            bus:Emit("TRADE_SKILL_SHOW")
            bus:Emit("TRADE_SKILL_UPDATE")
            assert.are.equal(2, #view.renders)
        end)

        it("draws again when a price event fires", function()
            bus:Emit("TRADE_SKILL_SHOW")
            bus:Emit("Flipside.ScanFinished")
            bus:Emit("Flipside.PriceCaptured")
            assert.are.equal(3, #view.renders)
        end)

        it("draws only when the selection changes", function()
            bus:Emit("TRADE_SKILL_SHOW")
            driver:Tick(0.25)
            assert.are.equal(1, #view.renders)
            client.key = 2
            driver:Tick(0.25)
            assert.are.equal(2, #view.renders)
            assert.are.equal(2, view.renders[2].recipe.key)
            driver:Tick(0.25)
            assert.are.equal(2, #view.renders)
        end)

        it("checks the selection at most once in each interval", function()
            bus:Emit("TRADE_SKILL_SHOW")
            client.key = 2
            driver:Tick(0.05)
            driver:Tick(0.05)
            assert.are.equal(1, #view.renders)
            driver:Tick(0.15)
            assert.are.equal(2, #view.renders)
        end)

        it("shows the empty state when nothing is selected", function()
            bus:Emit("TRADE_SKILL_SHOW")
            client.key = nil
            driver:Tick(0.25)
            assert.is_true(view.renders[2].empty)
        end)

        it("shows the unsupported state", function()
            client.supported = false
            bus:Emit("TRADE_SKILL_SHOW")
            assert.is_true(view.renders[1].unsupported)
        end)

        it("hides when the profession window is hidden", function()
            bus:Emit("TRADE_SKILL_SHOW")
            hostShown = false
            driver:Tick(0.25)
            assert.is_false(view.shown)
        end)

        it("does nothing on a tick while hidden", function()
            client.key = 2
            driver:Tick(0.25)
            assert.are.equal(0, #view.renders)
        end)
    end)
end)
