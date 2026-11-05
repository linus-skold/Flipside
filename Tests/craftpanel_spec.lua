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

        it("shows two lines: the material cost and a gain as good with its percent", function()
            local lines = panel.SummaryLines(base(), format)
            assert.are.equal(2, #lines)
            assert.are.same({ "Materials: 100c" }, lines[1])
            assert.are.same({ "Profit: +185c (185%)", "good" }, lines[2])
        end)

        it("shows a loss as bad with the positive amount and percent", function()
            local result = base()
            result.profit, result.percent = -50, -50
            assert.are.same({ "Loss: 50c (50%)", "bad" }, panel.SummaryLines(result, format)[2])
        end)

        it("shows a profit of zero with no tone", function()
            local result = base()
            result.profit, result.percent = 0, 0
            assert.are.same({ "Profit: 0c (0%)" }, panel.SummaryLines(result, format)[2])
        end)

        it("says at least for a partial cost and at most for the profit", function()
            local result = base()
            result.partial = true
            local lines = panel.SummaryLines(result, format)
            assert.are.equal("Materials: at least 100c", lines[1][1])
            assert.are.equal("Profit: at most +185c (185%)", lines[2][1])
            result.profit, result.percent = -50, -50
            assert.are.equal("Loss: at least 50c (50%)", panel.SummaryLines(result, format)[2][1])
        end)

        it("leaves out the percent when the cost is zero", function()
            local result = base()
            result.percent = nil
            assert.are.equal("Profit: +185c", panel.SummaryLines(result, format)[2][1])
        end)

        it("says no sell price when the item has no price", function()
            local result = { cost = 100, partial = false, hasItem = true, made = 1 }
            assert.are.same({ "No sell price" }, panel.SummaryLines(result, format)[2])
        end)

        it("says no item to sell for a recipe with no item", function()
            local lines = panel.SummaryLines({ cost = 100, partial = false, hasItem = false }, format)
            assert.are.equal(2, #lines)
            assert.are.equal("No item to sell", lines[2][1])
        end)
    end)

    describe("DetailLines", function()
        local function format(copper) return copper .. "c" end

        it("has the item value, the cut and the two formulas", function()
            local result = { hasItem = true, made = 1.5, value = 300, cutAmount = 15 }
            assert.are.same({ "Item value: 300c (1.5 made)", "AH cut: -15c", "Reagent price formula: a",
                "Item value formula: b" }, panel.DetailLines(result, format, "a", "b"))
        end)

        it("has only the formulas without an item value", function()
            assert.are.same({ "Reagent price formula: a", "Item value formula: b" },
                panel.DetailLines({ hasItem = false }, format, "a", "b"))
        end)
    end)

    describe("the block in the profession window", function()
        local mock = require("Tests.wow_mock")
        local function format(copper) return copper .. "c" end

        local kit = {
            Label = function(parent) return parent:CreateFontString(nil, "ARTWORK") end,
            Button = function(parent) return CreateFrame("Button", nil, parent) end,
            Input = function(parent) return CreateFrame("EditBox", nil, parent) end,
        }

        local function childOf(parent)
            for _, frame in ipairs(mock.frames) do
                if frame.parent == parent and frame.kind == "Frame" and frame.scripts.OnUpdate then
                    return frame
                end
            end
        end

        local function attach(client)
            local driver = panel.Attach({
                kit = kit, client = client, bus = bus, format = format,
                run = {}, cut = function() return 0 end,
                getFormulas = function() return "reagent", "item" end,
                setFormula = function() return true end,
            })
            return driver
        end

        local function fakeClient(mount, result)
            return {
                Supported = function() return true end,
                Read = function() return { key = 1 } end,
                SelectionKey = function() return 1 end,
                Host = function() return nil end,
                Events = function() return { "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE" } end,
                Mount = function() return mount end,
                result = result,
            }
        end

        before_each(function()
            mock.reset()
        end)

        local function texts(block)
            local out = {}
            for _, object in ipairs(mock.objects) do
                if object.kind == "FontString" and object.parent == block and object.shown and object.text then
                    out[#out + 1] = object.text
                end
            end
            return out
        end

        it("creates a plain child frame under the anchor and no separate window", function()
            local form = CreateFrame("Frame", "ProfessionsFrameForm")
            local reagents = CreateFrame("Frame", nil, form)
            local client = fakeClient({ parent = form, anchor = reagents, relativePoint = "BOTTOMLEFT", x = 0, y = -10 })
            local driver = attach(client)
            driver.compute = function() return { cost = 100, partial = false, hasItem = true, made = 1, value = 300,
                cutAmount = 15, profit = 185, percent = 185 } end
            bus:Emit("TRADE_SKILL_SHOW")
            local block = childOf(form)
            assert.is_truthy(block)
            assert.is_nil(block.template)
            assert.is_nil(block.name)
            assert.are.same({ "TOPLEFT", reagents, "BOTTOMLEFT", 0, -10 }, block.points[1])
            for _, frame in ipairs(mock.frames) do
                assert.is_nil(frame.name and frame.name:find("FlipsideCraftPanel"))
            end
        end)

        it("shows the gain, loss and special lines", function()
            local form = CreateFrame("Frame")
            local client = fakeClient({ parent = form, anchor = form, relativePoint = "TOPLEFT", x = 1, y = -2 })
            local driver = attach(client)
            local result
            driver.compute = function() return result end
            local cases = {
                { { cost = 100, partial = false, hasItem = true, made = 1, value = 300, cutAmount = 15,
                    profit = 185, percent = 185 }, "Profit: +185c (185%)" },
                { { cost = 100, partial = false, hasItem = true, made = 1, value = 60, cutAmount = 3,
                    profit = -43, percent = -43 }, "Loss: 43c (43%)" },
                { { cost = 100, partial = true, hasItem = true, made = 1, value = 300, cutAmount = 15,
                    profit = 185, percent = 185 }, "Profit: at most +185c (185%)" },
                { { cost = 100, partial = false, hasItem = false }, "No item to sell" },
                { { cost = 100, partial = false, hasItem = true, made = 1 }, "No sell price" },
            }
            for _, case in ipairs(cases) do
                result = case[1]
                driver:Refresh()
                bus:Emit("TRADE_SKILL_SHOW")
                local lines = texts(childOf(form))
                assert.is_true(lines[1]:find("Materials: ", 1, true) ~= nil)
                assert.is_truthy(lines[2]:find(case[2], 1, true))
            end
        end)

        it("anchors under the reagent of the TBC mount and grows the scroll child", function()
            local child = CreateFrame("Frame", "TradeSkillDetailScrollChildFrame")
            child:SetSize(297, 150)
            local scroll = CreateFrame("ScrollFrame")
            scroll.UpdateScrollChildRect = function() scroll.updated = true end
            local reagent = CreateFrame("Button", "TradeSkillReagent3", child)
            local client = fakeClient({ parent = child, anchor = reagent, relativePoint = "BOTTOMLEFT", x = 5, y = -8,
                scrollChild = child, scrollFrame = scroll })
            local driver = attach(client)
            driver.compute = function() return { cost = 1, partial = false, hasItem = false } end
            bus:Emit("TRADE_SKILL_SHOW")
            local block = childOf(child)
            assert.are.same({ "TOPLEFT", reagent, "BOTTOMLEFT", 5, -8 }, block.points[1])
            assert.is_true(child.height > 150)
            assert.is_true(scroll.updated)
            bus:Emit("TRADE_SKILL_CLOSE")
            assert.are.equal(150, child.height)
        end)

        it("builds nothing while the client gives no mount", function()
            local client = fakeClient(nil)
            attach(client)
            local before = #mock.frames
            bus:Emit("TRADE_SKILL_SHOW")
            assert.are.equal(before, #mock.frames)
        end)

        it("shows the unsupported message in the block", function()
            local form = CreateFrame("Frame")
            local client = fakeClient({ parent = form, anchor = form, relativePoint = "TOPLEFT", x = 0, y = 0 })
            client.Supported = function() return false end
            attach(client)
            bus:Emit("TRADE_SKILL_SHOW")
            assert.are.same({ ns.CraftClient.UNSUPPORTED }, texts(childOf(form)))
        end)
    end)

    describe("CraftClient Mount", function()
        local function frame(shown, bottom)
            return { IsShown = function() return shown end, GetBottom = function() return bottom end }
        end

        it("anchors Forever under the lowest shown reagent container", function()
            local form = { Reagents = frame(true, 300), OptionalReagents = frame(true, 200),
                FinishingReagents = frame(false, 50), Description = frame(true, 400) }
            local api = { C_TradeSkillUI = { GetRecipeSchematic = function() end },
                ProfessionsFrame = { CraftingPage = { SchematicForm = form } } }
            local mount = ns.CraftClient.New(api):Mount()
            assert.are.equal(form, mount.parent)
            assert.are.equal(form.OptionalReagents, mount.anchor)
            assert.are.equal("BOTTOMLEFT", mount.relativePoint)
            assert.is_nil(mount.scrollChild)
        end)

        it("anchors Forever under the description when no container is shown", function()
            local form = { Reagents = frame(false), Description = frame(true, 400) }
            local api = { C_TradeSkillUI = { GetRecipeSchematic = function() end },
                ProfessionsFrame = { CraftingPage = { SchematicForm = form } } }
            assert.are.equal(form.Description, ns.CraftClient.New(api):Mount().anchor)
        end)

        it("gives no Forever mount before the form exists", function()
            local api = { C_TradeSkillUI = { GetRecipeSchematic = function() end } }
            assert.is_nil(ns.CraftClient.New(api):Mount())
        end)

        local function tbcApi(count)
            local child = {}
            local api = {
                GetTradeSkillSelectionIndex = function() return 2 end,
                GetTradeSkillInfo = function() return "x", "optimal" end,
                GetTradeSkillNumReagents = function() return count end,
                GetTradeSkillReagentInfo = function() end,
                TradeSkillDetailScrollChildFrame = child,
                TradeSkillDetailScrollFrame = {},
                TradeSkillDescription = {},
            }
            for index = 1, 8 do
                api["TradeSkillReagent" .. index] = { index = index }
            end
            return api, child
        end

        it("anchors TBC under the left reagent of the last row", function()
            local api, child = tbcApi(3)
            local mount = ns.CraftClient.New(api):Mount()
            assert.are.equal(child, mount.parent)
            assert.are.equal(3, mount.anchor.index)
            assert.are.equal(child, mount.scrollChild)
            api = tbcApi(4)
            assert.are.equal(3, ns.CraftClient.New(api):Mount().anchor.index)
            api = tbcApi(1)
            assert.are.equal(1, ns.CraftClient.New(api):Mount().anchor.index)
        end)

        it("anchors TBC under the description when the recipe has no reagent", function()
            local api = tbcApi(0)
            assert.are.equal(api.TradeSkillDescription, ns.CraftClient.New(api):Mount().anchor)
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
