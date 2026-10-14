local mock = require("Tests.wow_mock")

local KIT = { "Theme", "Window", "Widgets", "Tabs", "List", "Tree", "Combat" }
local CORE = { "Core/ItemString", "Core/SettingsDB", "Services/ScanClock", "Services/ScanSources",
    "Services/FormulaParse", "Services/FormulaFunctions", "Services/FormulaEval", "Services/FormulaSources",
    "Services/CustomSources", "Services/GroupTree", "Services/OperationSchema", "Services/RulesStore",
    "Services/RulesExport", "Services/ItemNameIndex" }

local function load()
    local ns = {}
    for _, name in ipairs(CORE) do
        assert(loadfile(name .. ".lua"))("Flipside", ns)
    end
    for _, name in ipairs(KIT) do
        assert(loadfile("UI/Kit/" .. name .. ".lua"))("Flipside", ns)
    end
    assert(loadfile("UI/Pages/GroupsPage.lua"))("Flipside", ns)
    return ns
end

-- Client methods that the mock lacks.
local function stubMethods()
    local methods = getmetatable(CreateFrame("Frame")).__index
    methods.SetJustifyH = function() end
    methods.HasFocus = function(self)
        return self.focused
    end
end

local function click(button)
    button.scripts.OnClick(button)
end

-- Choose a menu entry of a drop-down by its text.
local function pick(dropdown, text)
    for _, item in ipairs(dropdown.menuItems) do
        if item.text == text then
            item.pick()
            return
        end
    end
    error("no menu entry " .. text)
end

