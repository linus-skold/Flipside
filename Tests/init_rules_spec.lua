local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local ns, deps

local function tocFiles()
    return manifest.files()
end

local function loadAddon()
    local space = {}
    for _, path in ipairs(tocFiles()) do
        assert(loadfile(path))("Flipside", space)
    end
    -- Record the deps that Init gives to the window.
    local create = space.MainWindow.Create
    space.MainWindow.Create = function(given)
        deps = given
        return create(given)
    end
    return space
end

local function login()
    mock.fire("ADDON_LOADED", "Flipside")
    mock.fire("PLAYER_LOGIN")
end

local function slash(text)
    mock.messages = {}
    _G.SlashCmdList.FLIPSIDE(text)
end

local function click(button)
    button.scripts.OnClick(button)
end

local function windowFrame()
    for _, f in ipairs(mock.frames) do
        if f.name == "FlipsideMainWindow" then
            return f
        end
    end
end

local function saveCustom(page, name, text)
    page.customName:SetText(name)
    page.customText:SetText(text)
    click(page.customSave)
end

local LINEN = "|cff1eff00|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r"

describe("Init rules", function()
    before_each(function()
        mock.reset()
        local methods = getmetatable(CreateFrame("Frame")).__index
        methods.SetJustifyH = function() end
        methods.HasFocus = function(self)
            return self.focused
        end
        _G.ScrollUtil = nil
        _G.ChatEdit_InsertLink = function()
            return true
        end
        _G.hooksecurefunc = function(name, hook)
            local original = _G[name]
            _G[name] = function(...)
                local result = original(...)
                hook(...)
                return result
            end
        end
        _G.C_Timer.NewTicker = function()
            return { Cancel = function() end }
        end
        mock.playerName = "Tester"
        mock.realmName = "TestRealm"
        deps = nil
        ns = loadAddon()
        login()
        mock.commodityResults[2589] = { { unitPrice = 100, quantity = 20 }, { unitPrice = 120, quantity = 30 } }
        mock.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    end)

    after_each(function()
        _G.hooksecurefunc = nil
        _G.ChatEdit_InsertLink = nil
        mock.teardown()
    end)

    it("loads the step 4 files in order before Init", function()
        local position = {}
        for i, path in ipairs(tocFiles()) do
            position[path] = i
        end
        local function before(first, second)
            assert.is_true(position[first] < position[second], first .. " before " .. second)
        end
        before(manifest.path("OperationSchema"), manifest.path("RulesStore"))
        before(manifest.path("GroupTree"), manifest.path("RulesStore"))
        before(manifest.path("FormulaSources"), manifest.path("CustomSources"))
        before(manifest.path("BagItems"), manifest.path("Init"))
        before(manifest.path("RulesStore"), manifest.path("Init"))
        before(manifest.path("CustomSources"), manifest.path("Init"))
        before(manifest.path("List"), manifest.path("Tree"))
        before(manifest.path("Tree"), manifest.path("GroupsPage"))
        before(manifest.path("FormulaPage"), manifest.path("OperationsPage"))
        before(manifest.path("OperationsPage"), manifest.path("MainWindow"))
        before(manifest.path("GroupsPage"), manifest.path("MainWindow"))
    end)

    it("creates the search lists at login with the saved-list contract", function()
        assert.is_table(ns.searchLists)
        for _, name in ipairs({ "List", "Get", "Create", "Upsert", "Rename", "Delete", "AddItem", "RemoveItem" }) do
            assert.is_function(ns.searchLists[name], name)
        end
        local id = ns.searchLists:Create("Recipe", { { itemID = 2589 } })
        local changed = 0
        ns.bus:Subscribe("Flipside.SearchListsChanged", "test", function()
            changed = changed + 1
        end)
        assert.are.equal(id, ns.searchLists:Upsert("Recipe", { { itemID = 2589 }, { itemID = 2592 } }))
        assert.are.equal(1, changed)
        assert.are.equal(2, ns.searchLists:List()[1].count)
    end)

    it("creates the rules and the custom sources at login", function()
        assert.is_table(ns.rules)
        assert.is_table(ns.customSources)
        assert.is_function(ns.SubscribeRules)
        assert.are.equal(ns.customSources, ns.formulaSources.custom)
    end)

    describe("window", function()
        before_each(function()
            slash("")
        end)

        it("has the six tabs in sequence", function()
            local tabs = windowFrame().Tabs
            assert.are.equal(6, #tabs)
            assert.are.equal("Groups", tabs[1]:GetText())
            assert.are.equal("Operations", tabs[2]:GetText())
            assert.are.equal("Tooltip", tabs[3]:GetText())
            assert.are.equal("Ledger", tabs[4]:GetText())
            assert.are.equal("Formulas", tabs[5]:GetText())
            assert.are.equal("About", tabs[6]:GetText())
            assert.are.same({}, mock.messages)
        end)

        it("passes the real services to the pages", function()
            assert.are.equal(ns.rules, deps.rules)
            assert.are.equal(ns.customSources, deps.customSources)
            assert.are.equal(ns.formulaRun, deps.formulaRun)
            assert.are.equal(ns.formulaSources, deps.formulaSources)
            assert.are.equal(ns.itemCache, deps.itemCache)
            assert.are.equal(ns.itemNameIndex, deps.itemNameIndex)
            assert.are.equal(ns.SubscribeRules, deps.subscribe)
            assert.is_function(deps.readBags)
            assert.is_function(deps.keyFor)
        end)

        it("builds the Groups and Operations pages with the real services", function()
            local groups = ns.GroupsPage.Build(CreateFrame("Frame", nil, UIParent), deps)
            local operations = ns.OperationsPage.Build(CreateFrame("Frame", nil, UIParent), deps)
            assert.is_table(groups)
            assert.is_table(operations)
            ns.MainWindow.Create(deps):SelectPage("operations")
            ns.MainWindow.Create(deps):SelectPage("about")
            assert.are.same({}, mock.messages)
        end)

        it("refreshes a subscribed page when the rules change", function()
            local operations = ns.OperationsPage.Build(CreateFrame("Frame", nil, UIParent), deps)
            assert.are.equal(2, #operations.list.data)
            assert.are.equal("Default", operations.list.data[1].name)
            assert.are.equal("Default", operations.list.data[2].name)
            local events = 0
            ns.bus:Subscribe("Flipside.RulesChanged", "test", function()
                events = events + 1
            end)
            assert.is_number(ns.rules:CreateOperation("selling", "Sell linen"))
            assert.are.equal(3, #operations.list.data)
            assert.are.equal("Sell linen", operations.list.data[3].name)
            assert.are.equal(1, events)
        end)

        it("makes the Default buying operation with no max price on Base", function()
            local op = ns.rules:ListOperations("buying")[1]
            assert.are.equal("Default", op.name)
            assert.are.equal(op.id, (ns.rules:EffectiveOperation(1, "buying")))
            assert.are.equal("", ns.rules:GetOperation(op.id).settings.maxPrice)
        end)

        it("makes the Default selling operation and attaches it to Base", function()
            local op = ns.rules:ListOperations("selling")[1]
            assert.are.equal("Default", op.name)
            assert.are.equal(op.id, (ns.rules:EffectiveOperation(1, "selling")))
            local settings = ns.rules:GetOperation(op.id).settings
            assert.are.equal(1, settings.undercut)
            assert.are.equal("first(vendorsell, 1)", settings.minPrice)
            assert.is_false(settings.needScanData)
        end)

        it("reports an error of a subscriber and keeps the others", function()
            local called = false
            ns.SubscribeRules(function()
                error("boom")
            end)
            ns.SubscribeRules(function()
                called = true
            end)
            mock.messages = {}
            ns.rules:CreateOperation("buying", "Buy")
            assert.is_true(called)
            assert.is_truthy(mock.messages[1]:find("boom", 1, true))
        end)

        it("fills the Operations example box from a shift-click link", function()
            local operations = ns.OperationsPage.Build(CreateFrame("Frame", nil, UIParent), deps)
            operations.exampleInput.focused = true
            _G.ChatEdit_InsertLink(LINEN)
            assert.are.equal(LINEN, operations.exampleInput:GetText())
        end)
    end)

    describe("bags", function()
        it("reads the bag items with the scan key lookups", function()
            mock.stackSizes[2589] = 200
            mock.bags[0] = {
                { itemID = 2589, hyperlink = LINEN, stackCount = 5, itemName = "Linen Cloth", isBound = false },
                { itemID = 2589, hyperlink = LINEN, stackCount = 7, itemName = "Linen Cloth", isBound = false },
                { itemID = 4306, hyperlink = "|Hitem:4306::::::::60:::::|h[Silk]|h", stackCount = 1,
                    itemName = "Silk", isBound = true },
            }
            local entries = ns.readBags()
            assert.are.equal(1, #entries)
            assert.are.equal("2589", entries[1].key)
            assert.are.equal(12, entries[1].count)
            assert.are.equal("Linen Cloth", entries[1].name)
        end)

        it("uses the client commodity status", function()
            mock.commodity[2589] = true
            mock.bags[1] = { { itemID = 2589, hyperlink = LINEN, stackCount = 3, itemName = "Linen Cloth" } }
            assert.are.equal("2589", ns.readBags()[1].key)
        end)

        it("returns the key of a link", function()
            mock.stackSizes[2589] = 200
            assert.are.equal("2589", ns.keyFor(LINEN))
            assert.is_nil(ns.keyFor("not a link"))
        end)
    end)

    describe("custom sources on the Formulas page", function()
        local page

        before_each(function()
            slash("")
            page = ns.FormulaPage.Build(CreateFrame("Frame", nil, UIParent), deps)
        end)

        local function customNames()
            local out = {}
            for _, entry in ipairs(page.list.data) do
                if entry.status == "custom" then
                    out[#out + 1] = entry.name
                end
            end
            return out
        end

        it("saves a source that a formula can use", function()
            saveCustom(page, "myprice", "scanmin * 2")
            assert.are.equal("", page.customMessage:GetText())
            slash("formula myprice 2589")
            assert.are.same({ "Flipside: formula = 200 (2s) for 2589" }, mock.messages)
        end)

        it("lists the source as custom", function()
            saveCustom(page, "myprice", "scanmin * 2")
            assert.are.same({ "myprice" }, customNames())
            assert.are.equal("myprice", page.customList.data[1].name)
        end)

        it("refuses a loop with the chain", function()
            saveCustom(page, "aaa", "scanmin")
            saveCustom(page, "bbb", "aaa + 1")
            saveCustom(page, "aaa", "bbb + 1")
            assert.are.equal("loop: aaa -> bbb -> aaa", page.customMessage:GetText())
            assert.are.equal("scanmin", ns.customSources:Get("aaa"))
        end)

        it("deletes the selected source after the confirm", function()
            saveCustom(page, "myprice", "scanmin * 2")
            click(page.customList.rows[1])
            assert.are.equal("myprice", page.customName:GetText())
            click(page.customDelete)
            assert.are.equal("FLIPSIDE_DELETE_CUSTOM_SOURCE", mock.popup.which)
            assert.are.equal("myprice", ns.customSources:List()[1].name)
            mock.acceptPopup()
            assert.are.same({}, ns.customSources:List())
            assert.are.same({}, customNames())
        end)

        it("shows the used-by message when a delete is refused", function()
            saveCustom(page, "aaa", "scanmin")
            saveCustom(page, "bbb", "aaa + 1")
            click(page.customList.rows[1])
            click(page.customDelete)
            mock.acceptPopup()
            assert.are.equal("'aaa' is used by: bbb", page.customMessage:GetText())
            assert.are.equal("scanmin", ns.customSources:Get("aaa"))
        end)
    end)

    describe("reload", function()
        it("keeps groups, operations and custom sources", function()
            local group = ns.rules:CreateGroup(1, "Cloth")
            ns.rules:AddItem("2589", group)
            local op = ns.rules:CreateOperation("selling", "Sell linen")
            ns.rules:AttachOperation(group, "selling", op)
            assert.is_true(ns.customSources:Set("myprice", "scanmin * 2"))

            mock.frames = {}
            ns = loadAddon()
            login()

            assert.are.equal("Cloth", ns.rules:Name(group))
            assert.are.equal(group, ns.rules:GroupOf("2589"))
            assert.are.equal("Sell linen", ns.rules:GetOperation(op).name)
            assert.are.equal(op, ns.rules:EffectiveOperation(group, "selling"))
            assert.are.equal("scanmin * 2", ns.customSources:Get("myprice"))
        end)
    end)
end)
