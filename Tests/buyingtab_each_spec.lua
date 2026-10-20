local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end, Flavour = { hasCommodityMarket = true, buyGroupAuctions = true } }
    for _, name in ipairs({ "EventBus", "ItemString", "BuyingPlan", "Theme", "Widgets", "Window", "List", "Tree",
        "Tabs", "Columns", "AuctionTabs", "BuyingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

-- TBC: each auction has its own row. Buy and Next buy one auction for each click.
describe("BuyingTab with one row for each auction", function()
    local ns, bus, client, tab, ui

    local function makeClient()
        local c = { rows = {}, calls = {}, violations = {} }
        c.CanLiveSearch = function() return true end
        c.IsReady = function() return true end
        c.LiveSearch = function() return true end
        c.LiveRows = function(itemID) return c.rows[itemID] or {} end
        c.LiveResultEvents = function() return "COMMODITY_RESULTS", "ITEM_RESULTS" end
        c.ReadyEvent = function() return "READY" end
        c.CloseEvent = function() return "CLOSE" end
        c.BuyEvents = function()
            return { itemCompleted = "ITEMBOUGHT", itemError = "ITEMERR" }
        end
        c.CanBuy = function() return true end
        c.BuyItemAuction = function(...)
            c.calls[#c.calls + 1] = { "bid", ... }
            if not c.inClick then
                c.violations[#c.violations + 1] = "bid"
            end
        end
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
                return { name = "Cheap", settings = { maxPrice = "100", showAboveMax = false } }
            end,
        }
    end

    -- One auction: list index, buyout, stack size, seller.
    local function auction(id, buyout, quantity, owner)
        quantity = quantity or 1
        return { auctionID = id, unitPrice = buyout / quantity, quantity = quantity, buyout = buyout,
            isCommodity = false, ownerItem = false, owner = owner or "Seller", timeLeft = 3 }
    end

    local function fourSingles()
        return { auction(1, 30), auction(2, 30), auction(3, 30), auction(4, 30) }
    end

    local function click(button)
        client.inClick = true
        button.scripts.OnClick(button)
        client.inClick = false
    end

    local function box()
        for _, frame in ipairs(mock.frames) do
            if frame.name == "FlipsideBuyConfirm" then
                return frame
            end
        end
    end

    local function search(rows)
        client.rows[10] = rows
        tab:Select_("10")
        tab:Search()
        bus:Emit("ITEM_RESULTS", 10)
    end

    -- Search the item and press Buy. Returns the confirm box.
    local function openBox(rows)
        search(rows or fourSingles())
        click(ui.buyNext)
        return box()
    end

    -- The first auction is bought: the success text and the fresh rows come.
    local function bought(freshRows, id)
        bus:Emit("ITEMBOUGHT", id or 1)
        client.rows[10] = freshRows
        bus:Emit("ITEM_RESULTS", 10)
    end

    before_each(function()
        mock.reset()
        _G.ScrollUtil = nil
        getmetatable(CreateFrame("Frame")).__index.SetJustifyH = function() end
        ns = loadModules()
        ns.Flavour.hasCommodityMarket = false
        ns.Flavour.buyGroupAuctions = false
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

    describe("the list", function()
        it("gives four rows for four stacks of one from one seller", function()
            search(fourSingles())
            for index = 1, 4 do
                assert.are.equal("x1", ui.rowsList.rows[index].cells.quantity.text)
                assert.are.equal("Seller", ui.rowsList.rows[index].cells.owner.text)
                assert.are.equal("Long", ui.rowsList.rows[index].cells.timeLeft.text)
            end
            assert.is_nil(ui.rowsList.rows[5])
            assert.is_true(ui.levelHeader.labels.owner.shown)
        end)

        it("sorts by unit price, then by stack size", function()
            search({ auction(1, 50, 5), auction(2, 10, 1), auction(3, 10, 2), auction(4, 5, 1) })
            local texts = {}
            for index = 1, 4 do
                texts[index] = ui.rowsList.rows[index].cells.unitPrice.text
                    .. " " .. ui.rowsList.rows[index].cells.quantity.text
            end
            assert.are.same({ "5c x1", "5c x2", "10c x1", "10c x5" }, texts)
        end)

        it("still groups by unit price when the flavour groups", function()
            ns.Flavour.buyGroupAuctions = true
            search(fourSingles())
            assert.are.equal("x4", ui.rowsList.rows[1].cells.quantity.text)
            assert.is_nil(ui.rowsList.rows[2])
            assert.is_false(ui.levelHeader.labels.owner.shown)
        end)
    end)

    describe("the confirm box", function()
        it("names one auction and its stack size, and one click makes one bid", function()
            local confirm = openBox({ auction(1, 100, 5), auction(2, 120, 5) })
            assert.matches("Buy one auction: 5 x", confirm.text.text)
            assert.matches("Seller: Seller", confirm.text.text)
            assert.are.equal("Buy", confirm.yesButton.text)
            assert.are.same({}, client.calls)
            click(confirm.yesButton)
            assert.are.same({ { "bid", 1, 100 } }, client.calls)
            assert.are.same({}, client.violations)
        end)

        it("turns the button off while the buy waits and ignores a second click", function()
            local confirm = openBox()
            click(confirm.yesButton)
            assert.is_false(confirm.yesButton.enabled)
            tab:_Confirm()
            assert.are.equal(1, #client.calls)
        end)

        it("shows the next auction with Next, and Next buys that auction", function()
            local confirm = openBox()
            click(confirm.yesButton)
            bought({ auction(1, 30), auction(2, 30), auction(3, 30) })
            assert.is_true(confirm:IsShown())
            assert.are.equal("Next", confirm.yesButton.text)
            assert.is_true(confirm.yesButton.enabled)
            assert.are.equal(1, #client.calls)
            click(confirm.yesButton)
            assert.are.same({ { "bid", 1, 30 }, { "bid", 1, 30 } }, client.calls)
            bought({ auction(1, 30), auction(2, 30) })
            click(confirm.yesButton)
            assert.are.equal(3, #client.calls)
            assert.are.same({}, client.violations)
        end)

        it("ends with no more auctions after the last one", function()
            local confirm = openBox({ auction(1, 30), auction(2, 30) })
            click(confirm.yesButton)
            bought({ auction(1, 30) })
            click(confirm.yesButton)
            bought({})
            assert.is_true(confirm:IsShown())
            assert.matches("No more auctions", confirm.text.text)
            assert.is_false(confirm.yesButton.enabled)
            assert.are.equal("Close", confirm.noButton.text)
            assert.are.equal(2, #client.calls)
        end)

        it("stops at Cancel and buys nothing more", function()
            local confirm = openBox()
            click(confirm.yesButton)
            bought({ auction(1, 30), auction(2, 30), auction(3, 30) })
            click(confirm.noButton)
            assert.is_false(confirm:IsShown())
            assert.are.equal(1, #client.calls)
            bus:Emit("ITEM_RESULTS", 10)
            assert.are.equal(1, #client.calls)
        end)

        it("shows an error, drops the auction and offers the next one", function()
            local confirm = openBox()
            click(confirm.yesButton)
            bus:Emit("ITEMERR", "not enough money")
            bus:Emit("ITEM_RESULTS", 10)
            assert.is_true(confirm:IsShown())
            assert.matches("Error: error not enough money", confirm.text.text)
            assert.are.equal("Next", confirm.yesButton.text)
            assert.are.equal(3, #tab.results["10"].rows)
            click(confirm.yesButton)
            assert.are.equal(2, #client.calls)
        end)

        it("does not drop an auction that is gone from the fresh rows", function()
            local confirm = openBox()
            click(confirm.yesButton)
            bus:Emit("ITEMERR", "gone")
            client.rows[10] = { auction(1, 30), auction(2, 30), auction(3, 30) }
            bus:Emit("ITEM_RESULTS", 10)
            assert.are.equal(3, #tab.results["10"].rows)
            assert.is_true(confirm:IsShown())
        end)

        it("refuses to buy when the shown auction is not in the list any more", function()
            local confirm = openBox({ auction(1, 30, 1, "Anna"), auction(2, 31, 1, "Ben") })
            client.rows[10] = { auction(1, 31, 1, "Ben") }
            click(confirm.yesButton)
            assert.are.same({}, client.calls)
            bus:Emit("ITEM_RESULTS", 10)
            assert.matches("Error: the auction is gone", confirm.text.text)
            assert.matches("Seller: Ben", confirm.text.text)
            assert.are.equal("Next", confirm.yesButton.text)
        end)

        it("buys the moved auction when the index changed", function()
            local confirm = openBox({ auction(1, 30, 1, "Anna"), auction(2, 31, 1, "Ben") })
            client.rows[10] = { auction(1, 31, 1, "Ben"), auction(2, 30, 1, "Anna") }
            click(confirm.yesButton)
            assert.are.same({ { "bid", 2, 30 } }, client.calls)
        end)
    end)

    describe("the price jump warning", function()
        it("shows in the box before the click that buys the dearer auction", function()
            local confirm = openBox({ auction(1, 30), auction(2, 40) })
            assert.is_nil(confirm.text.text:match("Price jumps"))
            click(confirm.yesButton)
            bought({ auction(1, 40) })
            assert.matches("Price jumps from 30c to 40c %(%+33%%%)", confirm.text.text)
            assert.are.equal(1, #client.calls)
            click(confirm.yesButton)
            assert.are.equal(2, #client.calls)
        end)

        it("shows for the first auction when the selected row is dearer than the cheapest", function()
            search({ auction(1, 30), auction(2, 40) })
            tab:SelectLevel(2)
            click(ui.buyNext)
            assert.matches("Price jumps from 30c to 40c", box().text.text)
            assert.are.same({}, client.calls)
        end)
    end)
end)
