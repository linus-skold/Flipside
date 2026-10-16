local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end, Flavour = { hasCommodityMarket = true } }
    for _, name in ipairs({ "EventBus", "ItemString", "BuyingPlan", "Theme", "Widgets", "Window", "List", "Tree",
        "Tabs",
        "Columns", "AuctionTabs", "BuyingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

-- These specs keep ScrollUtil: the game uses the ScrollBox path.
describe("BuyingTab totals, amount and columns", function()
    local ns, bus, client, tab, ui, views

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

    local function row(price, quantity, own)
        return { unitPrice = price, quantity = quantity, ownerItem = own or false, auctionID = price }
    end

    -- Levels: 50 x3, 60 x2 (own), 70 x4, 150 x1 (above the max price of 100).
    local function search(rows)
        client.rows[10] = rows or { row(50, 3), row(60, 2, true), row(70, 4), row(150, 1) }
        tab:Select_("10")
        tab.amount = nil -- all units; the default of 1 has its own test
        tab:Search()
        bus:Emit("COMMODITY_RESULTS", 10)
    end

    -- Draw the rows of the level list as the ScrollBox does. Returns the row frames.
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
        views = {}
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
            formulaRun = { Evaluate = function(_, text) return tonumber(text), nil end },
            itemInfo = function(id) return "Item" .. id, 1 end,
        })
        tab:Mount(CreateFrame("Frame", nil, UIParent), { Enter = function() end, Leave = function() end })
        ui = tab.ui
        tab:RefreshList()
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("the message line", function()
        it("shows no max price, buyable or stop line", function()
            search()
            assert.are.equal("", ui.summary.text)
            search({ row(150, 1) })
            assert.is_nil(ui.summary.text:match("[Mm]ax price:"))
            assert.is_nil(ui.summary.text:match("Buyable"))
            assert.is_nil(ui.summary.text:match("Stop"))
            assert.is_nil(ui.summary.text:match("end of results"))
        end)

        it("takes no space while it is empty, and shows again with text", function()
            assert.is_false(ui.message:IsShown())
            assert.are.equal(12, ui.leftTop.points[1][5])
            tab:Search()
            assert.is_false(ui.message:IsShown())
            tab:_Say("something failed")
            assert.is_true(ui.message:IsShown())
            assert.are.equal(0, ui.leftTop.points[1][5])
            tab:_Say("")
            assert.is_false(ui.message:IsShown())
            assert.are.equal(12, ui.leftTop.points[1][5])
        end)

        it("does not say searching when a search starts", function()
            tab:Select_("10")
            tab:Search()
            assert.are.equal("", ui.message.text)
        end)

        it("shows only the reason why the button is off", function()
            search({ row(150, 1) })
            assert.are.equal("Buy: above max price", ui.summary.text)
        end)
    end)

    describe("the totals row", function()
        it("sits above the list, apart from the list rows", function()
            search()
            assert.is_true(ui.totals:IsShown())
            assert.are_not.equal(ui.totals, ui.rowsList.frame)
            assert.are.equal(#ui.rowsList.box.dataProvider.data, 4)
        end)

        it("adds the units and the cost without own and above-max levels", function()
            search()
            assert.are.equal("x7", ui.totalCells.quantity.text)
            assert.are.equal("Total  430c", ui.totalCells.unitPrice.text)
        end)

        it("hides with no item and has a tooltip", function()
            assert.is_false(ui.totals:IsShown())
            assert.is_function(ui.totals.scripts.OnEnter)
        end)
    end)

    describe("the amount box", function()
        it("shows the units of the next buy with no selection", function()
            search()
            assert.are.equal("3", ui.amount.text)
            assert.are.equal("150c", ui.amountTotal.text)
        end)

        it("shows the units up to the selected level and the total of the whole range", function()
            search({ row(50, 3), row(60, 2), row(70, 4), row(150, 1) })
            tab:SelectLevel(70)
            tab:SetAmount("")
            tab.amountEdit = false
            tab:_Update()
            assert.are.equal("9", ui.amount.text)
            assert.are.equal(tostring(3 * 50 + 2 * 60 + 4 * 70) .. "c", ui.amountTotal.text)
        end)

        it("updates the total when the user types a number", function()
            search({ row(50, 3), row(60, 2), row(70, 4), row(150, 1) })
            tab:SelectLevel(70)
            ui.amount:SetText("4")
            ui.amount.scripts.OnTextChanged(ui.amount)
            assert.are.equal("4", ui.amount.text)
            assert.are.equal(tostring(3 * 50 + 60) .. "c", ui.amountTotal.text)
        end)

        it("shows the new quantity after a new selection", function()
            search({ row(50, 3), row(60, 2), row(70, 4), row(150, 1) })
            tab:SelectLevel(70)
            ui.amount:SetText("4")
            ui.amount.scripts.OnTextChanged(ui.amount)
            tab:SelectLevel(60)
            assert.are.equal("1", ui.amount.text)
        end)

        it("starts at 1 unit for a new selection and a new level", function()
            search()
            tab:Select_("11")
            assert.are.equal(1, tab.amount)
            tab:Select_("10")
            tab:SelectLevel(70)
            assert.are.equal(1, tab.amount)
            assert.are.equal("1", ui.amount.text)
        end)

        it("does not read its own fill as a typed amount", function()
            search()
            assert.is_nil(tab.amount)
        end)
    end)

    describe("the price level columns", function()
        local function widths(labels, keys)
            local out = {}
            for _, key in ipairs(keys) do
                out[#out + 1] = labels[key].width
            end
            return out
        end

        local function resize(frame, width)
            frame.GetWidth = function() return width end
            frame.scripts.OnSizeChanged(frame, width, 18)
        end

        it("gives Unit Price and Quantity 50% each, right-aligned", function()
            search()
            local edge = ui.rowsList.contentInsets
            local room = 400 - edge.left - edge.right - 6
            resize(ui.levelHeader.frame, 400)
            assert.are.same({ room / 2, room / 2 }, widths(ui.levelHeader.labels, { "unitPrice", "quantity" }))
            assert.are.equal("RIGHT", ui.levelHeader.labels.unitPrice.justifyH)
            assert.are.equal("RIGHT", ui.levelHeader.labels.quantity.justifyH)
        end)

        it("gives three columns one third each for items", function()
            ns.Flavour.hasCommodityMarket = false
            search()
            local edge = ui.rowsList.contentInsets
            local room = 400 - edge.left - edge.right - 12
            resize(ui.levelHeader.frame, 400)
            local w = widths(ui.levelHeader.labels, { "unitPrice", "stackPrice", "quantity" })
            assert.are.same({ room / 3, room / 3, room / 3 }, w)
            assert.are.equal("RIGHT", ui.levelHeader.labels.stackPrice.justifyH)
        end)

        it("has no separate Total label that can overlap the cost text", function()
            search()
            assert.is_nil(ui.totalLabel)
            assert.are.equal("RIGHT", ui.totalCells.unitPrice.justifyH)
            assert.is_truthy(ui.totalCells.unitPrice.text:find("^Total  "))
        end)

        it("uses the same columns in the totals row and in the list rows", function()
            search()
            local edge = ui.rowsList.contentInsets
            resize(ui.levelHeader.frame, 400)
            resize(ui.totals, 400)
            local rows = drawLevels()
            resize(rows[1], 400 - 0)
            assert.are.equal(ui.levelHeader.labels.unitPrice.width, ui.totalCells.unitPrice.width)
            assert.are.equal("RIGHT", ui.totalCells.quantity.justifyH)
            assert.are.equal("RIGHT", rows[1].cells.unitPrice.justifyH)
            assert.is_true(edge.left >= 0)
        end)
    end)
end)