local function menuTexts(dropdown)
    local texts = {}
    for _, item in ipairs(dropdown.menuItems) do
        texts[#texts + 1] = item.text
    end
    return texts
end

describe("GroupsPage", function()
    local ns, store, page, deps, content, saved, names, requests, bags, index, subscribers, ah, sources

    local function compile(text)
        local tree, err = ns.FormulaParse.Parse(text)
        if not tree then
            return nil, err
        end
        return { tree = tree }
    end

    local function newStore(data)
        saved = data or {}
        local db = ns.SettingsDB.New(saved, { character = "Me", schemaVersion = 1 })
        sources = ns.CustomSources.New(db)
        return ns.RulesStore.New(db, { onWarning = function() end, compile = compile })
    end

    local function build()
        content = CreateFrame("Frame", nil, UIParent)
        page = ns.GroupsPage.Build(content, deps)
    end

    local function treeText(id)
        return page.tree.byId[id].text
    end

    before_each(function()
        mock.reset()
        stubMethods()
        _G.ScrollUtil = nil
        ns = load()
        store = newStore()
        names, requests, subscribers = { ["100"] = "Peacebloom" }, {}, {}
        bags = {}
        index = {
            matches = {},
            pending = 0,
            Find = function(self, text, limit, options)
                self.query, self.limit, self.options = text, limit, options
                local exclude = options and options.exclude or {}
                local found = {}
                for _, match in ipairs(self.matches) do
                    if not exclude[match.key] then
                        found[#found + 1] = match
                    end
                end
                return found, self.pending
            end,
        }
        ah = {
            Find = function(self, name, callback, options)
                self.name, self.options, self.callback = name, options, callback
                if self.closed then
                    callback(nil, "open the Auction House to search it")
                end
            end,
        }
        deps = {
            rules = store,
            itemCache = {
                Get = function(_, id)
                    local name = names[tostring(id)]
                    if name then
                        return { name = name }, "loaded"
                    end
                    return nil, "unknown"
                end,
                Request = function(_, id)
                    requests[#requests + 1] = id
                end,
            },
            itemNameIndex = index,
            ahNameSearch = ah,
            customSources = sources,
            compile = compile,
            readBags = function()
                return bags
            end,
            subscribe = function(fn)
                subscribers[#subscribers + 1] = fn
            end,
        }
    end)

    after_each(function()
        _G.hooksecurefunc, _G.ChatEdit_InsertLink = nil, nil
        mock.teardown()
    end)

    describe("tree", function()
        it("shows Base with the item count", function()
            build()
            assert.are.equal("Base (0)", treeText(1))
            assert.are.equal(1, page.tree.selected)
            assert.are.equal("Base", page.header:GetText())
        end)

        it("counts items of sub-groups in each parent", function()
            local herbs = store:CreateGroup(1, "Herbs")
            local rare = store:CreateGroup(herbs, "Rare")
            store:AddItem("100", herbs)
            store:AddItem("200", rare)
            build()
            assert.are.equal("Base (2)", treeText(1))
            assert.are.equal("Herbs (2)", treeText(herbs))
            assert.are.equal("Rare (1)", treeText(rare))
        end)

        it("shows the path of the selected group", function()
            local herbs = store:CreateGroup(1, "Herbs")
            local rare = store:CreateGroup(herbs, "Rare")
            build()
            page.tree:Select(rare)
            assert.are.equal("Base > Herbs > Rare", page.header:GetText())
        end)

        it("registers a refresh callback", function()
            build()
            assert.are.equal(1, #subscribers)
            store:CreateGroup(1, "Herbs")
            subscribers[1]()
            assert.is_table(page.tree.byId[2])
        end)
    end)

    describe("group buttons", function()
        it("creates a group under the selected one", function()
            local herbs = store:CreateGroup(1, "Herbs")
            build()
            page.tree:Select(herbs)
            page.nameInput:SetText("Rare")
            click(page.newButton)
            assert.are.same({ "Base", "Herbs", "Rare" }, store:Path(3))
            assert.are.equal("Rare (0)", treeText(3))
            assert.are.equal("", page.nameInput:GetText())
            assert.are.equal("", page.status:GetText())
        end)

        it("creates under Base by default", function()
            build()
            page.nameInput:SetText("Herbs")
            click(page.newButton)
            assert.are.same({ "Base", "Herbs" }, store:Path(2))
        end)

        it("shows the store message for a bad name", function()
            local herbs = store:CreateGroup(1, "Herbs")
            build()
            page.nameInput:SetText("herbs")
            click(page.newButton)
            assert.are.equal("a sibling group has this name", page.status:GetText())
            assert.are.equal("Herbs (0)", treeText(herbs))
        end)

        it("renames the selected group", function()
            local herbs = store:CreateGroup(1, "Herbs")
            build()
            page.tree:Select(herbs)
            page.nameInput:SetText("Plants")
            click(page.renameButton)
            assert.are.equal("Plants", store:Name(herbs))
            assert.are.equal("Plants (0)", treeText(herbs))
            assert.are.equal("Base > Plants", page.header:GetText())
        end)

        it("shows the message when a rename fails", function()
            local herbs = store:CreateGroup(1, "Herbs")
            store:CreateGroup(1, "Ore")
            build()
            page.tree:Select(herbs)
            page.nameInput:SetText("Ore")
            click(page.renameButton)
            assert.are.equal("a sibling group has this name", page.status:GetText())
            assert.are.equal("Herbs", store:Name(herbs))
        end)

        it("moves the group with the drop-down", function()
            local herbs = store:CreateGroup(1, "Herbs")
            local rare = store:CreateGroup(herbs, "Rare")
            store:CreateGroup(1, "Ore")
            build()
            page.tree:Select(rare)
            assert.are.same({ "Base", "Base > Ore" }, menuTexts(page.moveDropdown))
            pick(page.moveDropdown, "Base > Ore")
            assert.are.same({ "Base", "Ore", "Rare" }, store:Path(rare))
            assert.are.equal("Base > Ore > Rare", page.header:GetText())
        end)

        it("refuses a move into an own sub-group", function()
            local herbs = store:CreateGroup(1, "Herbs")
            local rare = store:CreateGroup(herbs, "Rare")
            build()
            page.tree:Select(herbs)
            pick(page.moveDropdown, "Base > Herbs > Rare")
            assert.are.equal("a group cannot move into itself or its sub-groups", page.status:GetText())
            assert.are.same({ "Base", "Herbs", "Rare" }, store:Path(rare))
            assert.is_nil(page.moveDropdown:GetValue())
        end)

        it("asks before a delete and moves items to the parent", function()
            local herbs = store:CreateGroup(1, "Herbs")
            local rare = store:CreateGroup(herbs, "Rare")
            store:AddItem("100", herbs)
            store:AddItem("200", rare)
            build()
            page.tree:Select(rare)
            click(page.deleteButton)
            assert.are.equal('Delete group "Rare" and its 0 sub-groups? 1 items move to "Herbs".', mock.popup.text)
            assert.is_true(store:Name(rare) ~= nil)
            mock.acceptPopup()
            assert.is_nil(store:Name(rare))
            assert.are.equal(herbs, store:GroupOf("200"))
            assert.are.equal(herbs, page.selected)
            assert.are.equal("Herbs (2)", treeText(herbs))
        end)

        it("names the sub-groups in the delete text", function()
            local herbs = store:CreateGroup(1, "Herbs")
            store:CreateGroup(herbs, "Rare")
            store:CreateGroup(herbs, "Common")
            build()
            page.tree:Select(herbs)
            click(page.deleteButton)
            assert.is_truthy(mock.popup.text:find("its 2 sub-groups", 1, true))
        end)

        it("keeps the group when the confirm is cancelled", function()
            local herbs = store:CreateGroup(1, "Herbs")
            build()
            page.tree:Select(herbs)
            click(page.deleteButton)
            mock.cancelPopup()
            assert.are.equal("Herbs", store:Name(herbs))
            assert.are.equal(herbs, page.selected)
        end)

        it("protects the Base group", function()
            build()
            assert.is_false(page.renameButton.enabled)
            assert.is_false(page.deleteButton.enabled)
            assert.is_false(page.moveDropdown.enabled)
            assert.is_true(page.newButton.enabled)
            click(page.deleteButton)
            assert.is_nil(mock.popup)
            local herbs = store:CreateGroup(1, "Herbs")
            page.Refresh()
            page.tree:Select(herbs)
            assert.is_true(page.renameButton.enabled)
            assert.is_true(page.deleteButton.enabled)
            assert.is_true(page.moveDropdown.enabled)
        end)
    end)

    describe("operations", function()
        local main, other

        before_each(function()
            main = store:CreateOperation("selling", "Main")
            other = store:CreateOperation("selling", "Other")
            store:CreateOperation("buying", "Cheap")
        end)

        it("lists inherit and the operations of the type", function()
            build()
            assert.are.same({ "(inherit)", "Main", "Other" }, menuTexts(page.opRows.selling.dropdown))
            assert.are.same({ "(inherit)", "Cheap" }, menuTexts(page.opRows.buying.dropdown))
            assert.are.same({ "(inherit)" }, menuTexts(page.opRows.vendoring.dropdown))
            assert.are.equal("Using: none", page.opRows.selling.using:GetText())
        end)

        it("attaches an operation", function()
            local herbs = store:CreateGroup(1, "Herbs")
            build()
            page.tree:Select(herbs)
            pick(page.opRows.selling.dropdown, "Main")
            assert.are.equal(main, store:EffectiveOperation(herbs, "selling"))
            assert.are.equal(main, page.opRows.selling.dropdown:GetValue())
            assert.are.equal("Using: Main from Herbs", page.opRows.selling.using:GetText())
        end)

        it("shows the inherited operation and its group", function()
            local herbs = store:CreateGroup(1, "Herbs")
            store:AttachOperation(1, "selling", other)
            build()
            page.tree:Select(herbs)
            assert.are.equal(0, page.opRows.selling.dropdown:GetValue())
            assert.are.equal("Using: Other from Base", page.opRows.selling.using:GetText())
        end)

        it("detaches with (inherit)", function()
            local herbs = store:CreateGroup(1, "Herbs")
            store:AttachOperation(1, "selling", other)
            store:AttachOperation(herbs, "selling", main)
            build()
            page.tree:Select(herbs)
            assert.are.equal(main, page.opRows.selling.dropdown:GetValue())
            pick(page.opRows.selling.dropdown, "(inherit)")
            assert.are.equal(other, store:EffectiveOperation(herbs, "selling"))
            assert.are.equal(0, page.opRows.selling.dropdown:GetValue())
            assert.are.equal("Using: Other from Base", page.opRows.selling.using:GetText())
        end)
    end)

    describe("items", function()
        it("lists the items of the group with names", function()
            local herbs = store:CreateGroup(1, "Herbs")
            store:AddItem("100", herbs)
            store:AddItem("200", herbs)
            build()
            page.tree:Select(herbs)
            assert.are.same({ "100", "200" }, page.itemList:GetData())
            assert.are.equal("Peacebloom", page.itemList.rows[1].nameText:GetText())
            assert.are.equal("200", page.itemList.rows[2].nameText:GetText())
            assert.is_true(#requests > 0)
        end)

        it("shows no items for Base and disables the add controls", function()
            build()
            assert.are.same({}, page.itemList:GetData())
            assert.is_false(page.bagsButton.enabled)
            assert.is_false(page.addNameButton.enabled)
            assert.is_false(page.addLinkButton.enabled)
        end)

        it("removes an item", function()
            local herbs = store:CreateGroup(1, "Herbs")
            store:AddItem("100", herbs)
            store:AddItem("200", herbs)
            build()
            page.tree:Select(herbs)
            click(page.itemList.rows[1].removeButton)
            assert.are.same({ "200" }, page.itemList:GetData())
            assert.are.equal("Herbs (1)", treeText(herbs))
            assert.are.equal(1, store:GroupOf("100"))
        end)
    end)

    describe("add from bags", function()
        local herbs, ore

        before_each(function()
            herbs = store:CreateGroup(1, "Herbs")
            ore = store:CreateGroup(1, "Ore")
            store:AddItem("300", ore)
            bags = {
                { key = "100", name = "Peacebloom", count = 5 },
                { key = "200", name = "Silverleaf", count = 3 },
                { key = "300", name = "Copper Ore", count = 1 },
            }
            build()
            page.tree:Select(herbs)
        end)

        it("shows the bag items with the group of items that are in a group", function()
            click(page.bagsButton)
            assert.is_true(page.bagPanel:IsShown())
            assert.are.equal(3, #page.bagList:GetData())
            assert.are.equal("Peacebloom x5", page.bagList.rows[1].text:GetText())
            assert.are.equal("Copper Ore x1 (in Ore)", page.bagList.rows[3].text:GetText())
        end)

        it("adds all items with select all", function()
            click(page.bagsButton)
            click(page.selectAllButton)
            assert.is_true(page.bagList.rows[2].check:GetChecked())
            click(page.addSelectedButton)
            assert.are.same({ "100", "200", "300" }, store:ItemsIn(herbs))
            assert.are.same({}, store:ItemsIn(ore))
            assert.are.equal("Added 3 items", page.status:GetText())
            assert.is_false(page.bagPanel:IsShown())
        end)

        it("adds only the checked items", function()
            click(page.bagsButton)
            local row = page.bagList.rows[2]
            row.check:SetChecked(true)
            click(row.check)
            click(page.addSelectedButton)
            assert.are.same({ "200" }, store:ItemsIn(herbs))
            assert.are.equal("Added 1 items", page.status:GetText())
        end)

        it("asks for a selection first", function()
            click(page.bagsButton)
            click(page.addSelectedButton)
            assert.are.equal("Select items first", page.status:GetText())
            assert.are.same({}, store:ItemsIn(herbs))
            assert.is_true(page.bagPanel:IsShown())
        end)

        it("says so when the bags hold no items", function()
            bags = {}
            click(page.bagsButton)
            assert.are.equal("No items found in bags", page.status:GetText())
            assert.is_false(page.bagPanel:IsShown())
        end)
    end)

    describe("inner tabs", function()
        it("shows the Rules tab first and switches to Items", function()
            build()
            assert.is_true(page.rulesPanel:IsShown())
            assert.is_false(page.itemsPanel:IsShown())
            assert.is_false(page.tabButtons.rules.enabled)
            click(page.tabButtons.items)
            assert.is_false(page.rulesPanel:IsShown())
            assert.is_true(page.itemsPanel:IsShown())
            assert.is_false(page.tabButtons.items.enabled)
            assert.is_true(page.tabButtons.rules.enabled)
            click(page.tabButtons.rules)
            assert.is_true(page.rulesPanel:IsShown())
        end)

        it("keeps the tab when another group is selected", function()
            local herbs = store:CreateGroup(1, "Herbs")
            build()
            click(page.tabButtons.items)
            page.tree:Select(herbs)
            assert.are.equal("items", page.tab)
            assert.is_true(page.itemsPanel:IsShown())
        end)
    end)

    describe("add by name", function()
        local herbs
        local PEACE = { itemID = 100, name = "Peacebloom", key = "100", source = "scan" }
        local ORB = { itemID = 101, name = "Peaceful Orb", key = "101", source = "client" }

        local function search(text)
            page.addNameInput:SetText(text)
            page.addNameInput.scripts.OnEnterPressed(page.addNameInput)
        end

        before_each(function()
            herbs = store:CreateGroup(1, "Herbs")
            build()
            page.tree:Select(herbs)
            click(page.tabButtons.items)
        end)

        it("searches on Enter and lists the matches with their source", function()
            index.matches = { PEACE, ORB }
            index.pending = 2
            search("peace")
            assert.are.equal("peace", index.query)
            assert.are.same({ PEACE, ORB }, page.nameList:GetData())
            assert.are.equal("scan data", page.nameList.rows[1].sourceText:GetText())
            assert.are.equal("game cache", page.nameList.rows[2].sourceText:GetText())
            assert.are.equal("Peaceful Orb", page.nameList.rows[2].nameText:GetText())
            assert.is_truthy(page.status:GetText():find("2 items found", 1, true))
            assert.is_truthy(page.status:GetText():find("2 item names are still loading", 1, true))
            assert.are.same({}, store:ItemsIn(herbs))
        end)

        it("searches with the Add button too", function()
            index.matches = { PEACE }
            page.addNameInput:SetText("peace")
            click(page.addNameButton)
            assert.are.same({ PEACE }, page.nameList:GetData())
        end)

        it("hides the items that are in this group", function()
            store:AddItem("100", herbs)
            page.Refresh()
            index.matches = { PEACE, ORB }
            search("peace")
            assert.is_true(index.options.exclude["100"])
            assert.is_nil(index.options.exclude["101"])
            assert.are.same({ ORB }, page.nameList:GetData())
        end)

        it("shows items of another group", function()
            local ore = store:CreateGroup(1, "Ore")
            store:AddItem("100", ore)
            page.Refresh()
            index.matches = { PEACE }
            search("peace")
            assert.are.same({ PEACE }, page.nameList:GetData())
        end)

        it("keeps the list after an add and shows the row as added", function()
            index.matches = { PEACE, ORB }
            search("peace")
            click(page.nameList.rows[1].addButton)
            assert.are.same({ "100" }, store:ItemsIn(herbs))
            assert.are.equal("Added Peacebloom", page.status:GetText())
            assert.are.same({ PEACE, ORB }, page.nameList:GetData())
            assert.are.equal("Added", page.nameList.rows[1].addButton:GetText())
            assert.is_false(page.nameList.rows[1].addButton.enabled)
            assert.are.equal("Add", page.nameList.rows[2].addButton:GetText())
            assert.are.equal("peace", page.addNameInput:GetText())
        end)

        it("moves an item from another group", function()
            local ore = store:CreateGroup(1, "Ore")
            store:AddItem("100", ore)
            page.Refresh()
            index.matches = { PEACE }
            search("peace")
            click(page.nameList.rows[1].addButton)
            assert.are.equal(herbs, store:GroupOf("100"))
            assert.are.equal("Moved Peacebloom from Ore", page.status:GetText())
        end)

        it("passes quoted text on as the exact name", function()
            index.matches = {}
            search('"Peacebloom"')
            assert.are.equal('"Peacebloom"', index.query)
        end)

        it("says so when nothing matches", function()
            search("zzz")
            assert.are.equal('no item named "zzz"', page.status:GetText())
            assert.are.same({}, page.nameList:GetData())
        end)

        it("clears the list when another group is selected", function()
            index.matches = { PEACE }
            search("peace")
            page.tree:Select(1)
            assert.are.same({}, page.nameList:GetData())
        end)

        it("says so when there is no name index", function()
            deps.itemNameIndex = nil
            build()
            page.tree:Select(herbs)
            click(page.addNameButton)
            assert.are.equal("item names are not available", page.status:GetText())
        end)
    end)

    describe("Auction House search", function()
        local herbs
        local PEACE = { itemID = 100, name = "Peacebloom", key = "100", source = "scan" }

        before_each(function()
            herbs = store:CreateGroup(1, "Herbs")
            build()
            page.tree:Select(herbs)
            click(page.tabButtons.items)
        end)

        it("shows the hint under the button", function()
            assert.are.equal("Search the Auction House", page.ahButton:GetText())
            assert.are.equal("This uses the Auction House search; Blizzard's Buy tab will show these results.",
                page.ahHint:GetText())
        end)

        it("does not search without a click", function()
            index.matches = {}
            page.addNameInput:SetText("peace")
            click(page.addNameButton)
            assert.is_nil(ah.name)
        end)

        it("searches on a click and adds the results with the source", function()
            index.matches = { PEACE }
            page.addNameInput:SetText("peace")
            click(page.addNameButton)
            click(page.ahButton)
            assert.are.equal("peace", ah.name)
            assert.is_false(ah.options.exact)
            ah.callback({ { itemID = 100, name = "Peacebloom", key = "100" },
                { itemID = 7, name = "Peace Lily", key = "7" } })
            local data = page.nameList:GetData()
            assert.are.equal(2, #data)
            assert.are.equal("Peace Lily", data[1].name)
            assert.are.equal("ah", data[1].source)
            assert.are.equal("scan", data[2].source)
            assert.are.equal("Auction House", page.nameList.rows[1].sourceText:GetText())
            assert.are.equal("1 items found in the Auction House", page.status:GetText())
        end)

        it("leaves out items that are in the group", function()
            store:AddItem("7", herbs)
            page.Refresh()
            page.addNameInput:SetText("peace")
            click(page.ahButton)
            ah.callback({ { itemID = 7, name = "Peace Lily", key = "7" } })
            assert.are.same({}, page.nameList:GetData())
        end)

        it("uses the exact name for quoted text", function()
            page.addNameInput:SetText('"Peacebloom"')
            click(page.ahButton)
            assert.are.equal("Peacebloom", ah.name)
            assert.is_true(ah.options.exact)
        end)

        it("shows the message when the Auction House is closed", function()
            ah.closed = true
            page.addNameInput:SetText("peace")
            click(page.ahButton)
            assert.are.equal("open the Auction House to search it", page.status:GetText())
        end)

        it("asks for a name first", function()
            click(page.ahButton)
            assert.is_nil(ah.name)
            assert.are.equal("type a name first", page.status:GetText())
        end)

        it("hides the button without the service", function()
            deps.ahNameSearch = nil
            build()
            assert.is_false(page.ahButton:IsShown())
            assert.is_false(page.ahHint:IsShown())
        end)
    end)

    describe("drag and drop", function()
        local herbs, rare, ore

        local function rowOf(id)
            for _, row in ipairs(page.tree.list.rows) do
                if row:IsShown() and row.kitId == id then
                    return row
                end
            end
        end

        -- Drag a row and release it over a row, or over the empty tree when targetID is nil.
        local function dragTo(id, targetID)
            local row, target = rowOf(id), rowOf(targetID)
            row:GetScript("OnDragStart")(row)
            for _, other in ipairs(page.tree.list.rows) do
                other.mouseOver = other == target
            end
            page.tree.frame.mouseOver = true
            row:GetScript("OnDragStop")(row)
        end

        before_each(function()
            herbs = store:CreateGroup(1, "Herbs")
            rare = store:CreateGroup(herbs, "Rare")
            ore = store:CreateGroup(1, "Ore")
            build()
        end)

        it("moves a group onto another group", function()
            dragTo(rare, ore)
            assert.are.same({ "Base", "Ore", "Rare" }, store:Path(rare))
            assert.are.equal("", page.status:GetText())
            assert.is_table(page.tree.byId[rare])
        end)

        it("moves a group to Base on the empty tree area", function()
            dragTo(rare, nil)
            assert.are.same({ "Base", "Rare" }, store:Path(rare))
        end)

        it("does not drag Base", function()
            local row = rowOf(1)
            row:GetScript("OnDragStart")(row)
            assert.is_nil(page.tree.dragging)
            assert.is_false(page.tree.options.canDrag(1))
            assert.is_true(page.tree.options.canDrag(herbs))
        end)

        it("does not drag in a read-only store", function()
            store = newStore({ _schema = 999 })
            deps.rules = store
            build()
            assert.is_false(page.tree.options.canDrag(2))
        end)

        it("shows the store message for a cycle", function()
            dragTo(herbs, rare)
            assert.are.equal("a group cannot move into itself or its sub-groups", page.status:GetText())
            assert.are.same({ "Base", "Herbs", "Rare" }, store:Path(rare))
        end)

        it("shows the store message for a duplicate name", function()
            local other = store:CreateGroup(ore, "Rare")
            page.Refresh()
            dragTo(rare, ore)
            assert.are.equal("a sibling group has this name", page.status:GetText())
            assert.are.same({ "Base", "Herbs", "Rare" }, store:Path(rare))
            assert.is_true(other ~= nil)
        end)
    end)

    describe("export and import", function()
        local herbs, other

        -- Export text of a group "Flowers" with one item, made in a second profile.
        local function flowersText()
            local db = ns.SettingsDB.New({}, { character = "Other", schemaVersion = 1 })
            other = ns.RulesStore.New(db, { onWarning = function() end, compile = compile })
            local id = other:CreateGroup(1, "Flowers")
            other:AddItem("500", id)
            return ns.RulesExport.Export(other, ns.CustomSources.New(db), id)
        end

        before_each(function()
            herbs = store:CreateGroup(1, "Herbs")
            store:AddItem("100", herbs)
            build()
            page.tree:Select(herbs)
        end)

        it("opens a read-only dialog with the export text", function()
            click(page.exportButton)
            local dialog = page.exportDialog
            assert.is_true(dialog:IsShown())
            assert.is_nil(dialog.saveButton)
            assert.are.equal(ns.RulesExport.Export(store, sources, herbs), dialog.input:GetText())
            assert.is_truthy(dialog.input:GetText():find("FLIPSIDE-RULES", 1, true))
            assert.is_truthy(dialog.input:GetText():find("Herbs", 1, true))
        end)

        it("exports Base too", function()
            page.tree:Select(1)
            assert.is_true(page.exportButton.enabled)
            click(page.exportButton)
            assert.is_true(page.exportDialog:IsShown())
        end)

        it("shows a parse error with the line number and changes nothing", function()
            click(page.importButton)
            page.importDialog.input.EditBox:SetText("FLIPSIDE-RULES 1\nbogus|x")
            click(page.importDialog.saveButton)
            assert.is_truthy(page.status:GetText():find("Line 2", 1, true))
            assert.is_nil(mock.popup)
            assert.are.equal(1, #store:Children(1))
        end)

        it("shows the preview in plain words and the parent group", function()
            local text = flowersText()
            click(page.importButton)
            page.importDialog.input.EditBox:SetText(text)
            click(page.importDialog.saveButton)
            local popup = mock.popup.text
            assert.is_truthy(popup:find('Import below "Herbs"', 1, true))
            assert.is_truthy(popup:find("Groups: 1", 1, true))
            assert.is_truthy(popup:find("Items: 1 (0 move from other groups)", 1, true))
            assert.is_truthy(popup:find("Operations: 0 new, 0 reused", 1, true))
            assert.is_truthy(popup:find("Custom sources: 0 new, 0 reused", 1, true))
            assert.are.equal(0, #store:Children(herbs))
        end)

        it("names the renames and the moved items", function()
            store:CreateGroup(herbs, "Flowers")
            store:AddItem("500", herbs)
            page.Refresh()
            click(page.importButton)
            page.importDialog.input.EditBox:SetText(flowersText())
            click(page.importDialog.saveButton)
            local popup = mock.popup.text
            assert.is_truthy(popup:find('group "Flowers" becomes "Flowers (2)"', 1, true))
            assert.is_truthy(popup:find("(1 move from other groups)", 1, true))
        end)

        it("applies the import on accept and shows the new group", function()
            local text = flowersText()
            click(page.importButton)
            page.importDialog.input.EditBox:SetText(text)
            click(page.importDialog.saveButton)
            mock.acceptPopup()
            local flowers = store:Children(herbs)[1]
            assert.are.equal("Flowers", store:Name(flowers))
            assert.are.same({ "500" }, store:ItemsIn(flowers))
            assert.are.equal(flowers, page.selected)
            assert.are.equal("Flowers (1)", treeText(flowers))
            assert.are.equal("Imported 1 groups and 1 items", page.status:GetText())
        end)

        it("changes nothing on cancel", function()
            local text = flowersText()
            click(page.importButton)
            page.importDialog.input.EditBox:SetText(text)
            click(page.importDialog.saveButton)
            mock.cancelPopup()
            assert.are.equal(0, #store:Children(herbs))
            assert.are.equal(herbs, page.selected)
        end)

        it("shows the error when the apply stops", function()
            local text = flowersText()
            click(page.importButton)
            page.importDialog.input.EditBox:SetText(text)
            click(page.importDialog.saveButton)
            deps.rules.CreateGroup = function()
                return nil, "boom"
            end
            mock.acceptPopup()
            assert.is_truthy(page.status:GetText():find("Import stopped at step 'group Flowers': boom", 1, true))
        end)

        it("disables import in a read-only store", function()
            store = newStore({ _schema = 999 })
            deps.rules = store
            build()
            assert.is_false(page.importButton.enabled)
            assert.is_true(page.exportButton.enabled)
        end)

        it("disables both buttons without custom sources", function()
            deps.customSources = nil
            build()
            assert.is_false(page.exportButton.enabled)
            assert.is_false(page.importButton.enabled)
        end)
    end)
    describe("add by link", function()
        local herbs
        local LINK = "|cff1eff00|Hitem:100:0:0:0:0:0:0:0:0:0:0:0:2:5:3|h[Peacebloom]|h|r"

        before_each(function()
            herbs = store:CreateGroup(1, "Herbs")
        end)

        it("adds the exact key of a link", function()
            build()
            page.tree:Select(herbs)
            page.linkInput:SetText(LINK)
            click(page.addLinkButton)
            assert.are.same({ "100#b3,5" }, store:ItemsIn(herbs))
            assert.are.equal("", page.linkInput:GetText())
        end)

        it("uses keyFor when it is provided", function()
            deps.keyFor = function(link)
                assert.are.equal(LINK, link)
                return "100"
            end
            build()
            page.tree:Select(herbs)
            page.linkInput:SetText(LINK)
            click(page.addLinkButton)
            assert.are.same({ "100" }, store:ItemsIn(herbs))
        end)

        it("refuses text that is not an item", function()
            build()
            page.tree:Select(herbs)
            page.linkInput:SetText("hello")
            click(page.addLinkButton)
            assert.are.equal("not an item link", page.status:GetText())
        end)

        it("inserts a shift-clicked link while the box has focus", function()
            local hooked
            _G.ChatEdit_InsertLink = function() end
            _G.hooksecurefunc = function(name, fn)
                if name == "ChatEdit_InsertLink" then
                    hooked = fn
                end
            end
            build()
            hooked(LINK)
            assert.is_nil(page.linkInput:GetText())
            page.linkInput.focused = true
            hooked(LINK)
            assert.are.equal(LINK, page.linkInput:GetText())
        end)
    end)

    describe("read-only store", function()
        before_each(function()
            store = newStore({ _schema = 999 })
            deps.rules = store
            build()
        end)

        it("disables the controls and shows one line", function()
            assert.is_true(store:IsReadOnly())
            assert.is_true(page.readOnlyLabel:IsShown())
            assert.are.equal("Settings are read-only", page.readOnlyLabel:GetText())
            for _, control in ipairs({ page.newButton, page.renameButton, page.deleteButton, page.moveDropdown,
                page.nameInput, page.bagsButton, page.addNameButton, page.addNameInput, page.linkInput,
                page.addLinkButton, page.opRows.selling.dropdown }) do
                assert.is_false(control.enabled)
            end
        end)

        it("shows the store message when a change is tried", function()
            page.nameInput:SetText("Herbs")
            click(page.newButton)
            assert.are.equal("settings are read-only", page.status:GetText())
        end)

        it("hides the line for a writable store", function()
            store = newStore()
            deps.rules = store
            build()
            assert.is_false(page.readOnlyLabel:IsShown())
        end)
    end)
end)
