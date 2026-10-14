local mock = require("Tests.wow_mock")

local KIT = { "Theme", "Window", "Widgets", "Tabs", "List", "Tree", "Combat" }
local CORE = { "Core/ItemString", "Core/SettingsDB", "Services/GroupTree", "Services/OperationSchema",
    "Services/RulesStore" }

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
    local ns, store, page, deps, content, saved, names, requests, bags, index, subscribers

    local function newStore(data)
        saved = data or {}
        local db = ns.SettingsDB.New(saved, { character = "Me", schemaVersion = 1 })
        return ns.RulesStore.New(db, { onWarning = function() end })
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
            Find = function(self, text)
                self.query = text
                return self.matches, self.pending
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

    describe("add by name", function()
        local herbs

        before_each(function()
            herbs = store:CreateGroup(1, "Herbs")
            build()
            page.tree:Select(herbs)
        end)

        it("adds one match at once", function()
            index.matches = { { itemID = 100, name = "Peacebloom", key = "100" } }
            page.addNameInput:SetText("peace")
            click(page.addNameButton)
            assert.are.equal("peace", index.query)
            assert.are.same({ "100" }, store:ItemsIn(herbs))
            assert.are.equal("Added Peacebloom", page.status:GetText())
            assert.are.equal("", page.addNameInput:GetText())
        end)

        it("shows choices for several matches", function()
            index.matches = {
                { itemID = 100, name = "Peacebloom", key = "100" },
                { itemID = 101, name = "Peaceful Orb", key = "101" },
            }
            index.pending = 2
            page.addNameInput:SetText("peace")
            click(page.addNameButton)
            assert.are.same({}, store:ItemsIn(herbs))
            assert.is_true(page.choices[1]:IsShown())
            assert.is_true(page.choices[2]:IsShown())
            assert.is_false(page.choices[3]:IsShown())
            assert.are.equal("Peaceful Orb (101)", page.choices[2]:GetText())
            assert.is_truthy(page.status:GetText():find("2 items match", 1, true))
            assert.is_truthy(page.status:GetText():find("2 item names are still loading", 1, true))
            click(page.choices[2])
            assert.are.same({ "101" }, store:ItemsIn(herbs))
            assert.is_false(page.choices[1]:IsShown())
        end)

        it("says so when nothing matches", function()
            page.addNameInput:SetText("zzz")
            click(page.addNameButton)
            assert.are.equal('no item named "zzz"', page.status:GetText())
            assert.are.same({}, store:ItemsIn(herbs))
        end)

        it("says so when there is no name index", function()
            deps.itemNameIndex = nil
            build()
            page.tree:Select(herbs)
            click(page.addNameButton)
            assert.are.equal("item names are not available", page.status:GetText())
        end)

        it("moves an item from another group", function()
            local ore = store:CreateGroup(1, "Ore")
            store:AddItem("100", ore)
            page.Refresh()
            index.matches = { { itemID = 100, name = "Peacebloom", key = "100" } }
            page.addNameInput:SetText("peace")
            click(page.addNameButton)
            assert.are.equal(herbs, store:GroupOf("100"))
            assert.are.equal("Moved Peacebloom from Ore", page.status:GetText())
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
