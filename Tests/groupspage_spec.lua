local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local KIT = { "Theme", "Window", "Widgets", "Tabs", "List", "Tree", "Combat" }
local CORE = { "ItemString", "SettingsDB", "ScanClock", "ScanSources",
    "FormulaParse", "FormulaFunctions", "FormulaEval", "FormulaSources",
    "CustomSources", "GroupTree", "OperationSchema", "RulesStore",
    "RulesExport", "ItemNameIndex" }

local function load()
    local ns = {}
    for _, name in ipairs(CORE) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    for _, name in ipairs(KIT) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    assert(loadfile(manifest.path("GroupsPage")))("Flipside", ns)
    return ns
end

-- Client methods that the mock lacks.
local function stubMethods()
    local methods = getmetatable(CreateFrame("Frame")).__index
    methods.SetJustifyH = function() end
    methods.HasFocus = function(self)
        return self.focused
    end
    methods.SetTextColor = function(self, r, g, b, a)
        self.color = { r, g, b, a }
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

-- Open the right-click menu of a tree row and run the entry with this text.
local function menuClick(text)
    for _, item in ipairs(mock.menu.items) do
        if item.text == text then
            item.onClick()
            return
        end
    end
    error("no menu entry " .. text)
end

local function menuItem(text)
    for _, item in ipairs(mock.menu.items) do
        if item.text == text then
            return item
        end
    end
end

