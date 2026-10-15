local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local KIT = { "Theme", "Window", "Widgets", "Tabs", "List", "Columns", "Combat", "Graph" }
local CORE = {
    "EventBus", "ItemString", "SettingsDB", "LedgerRecord", "LedgerBuffer", "LedgerStore", "LedgerLoader",
    "LedgerBalance",
}

local DAY = 86400
local NOW = 400 * DAY + 7200
local ME, ALT = "Me-Realm", "Alt-Realm"

local function load()
    local ns = {}
    for _, name in ipairs(KIT) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    for _, name in ipairs(CORE) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    assert(loadfile(manifest.path("LedgerPage")))("Flipside", ns)
    assert(loadfile(manifest.path("MainWindow")))("Flipside", ns)
    return ns
end

-- The records of a ledger with every type of the spec table. Days are counted back from NOW.
local function seed()
    local function rec(fields)
        fields.char = fields.char or ME
        fields.item = fields.item or ""
        fields.qty = fields.qty or 0
        fields.money = fields.money or 0
        return fields
    end
    local mine = {
        rec({ time = NOW - 3600, type = "sale", source = "ahSale", item = "100", qty = 2, money = 5000,
            counterparty = "Buyer", ctx = "ah:1" }),
        rec({ time = NOW - 3 * DAY, type = "sale", source = "ahSale", item = "100", qty = 1, money = 2000 }),
        rec({ time = NOW - 20 * DAY, type = "sale", source = "ahSale", item = "101", qty = 1, money = 700 }),
        rec({ time = NOW - 100 * DAY, type = "sale", source = "ahSale", item = "101", qty = 1, money = 900 }),
        rec({ time = NOW - 200 * DAY, type = "sale", source = "ahSale", item = "101", qty = 1, money = 400 }),
        rec({ time = NOW - 1800, type = "purchase", source = "ahPurchase", item = "200", qty = 1, money = 300,
            ctx = "ah:2" }),
        rec({ time = NOW - 1700, type = "post", source = "ahPost", item = "100", qty = 1, buyout = 9000,
            deposit = 50, ctx = "ah:3" }),
        rec({ time = NOW - 1700, type = "log", item = "100", qty = 1, action = "post next", reason = "undercut",
            tab = "Selling", ctx = "ah:3" }),
        rec({ time = NOW - 1600, type = "log", item = "100", qty = 1, action = "dry run", reason = "tooLow",
            tab = "Selling", dryRun = true, ctx = "ah:4" }),
        rec({ time = NOW - 1500, type = "expired", source = "ahExpired", item = "100", qty = 1 }),
        rec({ time = NOW - 1400, type = "cancelled", source = "ahCancelled", item = "100", qty = 1 }),
        rec({ time = NOW - 1300, type = "loot", source = "loot", item = "300", qty = 3, value = 10, mob = "Boar" }),
        rec({ time = NOW - 1300, type = "loot", source = "loot", money = 77, mob = "Boar" }),
        rec({ time = NOW - 1200, type = "expense", source = "ahDeposit", money = 50 }),
        rec({ time = NOW - 1100, type = "expense", source = "repair", money = 200 }),
        rec({ time = NOW - 1000, type = "expense", source = "vendorPurchase", item = "400", qty = 1, money = 25 }),
        rec({ time = NOW - 900, type = "income", source = "vendorSale", item = "300", qty = 3, money = 150 }),
        rec({ time = NOW - 800, type = "income", source = "quest", money = 1000 }),
        rec({ time = NOW - 700, type = "income", source = "mailMoney", money = 40 }),
        rec({ time = NOW - 600, type = "income", source = "ahDepositRefund", money = 50 }),
        rec({ time = NOW - 500, type = "income", source = "trade", money = 60 }),
        rec({ time = NOW - 400, type = "expense", source = "unknown", money = 15 }),
    }
    local other = {
        { time = NOW - 2 * DAY, char = ALT, type = "sale", source = "ahSale", item = "100", qty = 1, money = 1000 },
    }
    return { records = { EU = { standard = { [ME] = mine, [ALT] = other } } } }
end

