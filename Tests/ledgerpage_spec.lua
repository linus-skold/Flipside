local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local KIT = { "Theme", "Window", "Widgets", "MoneyInput", "Tabs", "List", "Columns", "Combat", "Graph" }
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
    assert(loadfile(manifest.path("LedgerEdit")))("Flipside", ns)
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

    -- Builds the page. The tests of the record tabs start on Sales; stay = true keeps the default tab.
    local function build(extra, stay)
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
        if not stay then
            page.topTabs:Select("sales")
        end
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

        it("has the six inner tabs and no Income by source", function()
            local titles = {}
            for _, tab in ipairs(ns.LedgerPage.TABS) do
                titles[#titles + 1] = tab.title
            end
            assert.are.same({ "Overview", "Sales", "Purchases", "Auctions", "Loot", "Expenses" }, titles)
            assert.are.equal(6, #page.topTabs.buttons)
            assert.is_nil(ns.LedgerPage.IncomeRows)
        end)

        it("builds only the visible tab", function()
            build(nil, true)
            assert.is_truthy(page.views.overview)
            assert.is_nil(page.views.sales)
            select("sales")
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

    describe("realm filter", function()
        local BOB, TWO, OLD = "Bob-Other", "Cy-Other", "Old"

        local function seedRealms()
            local data = seed()
            local list = data.records.EU.standard
            local function sale(char, money)
                return { time = NOW - 3600, char = char, type = "sale", source = "ahSale", item = "100", qty = 1,
                    money = money }
            end
            list[BOB] = { sale(BOB, 111) }
            list[TWO] = { sale(TWO, 222) }
            list[OLD] = { sale(OLD, 333) }
            return data
        end

        local function buildTbc(flag)
            setup({ saved = seedRealms() })
            ns.Flavour = { ledgerRealmFilter = flag }
            return build()
        end

        local function graphNames()
            local names = {}
            for _, list in ipairs({ page.series.included, page.series.omitted }) do
                for _, name in ipairs(list) do
                    names[#names + 1] = name
                end
            end
            table.sort(names)
            return names
        end

        it("shows no realm dropdown when the flag is off", function()
            buildTbc(false)
            assert.is_nil(page.realmDropdown)
            assert.is_nil(page.filter.realm)
            assert.are.equal(ME, page.filter.char)
            assert.are.same({ "all", ME, ALT, BOB, TWO, OLD }, values(page.charDropdown))
        end)

        it("shows no realm dropdown when the flag is missing", function()
            setup({ saved = seedRealms() })
            build()
            assert.is_nil(page.realmDropdown)
        end)

        it("shows both dropdowns when the flag is on", function()
            buildTbc(true)
            assert.is_not_nil(page.realmDropdown)
            assert.are.same({ "Realm", "Other", "?" }, values(page.realmDropdown))
            assert.are.same({ "all", ALT, ME }, values(page.charDropdown))
        end)

        it("defaults to the current realm and All", function()
            buildTbc(true)
            assert.are.equal("Realm", page.filter.realm)
            assert.are.equal("all", page.filter.char)
            assert.are.equal(4, #rows("sales"))
        end)

        it("lists the current realm even with no records", function()
            setup({ saved = { records = { EU = { standard = { [BOB] = { { time = NOW - 60, char = BOB,
                type = "sale", source = "ahSale", item = "100", qty = 1, money = 5 } } } } } } })
            ns.Flavour = { ledgerRealmFilter = true }
            build()
            assert.are.same({ "Realm", "Other" }, values(page.realmDropdown))
            assert.are.same({ "all" }, values(page.charDropdown))
            assert.are.equal(0, #rows("sales"))
        end)

        it("resets the character when the server changes and saves both", function()
            buildTbc(true)
            pick(page.charDropdown, ALT)
            assert.are.equal(1, #rows("sales"))
            pick(page.realmDropdown, "Other")
            assert.are.equal("all", page.filter.char)
            assert.are.same({ "all", BOB, TWO }, values(page.charDropdown))
            assert.are.equal(2, #rows("sales"))
            assert.are.equal("Other", db:Get("character", "ledger.view.realm"))
            assert.are.equal("all", db:Get("character", "ledger.view.char"))
        end)

        it("filters rows and totals by character", function()
            buildTbc(true)
            pick(page.realmDropdown, "Other")
            pick(page.charDropdown, BOB)
            assert.are.equal(1, #rows("sales"))
            assert.are.equal(111, ns.LedgerPage.Totals(rows("sales")).moneyIn)
            pick(page.charDropdown, "all")
            assert.are.equal(333, ns.LedgerPage.Totals(rows("sales")).moneyIn)
        end)

        it("filters the daily sums by realm", function()
            local data = seedRealms()
            data.sums = { EU = { standard = {
                [BOB] = { { day = 380, source = "ahSale", item = "100", count = 2, qty = 2, moneyIn = 50,
                    moneyOut = 0 } },
                [ALT] = { { day = 380, source = "ahSale", item = "100", count = 1, qty = 1, moneyIn = 9,
                    moneyOut = 0 } },
            } } }
            setup({ saved = data })
            ns.Flavour = { ledgerRealmFilter = true }
            build()
            pick(page.realmDropdown, "Other")
            local daily = 0
            for _, row in ipairs(rows("sales")) do
                if row.daily then
                    daily = daily + row.moneyIn
                end
            end
            assert.are.equal(50, daily)
        end)

        it("puts a record with no realm under Unknown", function()
            buildTbc(true)
            pick(page.realmDropdown, "?")
            assert.are.same({ "all", OLD }, values(page.charDropdown))
            assert.are.equal(1, #rows("sales"))
            assert.are.equal(333, rows("sales")[1].moneyIn)
        end)

        it("limits the graph to the selected realm and character", function()
            buildTbc(true)
            assert.are.same({ ALT, ME }, graphNames())
            pick(page.realmDropdown, "Other")
            assert.are.same({ BOB, TWO }, graphNames())
            pick(page.charDropdown, BOB)
            assert.are.same({ BOB }, graphNames())
        end)

        it("restores the saved choice", function()
            buildTbc(true)
            pick(page.realmDropdown, "Other")
            pick(page.charDropdown, TWO)
            local again = build()
            assert.are.equal("Other", again.filter.realm)
            assert.are.equal(TWO, again.filter.char)
            assert.are.equal(1, #rows("sales"))
        end)

        it("falls back to the defaults when the saved realm has no records", function()
            buildTbc(true)
            db:Set("character", "ledger.view.realm", "Gone")
            db:Set("character", "ledger.view.char", BOB)
            build()
            assert.are.equal("Realm", page.filter.realm)
            assert.are.equal("all", page.filter.char)
        end)

        it("falls back to All when the saved character has no records on the realm", function()
            buildTbc(true)
            db:Set("character", "ledger.view.realm", "Realm")
            db:Set("character", "ledger.view.char", "Gone-Realm")
            build()
            assert.are.equal("Realm", page.filter.realm)
            assert.are.equal("all", page.filter.char)
        end)

        it("writes a debug line when the filter changes", function()
            buildTbc(true)
            local lines = {}
            ns.Log = { Write = function(category, level, text)
                lines[#lines + 1] = category .. "|" .. level .. "|" .. text
            end }
            pick(page.realmDropdown, "Other")
            assert.are.equal(1, #lines)
            assert.is_truthy(lines[1]:find("^ledger|debug|filter realm=Other"))
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

        describe("with the counterparty and the place", function()
            before_each(function()
                local mine = saved.records.EU.standard[ME]
                mine[#mine + 1] = { time = NOW - 60, char = ME, type = "purchase", source = "ahPurchase",
                    item = "201", qty = 2, money = 400, counterparty = "Poor-Realm", ctx = "ah:9" }
                mine[#mine + 1] = { time = NOW - 50, char = ME, type = "expense", source = "flight", item = "",
                    qty = 0, money = 1200, place = "Orgrimmar, Durotar" }
                mine[#mine + 1] = { time = NOW - 40, char = ME, type = "expense", source = "trade", item = "",
                    qty = 0, money = 90, counterparty = "Bob" }
                mine[#mine + 1] = { time = NOW - 30, char = ME, type = "expense", source = "training", item = "",
                    qty = 0, money = 300 }
                setup({ saved = saved })
                build()
            end)

            it("shows the seller of an Auction House purchase in Purchases", function()
                select("purchases")
                assert.are.equal("Poor-Realm", rows("purchases")[1].detail)
                assert.are.equal("Auction purchase", rows("purchases")[2].detail)
            end)

            it("shows the seller of an Auction House purchase in Auctions", function()
                select("auctions")
                local details = {}
                for _, row in ipairs(rows("auctions")) do
                    details[#details + 1] = row.detail
                end
                assert.are.equal("Bought from Poor-Realm", details[1])
                assert.are.equal("Bought", details[#details])
            end)

            it("shows the place and the partner in Expenses", function()
                select("expenses")
                local details = {}
                for _, row in ipairs(rows("expenses")) do
                    details[#details + 1] = row.detail
                end
                assert.are.same({ "Training", "Trade, Bob", "Flight path, Orgrimmar, Durotar" },
                    { details[1], details[2], details[3] })
            end)

            it("shows the seller and the place in the Overview detail", function()
                select("overview")
                local found = {}
                for _, row in ipairs(rows("overview")) do
                    found[row.kind] = found[row.kind] or row.detail
                end
                assert.are.equal("Poor-Realm", found["AH purchase"])
                assert.are.equal("Orgrimmar, Durotar", found["Flight path"])
                assert.are.equal("Bob", found["Trade"])
                assert.are.equal("", found["Training"])
            end)

            it("has labels for the money sources that the windows give", function()
                local labels = {
                    flight = "Flight path", training = "Training", bankSlot = "Bank slot", stable = "Stable",
                    barber = "Barber", talentReset = "Talent reset", guildBank = "Guild bank",
                }
                for source, label in pairs(labels) do
                    assert.are.equal(label, ns.LedgerPage.SourceLabel(source))
                    assert.are.equal(label, ns.LedgerPage.TypeLabel(source))
                end
            end)
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
    end)

    describe("overview", function()
        local function build_overview()
            return build(nil, true)
        end

        -- Expected totals, read from the store with no page code: full records by direction, plus daily sums.
        local function expected(char)
            local current = loader:Store()
            local totalIn, totalOut = 0, 0
            for _, record in ipairs(current:Records({ char = char })) do
                local dir = ns.LedgerRecord.Direction(record.type)
                if dir == "in" then
                    totalIn = totalIn + record.money
                elseif dir == "out" then
                    totalOut = totalOut + record.money
                end
            end
            for _, sum in ipairs(current:Sums({ char = char })) do
                totalIn, totalOut = totalIn + sum.moneyIn, totalOut + sum.moneyOut
            end
            return totalIn, totalOut
        end
        before_each(function()
            setup()
        end)

        it("is the first and default tab", function()
            build_overview()
            assert.are.equal("overview", ns.LedgerPage.TABS[1].key)
            assert.are.equal("overview", page.tab)
            assert.are.equal("overview", page.topTabs:GetSelected())
            assert.is_truthy(page.views.overview)
            assert.is_nil(page.views.sales)
        end)

        it("has no summary strip and keeps the totals row", function()
            build_overview()
            pick(page.rangeDropdown, "all")
            local totalIn, totalOut = expected(ME)
            local view = page.views.overview
            assert.is_nil(view.strip)
            assert.are.equal(totalIn .. "c", view.totals.moneyIn:GetText())
            assert.are.equal(totalOut .. "c", view.totals.moneyOut:GetText())
            assert.are.equal((totalIn - totalOut) .. "c", view.totals.net:GetText())
        end)

        it("shows buyout and deposit as the Detail of a post row, with Money empty", function()
            build_overview()
            pick(page.rangeDropdown, "all")
            local post
            for _, row in ipairs(rows("overview")) do
                if row.source == "ahPost" then
                    post = row
                end
            end
            assert.are.equal("Buyout 9000c, deposit 50c", post.detail)
            assert.is_nil(post.money)
        end)

        it("shows only the buyout when the post has no deposit", function()
            for _, record in ipairs(saved.records.EU.standard[ME]) do
                if record.source == "ahPost" then
                    record.deposit = nil
                end
            end
            build_overview()
            pick(page.rangeDropdown, "all")
            for _, row in ipairs(rows("overview")) do
                if row.source == "ahPost" then
                    assert.are.equal("Buyout 9000c", row.detail)
                end
            end
        end)

        it("gives the header the list insets and the cells none", function()
            build_overview()
            for _, tab in ipairs({ "overview", "sales" }) do
                select(tab)
                local view = page.views[tab]
                assert.is_nil(view.options.left)
                assert.is_nil(view.options.right)
                assert.are.equal(view.list.contentInsets.left, view.headerOptions.left)
                assert.are.equal(view.list.contentInsets.right, view.headerOptions.right)
            end
        end)
        it("counts every source, the daily sums and unknown", function()
            saved.sums = { EU = { standard = { [ME] = {
                { day = 100, source = "vendorSale", item = "", count = 2, qty = 0, moneyIn = 90, moneyOut = 0 },
                { day = 101, source = "unknown", item = "", count = 1, qty = 0, moneyIn = 0, moneyOut = 33 },
                { day = 102, source = "trade", item = "", count = 2, qty = 0, moneyIn = 20, moneyOut = 5 },
                { day = 103, source = "ahDeposit", item = "", count = 1, qty = 0, moneyIn = 0, moneyOut = 8 },
                { day = 104, source = "ahExpired", item = "100", count = 4, qty = 4, moneyIn = 0, moneyOut = 0 },
            } } } }
            build_overview()
            pick(page.rangeDropdown, "all")
            local totalIn, totalOut = expected(ME)
            assert.is_true(totalIn >= 90 + 20 and totalOut >= 33 + 5 + 8)
            local totals = ns.LedgerPage.Totals(page.views.overview.rows)
            assert.are.equal(totalIn, totals.moneyIn)
            assert.are.equal(totalOut, totals.moneyOut)
            assert.are.equal(totalIn - totalOut, totals.net)
        end)

        it("agrees with the other tabs for the money that they show", function()
            build_overview()
            pick(page.rangeDropdown, "all")
            local overview = ns.LedgerPage.Totals(page.views.overview.rows)
            local sum = { moneyIn = 0, moneyOut = 0 }
            -- Sales, Loot and Expenses hold no shared record. Income records (vendor, quest, mail, trade, refund)
            -- have no tab; the Overview adds them.
            for _, tab in ipairs({ "sales", "loot", "expenses" }) do
                select(tab)
                local totals = ns.LedgerPage.Totals(page.views[tab].rows)
                sum.moneyIn = sum.moneyIn + totals.moneyIn
                sum.moneyOut = sum.moneyOut + totals.moneyOut
            end
            select("purchases")
            local purchases = ns.LedgerPage.Totals(page.views.purchases.rows)
            sum.moneyOut = sum.moneyOut + purchases.moneyOut
            local income = 0
            for _, record in ipairs(saved.records.EU.standard[ME]) do
                if record.type == "income" then
                    income = income + record.money
                end
            end
            assert.are.equal(sum.moneyIn + income, overview.moneyIn)
            assert.are.equal(sum.moneyOut, overview.moneyOut)
        end)

        it("colours the net green when positive and red when negative", function()
            build_overview()
            local net = page.views.overview.totals.net
            assert.is_true(net.color[2] == 1 and net.color[1] < 0.5)
            pick(page.rangeDropdown, "today")
            -- Only money out in range: a negative net.
            saved.records.EU.standard[ME] = { { time = NOW - 60, char = ME, type = "expense", source = "repair",
                money = 90, item = "", qty = 0 } }
            setup({ saved = saved })
            build_overview()
            net = page.views.overview.totals.net
            assert.are.equal("-90c", net.text)
            assert.is_true(net.color[1] == 1 and net.color[2] < 0.5)
        end)

        it("lists every record newest first with the type labels", function()
            build_overview()
            local list = rows("overview")
            for index = 2, #list do
                assert.is_true(list[index - 1].time >= list[index].time)
            end
            assert.are.equal("AH sale", list[#list].kind)
            local seen = {}
            for _, row in ipairs(list) do
                seen[row.kind] = true
            end
            for _, label in ipairs({ "AH sale", "AH purchase", "AH post", "Deposit", "Deposit refund", "AH expired",
                "AH cancelled", "Loot", "Vendor sale", "Vendor purchase", "Repair", "Mail money", "Trade", "Quest",
                "Unknown", "Log", "Dry run" }) do
                assert.is_true(seen[label], label)
            end
        end)

        it("has labels for the mail send sources", function()
            assert.are.equal("Mail sent", ns.LedgerPage.SourceLabel("mailSent"))
            assert.are.equal("Mail money sent", ns.LedgerPage.SourceLabel("mailMoneySent"))
            assert.are.equal("Mail sent", ns.LedgerPage.TypeLabel("mailSent"))
            assert.are.equal("Mail money sent", ns.LedgerPage.TypeLabel("mailMoneySent"))
        end)

        it("shows records without money with an empty Money cell", function()
            build_overview()
            local init = initializers[page.views.overview.list.box].initializer
            local found = 0
            for _, data in ipairs(rows("overview")) do
                if data.kind == "AH expired" or data.kind == "AH cancelled" or data.kind == "AH post"
                    or data.kind == "Log" or data.kind == "Dry run" then
                    found = found + 1
                    local row = CreateFrame("Button", nil, UIParent)
                    init(row, data)
                    assert.are.equal("", row.money.flow:GetText())
                end
            end
            assert.are.equal(5, found)
        end)

        it("draws a green plus for money in and a red minus for money out", function()
            build_overview()
            local init = initializers[page.views.overview.list.box].initializer
            local function cell(kind)
                for _, data in ipairs(rows("overview")) do
                    if data.kind == kind then
                        local row = CreateFrame("Button", nil, UIParent)
                        init(row, data)
                        return row.money.flow:GetText()
                    end
                end
            end
            assert.are.equal("|cff40ff40+5000c|r", cell("AH sale"))
            assert.are.equal("|cffff4040\226\136\14625c|r", cell("Vendor purchase"))
        end)

        it("shows the detail and the item", function()
            build_overview()
            local list = rows("overview")
            local sale = list[#list]
            for _, row in ipairs(list) do
                if row.kind == "Loot" then
                    assert.are.equal("Boar", row.detail)
                end
                if row.kind == "AH sale" and row.qty == 2 then
                    sale = row
                end
            end
            assert.are.equal("Buyer", sale.detail)
            assert.are.equal("100", sale.item)
        end)

        it("marks a daily sum", function()
            build_overview()
            pick(page.rangeDropdown, "all")
            local list = rows("overview")
            local daily = list[#list]
            assert.is_true(daily.daily)
            assert.are.equal("daily total (1)", daily.detail)
            assert.are.equal("AH sale", daily.kind)
            assert.are.equal(400, daily.flow)
        end)

        it("shows the Character column only for all characters", function()
            build_overview()
            local view = page.views.overview
            assert.are.same({ "time", "kind", "item", "qty", "flow", "detail" }, keys(view.columns, true))
            pick(page.charDropdown, "all")
            assert.are.same({ "time", "char", "kind", "item", "qty", "flow", "detail" }, keys(view.columns, true))
            local alt = 0
            for _, row in ipairs(rows("overview")) do
                if row.char == ALT then
                    alt = alt + 1
                end
            end
            assert.are.equal(1, alt)
        end)

        it("keeps the graph above the tabs on every tab", function()
            build_overview()
            assert.is_true(page.graph:IsShown())
            select("loot")
            assert.is_true(page.graph:IsShown())
        end)
    end)

    describe("editing a record", function()
        local logged

        before_each(function()
            setup()
            logged = {}
            ns.Log = {
                Write = function(category, level, text)
                    logged[#logged + 1] = { category, level, text }
                end,
            }
        end)

        local function build_sales(extra)
            build(extra)
            return rows("sales")[1]
        end

        local function editWindow()
            local data = build_sales()
            return page.EditRow(data), data
        end

        local function rowFor(data)
            local init = initializers[page.views[page.tab].list.box].initializer
            local row = CreateFrame("Button", nil, UIParent)
            init(row, data)
            return row
        end

        local function texts(entries)
            local out = {}
            for _, entry in ipairs(entries) do
                out[#out + 1] = entry.text
            end
            return out
        end

        it("opens a menu with Edit on a right click of a record row", function()
            local data = build_sales()
            local row = rowFor(data)
            row.scripts.OnClick(row, "RightButton")
            assert.are.equal(row, mock.menu.owner)
            assert.are.equal("Edit...", mock.menu.items[1].text)
            assert.are.equal(1, #mock.menu.items)
        end)

        it("opens no menu on a left click or on a daily total", function()
            local data = build_sales()
            local row = rowFor(data)
            mock.menu = nil
            row.scripts.OnClick(row, "LeftButton")
            assert.is_nil(mock.menu)
            assert.are.same({}, page.RowMenuEntries({ daily = true, char = ME }))
        end)

        it("shows Revert only for an edited record", function()
            local data = build_sales()
            assert.are.same({ "Edit..." }, texts(page.RowMenuEntries(data)))
            assert.is_nil(page.SaveEdit(data, { money = 1 }))
            assert.are.same({ "Edit...", "Revert" }, texts(page.RowMenuEntries(rows("sales")[1])))
        end)

        it("opens the edit window with the values of the record", function()
            local data = build_sales()
            local win = page.EditRow(data)
            assert.is_true(win:IsShown())
            assert.are.equal("100", win.controls.item:GetText())
            assert.are.equal("2", win.controls.qty:GetText())
            assert.are.equal(5000, win.controls.money:GetCopper())
            assert.are.equal("ahSale", win.sourceValue)
        end)

        it("saves the edit window, marks the row and draws again", function()
            local data = build_sales()
            local win = page.EditRow(data)
            win.controls.money:SetCopper(1234)
            win.controls.qty:SetText("3")
            win.controls.note:SetText("checked")
            win.Save()
            assert.is_false(win:IsShown())
            local row = rows("sales")[1]
            assert.is_true(row.edited)
            assert.are.equal(1234, row.money)
            assert.are.equal(3, row.qty)
            assert.matches("^%* ", row.detail)
            assert.matches("checked", row.detail)
            local totals = ns.LedgerPage.Totals(rows("sales"))
            assert.are.equal(totals.moneyIn .. "c", page.views.sales.totals.moneyIn:GetText())
            assert.is_true(totals.moneyIn < 5000 + 2000 + 700 + 1)
        end)

        it("changes the revision of the store, so the graph draws again", function()
            local data = build_sales()
            local before = loader:Store():Revision()
            page.SaveEdit(data, { money = 99 })
            assert.is_true(loader:Store():Revision() > before)
        end)

        it("keeps the window open and shows a message for a bad value", function()
            local data = build_sales()
            local win = page.EditRow(data)
            win.controls.item:SetText("not an item")
            win.Save()
            assert.is_true(win:IsShown())
            assert.is_truthy(win.error:GetText() ~= "")
            assert.are.equal(5000, data.record.money)
            assert.is_nil(data.record.edited)
        end)

        it("shows the message of the store when it refuses a value", function()
            local data = build_sales()
            local win = page.EditRow(data)
            win.controls.item:SetText("")
            win.Save()
            assert.is_true(win:IsShown())
            assert.matches("qty needs an item", win.error:GetText())
        end)

        it("changes the source from the drop-down", function()
            local data = build_sales()
            local win = page.EditRow(data)
            pick(win.controls.source, "vendorSale")
            win.Save()
            assert.are.equal("vendorSale", data.record.source)
            assert.are.equal("income", data.record.type)
            assert.are.equal("ahSale", data.record.orig.source)
        end)

        it("lists every known source in the drop-down", function()
            local win = editWindow()
            assert.are.same(ns.LedgerRecord.SOURCES, values(win.controls.source))
        end)

        it("resolves an item link, an id and a name", function()
            local index = {
                Resolve = function(_, text)
                    if text == "Copper Bar" then
                        return { kind = "name", matches = { { key = "555", name = "Copper Bar" } } }
                    elseif text == "Bar" then
                        return { kind = "name", matches = { { key = "1", name = "A Bar" },
                            { key = "2", name = "B Bar" } } }
                    end
                    return { kind = "name", matches = {} }
                end,
            }
            local edit = ns.LedgerEdit
            assert.are.equal("", edit.ResolveItem("  ", index))
            assert.are.equal("777", edit.ResolveItem("|cffffffff|Hitem:777|h[X]|h|r", index))
            assert.are.equal("888", edit.ResolveItem("888", index))
            assert.are.equal("100#s5", edit.ResolveItem("100#s5", index))
            assert.are.equal("555", edit.ResolveItem("Copper Bar", index))
            assert.is_nil((edit.ResolveItem("Bar", index)))
            assert.is_nil((edit.ResolveItem("Nothing", index)))
            assert.is_nil((edit.ResolveItem("Copper Bar", nil)))
        end)

        it("takes an item name from the name index in the window", function()
            local index = {
                Resolve = function()
                    return { kind = "name", matches = { { key = "555", name = "Copper Bar" } } }
                end,
            }
            local data = build_sales({ itemNameIndex = index })
            local win = page.EditRow(data)
            win.controls.item:SetText("Copper Bar")
            win.Save()
            assert.are.equal("555", data.record.item)
        end)

        it("fills the item box when the user drops an item on it", function()
            local cleared = 0
            _G.GetCursorInfo = function()
                return "item", 9, "|Hitem:9|h[X]|h"
            end
            _G.ClearCursor = function()
                cleared = cleared + 1
            end
            local win = editWindow()
            win.controls.item.scripts.OnReceiveDrag(win.controls.item)
            assert.are.equal("|Hitem:9|h[X]|h", win.controls.item:GetText())
            assert.are.equal(1, cleared)
            _G.GetCursorInfo = function()
                return "money"
            end
            win.controls.item:SetText("5")
            win.controls.item.scripts.OnMouseDown(win.controls.item)
            assert.are.equal("5", win.controls.item:GetText())
            assert.are.equal(1, cleared)
            _G.GetCursorInfo, _G.ClearCursor = nil, nil
        end)
        it("reverts and shows the first values again", function()
            local data = build_sales()
            page.SaveEdit(data, { money = 1, note = "n" })
            assert.is_true(page.RevertRow(rows("sales")[1]))
            local row = rows("sales")[1]
            assert.is_false(row.edited)
            assert.are.equal(5000, row.money)
            assert.are.equal("Buyer", row.detail)
            assert.is_false(page.RevertRow(row))
        end)

        it("writes an info line on an edit and on a revert", function()
            local data = build_sales()
            page.SaveEdit(data, { money = 1, note = "n" })
            assert.are.equal("ledger", logged[1][1])
            assert.are.equal("info", logged[1][2])
            assert.matches("^edit Me%-Realm %S+: money, note$", logged[1][3])
            page.RevertRow(rows("sales")[1])
            assert.matches("^revert Me%-Realm ", logged[2][3])
            page.SaveEdit(rows("sales")[1], { money = 5000 })
            assert.are.equal(2, #logged)
        end)

        it("shows the note and the first values in the tooltip", function()
            local data = build_sales()
            assert.is_nil(ns.LedgerPage.TooltipLines(data.record))
            page.SaveEdit(data, { money = 1, note = "check this", source = "vendorSale" })
            local title, lines = ns.LedgerPage.TooltipLines(data.record)
            assert.are.equal("Edited entry", title)
            local text = table.concat(lines, "\n")
            assert.matches("Note: check this", text)
            assert.matches("Source: Auction sale", text)
            assert.matches("Amount: 5000c", text)
            assert.matches("quantity 2", text)
        end)

        it("shows a tooltip on mouse over of an edited row", function()
            local data = build_sales()
            page.SaveEdit(data, { note = "hello" })
            local row = rowFor(rows("sales")[1])
            assert.has_no.errors(function()
                row.scripts.OnEnter(row)
                row.scripts.OnLeave(row)
            end)
        end)

        it("does not edit when the ledger is not loaded", function()
            local data = build_sales()
            local lost = {
                Store = function() end,
                Ensure = function()
                    return false, "MISSING"
                end,
            }
            local bare = ns.LedgerPage.Build(CreateFrame("Frame", nil, UIParent), {
                ledgerLoader = lost,
                bus = bus,
                db = db,
                character = ME,
                now = function()
                    return NOW
                end,
            })
            assert.are.same({}, bare.RowMenuEntries(data))
            assert.is_string(bare.SaveEdit(data, { money = 1 }))
            assert.is_false(bare.RevertRow(data))
            assert.is_nil(data.record.edited)
        end)

        it("does not edit in a read-only store", function()
            local locked = seed()
            locked._schema = 9
            setup({ saved = locked })
            local data = build_sales()
            assert.are.same({}, page.RowMenuEntries(data))
            assert.is_string(page.SaveEdit(data, { money = 1 }))
            assert.is_nil(page.EditRow(data))
        end)
    end)
end)