local function menuTexts(dropdown)
    local texts = {}
    for _, item in ipairs(dropdown.menuItems) do
        texts[#texts + 1] = item.text
    end
    return texts
end

describe("GroupsPage", function()
    local ns, store, page, deps, content, saved, names, requests, bags, index, subscribers, ah, sources, quality

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
        names, requests, subscribers, quality = { ["100"] = "Peacebloom" }, {}, {}, nil
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
                        return { name = name, quality = quality }, "loaded"
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
        it("shows the no-group node for the hidden Base group, selected at the start", function()
            build()
            assert.are.equal("[No group]", treeText(1))
            assert.are.equal(1, page.tree.selected)
            assert.are.equal("[No group]", page.header:GetText())
            assert.are.equal(1, #page.tree.roots)
        end)

        it("shows the top-level groups as roots, many of them, before the no-group node", function()
            local herbs = store:CreateGroup(1, "Herbs")
            local ore = store:CreateGroup(1, "Ore")
            local cloth = store:CreateGroup(1, "Cloth")
            local rare = store:CreateGroup(herbs, "Rare")
            build()
            local ids = {}
            for _, node in ipairs(page.tree.roots) do
                ids[#ids + 1] = node.id
            end
            -- The store sorts sibling groups by name.
            assert.are.same({ cloth, herbs, ore, 1 }, ids)
            assert.are.equal(rare, page.tree.roots[2].children[1].id)
        end)

        it("counts items of sub-groups in each parent", function()
            local herbs = store:CreateGroup(1, "Herbs")
            local rare = store:CreateGroup(herbs, "Rare")
            store:AddItem("100", herbs)
            store:AddItem("200", rare)
            build()
            assert.are.equal("Herbs (2)", treeText(herbs))
            assert.are.equal("Rare (1)", treeText(rare))
        end)

        it("shows the path of the selected group", function()
            local herbs = store:CreateGroup(1, "Herbs")
            local rare = store:CreateGroup(herbs, "Rare")
            build()
            page.tree:Select(rare)
            assert.are.equal("Herbs > Rare", page.header:GetText())
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

        it("creates a root group when the no-group node is selected", function()
            build()
            page.nameInput:SetText("Herbs")
            click(page.newButton)
            assert.are.same({ "Base", "Herbs" }, store:Path(2))
            page.nameInput:SetText("Ore")
            click(page.newButton)
            assert.are.same({ "Base", "Ore" }, store:Path(3))
            assert.are.equal(3, #page.tree.roots)
        end)

        it("makes a root group with New root, whatever group is selected", function()
            local herbs = store:CreateGroup(1, "Herbs")
            build()
            page.tree:Select(herbs)
            page.nameInput:SetText("Ore")
            click(page.newRootButton)
            assert.are.same({ "Base", "Ore" }, store:Path(3))
            assert.are.equal("", page.nameInput:GetText())
            page.nameInput:SetText("Cloth")
            click(page.newRootButton)
            assert.are.same({ "Base", "Cloth" }, store:Path(4))
            assert.are.same({ 4, herbs, 3, 1 }, { page.tree.roots[1].id, page.tree.roots[2].id, page.tree.roots[3].id,
                page.tree.roots[4].id })
        end)

        it("moves a group to the top level when it is dropped on the empty tree", function()
            local herbs = store:CreateGroup(1, "Herbs")
            local rare = store:CreateGroup(herbs, "Rare")
            build()
            page.tree.options.onDrop(rare, nil)
            assert.are.same({ "Base", "Rare" }, store:Path(rare))
        end)

        it("turns the New root button off when the settings are read-only", function()
            build()
            assert.is_true(page.newRootButton.enabled)
        end)

        it("shows the store message for a bad name", function()
            local herbs = store:CreateGroup(1, "Herbs")
            build()
            page.nameInput:SetText("herbs")
            click(page.newButton)
            assert.are.equal("a sibling group has this name", page.status:GetText())
            assert.are.equal("Herbs (0)", treeText(herbs))
        end)

        it("has no Move drop-down and no Rename, Delete or Export button", function()
            build()
            assert.is_nil(page.moveDropdown)
            assert.is_nil(page.renameButton)
            assert.is_nil(page.deleteButton)
            assert.is_nil(page.exportButton)
        end)

        it("shows the placeholder texts", function()
            build()
            assert.are.equal("<group name>", page.nameInput.placeholder:GetText())
            assert.are.equal("Item name, link or id", page.addInput.placeholder:GetText())
        end)

        it("puts New root next to New group and Import next to New root", function()
            build()
            local root = page.newRootButton.points[1]
            assert.are.same({ "LEFT", page.newButton, "RIGHT" }, { root[1], root[2], root[3] })
            local point = page.importButton.points[1]
            assert.are.same({ "LEFT", page.newRootButton, "RIGHT" }, { point[1], point[2], point[3] })
        end)
    end)

    describe("context menu", function()
        local function rightClick(id)
            page.tree.options.onRightClick(id, { rowFor = id })
        end

        it("opens on a right click, selects the row and lists the entries", function()
            local herbs = store:CreateGroup(1, "Herbs")
            build()
            rightClick(herbs)
            assert.are.equal(herbs, page.selected)
            assert.are.equal("Herbs", mock.menu.title)
            assert.are.equal("Rename", mock.menu.items[1].text)
            assert.are.equal("Delete", mock.menu.items[2].text)
            assert.are.equal("Export", mock.menu.items[3].text)
            assert.is_true(menuItem("Rename").enabled)
            assert.is_true(menuItem("Delete").enabled)
        end)

        it("opens from a right click on a tree row", function()
            local herbs = store:CreateGroup(1, "Herbs")
            build()
            local row
            for _, candidate in ipairs(page.tree.list.rows) do
                if candidate.kitId == herbs then
                    row = candidate
                end
            end
            row.scripts.OnClick(row, "RightButton")
            assert.are.equal(row, mock.menu.owner)
            assert.are.equal(herbs, page.selected)
        end)

        it("disables Rename and Delete for Base", function()
            build()
            rightClick(1)
            assert.is_false(menuItem("Rename").enabled)
            assert.is_false(menuItem("Delete").enabled)
            assert.is_true(menuItem("Export").enabled)
        end)

        it("disables Rename and Delete in a read-only store", function()
            local herbs = store:CreateGroup(1, "Herbs")
            store = newStore({ _schema = 999 })
            deps.rules = store
            build()
            rightClick(1)
            assert.is_false(menuItem("Rename").enabled)
            assert.is_false(menuItem("Delete").enabled)
            assert.is_true(herbs ~= nil)
        end)

        it("disables Export without custom sources", function()
            deps.customSources = nil
            build()
            rightClick(1)
            assert.is_false(menuItem("Export").enabled)
        end)

        it("renames with the text of the name box", function()
            local herbs = store:CreateGroup(1, "Herbs")
            build()
            page.nameInput:SetText("Plants")
            rightClick(herbs)
            menuClick("Rename")
            assert.are.equal("Plants", store:Name(herbs))
            assert.are.equal("Plants (0)", treeText(herbs))
            assert.are.equal("Plants", page.header:GetText())
            assert.are.equal("", page.nameInput:GetText())
        end)

        it("asks for a name when the name box is empty", function()
            local herbs = store:CreateGroup(1, "Herbs")
            build()
            rightClick(herbs)
            menuClick("Rename")
            assert.are.equal("Herbs", store:Name(herbs))
            assert.is_truthy(page.status:GetText():find("type the new name", 1, true))
        end)

        it("shows the message when a rename fails", function()
            local herbs = store:CreateGroup(1, "Herbs")
            store:CreateGroup(1, "Ore")
            build()
            page.nameInput:SetText("Ore")
            rightClick(herbs)
            menuClick("Rename")
            assert.are.equal("a sibling group has this name", page.status:GetText())
            assert.are.equal("Herbs", store:Name(herbs))
        end)

        it("opens the export dialog", function()
            local herbs = store:CreateGroup(1, "Herbs")
            build()
            rightClick(herbs)
            menuClick("Export")
            assert.is_true(page.exportDialog:IsShown())
            assert.are.equal(ns.RulesExport.Export(store, sources, herbs), page.exportDialog.input:GetText())
        end)

        it("asks before a delete and moves items to the parent", function()
            local herbs = store:CreateGroup(1, "Herbs")
            local rare = store:CreateGroup(herbs, "Rare")
            store:AddItem("100", herbs)
            store:AddItem("200", rare)
            build()
            rightClick(rare)
            menuClick("Delete")
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
            rightClick(herbs)
            menuClick("Delete")
            assert.is_truthy(mock.popup.text:find("its 2 sub-groups", 1, true))
        end)

        it("keeps the group when the confirm is cancelled", function()
            local herbs = store:CreateGroup(1, "Herbs")
            build()
            rightClick(herbs)
            menuClick("Delete")
            mock.cancelPopup()
            assert.are.equal("Herbs", store:Name(herbs))
            assert.are.equal(herbs, page.selected)
        end)

        it("does not delete Base even when the entry runs", function()
            build()
            rightClick(1)
            menuClick("Delete")
            assert.is_nil(mock.popup)
            assert.is_true(page.newButton.enabled)
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
            assert.is_false(page.addSelectedButton.enabled)
            assert.is_false(page.addButton.enabled)
            assert.is_false(page.addInput.enabled)
        end)

        it("shows the item name in its rarity colour and white while loading", function()
            local herbs = store:CreateGroup(1, "Herbs")
            store:AddItem("100", herbs)
            store:AddItem("200", herbs)
            quality = 4
            build()
            page.tree:Select(herbs)
            assert.are.same({ 0.64, 0.21, 0.93 }, { page.itemList.rows[1].nameText.color[1],
                page.itemList.rows[1].nameText.color[2], page.itemList.rows[1].nameText.color[3] })
            assert.are.same({ 1, 1, 1 }, { page.itemList.rows[2].nameText.color[1],
                page.itemList.rows[2].nameText.color[2], page.itemList.rows[2].nameText.color[3] })
            assert.is_nil(page.itemList.rows[1].nameText.color[4])
        end)
    end)

    describe("split pane", function()
        local herbs, ore

        local function bagKeys()
            local keys = {}
            for _, entry in ipairs(page.bagList:GetData()) do
                keys[#keys + 1] = entry.key
            end
            return keys
        end

        before_each(function()
            _G.IsShiftKeyDown = function()
                return false
            end
            herbs = store:CreateGroup(1, "Herbs")
            ore = store:CreateGroup(1, "Ore")
            store:AddItem("300", ore)
            store:AddItem("400", herbs)
            bags = {
                { key = "100", name = "Peacebloom", count = 5 },
                { key = "200", name = "Silverleaf", count = 3 },
                { key = "300", name = "Copper Ore", count = 1 },
                { key = "400", name = "Tin Ore", count = 2 },
            }
            build()
            page.tree:Select(herbs)
        end)

        after_each(function()
            _G.IsShiftKeyDown = nil
        end)

        it("shows the bags on the left and hides the items that are already in the group", function()
            assert.are.same({ "100", "200", "300" }, bagKeys())
            assert.are.same({ "400" }, page.itemList:GetData())
            assert.are.equal("Peacebloom x5", page.bagList.rows[1].text:GetText())
            assert.are.equal("Copper Ore x1 (in Ore)", page.bagList.rows[3].text:GetText())
        end)

        it("adds the selected bag items with the right arrow and updates both lists", function()
            click(page.bagList.rows[1])
            click(page.bagList.rows[3])
            assert.is_true(page.bagList:IsSelected(bags[1]))
            click(page.addSelectedButton)
            assert.are.same({ "100", "300", "400" }, store:ItemsIn(herbs))
            assert.are.same({}, store:ItemsIn(ore))
            assert.are.same({ "100", "300", "400" }, page.itemList:GetData())
            assert.are.same({ "200" }, bagKeys())
            assert.are.equal("Added 2 items", page.status:GetText())
        end)

        it("clears both selections after a move", function()
            click(page.bagList.rows[1])
            click(page.itemList.rows[1])
            click(page.addSelectedButton)
            assert.are.same({}, page.bagList:GetSelected())
            assert.are.same({}, page.itemList:GetSelected())
            assert.is_false(page.bagList.rows[1].kitSelect:IsShown())
        end)

        it("removes the selected group items with the left arrow and updates both lists", function()
            store:AddItem("100", herbs)
            page.Refresh()
            click(page.itemList.rows[1])
            click(page.itemList.rows[2])
            click(page.removeSelectedButton)
            assert.are.same({}, store:ItemsIn(herbs))
            assert.are.same({}, page.itemList:GetData())
            assert.are.same({ "100", "200", "300", "400" }, bagKeys())
            assert.are.equal("Removed 2 items", page.status:GetText())
            assert.are.same({}, page.itemList:GetSelected())
        end)

        it("selects a range with Shift-click from the last clicked row", function()
            click(page.bagList.rows[1])
            _G.IsShiftKeyDown = function()
                return true
            end
            click(page.bagList.rows[3])
            click(page.addSelectedButton)
            assert.are.same({ "100", "200", "300", "400" }, store:ItemsIn(herbs))
        end)

        it("asks for a selection first", function()
            click(page.addSelectedButton)
            assert.are.equal("Select bag items first", page.status:GetText())
            click(page.removeSelectedButton)
            assert.are.equal("Select group items first", page.status:GetText())
            assert.are.same({ "400" }, store:ItemsIn(herbs))
        end)

        it("shows all bag items for Base and disables the arrows", function()
            page.tree:Select(1)
            assert.are.equal(4, #page.bagList:GetData())
            assert.is_false(page.addSelectedButton.enabled)
            assert.is_false(page.removeSelectedButton.enabled)
        end)

        it("shows no rows when the bags hold no items", function()
            bags = {}
            page.Refresh()
            assert.are.same({}, page.bagList:GetData())
        end)
    end)

    describe("top tabs", function()
        it("shows the Items tab first and by default, then Rules", function()
            build()
            assert.are.equal("Items", page.topTabs.buttons[1]:GetText())
            assert.are.equal("Rules", page.topTabs.buttons[2]:GetText())
            assert.are.equal("items", page.tab)
            assert.is_true(page.itemsPanel:IsShown())
            assert.is_false(page.rulesPanel:IsShown())
            click(page.topTabs.buttons[2])
            assert.is_false(page.itemsPanel:IsShown())
            assert.is_true(page.rulesPanel:IsShown())
            assert.are.equal("rules", page.tab)
            click(page.topTabs.buttons[1])
            assert.is_true(page.itemsPanel:IsShown())
            assert.are.equal("items", page.tab)
        end)
        it("keeps the tab when another group is selected", function()
            local herbs = store:CreateGroup(1, "Herbs")
            build()
            page.SelectTab("items")
            page.tree:Select(herbs)
            assert.are.equal("items", page.tab)
            assert.is_true(page.itemsPanel:IsShown())
        end)
    end)

    describe("list backgrounds", function()
        it("gives every list the inset background", function()
            build()
            assert.are.equal("InsetFrameTemplate", page.tree.frame.template)
            assert.are.equal("InsetFrameTemplate", page.itemList.frame.template)
            assert.are.equal("InsetFrameTemplate", page.rulesInset.template)
            assert.are.equal("InsetFrameTemplate", page.bagList.frame.template)
            assert.are.equal("InsetFrameTemplate", page.nameList.frame.template)
        end)
    end)

    describe("items layout", function()
        it("anchors the panes to the items panel, with the add box above the right pane", function()
            build()
            local box = page.addInput.points[1]
            local left, right = page.bagList.frame.points, page.itemList.frame.points
            assert.are.equal(page.middle, box[2])
            assert.are.equal("TOPRIGHT", box[3])
            assert.are.equal(page.itemsPanel, left[1][2])
            assert.are.equal(page.middle, left[2][2])
            assert.are.equal(page.middle, right[1][2])
            assert.are.equal("BOTTOMRIGHT", right[2][1])
            assert.are.equal(page.itemsPanel, right[2][2])
            assert.is_true(box[5] > right[1][5])
            assert.are.equal(page.addInput, page.addButton.points[1][2])
        end)

        it("anchors the right area to the page frame, with no fixed size", function()
            build()
            local points = page.itemsPanel:GetParent().points
            assert.are.equal("BOTTOMRIGHT", points[2][1])
            assert.are.equal(content, points[2][2])
        end)
    end)
    describe("add box", function()
        local herbs
        local LINK = "|cff1eff00|Hitem:100:0:0:0:0:0:0:0:0:0:0:0:2:5:3|h[Peacebloom]|h|r"
        local PEACE = { itemID = 100, name = "Peacebloom", key = "100", source = "scan" }
        local ORB = { itemID = 101, name = "Peaceful Orb", key = "101", source = "client" }

        local function submit(text)
            page.addInput:SetText(text)
            page.addInput.scripts.OnEnterPressed(page.addInput)
        end

        before_each(function()
            herbs = store:CreateGroup(1, "Herbs")
            build()
            page.tree:Select(herbs)
            page.SelectTab("items")
        end)

        it("adds the exact key of an item link at once", function()
            submit(LINK)
            assert.are.same({ "100#b3,5" }, store:ItemsIn(herbs))
            assert.are.equal("", page.addInput:GetText())
            assert.is_false(page.popup:IsShown())
        end)

        it("uses keyFor for a link when it is provided", function()
            deps.keyFor = function(link)
                assert.are.equal(LINK, link)
                return "100"
            end
            build()
            page.tree:Select(herbs)
            submit(LINK)
            assert.are.same({ "100" }, store:ItemsIn(herbs))
        end)

        it("adds the base key of an item id at once", function()
            submit(" 100 ")
            assert.are.same({ "100" }, store:ItemsIn(herbs))
            assert.are.equal("", page.addInput:GetText())
            assert.are.equal("Added Peacebloom", page.status:GetText())
        end)

        it("adds a quoted name with one match at once", function()
            index.matches = { PEACE }
            submit('"Peacebloom"')
            assert.are.equal('"Peacebloom"', index.query)
            assert.are.same({ "100" }, store:ItemsIn(herbs))
            assert.are.equal("", page.addInput:GetText())
            assert.is_false(page.popup:IsShown())
        end)

        it("shows a message for a quoted name with no match", function()
            submit('"Nothing"')
            assert.are.equal('no item named "Nothing"', page.status:GetText())
            assert.is_false(page.popup:IsShown())
            assert.are.same({}, store:ItemsIn(herbs))
        end)

        it("opens the popup for a quoted name with several matches", function()
            index.matches = { PEACE, ORB }
            submit('"Peace"')
            assert.is_true(page.popup:IsShown())
            assert.are.same({ PEACE, ORB }, page.nameList:GetData())
            assert.are.same({}, store:ItemsIn(herbs))
        end)

        it("opens the popup for plain text with the query as title", function()
            index.matches = { PEACE, ORB }
            index.pending = 2
            submit("peace")
            assert.is_true(page.popup:IsShown())
            assert.are.equal("peace", page.popup.title)
            assert.are.equal("peace", index.query)
            assert.are.same({ PEACE, ORB }, page.nameList:GetData())
            assert.are.equal("scan data", page.nameList.rows[1].sourceText:GetText())
            assert.are.equal("game cache", page.nameList.rows[2].sourceText:GetText())
            assert.are.equal("Peaceful Orb", page.nameList.rows[2].nameText:GetText())
            assert.is_truthy(page.status:GetText():find("2 items found", 1, true))
            assert.is_truthy(page.status:GetText():find("2 item names are still loading", 1, true))
            assert.are.same({}, store:ItemsIn(herbs))
        end)

        it("opens the popup with the Add button too", function()
            index.matches = { PEACE }
            page.addInput:SetText("peace")
            click(page.addButton)
            assert.is_true(page.popup:IsShown())
        end)

        it("opens the popup with no match and says so", function()
            submit("zzz")
            assert.is_true(page.popup:IsShown())
            assert.are.equal('no item named "zzz"', page.status:GetText())
            assert.are.same({}, page.nameList:GetData())
        end)

        it("says so when the box is empty", function()
            submit("  ")
            assert.is_false(page.popup:IsShown())
            assert.are.equal("type an item name, link or id", page.status:GetText())
        end)

        it("says so when there is no name index", function()
            deps.itemNameIndex = nil
            build()
            page.tree:Select(herbs)
            submit("peace")
            assert.are.equal("item names are not available", page.status:GetText())
        end)

        it("adds nothing for Base", function()
            page.tree:Select(1)
            submit("100")
            assert.are.equal("select a group first", page.status:GetText())
            assert.are.same({}, store:ItemsIn(1))
        end)

        it("inserts a shift-clicked link while the box has focus and adds it", function()
            local hooked
            _G.ChatEdit_InsertLink = function() end
            _G.hooksecurefunc = function(name, fn)
                if name == "ChatEdit_InsertLink" then
                    hooked = fn
                end
            end
            build()
            page.tree:Select(herbs)
            hooked(LINK)
            assert.is_nil(page.addInput:GetText())
            assert.are.same({}, store:ItemsIn(herbs))
            page.addInput.focused = true
            hooked(LINK)
            assert.are.same({ "100#b3,5" }, store:ItemsIn(herbs))
        end)
    end)

    describe("results popup", function()
        local herbs
        local PEACE = { itemID = 100, name = "Peacebloom", key = "100", source = "scan" }
        local ORB = { itemID = 101, name = "Peaceful Orb", key = "101", source = "client" }

        local function search(text)
            page.addInput:SetText(text)
            page.addInput.scripts.OnEnterPressed(page.addInput)
        end

        before_each(function()
            herbs = store:CreateGroup(1, "Herbs")
            build()
            page.tree:Select(herbs)
            page.SelectTab("items")
        end)

        it("is a window above the Flipside window that Escape closes", function()
            assert.are.equal("DIALOG", page.popup.strata)
            assert.is_true(page.popup.toplevel)
            assert.is_false(page.popup:IsShown())
            local found
            for _, name in ipairs(UISpecialFrames) do
                found = found or name == "FlipsideAddItemsWindow"
            end
            assert.is_true(found)
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

        it("adds an item, stays open and shows the row as added", function()
            index.matches = { PEACE, ORB }
            search("peace")
            click(page.nameList.rows[1].addButton)
            assert.are.same({ "100" }, store:ItemsIn(herbs))
            assert.are.equal("Added Peacebloom", page.status:GetText())
            assert.are.equal("Added Peacebloom", page.popup.status:GetText())
            assert.is_true(page.popup:IsShown())
            assert.are.same({ PEACE, ORB }, page.nameList:GetData())
            assert.are.equal("Added", page.nameList.rows[1].addButton:GetText())
            assert.is_false(page.nameList.rows[1].addButton.enabled)
            assert.are.equal("Add", page.nameList.rows[2].addButton:GetText())
            assert.are.equal("peace", page.addInput:GetText())
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

        it("shows the item name in its rarity colour", function()
            quality = 4
            index.matches = { PEACE, ORB }
            search("peace")
            assert.are.equal(0.64, page.nameList.rows[1].nameText.color[1])
            assert.are.equal(1, page.nameList.rows[2].nameText.color[1])
        end)

        it("closes with the Close button", function()
            search("peace")
            assert.are.equal("Close", page.popupClose:GetText())
            click(page.popupClose)
            assert.is_false(page.popup:IsShown())
        end)

        it("keeps the list until the next search and clears it for another group", function()
            index.matches = { PEACE }
            search("peace")
            page.Refresh()
            assert.are.same({ PEACE }, page.nameList:GetData())
            page.tree:Select(1)
            assert.are.same({}, page.nameList:GetData())
            assert.is_false(page.popup:IsShown())
        end)
    end)

    describe("Auction House search", function()
        local herbs
        local PEACE = { itemID = 100, name = "Peacebloom", key = "100", source = "scan" }

        local function search(text)
            page.addInput:SetText(text)
            page.addInput.scripts.OnEnterPressed(page.addInput)
        end

        before_each(function()
            herbs = store:CreateGroup(1, "Herbs")
            build()
            page.tree:Select(herbs)
            page.SelectTab("items")
        end)

        it("shows the hint under the button in the popup", function()
            assert.are.equal("Search the Auction House", page.ahButton:GetText())
            assert.are.equal(page.popup, page.ahButton:GetParent())
            assert.are.equal("This uses the Auction House search; Blizzard's Buy tab will show these results.",
                page.ahHint:GetText())
        end)

        it("does not search without a click", function()
            index.matches = {}
            search("peace")
            assert.is_nil(ah.name)
        end)

        it("searches on a click and adds the results with the source", function()
            index.matches = { PEACE }
            search("peace")
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
            search("peace")
            click(page.ahButton)
            ah.callback({ { itemID = 7, name = "Peace Lily", key = "7" } })
            assert.are.same({}, page.nameList:GetData())
        end)

        it("uses the exact name for quoted text", function()
            index.matches = { PEACE, { itemID = 101, name = "Peacebloom", key = "101", source = "scan" } }
            search('"Peacebloom"')
            click(page.ahButton)
            assert.are.equal("Peacebloom", ah.name)
            assert.is_true(ah.options.exact)
        end)

        it("shows the message when the Auction House is closed", function()
            ah.closed = true
            search("peace")
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

        local function exportFrom(id)
            page.tree.options.onRightClick(id, {})
            menuClick("Export")
        end

        it("opens a read-only dialog with the export text", function()
            exportFrom(herbs)
            local dialog = page.exportDialog
            assert.is_true(dialog:IsShown())
            assert.is_nil(dialog.saveButton)
            assert.are.equal(ns.RulesExport.Export(store, sources, herbs), dialog.input:GetText())
            assert.is_truthy(dialog.input:GetText():find("FLIPSIDE-RULES", 1, true))
            assert.is_truthy(dialog.input:GetText():find("Herbs", 1, true))
        end)

        it("exports Base too", function()
            exportFrom(1)
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
            exportFrom(1)
            assert.is_true(page.exportDialog:IsShown())
        end)

        it("disables Import and Export without custom sources", function()
            deps.customSources = nil
            build()
            assert.is_false(page.importButton.enabled)
            page.tree.options.onRightClick(1, {})
            assert.is_false(menuItem("Export").enabled)
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
            for _, control in ipairs({ page.newButton, page.nameInput, page.addSelectedButton,
                page.removeSelectedButton, page.addButton, page.addInput, page.opRows.selling.dropdown }) do
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

    describe("auto rules tab", function()
        local linen, uncommon, editor

        local function fire(input)
            input.scripts.OnTextChanged(input)
        end

        local function rowTexts()
            local texts = {}
            for _, row in ipairs(page.autoList.rows) do
                texts[#texts + 1] = row.text:GetText()
            end
            return texts
        end

        before_each(function()
            for _, name in ipairs({ "MailingPlan", "MailClient", "AutoRules", "AutoRulesPanel" }) do
                assert(loadfile(manifest.path(name)))("Flipside", ns)
            end
            ns.NameRegex = {
                Compile = function(source)
                    if source == "(" then
                        return nil, "missing )"
                    end
                    local anchored = source:sub(1, 1) == "^"
                    local body = (anchored and source:sub(2) or source):lower()
                    return {
                        Match = function(_, name)
                            name = name:lower()
                            return anchored and name:sub(1, #body) == body or name:find(body, 1, true) ~= nil
                        end,
                    }
                end,
            }
            _G.Enum = { ItemClass = { Weapon = 2, Tradegoods = 7 } }
            local colors = { [0] = "ff9d9d9d", "ffffffff", "ff1eff00", "ff0070dd", "ffa335ee", "ffff8000" }
            _G.C_Item = {
                GetItemClassInfo = function(id)
                    return id == 2 and "Weapon" or "Trade Goods"
                end,
                GetItemQualityColor = function(quality)
                    return 1, 1, 1, colors[quality]
                end,
            }
            linen = store:CreateGroup(1, "Linen")
            uncommon = store:CreateGroup(1, "Uncommon Linen")
            build()
            editor = page.autoEditor
        end)

        after_each(function()
            _G.Enum, _G.C_Item = nil, nil
        end)

        it("adds a third tab and the auto switch is on by default", function()
            assert.are.equal("Auto rules", page.topTabs.buttons[3]:GetText())
            assert.is_true(page.autoCheck:GetChecked())
            assert.are.same({}, rowTexts())
        end)

        it("has no tab when the logic is not loaded", function()
            ns.AutoRulesPanel = nil
            build()
            assert.is_nil(page.topTabs.buttons[3])
        end)

        it("adds a rule with the editor and lists it", function()
            click(page.autoAddButton)
            editor.pattern:SetText("^Linen")
            pick(editor.minQuality, "|cff1eff00Uncommon|r")
            pick(editor.group, "Uncommon Linen")
            editor.classes:SetValues({ [7] = true })
            fire(editor.pattern)
            assert.are.equal("", editor.error:GetText())
            assert.is_true(editor.saveButton.enabled)
            click(editor.saveButton)
            local list = store:AutoRules()
            assert.are.equal(1, #list)
            assert.are.same({ group = uncommon, pattern = "^Linen", minQuality = 2, maxQuality = 5, classes = "7" },
                list[1])
            assert.are.same({ "1. /^Linen/  Uncommon to Legendary  Trade Goods  >  Uncommon Linen" }, rowTexts())
        end)

        it("shows each rarity in its quality colour, Legendary included", function()
            local texts = {}
            for _, item in ipairs(editor.minQuality.menuItems) do
                texts[#texts + 1] = item.text
            end
            assert.are.same({ "|cff9d9d9dPoor|r", "|cffffffffCommon|r", "|cff1eff00Uncommon|r", "|cff0070ddRare|r",
                "|cffa335eeEpic|r", "|cffff8000Legendary|r" }, texts)
            assert.are.equal(6, #editor.maxQuality.menuItems)
        end)

        it("sets the item types with check boxes that keep the editor open", function()
            click(page.autoAddButton)
            pick(editor.group, "Linen")
            assert.are.equal(2, #editor.classes.checks)
            local tradeGoods = editor.classes.checks[1]
            tradeGoods:SetChecked(true)
            tradeGoods.scripts.OnClick(tradeGoods)
            assert.are.same({ [7] = true }, editor.classes:GetValues())
            assert.is_true(editor:IsShown())
            assert.is_true(editor.saveButton.enabled)
            tradeGoods:SetChecked(false)
            tradeGoods.scripts.OnClick(tradeGoods)
            assert.are.same({}, editor.classes:GetValues())
            assert.is_true(editor:IsShown())
        end)

        it("shows the compile error of a bad pattern and blocks Save", function()
            click(page.autoAddButton)
            pick(editor.group, "Linen")
            editor.pattern:SetText("(")
            fire(editor.pattern)
            assert.are.equal("missing )", editor.error:GetText())
            assert.is_false(editor.saveButton.enabled)
        end)

        it("blocks Save for a rule with no filter", function()
            click(page.autoAddButton)
            pick(editor.group, "Linen")
            fire(editor.pattern)
            assert.is_false(editor.saveButton.enabled)
            click(editor.saveButton)
            assert.are.same({}, store:AutoRules())
        end)

        it("edits a rule", function()
            store:AddAutoRule({ group = linen, pattern = "Linen" })
            page.Refresh()
            click(page.autoList.rows[1].editButton)
            assert.are.equal("Linen", editor.pattern:GetText())
            editor.pattern:SetText("Silk")
            click(editor.saveButton)
            assert.are.equal("Silk", store:AutoRules()[1].pattern)
        end)

        it("moves and deletes rules with the row buttons", function()
            store:AddAutoRule({ group = linen, pattern = "a" })
            store:AddAutoRule({ group = linen, pattern = "b" })
            page.Refresh()
            assert.is_false(page.autoList.rows[1].upButton.enabled)
            assert.is_false(page.autoList.rows[2].downButton.enabled)
            click(page.autoList.rows[2].upButton)
            assert.are.equal("b", store:AutoRules()[1].pattern)
            click(page.autoList.rows[1].downButton)
            assert.are.equal("a", store:AutoRules()[1].pattern)
            click(page.autoList.rows[1].deleteButton)
            assert.are.equal(1, #store:AutoRules())
            assert.are.equal("b", store:AutoRules()[1].pattern)
        end)

        it("shows a rule with a deleted group in red", function()
            store:AddAutoRule({ group = linen, pattern = "a" })
            store:DeleteGroup(linen)
            page.Refresh()
            local row = page.autoList.rows[1]
            assert.are.equal("1. /a/  >  (no group)", row.text:GetText())
            assert.are.same({ 1, 0.3, 0.3 }, { row.text.color[1], row.text.color[2], row.text.color[3] })
        end)

        it("saves the switch", function()
            page.autoCheck:SetChecked(false)
            page.autoCheck.scripts.OnClick(page.autoCheck)
            assert.is_false(store:AutoRulesEnabled())
        end)

        describe("Apply now", function()
            before_each(function()
                deps.itemCache = {
                    Get = function()
                        return { name = "Linen Cloth", quality = 1, classID = 7 }
                    end,
                }
                bags = { { key = "100", itemID = 100, name = "Linen Cloth", count = 1 } }
                store:AddAutoRule({ group = linen, pattern = "^Linen" })
                build()
            end)

            it("shows the preview and adds the items after the confirm", function()
                click(page.autoApplyButton)
                assert.is_truthy(mock.popup.text:find("Linen Cloth > Linen", 1, true))
                assert.are.equal(1, store:GroupOf("100"))
                mock.acceptPopup()
                assert.are.equal(linen, store:GroupOf("100"))
                assert.are.equal("Added 1 items to groups", page.status:GetText())
            end)

            it("adds nothing when the player cancels", function()
                click(page.autoApplyButton)
                mock.cancelPopup()
                assert.are.equal(1, store:GroupOf("100"))
            end)

            it("says so when no item matches", function()
                bags = {}
                click(page.autoApplyButton)
                assert.is_nil(mock.popup)
                assert.are.equal("No bag item matches the rules", page.status:GetText())
            end)
        end)
    end)
end)