describe("LedgerPage", function()
    local ns, bus, db, loader, saved, combat, loadResult, ensureCalls, page, initializers, itemCache

    local function setup(options)
        options = options or {}
        mock.reset()
        mock.serverBase = NOW
        mock.clock = 0
        local real = _G.ScrollUtil.InitScrollBoxListWithScrollBar
        initializers = {}
        _G.ScrollUtil.InitScrollBoxListWithScrollBar = function(box, bar, view)
            real(box, bar, view)
            initializers[box] = view
        end
        ns = load()
        combat, loadResult, ensureCalls = false, { true }, 0
        saved = options.saved or seed()
        bus = ns.EventBus.New()
        db = ns.SettingsDB.New(options.dbData or {}, {
            character = ME,
            schemaVersion = 1,
            defaults = { account = ns.LedgerRecord.Defaults() },
        })
        local buffer = ns.LedgerBuffer.New(db, {})
        local real_loader = ns.LedgerLoader.New({
            bus = bus,
            buffer = buffer,
            now = function()
                return NOW
            end,
            inCombat = function()
                return combat
            end,
            loadAddOn = function()
                return loadResult[1], loadResult[2]
            end,
            openStore = function()
                return ns.LedgerStore.New(saved, { region = "EU", ruleset = "standard" })
            end,
            setting = function(key)
                return db:Get("account", key)
            end,
        })
        real_loader:Attach()
        loader = setmetatable({
            Ensure = function()
                ensureCalls = ensureCalls + 1
                return real_loader.Ensure(real_loader)
            end,
            Store = function()
                return real_loader:Store()
            end,
        }, {})
        itemCache = nil
    end

    local function build(extra)
        local deps = {
            ledgerLoader = loader,
            bus = bus,
            db = db,
            character = ME,
            now = function()
                return NOW
            end,
            itemCache = itemCache,
        }
        for k, v in pairs(extra or {}) do
            deps[k] = v
        end
        page = ns.LedgerPage.Build(CreateFrame("Frame", nil, UIParent), deps)
        return page
    end

    local function select(tab)
        page.topTabs:Select(tab)
    end

    local function rows(tab)
        return page.views[tab].list:GetData()
    end

    local function pick(dropdown, value)
        for _, item in ipairs(dropdown.menuItems) do
            if item.value == value then
                item.pick()
                return
            end
        end
        error("no menu item " .. tostring(value))
    end

    local function values(dropdown)
        local out = {}
        for _, item in ipairs(dropdown.menuItems) do
            out[#out + 1] = item.value
        end
        return out
    end

    local function keys(columns, onlyShown)
        local out = {}
        for _, column in ipairs(columns) do
            if not (onlyShown and column.hidden) then
                out[#out + 1] = column.key
            end
        end
        return out
    end

    after_each(function()
        mock.teardown()
    end)

    describe("registration and loading", function()
        before_each(function()
            setup()
        end)

        it("adds the Ledger page to the window", function()
            local win = ns.MainWindow.Create({
                ledgerLoader = loader, bus = bus, db = db, character = ME, now = function()
                    return NOW
                end,
                formulaRun = {},
            })
            local titles = {}
            for _, tab in ipairs(win.frame.Tabs) do
                titles[#titles + 1] = tab:GetText()
            end
            assert.are.equal("Ledger", titles[1])
            assert.are.equal("ledger", win:GetSelectedPage())
            assert.are.equal(1, ensureCalls)
            win:SelectPage("ledger")
            assert.are.equal(1, ensureCalls)
        end)

        it("calls Ensure when the page opens", function()
            build()
            assert.are.equal(1, ensureCalls)
            page.Open()
            assert.are.equal(2, ensureCalls)
        end)

        it("shows the loading text while the ledger waits for combat", function()
            combat = true
            build()
            assert.are.equal("Loading ledger... It loads when combat ends.", page.status:GetText())
            assert.is_nil(page.views.sales)
            combat = false
            bus:Emit("PLAYER_REGEN_ENABLED")
            assert.are.equal("", page.status:GetText())
            assert.is_truthy(page.views.sales)
            assert.is_true(#rows("sales") > 0)
        end)

        it("shows the failure reason", function()
            loadResult = { false, "the addon is disabled" }
            build()
            assert.are.equal("the addon is disabled", page.status:GetText())
            assert.is_nil(page.views.sales)
        end)

        it("draws the data after the loaded event", function()
            loadResult = { false, "missing" }
            build()
            assert.are.equal("missing", page.status:GetText())
            loadResult = { true }
            page.Open()
            assert.are.equal("", page.status:GetText())
            assert.is_true(#rows("sales") > 0)
        end)

        it("says that the ledger is missing when there is no loader", function()
            build({ ledgerLoader = false })
            assert.are.equal("The ledger is not available this session.", page.status:GetText())
        end)

        it("adds no hook and registers no event", function()
            local handle = assert(io.open(manifest.path("LedgerPage"), "rb"))
            local text = handle:read("*a")
            handle:close()
            assert.is_nil(text:find("hooksecurefunc", 1, true))
            assert.is_nil(text:find("RegisterEvent", 1, true))
            assert.is_nil(text:find("HookScript", 1, true))
        end)
    end)

    describe("tabs and columns", function()
        before_each(function()
            setup()
            build()
        end)

        it("has the five inner tabs and no Income by source", function()
            local titles = {}
            for _, tab in ipairs(ns.LedgerPage.TABS) do
                titles[#titles + 1] = tab.title
            end
            assert.are.same({ "Sales", "Purchases", "Auctions", "Loot", "Expenses" }, titles)
            assert.are.equal(5, #page.topTabs.buttons)
            assert.is_nil(ns.LedgerPage.IncomeRows)
        end)

        it("builds only the visible tab", function()
            assert.is_truthy(page.views.sales)
            assert.is_nil(page.views.loot)
            select("loot")
            assert.is_truthy(page.views.loot)
        end)

        it("gives each tab its columns", function()
            local expected = {
                sales = { "time", "item", "qty", "money", "detail" },
                purchases = { "time", "item", "qty", "money", "detail" },
                auctions = { "time", "item", "qty", "money", "detail" },
                loot = { "time", "item", "qty", "money", "value", "detail" },
                expenses = { "time", "item", "qty", "money", "detail" },
            }
            for tab, list in pairs(expected) do
                select(tab)
                assert.are.same(list, keys(page.views[tab].columns, true), tab)
            end
            assert.are.equal("Buyer", page.views.sales.columns[7].title)
            assert.are.equal("Seller", page.views.purchases.columns[7].title)
            assert.are.equal("Mob", page.views.loot.columns[7].title)
        end)

        it("shows the character column only for all characters", function()
            assert.is_true(page.views.sales.columns[2].hidden)
            pick(page.charDropdown, "all")
            assert.is_false(page.views.sales.columns[2].hidden)
            assert.are.same({ "time", "char", "item", "qty", "money", "detail" },
                keys(page.views.sales.columns, true))
        end)
    end)

    describe("filters", function()
        before_each(function()
            setup()
            build()
        end)

        it("lists all characters, then the current one, then the others", function()
            assert.are.same({ "all", ME, ALT }, values(page.charDropdown))
        end)

        it("puts the current character first when the sort order differs", function()
            saved.records.EU.standard["Aaa-Realm"] = { { time = NOW, char = "Aaa-Realm", type = "income",
                source = "quest", money = 1 } }
            page.Open()
            assert.are.same({ "all", ME, "Aaa-Realm", ALT }, values(page.charDropdown))
        end)

        it("defaults to the current character and 30 days", function()
            assert.are.equal(ME, page.filter.char)
            assert.are.equal("30", page.filter.range)
            assert.are.equal(3, #rows("sales"))
        end)

        it("filters by character and saves the choice", function()
            pick(page.charDropdown, ALT)
            assert.are.equal(1, #rows("sales"))
            assert.are.equal(ALT, rows("sales")[1].char)
            assert.are.equal(ALT, db:Get("character", "ledger.view.char"))
            pick(page.charDropdown, "all")
            assert.are.equal(4, #rows("sales"))
        end)

        it("filters by date range and saves the choice", function()
            local expected = { today = 1, ["7"] = 2, ["30"] = 3, ["180"] = 4, all = 5 }
            for range, count in pairs(expected) do
                pick(page.rangeDropdown, range)
                assert.are.equal(count, #rows("sales"), range)
                assert.are.equal(range, db:Get("character", "ledger.view.range"))
            end
        end)

        it("starts the range at the first second of a UTC day", function()
            assert.are.equal(400 * DAY, ns.LedgerPage.RangeStart("today", NOW))
            assert.are.equal(394 * DAY, ns.LedgerPage.RangeStart("7", NOW))
            assert.is_nil(ns.LedgerPage.RangeStart("all", NOW))
        end)

        it("reads the saved choice when the page builds again", function()
            pick(page.charDropdown, "all")
            pick(page.rangeDropdown, "7")
            local again = build()
            assert.are.equal("all", again.filter.char)
            assert.are.equal("7", again.filter.range)
        end)

        it("lists the saved character even if it has no records", function()
            db:Set("character", "ledger.view.char", "Gone-Realm")
            build()
            local has = false
            for _, value in ipairs(values(page.charDropdown)) do
                has = has or value == "Gone-Realm"
            end
            assert.is_true(has)
            assert.are.equal(0, #rows("sales"))
        end)
    end)

    describe("rows", function()
        before_each(function()
            setup()
            build()
        end)

        it("sorts the rows newest first", function()
            local sales = rows("sales")
            assert.are.equal(NOW - 3600, sales[1].time)
            assert.are.equal(NOW - 20 * DAY, sales[3].time)
            assert.are.equal("Buyer", sales[1].detail)
            assert.are.equal(2, sales[1].qty)
            assert.are.equal(5000, sales[1].money)
        end)

        it("shows a mail sale with item, quantity, real money and buyer in Sales", function()
            local mine = saved.records.EU.standard[ME]
            mine[#mine + 1] = { time = NOW - 60, char = ME, type = "sale", source = "ahSale", item = "",
                itemName = "Mystery Herb", qty = 4, money = 9050, bid = 9500, deposit = 100, cut = 550,
                counterparty = "Rich-Realm" }
            setup({ saved = saved })
            build()
            local first = rows("sales")[1]
            assert.are.equal(NOW - 60, first.time)
            assert.are.equal("Mystery Herb", first.item)
            assert.are.equal(4, first.qty)
            assert.are.equal(9050, first.money)
            assert.are.equal(9050, first.moneyIn)
            assert.are.equal("Rich-Realm", first.detail)
        end)

        it("shows the purchases of the Auction House", function()
            select("purchases")
            assert.are.equal(1, #rows("purchases"))
            assert.are.equal("Auction purchase", rows("purchases")[1].detail)
            assert.are.equal(300, rows("purchases")[1].moneyOut)
        end)

        it("shows posts, buys, expired, cancelled and dry runs in Auctions", function()
            select("auctions")
            local details = {}
            for _, row in ipairs(rows("auctions")) do
                details[#details + 1] = row.detail
            end
            assert.are.same({
                "Cancelled",
                "Expired",
                "dry run, dry run, tooLow",
                "Posted, buyout 9000c, deposit 50c: undercut",
                "Bought",
            }, details)
        end)

        it("shows the mob and the vendor value in Loot", function()
            select("loot")
            local loot = rows("loot")
            assert.are.equal(2, #loot)
            assert.are.equal("Boar", loot[1].detail)
            local item, coin
            for _, row in ipairs(loot) do
                if row.item == "300" then
                    item = row
                else
                    coin = row
                end
            end
            assert.are.equal(30, item.value)
            assert.are.equal(77, coin.moneyIn)
        end)

        it("shows deposits, repairs, vendor purchases and unknown spending in Expenses", function()
            select("expenses")
            local details = {}
            for _, row in ipairs(rows("expenses")) do
                details[#details + 1] = row.detail
            end
            assert.are.same({ "Unknown", "Vendor purchase", "Repair", "Auction deposit" }, details)
        end)

        it("shows daily sums as one row with the daily total mark", function()
            pick(page.rangeDropdown, "all")
            local sales = rows("sales")
            local daily = sales[#sales]
            assert.is_true(daily.daily)
            assert.are.equal("daily total (1)", daily.detail)
            assert.are.equal(ME, daily.char)
            assert.are.equal("101", daily.item)
            assert.are.equal(200 * DAY, daily.time)
            assert.are.equal(400, daily.moneyIn)
        end)

        it("marks the daily rows of Auctions with the source", function()
            saved.sums = { EU = { standard = { [ME] = {
                { day = 100, source = "ahExpired", item = "100", count = 4, qty = 4, moneyIn = 0, moneyOut = 0 },
                { day = 100, source = "vendorSale", item = "", count = 2, qty = 0, moneyIn = 90, moneyOut = 0 },
            } } } }
            pick(page.rangeDropdown, "all")
            select("auctions")
            local auctions = rows("auctions")
            assert.are.equal("Auction expired, daily total (4)", auctions[#auctions].detail)
            select("expenses")
            for _, row in ipairs(rows("expenses")) do
                assert.is_nil(row.daily)
            end
        end)

        it("puts a daily sum of a two-way source in Expenses only for money out", function()
            saved.sums = { EU = { standard = { [ME] = {
                { day = 100, source = "trade", item = "", count = 1, qty = 0, moneyIn = 0, moneyOut = 30 },
                { day = 101, source = "trade", item = "", count = 1, qty = 0, moneyIn = 20, moneyOut = 0 },
            } } } }
            pick(page.rangeDropdown, "all")
            select("expenses")
            local daily = 0
            for _, row in ipairs(rows("expenses")) do
                if row.daily then
                    daily = daily + 1
                    assert.are.equal(30, row.moneyOut)
                end
            end
            assert.are.equal(1, daily)
        end)
    end)

    describe("totals", function()
        before_each(function()
            setup()
            build()
        end)

        it("adds the money in and out of the rows", function()
            local totals = ns.LedgerPage.Totals({
                { moneyIn = 100, moneyOut = 0 }, { moneyIn = 0, moneyOut = 30 }, { moneyIn = 5, moneyOut = 0 },
            })
            assert.are.same({ moneyIn = 105, moneyOut = 30, net = 75, count = 3 }, totals)
        end)

        it("shows the totals of the visible rows", function()
            local view = page.views.sales
            assert.are.equal("7700c", view.totals.moneyIn:GetText())
            assert.are.equal("0c", view.totals.moneyOut:GetText())
            assert.are.equal("7700c", view.totals.net:GetText())
            assert.are.equal("3 rows", view.totals.count:GetText())
            pick(page.rangeDropdown, "today")
            assert.are.equal("5000c", view.totals.moneyIn:GetText())
            assert.are.equal("1 row", view.totals.count:GetText())
        end)

        it("shows a negative net with a minus sign", function()
            select("expenses")
            local view = page.views.expenses
            assert.are.equal("290c", view.totals.moneyOut:GetText())
            assert.are.equal("0c", view.totals.moneyIn:GetText())
            assert.are.equal("-290c", view.totals.net:GetText())
        end)

        it("counts only money rows in Loot and Auctions", function()
            select("loot")
            assert.are.equal("77c", page.views.loot.totals.moneyIn:GetText())
            select("auctions")
            assert.are.equal("300c", page.views.auctions.totals.moneyOut:GetText())
        end)
    end)

    describe("empty state", function()
        it("shows the message when there are no records", function()
            setup({ saved = {} })
            build()
            local view = page.views.sales
            assert.are.equal(0, #rows("sales"))
            assert.is_true(view.empty:IsShown())
            assert.are.equal("No records yet. The ledger records money from loot, vendors, mail, trades, quests "
                .. "and the Auction House.", view.empty:GetText())
        end)

        it("hides the message when rows exist", function()
            setup()
            build()
            assert.is_false(page.views.sales.empty:IsShown())
        end)
    end)

    describe("row cells", function()
        before_each(function()
            setup()
        end)

        local function draw(tab, data)
            local view = page.views[tab]
            local init = initializers[view.list.box].initializer
            local row = CreateFrame("Button", nil, UIParent)
            init(row, data)
            return row
        end

        it("draws text and money from one row", function()
            build()
            local row = draw("sales", rows("sales")[1])
            assert.are.equal("2", row.cells.qty:GetText())
            assert.are.equal("Buyer", row.cells.detail:GetText())
            assert.are.equal("5000c", row.money.money:GetText())
            assert.matches("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d$", row.cells.time:GetText())
            assert.are.equal("100", row.cells.item:GetText())
        end)

        it("shows an item link and falls back to the name with the quality colour", function()
            itemCache = {
                Get = function(_, id)
                    if id == 100 then
                        return { name = "Copper Bar", link = "|cffffffff|Hitem:100|h[Copper Bar]|h|r", quality = 1 }
                    elseif id == 101 then
                        return { name = "Iron Bar", quality = 2 }
                    end
                end,
                Request = function() end,
            }
            build()
            pick(page.rangeDropdown, "180")
            local sales = rows("sales")
            local row = draw("sales", sales[1])
            assert.are.equal("|cffffffff|Hitem:100|h[Copper Bar]|h|r", row.cells.item:GetText())
            row = draw("sales", sales[#sales])
            assert.matches("^|c%x+Iron Bar|r$", row.cells.item:GetText())
        end)

        it("draws the daily date in UTC and the character when all is chosen", function()
            build()
            pick(page.charDropdown, "all")
            pick(page.rangeDropdown, "all")
            local sales = rows("sales")
            local row = draw("sales", sales[#sales])
            assert.are.equal(os.date("!%Y-%m-%d", sales[#sales].time), row.cells.time:GetText())
            assert.are.equal(ME, row.cells.char:GetText())
        end)

        it("draws a dash for a row without money", function()
            build()
            select("auctions")
            local row = draw("auctions", rows("auctions")[1])
            assert.are.equal("-", row.money.money:GetText())
        end)

        it("asks the item cache once for an item that is not known", function()
            local requests = 0
            itemCache = {
                Get = function() end,
                Request = function()
                    requests = requests + 1
                end,
            }
            build()
            local data = rows("sales")[1]
            draw("sales", data)
            draw("sales", data)
            assert.are.equal(1, requests)
        end)
    end)

    describe("balance graph", function()
        local MONEY = 5000

        -- Day 400 is today. Money changes: +1000 today, -300 yesterday, +500 two days ago.
        local function graphData()
            local function rec(time, kind, source, money, char)
                return {
                    time = time, char = char or ME, type = kind, source = source, money = money, item = "", qty = 0,
                }
            end
            return { records = { EU = { standard = {
                [ME] = {
                    rec(NOW - 3600, "income", "quest", 1000),
                    rec(NOW - DAY, "expense", "unknown", 300),
                    rec(NOW - 2 * DAY, "sale", "ahSale", 500),
                },
                [ALT] = { rec(NOW - 2 * DAY, "sale", "ahSale", 1000, ALT) },
            } } } }
        end

        local function ys()
            local out = {}
            for _, point in ipairs(page.series.points) do
                out[#out + 1] = point.y
            end
            return out
        end

        local function buildGraph(extra)
            local deps = {
                getMoney = function()
                    return MONEY
                end,
                ledgerBuffer = ns.LedgerBuffer.New(db, {}),
            }
            for k, v in pairs(extra or {}) do
                deps[k] = v
            end
            return build(deps)
        end

        before_each(function()
            setup({ saved = graphData() })
            MONEY = 5000
            db:Set("character", "ledger.view.range", "7")
        end)

        it("draws one point for each day of the range from the live money", function()
            buildGraph()
            assert.are.equal("days", page.series.mode)
            assert.are.same({ 3800, 3800, 3800, 3800, 4300, 4000, 5000 }, ys())
            assert.are.equal(7, #page.graph:GetLayout())
        end)

        it("sets the y axis from 0 to a clean value above the highest balance", function()
            buildGraph()
            local view = page.graph:GetView()
            assert.are.equal(0, view.yMin)
            assert.are.equal(6000, page.graphScale.max)
            assert.are.equal(6000, view.yMax)
            assert.are.equal("s", page.graphScale.unit)
            assert.are.same({ 0, 2000, 4000, 6000 }, page.graphScale.ticks)
        end)

        it("follows the range filter", function()
            buildGraph()
            pick(page.rangeDropdown, "today")
            assert.are.equal("records", page.series.mode)
            assert.are.same({ 4000, 5000, 5000 }, ys())
            pick(page.rangeDropdown, "30")
            assert.are.equal(30, #page.series.points)
        end)

        it("uses the saved balance of another character", function()
            db:SetFor(ALT, "ledger.balance", { copper = 2000, time = NOW - 100 })
            buildGraph()
            pick(page.charDropdown, ALT)
            assert.are.same({ 1000, 1000, 1000, 1000, 2000, 2000, 2000 }, ys())
            assert.are.equal("", page.graphNote:GetText())
        end)

        it("leaves out a character without a balance and says so", function()
            buildGraph()
            pick(page.charDropdown, ALT)
            assert.are.equal(0, #page.series.points)
            assert.is_truthy(page.graphNote:GetText():find(ALT, 1, true))
        end)

        it("adds the characters for \"All characters\" and notes the missing one", function()
            buildGraph()
            pick(page.charDropdown, "all")
            assert.are.same({ 3800, 3800, 3800, 3800, 4300, 4000, 5000 }, ys())
            assert.is_truthy(page.graphNote:GetText():find(ALT, 1, true))
            db:SetFor(ALT, "ledger.balance", { copper = 2000, time = NOW - 100 })
            page.graphSignature = nil
            page.Draw()
            assert.are.same({ 4800, 4800, 4800, 4800, 6300, 6000, 7000 }, ys())
            assert.are.equal("", page.graphNote:GetText())
        end)

        it("does not compute the points again if nothing changed", function()
            buildGraph()
            local calls = 0
            local real = page.graph.SetPoints
            page.graph.SetPoints = function(...)
                calls = calls + 1
                return real(...)
            end
            page.Draw()
            page.Draw()
            assert.are.equal(0, calls)
            pick(page.rangeDropdown, "30")
            assert.are.equal(1, calls)
            MONEY = 6000
            page.Draw()
            assert.are.equal(2, calls)
        end)

        it("counts the records that wait in the buffer", function()
            buildGraph()
            local buffer = ns.LedgerBuffer.New(db, {})
            buffer:Add({ time = NOW - 60, char = ME, type = "income", source = "mailMoney", money = 40 })
            page.Draw()
            assert.are.equal(3960, page.series.points[6].y)
        end)

        it("shows the date and the balance when the mouse is over a point", function()
            buildGraph()
            page.graph:SetWidth(780)
            page.graph:Redraw()
            local layout = page.graph:GetLayout()
            assert.are.equal(7, page.graph:HoverAt(layout[7].x))
            assert.are.equal(os.date("!%Y-%m-%d", 400 * DAY), mock.tooltip.title)
            assert.are.same({ "Balance: 5000c" }, mock.tooltip.lines)
            assert.are.equal(5, page.graph:HoverAt(layout[5].x - 3))
            assert.are.equal(os.date("!%Y-%m-%d", 398 * DAY), mock.tooltip.title)
        end)

        it("labels the y axis with the money text", function()
            buildGraph()
            local labels = {}
            for _, object in ipairs(mock.objects) do
                if object.kind == "FontString" and object.parent == page.graph and object.text then
                    labels[object.text] = true
                end
            end
            assert.is_true(labels["0c"])
            assert.is_true(labels["2000c"])
            assert.is_true(labels["6000c"])
            assert.is_true(labels[os.date("!%Y-%m-%d", 394 * DAY)])
            assert.is_true(labels[os.date("!%Y-%m-%d", 400 * DAY)])
        end)

        it("hides the graph, moves the list up and saves the choice", function()
            buildGraph()
            assert.is_true(page.graph:IsShown())
            page.graphToggle.scripts.OnClick(page.graphToggle)
            assert.is_false(page.graph:IsShown())
            assert.is_false(page.graphNote:IsShown())
            assert.are.equal(false, db:Get("character", "ledger.view.graph"))
            assert.are.equal("Show graph", page.graphToggle:GetText())
            local again = buildGraph()
            assert.is_false(again.graph:IsShown())
        end)

        it("makes the graph 130 high and as wide as the page", function()
            buildGraph()
            assert.are.equal(130, page.graph.height)
            local left, right = page.graph.points[1], page.graph.points[2]
            assert.are.equal("TOPLEFT", left[1])
            assert.are.equal("TOPRIGHT", right[1])
        end)
    end)end)
