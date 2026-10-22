local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end, Flavour = { hasCommodityMarket = false } }
    for _, name in ipairs({ "EventBus", "ItemString", "BuyingPlan", "Theme", "Widgets", "Window", "List", "Tree",
        "Tabs", "Columns", "AuctionTabs", "BuyingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

-- Item auctions of the same seller, price and stack size are one row. Buy and Buy next buy one stack for each click.
describe("BuyingTab with stack groups", function()
    local ns, bus, client, tab, ui

    -- A fake client. c.rows[itemID] is one page of rows. c.pages[itemID] is a list of pages (a paged client).
    local function makeClient()
        local c = { rows = {}, pages = {}, calls = {}, searches = {}, violations = {}, ready = true, page = 0 }
        c.CanLiveSearch = function() return true end
        c.IsReady = function() return c.ready end
        c.LiveSearch = function(itemID, page)
            c.searches[#c.searches + 1] = { itemID, page or 0 }
            c.item, c.page = itemID, page or 0
            return true
        end
        c.LiveRows = function(itemID)
            if not c.pages[itemID] then
                return c.rows[itemID] or {}
            end
            local out = {}
            for index, row in ipairs(c.pages[itemID][c.page + 1] or {}) do
                local copy = {}
                for key, value in pairs(row) do
                    copy[key] = value
                end
                copy.auctionID = index
                out[index] = copy
            end
            return out
        end
        c.LivePageCount = function()
            return c.item and c.pages[c.item] and #c.pages[c.item] or nil
        end
        c.SortedPaging = function() return c.sorted == true end
        c.LiveOwnersPending = function() return c.ownersPending == true end
        c.LiveResultEvents = function() return "COMMODITY_RESULTS", "ITEM_RESULTS" end
        c.ReadyEvent = function() return "READY" end
        c.CloseEvent = function() return "CLOSE" end
        c.BuyEvents = function()
            return {
                priceUpdated = "QUOTE", priceUnavailable = "NOQUOTE", commoditySucceeded = "BOUGHT",
                commodityFailed = "NOTBOUGHT", itemCompleted = "ITEMBOUGHT", itemError = "ITEMERR",
            }
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

    local function levels()
        return tab:_Levels(tab.results["10"].rows)
    end

    local function levelOf(owner)
        for _, level in ipairs(levels()) do
            if level.owner == owner then
                return level
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

    -- The first stack is bought: the success text and the fresh rows come.
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
        it("puts three stacks of one from one seller in one row", function()
            search({ auction(1, 30), auction(2, 30), auction(3, 30) })
            assert.are.equal(1, #ui.rowsList.rows)
            local cells = ui.rowsList.rows[1].cells
            assert.are.equal("3 stacks of 1", cells.quantity.text)
            assert.are.equal("Seller", cells.owner.text)
            assert.are.equal("Long", cells.timeLeft.text)
            assert.are.equal("Available", ui.levelHeader.labels.quantity.text)
            assert.is_true(ui.levelHeader.labels.owner.shown)
        end)

        it("says 1 stack of 20 for one auction", function()
            search({ auction(1, 100, 20) })
            assert.are.equal("1 stack of 20", ui.rowsList.rows[1].cells.quantity.text)
        end)

        it("keeps two sellers in two rows", function()
            search({ auction(1, 30, 1, "Anna"), auction(2, 30, 1, "Ben"), auction(3, 30, 1, "Anna") })
            assert.are.equal(2, #ui.rowsList.rows)
            assert.are.equal("2 stacks of 1", ui.rowsList.rows[1].cells.quantity.text)
            assert.are.equal("Anna", ui.rowsList.rows[1].cells.owner.text)
            assert.are.equal("1 stack of 1", ui.rowsList.rows[2].cells.quantity.text)
            assert.are.equal("Ben", ui.rowsList.rows[2].cells.owner.text)
        end)

        it("keeps a different price or stack size in its own row", function()
            search({ auction(1, 30), auction(2, 31), auction(3, 60, 2), auction(4, 30) })
            local texts = {}
            for index = 1, 3 do
                texts[index] = ui.rowsList.rows[index].cells.unitPrice.text
                    .. " " .. ui.rowsList.rows[index].cells.quantity.text
            end
            assert.is_nil(ui.rowsList.rows[4])
            assert.are.same({ "30c 2 stacks of 1", "30c 1 stack of 2", "31c 1 stack of 1" }, texts)
        end)

        it("sorts by unit price, then by stack size", function()
            search({ auction(1, 50, 5), auction(2, 10, 1), auction(3, 20, 2), auction(4, 5, 1) })
            local texts = {}
            for index = 1, 4 do
                texts[index] = ui.rowsList.rows[index].cells.unitPrice.text
                    .. " " .. ui.rowsList.rows[index].cells.quantity.text
            end
            assert.are.same({ "5c 1 stack of 1", "10c 1 stack of 1", "10c 1 stack of 2", "10c 1 stack of 5" },
                texts)
        end)

        it("totals the items of all stacks that you can buy", function()
            search({ auction(1, 30), auction(2, 30, 1, "Ben"), auction(3, 90, 3) })
            assert.are.equal("x5", ui.totalCells.quantity.text)
        end)
    end)

    describe("your own auctions", function()
        local function mine()
            local row = auction(1, 30, 1, "Me")
            row.ownerItem = true
            return row
        end

        it("show as You and have Buy off", function()
            search({ mine(), auction(2, 40, 1, "Ben") })
            assert.are.equal("You", ui.rowsList.rows[1].cells.owner.text)
            tab:SelectLevel(levels()[1].id)
            assert.is_false(ui.buyNext.enabled)
            assert.are.equal("own listing", ui.message.text)
            assert.is_false((tab:BuyNext()))
            assert.are.same({}, client.calls)
        end)

        it("are not bought when Buy has no selection", function()
            search({ mine(), auction(2, 40, 1, "Ben") })
            click(ui.buyNext)
            click(box().yesButton)
            assert.are.same({ { "bid", 2, 40 } }, client.calls)
        end)

        it("are not in the totals", function()
            search({ mine(), auction(2, 40, 1, "Ben") })
            assert.are.equal("x1", ui.totalCells.quantity.text)
        end)

        it("are never the target of the re-find", function()
            local confirm = openBox({ auction(1, 30, 1, "Ben"), auction(2, 31) })
            local own = auction(1, 30, 1, "Ben")
            own.ownerItem = true
            client.rows[10] = { own }
            click(confirm.yesButton)
            assert.are.same({}, client.calls)
        end)
    end)

    describe("the confirm box", function()
        it("names one stack and the stacks available, and one click makes one bid", function()
            local confirm = openBox({ auction(1, 100, 5), auction(2, 100, 5), auction(3, 120, 5) })
            assert.matches("Buy one stack: 5 x", confirm.text.text)
            assert.matches("Seller: Seller", confirm.text.text)
            assert.matches("Available: 2 stacks of 5", confirm.text.text)
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

        it("reads Buy next after a buy, counts down, and buys one stack for each click", function()
            local confirm = openBox()
            assert.matches("Available: 4 stacks of 1", confirm.text.text)
            click(confirm.yesButton)
            bought({ auction(1, 30), auction(2, 30), auction(3, 30) })
            assert.is_true(confirm:IsShown())
            assert.are.equal("Buy next", confirm.yesButton.text)
            assert.is_true(confirm.yesButton.enabled)
            assert.matches("Available: 3 stacks of 1", confirm.text.text)
            assert.are.equal(1, #client.calls)
            click(confirm.yesButton)
            assert.are.same({ { "bid", 1, 30 }, { "bid", 1, 30 } }, client.calls)
            bought({ auction(1, 30), auction(2, 30) })
            assert.matches("Available: 2 stacks of 1", confirm.text.text)
            click(confirm.yesButton)
            assert.are.equal(3, #client.calls)
            assert.are.same({}, client.violations)
        end)

        it("stays in the group first, then goes on with the next cheapest stack", function()
            local confirm = openBox({ auction(1, 30), auction(2, 30), auction(3, 31) })
            click(confirm.yesButton)
            bought({ auction(1, 30), auction(2, 31) })
            click(confirm.yesButton)
            bought({ auction(1, 31) })
            assert.is_true(confirm:IsShown())
            assert.are.equal("Buy next", confirm.yesButton.text)
            assert.is_true(confirm.yesButton.enabled)
            assert.matches("Available: 1 stack of 1", confirm.text.text)
            assert.are.equal(2, #client.calls)
            click(confirm.yesButton)
            assert.are.same({ { "bid", 1, 30 }, { "bid", 1, 30 }, { "bid", 1, 31 } }, client.calls)
        end)

        it("shows No more stacks only when the item has no buyable stack left", function()
            local confirm = openBox({ auction(1, 30), auction(2, 30) })
            click(confirm.yesButton)
            bought({ auction(1, 30) })
            click(confirm.yesButton)
            bought({})
            assert.is_true(confirm:IsShown())
            assert.matches("No more stacks of this item", confirm.text.text)
            assert.is_false(confirm.yesButton.enabled)
            assert.are.equal("Close", confirm.noButton.text)
            assert.are.equal(2, #client.calls)
            assert.are.equal("No more stacks of this item", ui.message.text)
        end)

        it("skips your own stack and offers the next buyable one", function()
            local confirm = openBox({ auction(1, 30), auction(2, 31, 1, "Me"), auction(3, 32, 1, "Ben") })
            click(confirm.yesButton)
            local mine = auction(1, 31, 1, "Me")
            mine.ownerItem = true
            bought({ mine, auction(2, 32, 1, "Ben") })
            assert.is_true(confirm.yesButton.enabled)
            click(confirm.yesButton)
            assert.are.same({ { "bid", 1, 30 }, { "bid", 2, 32 } }, client.calls)
        end)

        it("follows a stack whose seller name comes late", function()
            local confirm = openBox({ auction(1, 30, 1, "Anna"), auction(2, 30, 1, "Anna") })
            click(confirm.yesButton)
            local late = auction(1, 30)
            late.owner = nil
            bought({ late })
            assert.is_true(confirm.yesButton.enabled)
            assert.matches("Available: 1 stack of 1", confirm.text.text)
            click(confirm.yesButton)
            assert.are.equal(2, #client.calls)
        end)

        it("follows a stack whose link is missing in the fresh rows", function()
            local first = auction(1, 30)
            first.itemLink = "|cff1eff00|Hitem:10::::::::70:::::|h[Item10]|h|r"
            local confirm = openBox({ first, auction(2, 30) })
            click(confirm.yesButton)
            bought({ auction(1, 30) })
            assert.is_true(confirm.yesButton.enabled)
            click(confirm.yesButton)
            assert.are.equal(2, #client.calls)
        end)

        it("waits for the ready event when the client is not ready and then shows the next stack", function()
            local confirm = openBox({ auction(1, 30), auction(2, 31) })
            click(confirm.yesButton)
            bus:Emit("ITEMBOUGHT", 1)
            client.rows[10] = { auction(1, 31) }
            client.ready = false
            bus:Emit("ITEM_RESULTS", 10)
            assert.is_false(confirm.yesButton.enabled)
            assert.are.equal("waiting for the Auction House", ui.message.text)
            client.ready = true
            bus:Emit("READY")
            assert.is_true(confirm.yesButton.enabled)
            assert.are.equal("quoted", tab.buy.phase)
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

        it("shows an error, drops the stack and offers the next one", function()
            local confirm = openBox()
            click(confirm.yesButton)
            bus:Emit("ITEMERR", "not enough money")
            bus:Emit("ITEM_RESULTS", 10)
            assert.is_true(confirm:IsShown())
            assert.matches("Error: error not enough money", confirm.text.text)
            assert.are.equal("Buy next", confirm.yesButton.text)
            assert.are.equal(3, #tab.results["10"].rows)
            click(confirm.yesButton)
            assert.are.equal(2, #client.calls)
        end)

        it("does not drop a stack that is gone from the fresh rows", function()
            local confirm = openBox()
            click(confirm.yesButton)
            bus:Emit("ITEMERR", "gone")
            client.rows[10] = { auction(1, 30), auction(2, 30), auction(3, 30) }
            bus:Emit("ITEM_RESULTS", 10)
            assert.are.equal(3, #tab.results["10"].rows)
            assert.is_true(confirm:IsShown())
        end)

        it("drops only the failed auction, by its auction ID", function()
            local confirm = openBox()
            click(confirm.yesButton)
            bus:Emit("ITEMERR", "busy")
            bus:Emit("ITEM_RESULTS", 10)
            local ids = {}
            for _, row in ipairs(tab.results["10"].rows) do
                ids[#ids + 1] = row.auctionID
            end
            assert.are.same({ 2, 3, 4 }, ids)
            assert.is_true(confirm.yesButton.enabled)
        end)

        it("shows an identical stack again after a failed buy and a good buy", function()
            local confirm = openBox()
            click(confirm.yesButton)
            bus:Emit("ITEMERR", "busy")
            bus:Emit("ITEM_RESULTS", 10)
            click(confirm.yesButton)
            assert.are.same({ { "bid", 1, 30 }, { "bid", 2, 30 } }, client.calls)
            bought({ auction(1, 30), auction(2, 30), auction(3, 30) }, 2)
            -- The list holds three identical stacks. The failed one does not hide one of them.
            assert.are.equal(3, #tab.results["10"].rows)
            assert.matches("Available: 3 stacks of 1", confirm.text.text)
        end)

        it("keeps going after a failed buy when the next stack is the only buyable one of the item", function()
            local confirm = openBox({ auction(1, 30), auction(2, 45) })
            click(confirm.yesButton)
            bus:Emit("ITEMERR", "busy")
            client.rows[10] = { auction(1, 30), auction(2, 45) }
            bus:Emit("ITEM_RESULTS", 10)
            assert.are.equal(1, #tab.results["10"].rows)
            assert.is_true(confirm.yesButton.enabled)
            assert.are.equal(45, tab.buy.total)
        end)

        it("buys an identical stack when the index changed", function()
            local confirm = openBox({ auction(1, 30, 1, "Anna"), auction(2, 31, 1, "Ben") })
            client.rows[10] = { auction(1, 31, 1, "Ben"), auction(2, 30, 1, "Anna") }
            click(confirm.yesButton)
            assert.are.same({ { "bid", 2, 30 } }, client.calls)
        end)

        it("buys another identical stack when the shown one is gone", function()
            local confirm = openBox({ auction(1, 30), auction(2, 30), auction(3, 30) })
            client.rows[10] = { auction(1, 31, 1, "Ben"), auction(2, 30), auction(3, 30) }
            click(confirm.yesButton)
            assert.are.same({ { "bid", 2, 30 } }, client.calls)
        end)

        it("never buys another price or stack size at the click when no identical stack is left", function()
            local confirm = openBox({ auction(1, 30, 1, "Anna"), auction(2, 31, 1, "Ben") })
            client.rows[10] = { auction(1, 31, 1, "Ben"), auction(2, 60, 2, "Anna"), auction(3, 30, 1, "Cara") }
            click(confirm.yesButton)
            assert.are.same({}, client.calls)
            bus:Emit("ITEM_RESULTS", 10)
            -- The box shows the error and the next stack, which is the same price and size from another seller.
            assert.matches("Error: the auction is gone", confirm.text.text)
            assert.is_true(confirm.yesButton.enabled)
            assert.are.equal("Cara", tab.buy.row.owner)
            assert.are.same({}, client.calls)
        end)

        it("shows a different price in the middle of a chain but buys only at the click", function()
            local confirm = openBox({ auction(1, 30), auction(2, 31, 1, "Ben") })
            click(confirm.yesButton)
            bought({ auction(1, 31, 1, "Ben") })
            assert.is_true(confirm.yesButton.enabled)
            assert.are.equal("quoted", tab.buy.phase)
            assert.are.equal(31, tab.buy.total)
            assert.are.equal(1, #client.calls)
        end)
    end)

    describe("the price jump warning", function()
        it("shows in the box for a dearer group that you select", function()
            search({ auction(1, 30), auction(2, 40, 1, "Ben") })
            tab:SelectLevel(levelOf("Ben").id)
            click(ui.buyNext)
            assert.matches("Price jumps from 30c to 40c %(%+33%%%)", box().text.text)
            assert.are.same({}, client.calls)
            click(box().yesButton)
            assert.are.same({ { "bid", 2, 40 } }, client.calls)
        end)

        it("shows nothing for the next stack of the same group", function()
            local confirm = openBox({ auction(1, 30), auction(2, 30), auction(3, 40, 1, "Ben") })
            click(confirm.yesButton)
            bought({ auction(1, 30), auction(2, 40, 1, "Ben") })
            assert.is_nil(confirm.text.text:match("Price jumps"))
        end)
    end)

    describe("Forever", function()
        before_each(function()
            ns.Flavour.hasCommodityMarket = true
        end)

        it("groups item auctions by item, price and stack size when no seller is known", function()
            local rows = {}
            for index = 1, 3 do
                local row = auction(100 + index, 30, 1, nil)
                row.owner, row.timeLeft = nil, nil
                rows[index] = row
            end
            search(rows)
            assert.are.equal(1, #ui.rowsList.rows)
            assert.are.equal("3 stacks of 1", ui.rowsList.rows[1].cells.quantity.text)
            assert.is_false(ui.levelHeader.labels.owner.shown)
            assert.is_false(ui.levelHeader.labels.timeLeft.shown)
        end)

        it("shows the seller when the client gives one, and keeps sellers apart", function()
            search({ auction(101, 30, 1, "Anna-Realm"), auction(102, 30, 1, "Ben-Realm") })
            assert.are.equal(2, #ui.rowsList.rows)
            assert.is_true(ui.levelHeader.labels.owner.shown)
            assert.is_false(ui.levelHeader.labels.timeLeft.shown)
        end)

        it("buys one item stack for each click and reads Buy next", function()
            local rows = { auction(101, 30), auction(102, 30), auction(103, 30) }
            local confirm = openBox(rows)
            click(confirm.yesButton)
            assert.are.same({ { "bid", 101, 30 } }, client.calls)
            bought({ auction(102, 30), auction(103, 30) }, 101)
            assert.are.equal("Buy next", confirm.yesButton.text)
            assert.matches("Available: 2 stacks of 1", confirm.text.text)
            click(confirm.yesButton)
            assert.are.same({ { "bid", 101, 30 }, { "bid", 102, 30 } }, client.calls)
        end)

        it("finds an identical item auction under a new auction ID", function()
            local confirm = openBox({ auction(101, 30), auction(102, 30) })
            client.rows[10] = { auction(205, 30) }
            click(confirm.yesButton)
            assert.are.same({ { "bid", 205, 30 } }, client.calls)
        end)

        it("still groups a commodity by unit price", function()
            local commodity = function(id, price, quantity)
                return { auctionID = id, unitPrice = price, quantity = quantity, isCommodity = true,
                    ownerItem = false }
            end
            search({ commodity(1, 30, 4), commodity(2, 30, 6), commodity(3, 40, 2) })
            assert.are.equal(2, #ui.rowsList.rows)
            assert.are.equal("x10", ui.rowsList.rows[1].cells.quantity.text)
            assert.are.equal("Available", ui.levelHeader.labels.quantity.text)
            assert.is_false(ui.levelHeader.labels.owner.shown)
        end)
    end)

    describe("the read of all pages", function()
        -- Three pages: Ben 29 on page 0, Anna 30 on pages 1 and 2, Cara 50 on page 2.
        local function threePages()
            return {
                { auction(1, 29, 1, "Ben") },
                { auction(1, 30, 1, "Anna"), auction(2, 30, 1, "Anna") },
                { auction(1, 30, 1, "Anna"), auction(2, 50, 1, "Cara") },
            }
        end

        local function startRead(pages)
            client.pages[10] = pages or threePages()
            tab:Select_("10")
            tab:Search()
        end

        it("asks for each page and counts the stacks of all pages", function()
            startRead()
            assert.are.same({ { 10, 0 } }, client.searches)
            bus:Emit("ITEM_RESULTS", 10)
            assert.are.same({ { 10, 0 }, { 10, 1 } }, client.searches)
            assert.are.equal("Reading page 2 of 3", ui.message.text)
            assert.is_true(ui.stop:IsShown())
            bus:Emit("ITEM_RESULTS", 10)
            assert.are.equal("Reading page 3 of 3", ui.message.text)
            bus:Emit("ITEM_RESULTS", 10)
            assert.are.equal("", ui.message.text)
            assert.are.equal(3, levelOf("Anna").stacks)
            assert.are.equal("3 stacks of 1", ui.rowsList.rows[2].cells.quantity.text)
        end)

        it("stamps the page on each row", function()
            startRead()
            for _ = 1, 3 do
                bus:Emit("ITEM_RESULTS", 10)
            end
            local pages = {}
            for _, row in ipairs(levelOf("Anna").rows) do
                pages[#pages + 1] = row.page
            end
            assert.are.same({ 1, 1, 2 }, pages)
        end)

        it("reads the page of the next stack again, so that the client list holds it", function()
            startRead()
            for _ = 1, 3 do
                bus:Emit("ITEM_RESULTS", 10)
            end
            -- The last page read was 2. The cheapest stack is on page 0.
            assert.are.same({ 10, 0 }, client.searches[4])
            assert.is_false(ui.buyNext.enabled)
            bus:Emit("ITEM_RESULTS", 10)
            assert.are.equal(4, #client.searches)
            assert.is_true(ui.buyNext.enabled)
        end)

        it("waits for the client throttle between pages", function()
            startRead()
            client.ready = false
            bus:Emit("ITEM_RESULTS", 10)
            assert.are.equal(1, #client.searches)
            assert.are.equal("Waiting to read page 2 of 3", ui.message.text)
            -- A late update of the page before does not count as a page.
            bus:Emit("ITEM_RESULTS", 10)
            assert.are.equal(1, #client.searches)
            client.ready = true
            bus:Emit("READY")
            assert.are.same({ { 10, 0 }, { 10, 1 } }, client.searches)
            assert.are.equal("Reading page 2 of 3", ui.message.text)
        end)

        it("can be stopped, and keeps the earlier result", function()
            startRead()
            bus:Emit("ITEM_RESULTS", 10)
            tab:Stop()
            assert.is_nil(tab.pending)
            assert.are.equal("read stopped", ui.message.text)
            assert.is_false(ui.stop:IsShown())
            bus:Emit("ITEM_RESULTS", 10)
            assert.are.equal(2, #client.searches)
            assert.is_nil(tab.results["10"])
        end)

        it("stops with the Stop button", function()
            startRead()
            bus:Emit("ITEM_RESULTS", 10)
            click(ui.stop)
            assert.is_nil(tab.pending)
        end)

        it("is stopped by a new search, which starts at page 0 again", function()
            startRead()
            bus:Emit("ITEM_RESULTS", 10)
            assert.is_true(tab:Search())
            assert.are.same({ { 10, 0 }, { 10, 1 }, { 10, 0 } }, client.searches)
            bus:Emit("ITEM_RESULTS", 10)
            assert.are.same({ 10, 1 }, client.searches[4])
        end)

        it("gives up when a page does not come", function()
            local timers = {}
            tab.deps.after = function(seconds, fn)
                timers[#timers + 1] = { seconds = seconds, fn = fn }
            end
            startRead()
            bus:Emit("ITEM_RESULTS", 10)
            timers[1].fn()
            assert.is_not_nil(tab.pending)
            timers[#timers].fn()
            assert.is_nil(tab.pending)
            assert.matches("no response", ui.message.text)
        end)

        it("makes a one page list read once", function()
            client.pages[10] = { { auction(1, 30), auction(2, 30) } }
            tab:Select_("10")
            tab:Search()
            bus:Emit("ITEM_RESULTS", 10)
            assert.are.equal(1, #client.searches)
            assert.are.equal("2 stacks of 1", ui.rowsList.rows[1].cells.quantity.text)
        end)

        describe("a late seller name", function()
            local timers

            -- The timers of the owner wait. The search timeout timers stay out.
            local function ownerTimer()
                for index, timer in ipairs(timers) do
                    if timer.seconds < 1 then
                        table.remove(timers, index)
                        return timer
                    end
                end
            end

            before_each(function()
                timers = {}
                tab.deps.after = function(seconds, fn)
                    timers[#timers + 1] = { seconds = seconds, fn = fn }
                end
                client.rows[10] = { auction(1, 30) }
                tab:Select_("10")
                tab:Search()
            end)

            it("waits for the update with the names before it shows the rows", function()
                client.ownersPending = true
                bus:Emit("ITEM_RESULTS", 10)
                assert.is_nil(tab.results["10"])
                assert.is_not_nil(tab.pending)
                client.ownersPending = false
                bus:Emit("ITEM_RESULTS", 10)
                assert.is_not_nil(tab.results["10"])
                assert.is_nil(tab.pending)
            end)

            it("accepts unknown names after a short, bounded wait", function()
                client.ownersPending = true
                bus:Emit("ITEM_RESULTS", 10)
                for _ = 1, 3 do
                    assert.is_nil(tab.results["10"])
                    ownerTimer().fn()
                end
                assert.is_not_nil(tab.results["10"])
                assert.is_nil(ownerTimer())
            end)

            it("does not read the page again when the names came before the timer", function()
                client.ownersPending = true
                bus:Emit("ITEM_RESULTS", 10)
                client.ownersPending = false
                bus:Emit("ITEM_RESULTS", 10)
                local timer = ownerTimer()
                client.rows[10] = {}
                timer.fn()
                assert.are.equal(1, #tab.results["10"].rows)
            end)
        end)

        describe("sorted pages", function()
            -- One auction for each page. The list is sorted by unit price.
            local function sortedPages()
                return {
                    { auction(1, 29, 1, "Ben") },
                    { auction(1, 30, 1, "Anna") },
                    { auction(1, 31, 1, "Cara") },
                }
            end

            -- Search the item and read page 1.
            local function read(pages)
                client.sorted = true
                client.pages[10] = pages or sortedPages()
                tab:Select_("10")
                tab:Search()
                bus:Emit("ITEM_RESULTS", 10)
            end

            it("reads page 1 only and shows it at once", function()
                read()
                assert.are.same({ { 10, 0 } }, client.searches)
                assert.is_nil(tab.pending)
                assert.is_false(ui.stop:IsShown())
                assert.are.equal(1, #ui.rowsList.rows)
                assert.is_true(ui.loadMore:IsShown())
                assert.are.equal("Load more (1/3)", ui.loadMore.text)
                assert.is_true(ui.buyNext.enabled)
            end)

            it("hides Load more when the result has one page", function()
                read({ { auction(1, 29, 1, "Ben") } })
                assert.is_false(ui.loadMore:IsShown())
                assert.is_nil(tab.results["10"].more)
            end)

            it("reads the next page at Load more and keeps the pages that are loaded", function()
                read()
                click(ui.loadMore)
                assert.are.same({ 10, 1 }, client.searches[2])
                bus:Emit("ITEM_RESULTS", 10)
                -- The client list shows page 2 now. The cheapest stack is on page 1: its page is read again.
                bus:Emit("ITEM_RESULTS", 10)
                assert.are.equal(2, #tab.results["10"].rows)
                assert.are.same({ next = 2, total = 3 }, tab.results["10"].more)
                assert.are.equal("Load more (2/3)", ui.loadMore.text)
                click(ui.loadMore)
                bus:Emit("ITEM_RESULTS", 10)
                bus:Emit("ITEM_RESULTS", 10)
                assert.are.equal(3, #tab.results["10"].rows)
                assert.is_nil(tab.results["10"].more)
                assert.is_false(ui.loadMore:IsShown())
            end)

            it("refuses Load more with no more pages", function()
                read({ { auction(1, 29, 1, "Ben") } })
                local ok = tab:LoadMore()
                assert.is_false(ok)
            end)

            -- Buy the stack on page 1 and open the next box. Returns the box.
            local function buyFirstStack()
                read()
                click(ui.buyNext)
                local confirm = box()
                click(confirm.yesButton)
                return confirm
            end

            it("makes Buy next read the next page when the next stack is at the tail price", function()
                local confirm = buyFirstStack()
                -- The bought stack is gone. The pages shift: two pages are left.
                client.pages[10] = { { auction(1, 30, 1, "Anna") }, { auction(1, 31, 1, "Cara") } }
                bus:Emit("ITEMBOUGHT", 1)
                bus:Emit("ITEM_RESULTS", 10)
                -- The loaded page has only the stack at the tail price: Buy next reads the next page first.
                assert.are.same({ 10, 1 }, client.searches[3])
                bus:Emit("ITEM_RESULTS", 10)
                bus:Emit("ITEM_RESULTS", 10)
                assert.is_true(confirm.yesButton.enabled)
                assert.are.equal("quoted", tab.buy.phase)
                assert.are.equal(30, tab.buy.total)
            end)

            it("makes Buy next read the next page when the loaded page has only your own stacks", function()
                local confirm = buyFirstStack()
                local mine = auction(1, 30, 1, "Me")
                mine.ownerItem = true
                client.pages[10] = { { mine }, { auction(1, 31, 1, "Cara") } }
                bus:Emit("ITEMBOUGHT", 1)
                bus:Emit("ITEM_RESULTS", 10)
                assert.are.same({ 10, 1 }, client.searches[3])
                bus:Emit("ITEM_RESULTS", 10)
                bus:Emit("ITEM_RESULTS", 10)
                assert.is_true(confirm.yesButton.enabled)
                assert.are.equal(31, tab.buy.total)
            end)

            it("says No more stacks only when no page is left", function()
                local confirm = buyFirstStack()
                client.pages[10] = {}
                bus:Emit("ITEMBOUGHT", 1)
                bus:Emit("ITEM_RESULTS", 10)
                assert.is_true(confirm:IsShown())
                assert.matches("No more stacks of this item", confirm.text.text)
            end)
        end)

        describe("a buy", function()
            -- Select the Anna group, so that the client list holds its page. Returns the box.
            local function openAnna(pages)
                startRead(pages)
                for _ = 1, 4 do
                    bus:Emit("ITEM_RESULTS", 10)
                end
                tab:SelectLevel(levelOf("Anna").id)
                -- The group starts on page 1, the client list shows page 0.
                assert.are.same({ 10, 1 }, client.searches[5])
                bus:Emit("ITEM_RESULTS", 10)
                click(ui.buyNext)
                return box()
            end

            it("buys on the page that holds the group", function()
                local confirm = openAnna()
                assert.matches("Available: 3 stacks of 1", confirm.text.text)
                click(confirm.yesButton)
                assert.are.same({ { "bid", 1, 30 } }, client.calls)
                assert.are.same({}, client.violations)
            end)

            it("reads again only the pages that hold the group, and counts the stacks left", function()
                local confirm = openAnna()
                click(confirm.yesButton)
                client.pages[10] = {
                    { auction(1, 29, 1, "Ben") },
                    { auction(1, 30, 1, "Anna"), auction(2, 30, 1, "Anna") },
                    { auction(1, 50, 1, "Cara") },
                }
                bus:Emit("ITEMBOUGHT", 1)
                -- Pages 2 and 1, the last page first. Page 0 is not read.
                assert.are.same({ 10, 2 }, client.searches[6])
                bus:Emit("ITEM_RESULTS", 10)
                assert.are.same({ 10, 1 }, client.searches[7])
                bus:Emit("ITEM_RESULTS", 10)
                assert.are.equal(7, #client.searches)
                assert.are.equal("Buy next", confirm.yesButton.text)
                assert.matches("Available: 2 stacks of 1", confirm.text.text)
                click(confirm.yesButton)
                assert.are.same({ { "bid", 1, 30 }, { "bid", 1, 30 } }, client.calls)
            end)

            it("reads the page of the next stack when it is not on the page of the client list", function()
                local confirm = openAnna({
                    { auction(1, 29, 1, "Ben") },
                    { auction(1, 30, 1, "Anna"), auction(2, 31, 1, "Dan") },
                    { auction(1, 32, 1, "Eve"), auction(2, 30, 1, "Anna") },
                })
                click(confirm.yesButton)
                -- The bought stack leaves page 1. The other Anna stack moves to the top of page 2 only.
                client.pages[10] = {
                    { auction(1, 29, 1, "Ben") },
                    { auction(1, 31, 1, "Dan"), auction(2, 32, 1, "Eve") },
                    { auction(1, 30, 1, "Anna") },
                }
                bus:Emit("ITEMBOUGHT", 1)
                bus:Emit("ITEM_RESULTS", 10)
                bus:Emit("ITEM_RESULTS", 10)
                -- The client list shows page 1 now, and the last Anna stack is on page 2.
                assert.are.same({ 10, 2 }, client.searches[8])
                assert.is_false(confirm.yesButton.enabled)
                bus:Emit("ITEM_RESULTS", 10)
                assert.is_true(confirm.yesButton.enabled)
                assert.matches("Available: 1 stack of 1", confirm.text.text)
                click(confirm.yesButton)
                assert.are.same({ { "bid", 1, 30 }, { "bid", 1, 30 } }, client.calls)
                assert.are.same({}, client.violations)
            end)
        end)
    end)
end)
