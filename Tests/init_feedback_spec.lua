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

local function enter(widget, text)
    widget:SetText(text)
    widget.scripts.OnEnterPressed(widget)
end

-- Click New, choose the type, type the name and press OK.
local function createOperation(page, opType, name)
    click(page.newButton)
    local window = ns.Kit.Prompt("FlipsideNewOperationPrompt")
    for _, item in ipairs(window.choice.menuItems) do
        if item.value == opType then
            item.pick()
        end
    end
    window.input:SetText(name)
    window.input.scripts.OnTextChanged(window.input)
    click(window.okButton)
end
local LINEN = "|cff1eff00|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r"

describe("Init feedback", function()
    local groups

    before_each(function()
        mock.reset()
        local methods = getmetatable(CreateFrame("Frame")).__index
        methods.SetJustifyH = function() end
        methods.HasFocus = function(self)
            return self.focused
        end
        _G.ScrollUtil = nil
        _G.C_Timer.NewTicker = function()
            return { Cancel = function() end }
        end
        mock.playerName = "Tester"
        mock.realmName = "TestRealm"
        deps = nil
        ns = loadAddon()
        login()
        slash("")
        groups = ns.GroupsPage.Build(CreateFrame("Frame", nil, UIParent), deps)
    end)

    after_each(function()
        mock.teardown()
    end)

    it("loads the full TOC sequence", function()
        local position = {}
        for i, path in ipairs(tocFiles()) do
            position[path] = i
        end
        local function before(first, second)
            assert.is_true(position[first] < position[second], first .. " before " .. second)
        end
        before(manifest.path("RulesStore"), manifest.path("RulesExport"))
        before(manifest.path("CustomSources"), manifest.path("RulesExport"))
        before(manifest.path("AHNameSearch"), manifest.path("GroupsPage"))
        before(manifest.path("RulesExport"), manifest.path("GroupsPage"))
        before(manifest.path("ItemNameIndex"), manifest.path("GroupsPage"))
        before(manifest.path("RulesExport"), manifest.path("Init"))
        assert.is_table(ns.AHNameSearch)
        assert.is_table(ns.RulesExport)
    end)

    it("creates the Auction House name search at login", function()
        assert.is_table(ns.ahNameSearch)
        assert.are.same({}, mock.messages)
    end)

    it("gives the window and the Groups page the new deps", function()
        assert.are.equal(ns.ahNameSearch, deps.ahNameSearch)
        assert.are.equal(ns.customSources, deps.customSources)
        assert.is_function(deps.compile)
        local compiled = deps.compile("scanmin * 2")
        assert.is_table(compiled)
        assert.is_nil((deps.compile("bad(")))
    end)

    describe("clientLookup", function()
        it("returns the item id, link and name from the client", function()
            mock.itemInfo["linen cloth"] = { "Linen Cloth", LINEN }
            local itemID, link, name = ns.itemNameIndex.clientLookup("linen cloth")
            assert.are.equal(2589, itemID)
            assert.are.equal(LINEN, link)
            assert.are.equal("Linen Cloth", name)
        end)

        it("gives nil when the client has no answer", function()
            assert.is_nil(ns.itemNameIndex.clientLookup("unknown thing"))
        end)

        it("gives nil when the client call fails", function()
            _G.C_Item.GetItemInfo = function()
                error("bad argument")
            end
            assert.is_nil(ns.itemNameIndex.clientLookup("linen cloth"))
        end)
    end)

    describe("Groups page", function()
        local herbs

        before_each(function()
            herbs = ns.rules:CreateGroup(1, "Herbs")
            groups.Refresh()
            groups.tree:Select(herbs)
            groups.SelectTab("items")
        end)

        it("finds an item from the client cache by name", function()
            mock.itemInfo["linen cloth"] = { "Linen Cloth", LINEN }
            groups.addInput:SetText("linen cloth")
            click(groups.addButton)
            assert.is_true(groups.popup:IsShown())
            local data = groups.nameList:GetData()
            assert.are.equal(1, #data)
            assert.are.equal("2589", data[1].key)
            assert.are.equal("Linen Cloth", data[1].name)
        end)

        it("finds items with the Auction House search", function()
            mock.fire("AUCTION_HOUSE_SHOW")
            mock.browseRows = { { itemKey = { itemID = 2589, battlePetSpeciesID = 0 } } }
            mock.itemNames[2589] = "Linen Cloth"
            groups.addInput:SetText("linen")
            click(groups.addButton)
            click(groups.ahButton)
            assert.are.equal("linen", mock.browseQueries[1].searchString)
            mock.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
            local data = groups.nameList:GetData()
            assert.are.equal(1, #data)
            assert.are.equal("2589", data[1].key)
            assert.are.equal("ah", data[1].source)
        end)

        it("says so when the Auction House is closed", function()
            groups.addInput:SetText("linen")
            click(groups.addButton)
            click(groups.ahButton)
            assert.are.equal("open the Auction House to search it", groups.status:GetText())
        end)
    end)

    describe("export and import", function()
        it("exports a group and imports it under another group, and keeps it after a reload", function()
            local herbs = ns.rules:CreateGroup(1, "Herbs")
            ns.rules:AddItem("2589", herbs)
            local dest = ns.rules:CreateGroup(1, "Dest")
            groups.Refresh()
            groups.tree:Select(herbs)
            groups.tree.options.onRightClick(herbs, {})
            for _, item in ipairs(mock.menu.items) do
                if item.text == "Export" then
                    item.onClick()
                end
            end
            local text = groups.exportDialog.input:GetText()
            assert.is_truthy(text:find("FLIPSIDE-RULES", 1, true))

            groups.tree:Select(dest)
            click(groups.importButton)
            groups.importDialog.input.EditBox:SetText(text)
            click(groups.importDialog.saveButton)
            mock.acceptPopup()
            local copy = ns.rules:Children(dest)[1]
            assert.are.equal("Herbs", ns.rules:Name(copy))
            assert.are.same({ "2589" }, ns.rules:ItemsIn(copy))

            mock.frames = {}
            ns = loadAddon()
            login()
            local reloaded = ns.rules:Children(dest)[1]
            assert.are.equal("Herbs", ns.rules:Name(reloaded))
            assert.are.same({ "2589" }, ns.rules:ItemsIn(reloaded))
        end)
    end)

    describe("Operations page", function()
        local page, id

        before_each(function()
            page = ns.OperationsPage.Build(CreateFrame("Frame", nil, UIParent), deps)
            createOperation(page, "selling", "Main")
            for _, op in ipairs(ns.rules:ListOperations()) do
                if op.name == "Main" then
                    id = op.id
                end
            end
        end)

        it("saves a formula from the ... editor", function()
            local part = page.FieldPart("normalPrice")
            click(part.expand)
            local dialog = ns.Kit.EditorDialog("FlipsideFormulaEditor")
            dialog.input.EditBox:SetText("2 *\nscanmin")
            click(dialog.saveButton)
            assert.are.equal("2 * scanmin", ns.rules:GetOperation(id).settings.normalPrice)
        end)

        it("saves the keep-in-bags value of a selling operation", function()
            local part = page.FieldPart("keepInBags")
            enter(part.number, "5")
            assert.are.equal(5, ns.rules:GetOperation(id).settings.keepInBags)
        end)
    end)
end)
