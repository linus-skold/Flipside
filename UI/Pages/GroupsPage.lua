local _, ns = ...

-- The groups page of the Flipside window.

local GroupsPage = {}
ns.GroupsPage = GroupsPage

local BASE_ID = 1
local INHERIT = 0
local MAX_RESULTS = 20
local RIGHT = 260
local PANE_Y = 56
local DELETE_DIALOG = "FLIPSIDE_DELETE_GROUP"
local IMPORT_CONFIRM = "FLIPSIDE_IMPORT_CONFIRM"
local EXPORT_DIALOG = "FLIPSIDE_EXPORT_DIALOG"
local IMPORT_DIALOG = "FLIPSIDE_IMPORT_DIALOG"
local TYPE_LABELS = { selling = "Selling", buying = "Buying", vendoring = "Vendoring" }
local SOURCE_LABELS = { scan = "scan data", client = "game cache", ah = "Auction House" }
local AH_HINT = "This uses the Auction House search; Blizzard's Buy tab will show these results."

local function trim(text)
    return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

local function byName(a, b)
    local left, right = tostring(a.name or a.key):lower(), tostring(b.name or b.key):lower()
    if left ~= right then
        return left < right
    end
    return a.key < b.key
end

-- Return the text of an import preview in plain words.
local function describePreview(parentName, summary)
    local lines = {
        string.format('Import below "%s":', parentName),
        "Groups: " .. summary.groups,
        string.format("Items: %d (%d move from other groups)", summary.items, summary.itemsMoved),
        string.format("Operations: %d new, %d reused", summary.operationsNew, summary.operationsReused),
        string.format("Custom sources: %d new, %d reused", summary.customNew, summary.customReused),
    }
    if #summary.renames > 0 then
        local parts = {}
        for _, rename in ipairs(summary.renames) do
            parts[#parts + 1] = string.format('%s "%s" becomes "%s"', rename.kind, rename.from, rename.to)
        end
        lines[#lines + 1] = "Renames: " .. table.concat(parts, "; ")
    end
    return table.concat(lines, "\n")
end

-- Build the page in the content frame.
-- deps: rules, itemCache, itemNameIndex, readBags(), keyFor(link) (optional), subscribe(fn) (optional),
-- ahNameSearch (optional), customSources and compile(text) (for export and import).
function GroupsPage.Build(content, deps)
    local Kit = ns.Kit
    local rules, index = deps.rules, deps.itemNameIndex
    local gap = Kit.Theme.gap
    local page = { selected = BASE_ID, opRows = {}, bagEntries = {}, bagSelected = {}, results = {}, tab = "rules" }

    local function place(frame, x, y)
        frame:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
    end

    local function placeIn(panel, frame, x, y)
        frame:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -y)
    end

    local function editable()
        return not rules:IsReadOnly()
    end

    local function parentOf(id)
        local found
        rules:Walk(function(groupID)
            for _, childID in ipairs(rules:Children(groupID)) do
                if childID == id then
                    found = groupID
                end
            end
        end)
        return found
    end

    local function countSubGroups(id)
        local count = 0
        for _, childID in ipairs(rules:Children(id)) do
            count = count + 1 + countSubGroups(childID)
        end
        return count
    end

    local function itemName(key)
        local parsed = ns.ItemString.ParseKey(key)
        local cache = deps.itemCache
        if parsed and cache then
            local info = cache:Get(parsed.itemID)
            if info and info.name then
                if key == string.format("%d", parsed.itemID) then
                    return info.name
                end
                return info.name .. " (" .. key .. ")"
            end
            if cache.Request then
                cache:Request(parsed.itemID)
            end
        end
        return key
    end

    -- Show the store message when a call gave nil. Returns true on success.
    local function report(ok, message)
        if ok == nil then
            page.status:SetText(tostring(message or ""))
            return false
        end
        page.status:SetText("")
        return true
    end

    local refresh

    -- Tree and buttons.

    local function nodeFor(id)
        local node = {
            id = id,
            text = string.format("%s (%d)", rules:Name(id), rules:CountItems(id, true)),
            children = {},
        }
        for _, childID in ipairs(rules:Children(id)) do
            node.children[#node.children + 1] = nodeFor(childID)
        end
        return node
    end

    local function onDrop(draggedID, targetID)
        if draggedID == BASE_ID then
            return
        end
        report(rules:MoveGroup(draggedID, targetID or BASE_ID))
        refresh()
    end

    page.tree = Kit.CreateTree(content, {
        onSelect = function(node)
            if node.id ~= page.selected then
                page.results = {}
            end
            page.selected = node.id
            page.RefreshPane()
        end,
        onDrop = onDrop,
        canDrag = function(id)
            return id ~= BASE_ID and editable()
        end,
    })
    page.tree.frame:SetSize(250, 270)
    place(page.tree.frame, 0, 0)

    page.nameInput = Kit.Input(content, 236, nil)
    place(page.nameInput, 6, 278)

    local function onNew()
        local id, message = rules:CreateGroup(page.selected, page.nameInput:GetText())
        if report(id, message) then
            page.nameInput:SetText("")
        end
        refresh()
    end

    local function onRename()
        local ok, message = rules:RenameGroup(page.selected, page.nameInput:GetText())
        if report(ok, message) then
            page.nameInput:SetText("")
        end
        refresh()
    end

    local function onDelete()
        local id = page.selected
        if id == BASE_ID or not editable() then
            return
        end
        local parentID = parentOf(id) or BASE_ID
        local text = string.format('Delete group "%s" and its %d sub-groups? %d items move to "%s".',
            rules:Name(id), countSubGroups(id), rules:CountItems(id, true), rules:Name(parentID))
        Kit.Confirm(DELETE_DIALOG, text, function()
            local ok, message = rules:DeleteGroup(id)
            if report(ok, message) then
                page.selected = parentID
            end
            refresh()
        end)
    end

    page.newButton = Kit.Button(content, "New group", 78, onNew)
    place(page.newButton, 0, 304)
    page.renameButton = Kit.Button(content, "Rename", 78, onRename)
    page.renameButton:SetPoint("LEFT", page.newButton, "RIGHT", gap, 0)
    page.deleteButton = Kit.Button(content, "Delete", 78, onDelete)
    page.deleteButton:SetPoint("LEFT", page.renameButton, "RIGHT", gap, 0)

    local moveLabel = Kit.Label(content, "Move to...", "normal")
    place(moveLabel, 0, 336)
    page.moveDropdown = Kit.Dropdown(content, 160, {
        items = {},
        onChange = function(targetID)
            local ok, message = rules:MoveGroup(page.selected, targetID)
            report(ok, message)
            refresh()
        end,
    })
    place(page.moveDropdown, 80, 330)

    -- Export and import.

    local function onExport()
        if not deps.customSources then
            page.status:SetText("export is not available")
            return
        end
        local text, message = ns.RulesExport.Export(rules, deps.customSources, page.selected)
        if not text then
            page.status:SetText(tostring(message or ""))
            return
        end
        page.status:SetText("")
        page.exportDialog = Kit.EditorDialog(EXPORT_DIALOG, {
            readOnly = true,
            help = "Copy this text with Ctrl+C. Share it. Another player can import it.",
        })
        page.exportDialog:Open("Export group " .. tostring(rules:Name(page.selected)), text)
    end

    local function applyImport(data, parentID)
        local ok, result = ns.RulesExport.Apply(rules, deps.customSources, data, parentID, deps.compile)
        if not ok then
            page.status:SetText(tostring(result))
            refresh()
            return
        end
        page.selected = result.groupID or page.selected
        refresh()
        page.status:SetText(string.format("Imported %d groups and %d items", result.groups, result.items))
    end

    local function onImportText(text)
        local data, message = ns.RulesExport.Parse(text)
        if not data then
            page.status:SetText(tostring(message))
            return
        end
        local parentID = page.selected
        local summary, previewMessage = ns.RulesExport.Preview(rules, deps.customSources, data, parentID)
        if not summary then
            page.status:SetText(tostring(previewMessage))
            return
        end
        page.status:SetText("")
        Kit.Confirm(IMPORT_CONFIRM, describePreview(tostring(rules:Name(parentID)), summary), function()
            applyImport(data, parentID)
        end)
    end

    local function onImport()
        if not deps.customSources then
            page.status:SetText("import is not available")
            return
        end
        page.status:SetText("")
        page.importDialog = Kit.EditorDialog(IMPORT_DIALOG, {
            help = "Paste an export text. It is imported below the selected group.",
        })
        page.importDialog:Open("Import below " .. tostring(rules:Name(page.selected)), "", onImportText)
    end

    page.exportButton = Kit.Button(content, "Export", 78, onExport)
    place(page.exportButton, 0, 364)
    page.importButton = Kit.Button(content, "Import", 78, onImport)
    page.importButton:SetPoint("LEFT", page.exportButton, "RIGHT", gap, 0)

    -- Header and inner tabs.

    page.header = Kit.Label(content, "", "title")
    place(page.header, RIGHT, 0)

    page.tabButtons = {}
    local function selectTab(name)
        page.tab = name
        page.rulesPanel:SetShown(name == "rules")
        page.itemsPanel:SetShown(name == "items")
        for key, button in pairs(page.tabButtons) do
            button:SetEnabled(key ~= name)
        end
    end
    page.SelectTab = selectTab

    page.tabButtons.rules = Kit.Button(content, "Rules", 90, function()
        selectTab("rules")
    end)
    place(page.tabButtons.rules, RIGHT, 26)
    page.tabButtons.items = Kit.Button(content, "Items", 90, function()
        selectTab("items")
    end)
    page.tabButtons.items:SetPoint("LEFT", page.tabButtons.rules, "RIGHT", gap, 0)

    page.rulesPanel = CreateFrame("Frame", nil, content)
    page.rulesPanel:SetSize(520, 140)
    place(page.rulesPanel, RIGHT, PANE_Y)
    page.itemsPanel = CreateFrame("Frame", nil, content)
    page.itemsPanel:SetSize(520, 380)
    place(page.itemsPanel, RIGHT, PANE_Y)

    -- Rules tab.

    local function onOperation(opType, value)
        local ok, message
        if value == INHERIT then
            ok, message = rules:DetachOperation(page.selected, opType)
        else
            ok, message = rules:AttachOperation(page.selected, opType, value)
        end
        report(ok, message)
        refresh()
    end

    for position, opType in ipairs(ns.OperationSchema.TYPES) do
        local y = 4 + (position - 1) * 42
        local row = {}
        row.label = Kit.Label(page.rulesPanel, TYPE_LABELS[opType] or opType, "highlight")
        placeIn(page.rulesPanel, row.label, 0, y + 4)
        row.dropdown = Kit.Dropdown(page.rulesPanel, 200, {
            items = { { value = INHERIT, text = "(inherit)" } },
            value = INHERIT,
            onChange = function(value)
                onOperation(opType, value)
            end,
        })
        placeIn(page.rulesPanel, row.dropdown, 80, y)
        row.using = Kit.Label(page.rulesPanel, "", "small")
        placeIn(page.rulesPanel, row.using, 86, y + 24)
        page.opRows[opType] = row
    end

    -- Items tab: the items of the group.

    local itemsPanel = page.itemsPanel
    page.itemsLabel = Kit.Label(itemsPanel, "Items", "highlight")
    placeIn(itemsPanel, page.itemsLabel, 0, 0)

    local function onRemove(key)
        local ok, message = rules:RemoveItem(key)
        report(ok, message)
        refresh()
    end

    page.itemList = Kit.CreateList(itemsPanel, {
        initRow = function(row, key)
            if not row.nameText then
                row.nameText = Kit.Label(row, "", "normal")
                row.nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
                row.nameText:SetWidth(380)
                row.nameText:SetJustifyH("LEFT")
                row.removeButton = Kit.Button(row, "Remove", 70, nil)
                row.removeButton:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            end
            row.nameText:SetText(itemName(key))
            row.removeButton:SetEnabled(editable())
            row.removeButton:SetScript("OnClick", function()
                onRemove(key)
            end)
        end,
    })
    page.itemList.frame:SetSize(490, 100)
    placeIn(itemsPanel, page.itemList.frame, 0, 18)

    -- Add items.

    local bagPanel = CreateFrame("Frame", nil, itemsPanel)
    bagPanel:SetSize(490, 100)
    placeIn(itemsPanel, bagPanel, 0, 214)
    bagPanel:Hide()
    page.bagPanel = bagPanel

    local function showBags(shown)
        bagPanel:SetShown(shown)
        page.nameList.frame:SetShown(not shown)
    end

    -- Add one item to the selected group. It moves from another group.
    local function addKey(key)
        local previous = rules:GroupOf(key)
        local ok, message = rules:AddItem(key, page.selected)
        if report(ok, message) then
            local text = "Added " .. itemName(key)
            if previous ~= BASE_ID and previous ~= page.selected then
                text = "Moved " .. itemName(key) .. " from " .. tostring(rules:Name(previous))
            end
            page.status:SetText(text)
        end
        refresh()
    end

    page.bagsButton = Kit.Button(itemsPanel, "Add from bags", 110, nil)
    placeIn(itemsPanel, page.bagsButton, 0, 122)

    page.bagList = Kit.CreateList(bagPanel, {
        initRow = function(row, entry)
            if not row.check then
                row.check = Kit.Check(row, "", function(checked)
                    if row.entry then
                        page.bagSelected[row.entry.key] = checked or nil
                    end
                end)
                row.check:SetPoint("LEFT", row, "LEFT", 0, 0)
                row.text = Kit.Label(row, "", "normal")
                row.text:SetPoint("LEFT", row, "LEFT", 28, 0)
            end
            row.entry = entry
            row.check:SetChecked(page.bagSelected[entry.key] == true)
            row.check:SetEnabled(editable())
            local text = string.format("%s x%d", entry.name ~= "" and entry.name or entry.key, entry.count or 1)
            local groupID = rules:GroupOf(entry.key)
            if groupID ~= BASE_ID then
                text = text .. " (in " .. tostring(rules:Name(groupID)) .. ")"
            end
            row.text:SetText(text)
        end,
    })
    page.bagList.frame:SetPoint("TOPLEFT", bagPanel, "TOPLEFT", 0, 0)
    page.bagList.frame:SetPoint("BOTTOMRIGHT", bagPanel, "BOTTOMRIGHT", 0, 26)

    page.selectAllButton = Kit.Button(bagPanel, "Select all", 90, function()
        for _, entry in ipairs(page.bagEntries) do
            page.bagSelected[entry.key] = true
        end
        page.bagList:SetData(page.bagEntries)
    end)
    page.selectAllButton:SetPoint("BOTTOMLEFT", bagPanel, "BOTTOMLEFT", 0, 0)

    page.addSelectedButton = Kit.Button(bagPanel, "Add selected", 100, function()
        local keys = {}
        for _, entry in ipairs(page.bagEntries) do
            if page.bagSelected[entry.key] then
                keys[#keys + 1] = entry.key
            end
        end
        if #keys == 0 then
            page.status:SetText("Select items first")
            return
        end
        local added, message = rules:AddItems(keys, page.selected)
        if report(added, message) then
            page.status:SetText("Added " .. added .. " items")
            showBags(false)
        end
        refresh()
    end)
    page.addSelectedButton:SetPoint("LEFT", page.selectAllButton, "RIGHT", gap, 0)

    page.bagsButton:SetScript("OnClick", function()
        showBags(false)
        local entries = deps.readBags and deps.readBags() or {}
        if #entries == 0 then
            page.status:SetText("No items found in bags")
            return
        end
        page.status:SetText("")
        page.bagEntries, page.bagSelected = entries, {}
        page.bagList:SetData(entries)
        showBags(true)
    end)

    -- Add by link.

    local linkLabel = Kit.Label(itemsPanel, "Add by link", "normal")
    placeIn(itemsPanel, linkLabel, 0, 154)
    page.linkInput = Kit.Input(itemsPanel, 220, nil)
    placeIn(itemsPanel, page.linkInput, 96, 150)

    local function onAddLink()
        showBags(false)
        local link = trim(page.linkInput:GetText())
        local key = deps.keyFor and deps.keyFor(link) or ns.ItemString.ToExactKey(link)
        if not key then
            page.status:SetText("not an item link")
            return
        end
        addKey(key)
        page.linkInput:SetText("")
    end
    page.addLinkButton = Kit.Button(itemsPanel, "Add", 60, onAddLink)
    page.addLinkButton:SetPoint("LEFT", page.linkInput, "RIGHT", gap, 0)

    -- Add by name. The result list stays until the next search.

    local nameLabel = Kit.Label(itemsPanel, "Add by name", "normal")
    placeIn(itemsPanel, nameLabel, 0, 184)
    page.addNameInput = Kit.Input(itemsPanel, 220, function()
        page.SearchName()
    end)
    placeIn(itemsPanel, page.addNameInput, 96, 180)

    page.nameList = Kit.CreateList(itemsPanel, {
        initRow = function(row, match)
            if not row.nameText then
                row.nameText = Kit.Label(row, "", "normal")
                row.nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
                row.nameText:SetWidth(290)
                row.nameText:SetJustifyH("LEFT")
                row.sourceText = Kit.Label(row, "", "small")
                row.sourceText:SetPoint("LEFT", row, "LEFT", 300, 0)
                row.addButton = Kit.Button(row, "Add", 70, nil)
                row.addButton:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            end
            local inGroup = page.selected ~= BASE_ID and rules:GroupOf(match.key) == page.selected
            local text = match.name or match.key
            if match.key ~= string.format("%d", match.itemID or 0) then
                text = text .. " (" .. match.key .. ")"
            end
            row.nameText:SetText(text)
            row.sourceText:SetText(SOURCE_LABELS[match.source] or "")
            row.addButton:SetText(inGroup and "Added" or "Add")
            row.addButton:SetEnabled(editable() and page.selected ~= BASE_ID and not inGroup)
            row.addButton:SetScript("OnClick", function()
                addKey(match.key)
            end)
        end,
    })
    page.nameList.frame:SetSize(490, 100)
    placeIn(itemsPanel, page.nameList.frame, 0, 214)

    local function inGroupKeys()
        local exclude = {}
        for _, key in ipairs(rules:ItemsIn(page.selected)) do
            exclude[key] = true
        end
        return exclude
    end

    function page.SearchName()
        showBags(false)
        local text = trim(page.addNameInput:GetText())
        if not index then
            page.status:SetText("item names are not available")
            return
        end
        local matches, pending = index:Find(text, MAX_RESULTS, { exclude = inGroupKeys() })
        page.results = matches
        page.nameList:SetData(page.results)
        local note = pending > 0 and ("\n" .. pending .. " item names are still loading") or ""
        if #matches == 0 then
            page.status:SetText('no item named "' .. ns.ItemNameIndex.ParseQuery(text).raw .. '"' .. note)
        else
            page.status:SetText(#matches .. " items found" .. note)
        end
    end
    page.addNameButton = Kit.Button(itemsPanel, "Add", 60, function()
        page.SearchName()
    end)
    page.addNameButton:SetPoint("LEFT", page.addNameInput, "RIGHT", gap, 0)

    -- Auction House search, only on a click.

    local function onAHResults(items, err)
        if not items then
            page.status:SetText(tostring(err or ""))
            return
        end
        local exclude, known = inGroupKeys(), {}
        for _, match in ipairs(page.results) do
            known[match.key] = true
        end
        local added = 0
        for _, item in ipairs(items) do
            if not known[item.key] and not exclude[item.key] then
                page.results[#page.results + 1] =
                    { itemID = item.itemID, name = item.name, key = item.key, source = "ah" }
                known[item.key] = true
                added = added + 1
            end
        end
        table.sort(page.results, byName)
        page.nameList:SetData(page.results)
        page.status:SetText(added .. " items found in the Auction House")
    end

    page.ahButton = Kit.Button(itemsPanel, "Search the Auction House", 190, function()
        if not deps.ahNameSearch then
            return
        end
        showBags(false)
        local query = ns.ItemNameIndex.ParseQuery(page.addNameInput:GetText())
        if query.raw == "" then
            page.status:SetText("type a name first")
            return
        end
        page.status:SetText("")
        deps.ahNameSearch:Find(query.raw, onAHResults, { exact = query.exact })
    end)
    placeIn(itemsPanel, page.ahButton, 0, 318)
    page.ahHint = Kit.Label(itemsPanel, AH_HINT, "small")
    placeIn(itemsPanel, page.ahHint, 0, 344)
    page.ahHint:SetWidth(490)
    page.ahHint:SetJustifyH("LEFT")
    if not deps.ahNameSearch then
        page.ahButton:Hide()
        page.ahHint:Hide()
    end

    -- Status lines.

    page.readOnlyLabel = Kit.Label(content, "Settings are read-only", "bad")
    page.readOnlyLabel:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 18)
    page.readOnlyLabel:Hide()
    page.status = Kit.Label(content, "", "normal")
    page.status:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    page.status:SetWidth(770)
    page.status:SetJustifyH("LEFT")

    -- Refresh.

    function page.RefreshTree()
        if not rules:Name(page.selected) then
            page.selected = BASE_ID
        end
        page.tree.selected = page.selected
        page.tree:SetNodes({ nodeFor(BASE_ID) })
    end

    local function moveTargets(id)
        local items, parentID = {}, parentOf(id)
        rules:Walk(function(groupID)
            if groupID ~= id and groupID ~= parentID then
                items[#items + 1] = { value = groupID, text = table.concat(rules:Path(groupID), " > ") }
            end
        end)
        return items
    end

    local function setEnabled(frame, enabled)
        frame:SetEnabled(enabled)
    end

    function page.RefreshPane()
        local id = page.selected
        local isBase = id == BASE_ID
        local canEdit = editable()
        local canAdd = canEdit and not isBase
        local canShare = deps.customSources ~= nil
        page.header:SetText(table.concat(rules:Path(id) or {}, " > "))

        for _, opType in ipairs(ns.OperationSchema.TYPES) do
            local row = page.opRows[opType]
            local items = { { value = INHERIT, text = "(inherit)" } }
            for _, op in ipairs(rules:ListOperations(opType)) do
                items[#items + 1] = { value = op.id, text = op.name }
            end
            local opID, fromID = rules:EffectiveOperation(id, opType)
            row.dropdown:SetItems(items)
            row.dropdown:SetValue((opID and fromID == id) and opID or INHERIT)
            setEnabled(row.dropdown, canEdit)
            local op = opID and rules:GetOperation(opID)
            if op then
                row.using:SetText("Using: " .. op.name .. " from " .. tostring(rules:Name(fromID)))
            else
                row.using:SetText("Using: none")
            end
        end

        page.itemList:SetData(rules:ItemsIn(id))
        page.nameList:SetData(page.results)
        page.itemsLabel:SetText(isBase and "Items (select a group to add items)" or "Items")

        setEnabled(page.nameInput, canEdit)
        setEnabled(page.newButton, canEdit)
        setEnabled(page.renameButton, canEdit and not isBase)
        setEnabled(page.deleteButton, canEdit and not isBase)
        setEnabled(page.exportButton, canShare)
        setEnabled(page.importButton, canShare and canEdit)
        page.moveDropdown:SetItems(moveTargets(id))
        page.moveDropdown:SetValue(nil)
        setEnabled(page.moveDropdown, canEdit and not isBase)
        setEnabled(page.bagsButton, canAdd)
        setEnabled(page.addNameInput, canAdd)
        setEnabled(page.addNameButton, canAdd)
        setEnabled(page.ahButton, canAdd)
        setEnabled(page.linkInput, canAdd)
        setEnabled(page.addLinkButton, canAdd)
        setEnabled(page.selectAllButton, canAdd)
        setEnabled(page.addSelectedButton, canAdd)
        page.readOnlyLabel:SetShown(not canEdit)
    end

    function refresh()
        page.RefreshTree()
        page.RefreshPane()
    end
    page.Refresh = refresh

    if deps.subscribe then
        deps.subscribe(refresh)
    end

    local hook, insertLink = _G.hooksecurefunc, _G.ChatEdit_InsertLink
    if hook and insertLink then
        hook("ChatEdit_InsertLink", function(link)
            if type(link) == "string" and page.linkInput:HasFocus() then
                page.linkInput:SetText(link)
            end
        end)
    end

    selectTab("rules")
    refresh()
    return page
end
