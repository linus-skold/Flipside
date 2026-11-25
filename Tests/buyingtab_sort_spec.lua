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

describe("BuyingTab sort helpers", function()
    local ns

    before_each(function()
        mock.reset()
        ns = loadModules()
    end)

    after_each(function()
        mock.teardown()
    end)

    local function keys(rows)
        local out = {}
        for _, row in ipairs(rows) do
            out[#out + 1] = row.id
        end
        return out
    end

    it("sorts ascending, then descending, on a second click of the same column", function()
        local first = ns.BuyingTab.NextSort(nil, "price")
        assert.are.same({ key = "price", descending = false }, first)
        local second = ns.BuyingTab.NextSort(first, "price")
        assert.are.same({ key = "price", descending = true }, second)
        assert.are.same({ key = "price", descending = false }, ns.BuyingTab.NextSort(second, "price"))
        assert.are.same({ key = "other", descending = false }, ns.BuyingTab.NextSort(second, "other"))
    end)

    it("keeps the rows as they are with no key", function()
        local rows = { { id = 2, v = 2 }, { id = 1, v = 1 } }
        assert.are.equal(rows, ns.BuyingTab.SortRows(rows, nil, false))
    end)

    it("puts rows with no value last in both directions", function()
        local rows = { { id = "a" }, { id = "b", v = 5 }, { id = "c", v = 1 }, { id = "d" } }
        assert.are.same({ "c", "b", "a", "d" }, keys(ns.BuyingTab.SortRows(rows, "v", false)))
        assert.are.same({ "b", "c", "a", "d" }, keys(ns.BuyingTab.SortRows(rows, "v", true)))
    end)

    it("keeps the order of equal values and does not change the input", function()
        local rows = { { id = 1, v = 2 }, { id = 2, v = 2 }, { id = 3, v = 1 } }
        assert.are.same({ 3, 1, 2 }, keys(ns.BuyingTab.SortRows(rows, "v", false)))
        assert.are.same({ 1, 2, 3 }, keys(ns.BuyingTab.SortRows(rows, "v", true)))
        assert.are.same({ 1, 2, 3 }, keys(rows))
    end)

    it("sorts text with no regard to case", function()
        local rows = { { id = 1, v = "Zed" }, { id = 2, v = "alpha" }, { id = 3, v = "Mid" } }
        assert.are.same({ 2, 3, 1 }, keys(ns.BuyingTab.SortRows(rows, "v", false)))
        assert.are.same({ 1, 3, 2 }, keys(ns.BuyingTab.SortRows(rows, "v", true)))
    end)
end)

-- These specs keep ScrollUtil: the game uses the ScrollBox path.
describe("BuyingTab column sort", function()
    local ns, bus, client, tab, ui, views, groups, markets

    local function makeClient()
        local c = { ready = true, searches = {}, rows = {} }
        c.CanLiveSearch = function() return true end
        c.IsReady = function() return c.ready end
        c.LiveSearch = function(itemID)
            c.searches[#c.searches + 1] = itemID
            return true
        end
        c.LiveRows = function(itemID) return c.rows[itemID] or {} end
        c.LiveResultEvents = function() return "COMMODITY_RESULTS", "ITEM_RESULTS" end
        c.ReadyEvent = function() return "READY" end
        c.CloseEvent = function() return "CLOSE" end
        c.BuyEvents = function() return nil end
        c.CanBuy = function() return true end
        return c
    end

    -- Group 2 "Herbs" holds items 10 and 13 and the subgroup 3 with item 11. The names tell the name sort.
    local function makeRules()
        return {
            Walk = function(_, fn)
                fn(1)
                fn(2)
                fn(3)
            end,
            ItemsIn = function(_, id)
                return id == 2 and { "10", "13" } or id == 3 and { "11" } or {}
            end,
            Children = function(_, id) return (groups[id] or {}).children or {} end,
            Name = function(_, id) return groups[id].name end,
            Path = function(_, id) return groups[id].name end,
            GroupOf = function() return 1 end,
            EffectiveOperation = function() return 7 end,
            GetOperation = function()
                return { name = "Cheap", settings = { maxPrice = "100", showAboveMax = true } }
            end,
        }
    end

    local names = { [10] = "Zed", [13] = "alpha", [11] = "Mid" }

    -- A Forever item auction: the stack price is the unit price times the quantity.
    local function item(price, quantity, id)
        return { unitPrice = price, quantity = quantity, isCommodity = false, ownerItem = false, auctionID = id }
    end

    local function click(frame)
        frame.scripts.OnClick(frame, "LeftButton")
    end

    local function result(itemID, rows)
        client.rows[itemID] = rows
        bus:Emit("COMMODITY_RESULTS", itemID)
    end

    local function draw(id)
        for _, treeNode in ipairs(ui.tree.box.dataProvider:GetVisible()) do
            if treeNode:GetData().id == id then
                local frame = CreateFrame("Button")
                views[ui.tree.box].initializer(frame, treeNode)
                return frame
            end
        end
        error("no visible node " .. id)
    end

    local function levelPrices()
        local out = {}
        for _, data in ipairs(ui.rowsList.box.dataProvider.data) do
            out[#out + 1] = data.unitPrice
        end
        return out
    end

    local function groupKeys()
        local out = {}
        for _, data in ipairs(ui.groupList.box.dataProvider.data) do
            out[#out + 1] = data.key
        end
        return out
    end

    local function headerClick(header, key)
        click(header.buttons[key])
    end

    before_each(function()
        mock.reset()
        views = {}
        markets = { ["10"] = 100, ["11"] = 100, ["13"] = 100 }
        local init = _G.ScrollUtil.InitScrollBoxListWithScrollBar
        _G.ScrollUtil.InitScrollBoxListWithScrollBar = function(box, bar, view)
            views[box] = view
            init(box, bar, view)
        end
        getmetatable(CreateFrame("Frame")).__index.SetJustifyH = function() end
        ns = loadModules()
        bus = ns.EventBus.New({})
        client = makeClient()
        groups = {
            [1] = { name = "Base", children = { 2 } },
            [2] = { name = "Herbs", children = { 3 } },
            [3] = { name = "Flowers", children = {} },
        }
        ns.BuyingPlan.Log:Clear()
        tab = ns.BuyingTab.New({
            bus = bus, rules = makeRules(), client = client,
            formulaRun = {
                Evaluate = function(_, text, key)
                    if text == "scanmarket" then
                        return markets[key], nil
                    end
                    return tonumber(text), nil
                end,
            },
            after = function() end,
            itemInfo = function(id) return names[id] or ("Item" .. id), 1 end,
        })
        tab:Mount(CreateFrame("Frame", nil, UIParent), { Enter = function() end, Leave = function() end })
        ui = tab.ui
        tab:RefreshList()
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("the price level list", function()
        -- Levels: 50 x4 (stack 200), 60 x2 (stack 120), 70 x3 (stack 210).
        local function search()
            click(draw("i10"))
            result(10, { item(50, 4, 1), item(60, 2, 2), item(70, 3, 3) })
        end

        it("starts in the price order and shows no marker", function()
            search()
            assert.are.same({ 50, 60, 70 }, levelPrices())
            assert.are.equal("Unit Price", ui.levelHeader.labels.unitPrice.text)
            assert.is_nil(tab.levelSort)
        end)

        it("sorts each column ascending on the first click and descending on the second", function()
            search()
            local cases = {
                { "unitPrice", { 50, 60, 70 }, { 70, 60, 50 } },
                { "stackPrice", { 60, 50, 70 }, { 70, 50, 60 } },
                { "quantity", { 60, 70, 50 }, { 50, 70, 60 } },
                { "percent", { 50, 60, 70 }, { 70, 60, 50 } },
            }
            for _, case in ipairs(cases) do
                local key = case[1]
                headerClick(ui.levelHeader, key)
                assert.are.same(case[2], levelPrices(), key .. " ascending")
                assert.are.equal(ui.levelHeader.labels[key].text:sub(-2), " ^")
                headerClick(ui.levelHeader, key)
                assert.are.same(case[3], levelPrices(), key .. " descending")
                assert.are.equal(ui.levelHeader.labels[key].text:sub(-2), " v")
            end
        end)

        it("shows the marker on the active column only", function()
            search()
            headerClick(ui.levelHeader, "quantity")
            assert.are.equal("Available ^", ui.levelHeader.labels.quantity.text)
            assert.are.equal("Unit Price", ui.levelHeader.labels.unitPrice.text)
            headerClick(ui.levelHeader, "percent")
            assert.are.equal("Available", ui.levelHeader.labels.quantity.text)
            assert.are.equal("% MV ^", ui.levelHeader.labels.percent.text)
        end)

        it("puts a level with no percent last in both directions", function()
            markets["10"] = nil
            search()
            headerClick(ui.levelHeader, "percent")
            assert.are.same({ 50, 60, 70 }, levelPrices())
            headerClick(ui.levelHeader, "percent")
            assert.are.same({ 50, 60, 70 }, levelPrices())
        end)

        it("keeps the selected level selected after a re-sort", function()
            search()
            tab:SelectLevel(ui.rowsList.box.dataProvider.data[2].id)
            local selected = tab.levelSel
            assert.is_not_nil(selected)
            headerClick(ui.levelHeader, "unitPrice")
            headerClick(ui.levelHeader, "unitPrice")
            assert.are.equal(selected, tab.levelSel)
            local shown
            for index, data in ipairs(ui.rowsList.box.dataProvider.data) do
                local frame = CreateFrame("Button")
                views[ui.rowsList.box].initializer(frame, data)
                if frame.selection:IsShown() then
                    shown = index
                end
            end
            assert.are.equal(selected, ui.rowsList.box.dataProvider.data[shown].id)
        end)

        it("does not change the buy order: Buy next and the totals use the cheapest level", function()
            search()
            local _, level, _, _, cover = tab:_NextBuy()
            local before = { level.unitPrice, cover.cost, ui.totalCells.quantity.text, ui.totalCells.stackPrice.text }
            headerClick(ui.levelHeader, "unitPrice")
            headerClick(ui.levelHeader, "unitPrice")
            assert.are.same({ 70, 60, 50 }, levelPrices())
            local _, after, _, _, afterCover = tab:_NextBuy()
            assert.are.equal(50, after.unitPrice)
            assert.are.same(before, { after.unitPrice, afterCover.cost, ui.totalCells.quantity.text,
                ui.totalCells.stackPrice.text })
            local levels = tab:_Levels(tab.results["10"].rows)
            assert.are.equal(50, levels[1].unitPrice)
        end)

        it("keeps its own sort and does not touch the group list sort", function()
            search()
            headerClick(ui.levelHeader, "quantity")
            assert.is_nil(tab.groupSort)
            click(draw("g2"))
            headerClick(ui.groupHeader, "price")
            assert.are.equal("quantity", tab.levelSort.key)
            assert.are.equal("price", tab.groupSort.key)
        end)

        it("has no click area on a hidden column", function()
            client.rows[10] = {}
            click(draw("i10"))
            result(10, { { unitPrice = 50, quantity = 3, ownerItem = false, auctionID = 1 } })
            -- A commodity has no Stack Price column.
            assert.is_false(ui.levelHeader.buttons.stackPrice:IsShown())
            assert.is_true(ui.levelHeader.buttons.unitPrice:IsShown())
        end)
    end)

    describe("the group item list", function()
        -- 10 "Zed": 50 x3. 13 "alpha": no auction. 11 "Mid": 30 x9. The tree order is 10, 13, 11.
        local function fill()
            click(draw("g2"))
            result(10, { item(50, 3, 1) })
            result(13, {})
            result(11, { item(30, 9, 2) })
        end

        it("starts in the tree order", function()
            fill()
            assert.are.same({ "10", "13", "11" }, groupKeys())
            assert.is_nil(tab.groupSort)
            assert.are.equal("Lowest", ui.groupHeader.labels.price.text)
        end)

        it("sorts each column ascending on the first click and descending on the second", function()
            fill()
            local cases = {
                { "name", { "13", "11", "10" }, { "10", "11", "13" } },
                { "price", { "11", "10", "13" }, { "10", "11", "13" } },
                { "percent", { "11", "10", "13" }, { "10", "11", "13" } },
                { "quantity", { "13", "10", "11" }, { "11", "10", "13" } },
            }
            for _, case in ipairs(cases) do
                local key = case[1]
                headerClick(ui.groupHeader, key)
                assert.are.same(case[2], groupKeys(), key .. " ascending")
                assert.are.equal(" ^", ui.groupHeader.labels[key].text:sub(-2))
                headerClick(ui.groupHeader, key)
                assert.are.same(case[3], groupKeys(), key .. " descending")
                assert.are.equal(" v", ui.groupHeader.labels[key].text:sub(-2))
            end
        end)

        it("puts an item with no price last in both directions", function()
            fill()
            headerClick(ui.groupHeader, "price")
            assert.are.equal("13", groupKeys()[3])
            headerClick(ui.groupHeader, "price")
            assert.are.equal("13", groupKeys()[3])
        end)

        it("puts an item that is not searched yet last", function()
            click(draw("g2"))
            result(10, { item(50, 3, 1) })
            headerClick(ui.groupHeader, "price")
            assert.are.equal("10", groupKeys()[1])
        end)

        it("keeps the sort while results come and after Back", function()
            click(draw("g2"))
            headerClick(ui.groupHeader, "name")
            result(10, { item(50, 3, 1) })
            assert.are.same({ "13", "11", "10" }, groupKeys())
            result(13, {})
            result(11, { item(30, 9, 2) })
            assert.are.same({ "13", "11", "10" }, groupKeys())
            local frame = CreateFrame("Button")
            views[ui.groupList.box].initializer(frame, ui.groupList.box.dataProvider.data[1])
            click(frame)
            click(ui.back)
            assert.are.equal("name", tab.groupSort.key)
            assert.is_false(tab.groupSort.descending)
            assert.are.same({ "13", "11", "10" }, groupKeys())
        end)

        it("opens the item that the row shows after a re-sort", function()
            fill()
            headerClick(ui.groupHeader, "name")
            local frame = CreateFrame("Button")
            views[ui.groupList.box].initializer(frame, ui.groupList.box.dataProvider.data[1])
            click(frame)
            assert.are.equal("13", tab.selectedKey)
        end)
    end)
end)
