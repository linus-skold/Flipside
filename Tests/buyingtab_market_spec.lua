local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end, Flavour = { hasCommodityMarket = true } }
    for _, name in ipairs({ "EventBus", "ItemString", "BuyingPlan",
        "BuyFlow", "Theme", "Widgets", "Window", "List", "Tree",
        "Tabs",
        "Columns", "AuctionTabs", "BuyDialog", "BuyingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

-- These specs keep ScrollUtil: the game uses the ScrollBox path.
describe("BuyingTab market value and % MV", function()
    local ns, bus, client, tab, ui, views, evaluated, values, saved

    local function makeClient()
        local c = { ready = true, rows = {} }
        c.CanLiveSearch = function() return true end
        c.IsReady = function() return c.ready end
        c.LiveSearch = function() return true end
        c.LiveRows = function(itemID) return c.rows[itemID] or {} end
        c.LiveResultEvents = function() return "COMMODITY_RESULTS", "ITEM_RESULTS" end
        c.ReadyEvent = function() return "READY" end
        c.CloseEvent = function() return "CLOSE" end
        c.BuyEvents = function() return nil end
        c.CanBuy = function() return true end
        return c
    end

    local function makeRules()
        return {
            Walk = function(_, fn) fn(1) fn(2) end,
            ItemsIn = function(_, id) return id == 2 and { "10" } or {} end,
            Children = function() return {} end,
            Name = function() return "Herbs" end,
            Path = function() return "Herbs" end,
            GroupOf = function() return 1 end,
            EffectiveOperation = function() return 7 end,
            GetOperation = function()
                return { name = "Cheap", settings = { maxPrice = "100", showAboveMax = true } }
            end,
        }
    end

    local function row(price, quantity)
        return { unitPrice = price, quantity = quantity, ownerItem = false, auctionID = price }
    end

    local function useDb()
        tab.deps.db = {
            Get = function(_, scope, key) return saved[scope .. key] end,
            Set = function(_, scope, key, value)
                saved[scope .. key] = value
                return true
            end,
        }
    end

    local function search(rows)
        client.rows[10] = rows
        tab:Select_("10")
        tab:Search()
        bus:Emit("COMMODITY_RESULTS", 10)
    end

    local function drawLevels()
        local rows = {}
        for index, data in ipairs(ui.rowsList.box.dataProvider.data) do
            rows[index] = CreateFrame("Button")
            views[ui.rowsList.box].initializer(rows[index], data)
        end
        return rows
    end

    before_each(function()
        mock.reset()
        views, evaluated, saved = {}, {}, {}
        values = { scanmarket = { ["10"] = 100 }, tsmmarket = { ["10"] = 200 } }
        local init = _G.ScrollUtil.InitScrollBoxListWithScrollBar
        _G.ScrollUtil.InitScrollBoxListWithScrollBar = function(box, bar, view)
            views[box] = view
            init(box, bar, view)
        end
        ns = loadModules()
        bus = ns.EventBus.New({})
        client = makeClient()
        ns.BuyingPlan.Log:Clear()
        tab = ns.BuyingTab.New({
            bus = bus, rules = makeRules(), client = client, after = function() end,
            formulaRun = {
                Evaluate = function(_, text, key)
                    evaluated[#evaluated + 1] = text
                    local source = values[text]
                    if source then
                        return source[key], nil
                    end
                    return tonumber(text), nil
                end,
            },
            itemInfo = function(id) return "Item" .. id, 1 end,
        })
        tab:Mount(CreateFrame("Frame", nil, UIParent), { Enter = function() end, Leave = function() end })
        ui = tab.ui
        tab:RefreshList()
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("the color of a percent", function()
        local function color(percent)
            local r, g, b = ns.BuyingTab.PercentColor(percent)
            return { r, g, b }
        end

        it("is green at 0, yellow at 100 and red from 150", function()
            local green, yellow, red = color(0), color(100), color(150)
            assert.is_true(green[2] > green[1] and green[2] > green[3])
            assert.is_true(yellow[1] > 0.9 and yellow[2] > 0.7 and yellow[3] < 0.3)
            assert.is_true(red[1] > 0.9 and red[2] < 0.4 and red[3] < 0.4)
            assert.are.same(red, color(150))
            assert.are.same(red, color(400))
            assert.are.same(green, color(-20))
        end)

        it("blends straight from green to yellow between 0 and 100", function()
            local green, yellow, middle = color(0), color(100), color(50)
            for index = 1, 3 do
                assert.is_near((green[index] + yellow[index]) / 2, middle[index], 1e-9)
            end
            local quarter = color(25)
            for index = 1, 3 do
                assert.is_near(green[index] + (yellow[index] - green[index]) * 0.25, quarter[index], 1e-9)
            end
        end)

        it("blends straight from yellow to red between 100 and 150", function()
            local yellow, red, middle = color(100), color(150), color(125)
            for index = 1, 3 do
                assert.is_near((yellow[index] + red[index]) / 2, middle[index], 1e-9)
            end
        end)

        it("gives no color for no percent", function()
            assert.is_nil(ns.BuyingTab.PercentColor(nil))
            assert.is_nil(ns.BuyingTab.PercentColor("x"))
        end)
    end)

    describe("the setting Market value source", function()
        it("is the Flipside scan market value by default", function()
            assert.are.equal("scanmarket", ns.BuyingTab.DEFAULT_MARKET_SOURCE)
            assert.are.equal("scanmarket", ns.BuyingTab.ReadMarketSource(nil))
            useDb()
            assert.are.equal("scanmarket", tab:GetMarketSource())
        end)

        it("saves a formula and reads it back", function()
            useDb()
            assert.is_true(ns.BuyingTab.WriteMarketSource(tab.deps.db, "  tsmmarket "))
            assert.are.equal("tsmmarket", saved["profilebuying.marketSource"])
            assert.are.equal("tsmmarket", tab:GetMarketSource())
        end)

        it("refuses an empty formula and falls back to the default", function()
            useDb()
            assert.is_false(ns.BuyingTab.WriteMarketSource(tab.deps.db, "   "))
            assert.is_false(ns.BuyingTab.WriteMarketSource(nil, "tsmmarket"))
            saved["profilebuying.marketSource"] = "  "
            assert.are.equal("scanmarket", tab:GetMarketSource())
        end)

        it("gives the market value of the default formula", function()
            assert.are.equal(100, tab:MarketValue({ key = "10" }))
            assert.are.equal("scanmarket", evaluated[#evaluated])
        end)

        it("gives the market value of a custom formula", function()
            useDb()
            ns.BuyingTab.WriteMarketSource(tab.deps.db, "tsmmarket")
            assert.are.equal(200, tab:MarketValue({ key = "10" }))
            ns.BuyingTab.WriteMarketSource(tab.deps.db, "150")
            assert.are.equal(150, tab:MarketValue({ key = "10" }))
        end)

        it("gives nil when the formula has no value for the item", function()
            assert.is_nil(tab:MarketValue({ key = "99" }))
            values.scanmarket["10"] = 0
            assert.is_nil(tab:MarketValue({ key = "10" }))
            tab.deps.formulaRun = nil
            assert.is_nil(tab:MarketValue({ key = "10" }))
        end)
    end)

    describe("the % MV column", function()
        it("shows the percent of the market value, colored", function()
            search({ row(50, 3), row(100, 2), row(150, 1) })
            local rows = drawLevels()
            assert.are.equal("50%", rows[1].cells.percent.text)
            assert.are.equal("100%", rows[2].cells.percent.text)
            assert.are.equal("150%", rows[3].cells.percent.text)
            local r, g, b = ns.BuyingTab.PercentColor(50)
            assert.are.same({ r, g, b }, { unpack(rows[1].cells.percent.color, 1, 3) })
            r, g, b = ns.BuyingTab.PercentColor(150)
            assert.are.same({ r, g, b }, { unpack(rows[3].cells.percent.color, 1, 3) })
        end)

        it("takes the 100% from the setting", function()
            useDb()
            ns.BuyingTab.WriteMarketSource(tab.deps.db, "tsmmarket")
            search({ row(50, 3) })
            local rows = drawLevels()
            assert.are.equal("25%", rows[1].cells.percent.text)
        end)

        it("shows a dash in grey when there is no market value", function()
            values.scanmarket["10"] = nil
            search({ row(50, 3) })
            local rows = drawLevels()
            assert.are.equal("—", rows[1].cells.percent.text)
            assert.are.same({ 0.5, 0.5, 0.5 }, { unpack(rows[1].cells.percent.color, 1, 3) })
        end)

        it("leaves the totals cell of the percent empty", function()
            search({ row(50, 3) })
            assert.are.equal("", ui.totalCells.percent.text)
        end)
    end)
end)
