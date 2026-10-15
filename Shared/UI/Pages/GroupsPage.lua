local _, ns = ...

-- The groups page of the Flipside window.

local GroupsPage = {}
ns.GroupsPage = GroupsPage

local BASE_ID = 1
local NO_GROUP_TEXT = "[No group]"
local INHERIT = 0
local MAX_RESULTS = 20
local RIGHT = 260
local TAB_Y = 24
local LIST_Y = 46
local DELETE_DIALOG = "FLIPSIDE_DELETE_GROUP"
local IMPORT_CONFIRM = "FLIPSIDE_IMPORT_CONFIRM"
local EXPORT_DIALOG = "FLIPSIDE_EXPORT_DIALOG"
local IMPORT_DIALOG = "FLIPSIDE_IMPORT_DIALOG"
local RESULTS_WINDOW = "FlipsideAddItemsWindow"
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
    local gap, pad = Kit.Theme.gap, Kit.Theme.padding
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

    local function qualityOf(itemID)
        local cache = deps.itemCache
        local info = cache and itemID and cache:Get(itemID)
        return info and info.quality
    end

    local function setQualityColor(label, quality)
        local r, g, b = Kit.QualityColor(quality)
        label:SetTextColor(r, g, b)
    end

    -- Return the display text of a key and the item quality (nil while the item loads).
    local function itemName(key)
        local parsed = ns.ItemString.ParseKey(key)
        local cache = deps.itemCache
        if parsed and cache then
            local info = cache:Get(parsed.itemID)
            if info and info.name then
                if key == string.format("%d", parsed.itemID) then
                    return info.name, info.quality
                end
                return info.name .. " (" .. key .. ")", info.quality
            end
            if cache.Request then
                cache:Request(parsed.itemID)
            end
        end
        return key
    end

    -- Show a message on the page and in the results window.
    local function say(text)
        page.status:SetText(text)
        if page.popup then
            page.popup.status:SetText(text)
        end
    end

    -- Show the store message when a call gave nil. Returns true on success.
    local function report(ok, message)
        if ok == nil then
            say(tostring(message or ""))
            return false
        end
        say("")
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

    local onRightClick

    page.tree = Kit.CreateTree(content, {
        inset = true,
        onSelect = function(node)
            if node.id ~= page.selected then
                page.results = {}
                if page.popup then
                    page.popup:Hide()
                end
            end
            page.selected = node.id
            page.RefreshPane()
        end,
        onDrop = onDrop,
        canDrag = function(id)
            return id ~= BASE_ID and editable()
        end,
        onRightClick = function(id, row)
            onRightClick(id, row)
        end,
    })
    page.tree.frame:SetSize(250, 330)
    place(page.tree.frame, 0, 0)

    page.nameInput = Kit.Input(content, 236, nil, nil, { placeholder = "<group name>" })
    place(page.nameInput, 6, 338)

    -- A new group goes below the selected group. With parentID = BASE_ID it is a root group (a top-level group).
    local function create(parentID)
        local id, message = rules:CreateGroup(parentID, page.nameInput:GetText())
        if report(id, message) then
            page.nameInput:SetText("")
        end
        refresh()
    end

    local function onNew()
        create(page.selected)
    end

    local function onNewRoot()
        create(BASE_ID)
    end

    local function onRename()
        if trim(page.nameInput:GetText()) == "" then
            say("type the new name in the box under the tree, then choose Rename")
            return
        end
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

    -- Export and import.

    local function onExport()
        if not deps.customSources then
            say("export is not available")
            return
        end
        local text, message = ns.RulesExport.Export(rules, deps.customSources, page.selected)
        if not text then
            say(tostring(message or ""))
            return
        end
        say("")
        page.exportDialog = Kit.EditorDialog(EXPORT_DIALOG, {
            readOnly = true,
            help = "Copy this text with Ctrl+C. Share it. Another player can import it.",
        })
        page.exportDialog:Open("Export group " .. tostring(rules:Name(page.selected)), text)
    end

    local function applyImport(data, parentID)
        local ok, result = ns.RulesExport.Apply(rules, deps.customSources, data, parentID, deps.compile)
        if not ok then
            say(tostring(result))
            refresh()
            return
        end
        page.selected = result.groupID or page.selected
        refresh()
        say(string.format("Imported %d groups and %d items", result.groups, result.items))
    end

    local function onImportText(text)
        local data, message = ns.RulesExport.Parse(text)
        if not data then
            say(tostring(message))
            return
        end
        local parentID = page.selected
        local summary, previewMessage = ns.RulesExport.Preview(rules, deps.customSources, data, parentID)
        if not summary then
            say(tostring(previewMessage))
            return
        end
        say("")
        Kit.Confirm(IMPORT_CONFIRM, describePreview(tostring(rules:Name(parentID)), summary), function()
            applyImport(data, parentID)
        end)
    end

    local function onImport()
        if not deps.customSources then
            say("import is not available")
            return
        end
        say("")
        page.importDialog = Kit.EditorDialog(IMPORT_DIALOG, {
            help = "Paste an export text. It is imported below the selected group.",
        })
        page.importDialog:Open("Import below " .. tostring(rules:Name(page.selected)), "", onImportText)
    end

    page.newButton = Kit.Button(content, "New group", 78, onNew)
    place(page.newButton, 0, 364)
    page.newRootButton = Kit.Button(content, "New root", 78, onNewRoot)
    page.newRootButton:SetPoint("LEFT", page.newButton, "RIGHT", gap, 0)
    Kit.Tooltip(page.newRootButton, "New root group", { "Makes a top-level group, whatever group is selected." })
    page.importButton = Kit.Button(content, "Import", 78, onImport)
    page.importButton:SetPoint("LEFT", page.newRootButton, "RIGHT", gap, 0)

    -- Right-click menu of a tree row. Rename uses the text of the name box.
    function onRightClick(id, row)
        page.tree:Select(id)
        local locked = id == BASE_ID or not editable()
        page.menu = Kit.ContextMenu(row, {
            { text = "Rename", onClick = onRename, disabled = locked },
            { text = "Delete", onClick = onDelete, disabled = locked },
            { text = "Export", onClick = onExport, disabled = deps.customSources == nil },
        }, { title = tostring(rules:Name(id)) })
    end

    -- Header and top tabs.

    page.header = Kit.Label(content, "", "title")
    place(page.header, RIGHT, 0)

    local right = CreateFrame("Frame", nil, content)
    right:SetSize(516, 400)
    place(right, RIGHT, TAB_Y)
    local flavour = ns.Flavour or {}
    page.topTabs = Kit.CreateTopTabs(right, {
        { key = "rules", title = "Rules" },
        { key = "items", title = "Items" },
    }, {
        template = flavour.topTabTemplate,
        tabPadding = flavour.topTabPadding,
        minTabWidth = flavour.topTabMinWidth,
        onSelect = function(key)
            page.tab = key
        end,
    })
    function page.SelectTab(name)
        page.topTabs:Select(name)
    end
    page.rulesPanel = page.topTabs:GetContent("rules")
    page.itemsPanel = page.topTabs:GetContent("items")

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

    page.rulesInset = Kit.Inset(page.rulesPanel)
    page.rulesInset:SetPoint("TOPLEFT", page.rulesPanel, "TOPLEFT", 0, 0)
    page.rulesInset:SetPoint("TOPRIGHT", page.rulesPanel, "TOPRIGHT", 0, 0)
    page.rulesInset:SetHeight(146)
    local rulesBox = page.rulesInset

    for position, opType in ipairs(ns.OperationSchema.TYPES) do
        local y = 6 + (position - 1) * 44
        local row = {}
        row.label = Kit.Label(rulesBox, TYPE_LABELS[opType] or opType, "highlight")
        placeIn(rulesBox, row.label, 10, y + 4)
        row.dropdown = Kit.Dropdown(rulesBox, 200, {
            items = { { value = INHERIT, text = "(inherit)" } },
            value = INHERIT,
            onChange = function(value)
                onOperation(opType, value)
            end,
        })
        placeIn(rulesBox, row.dropdown, 90, y)
        row.using = Kit.Label(rulesBox, "", "small")
        placeIn(rulesBox, row.using, 96, y + 24)
        page.opRows[opType] = row
    end

    -- Items tab: the add box and its buttons, then the items of the group.

    local itemsPanel = page.itemsPanel

    local function onRemove(key)
        local ok, message = rules:RemoveItem(key)
        report(ok, message)
        refresh()
    end

    page.addInput = Kit.Input(itemsPanel, 250, function()
        page.Submit()
    end, nil, { placeholder = "Item name, link or id" })
    placeIn(itemsPanel, page.addInput, 6, 0)
    page.addButton = Kit.Button(itemsPanel, "Add", 60, function()
        page.Submit()
    end)
    page.addButton:SetPoint("LEFT", page.addInput, "RIGHT", gap, 0)
    page.bagsButton = Kit.Button(itemsPanel, "Add from bags", 110, nil)
    page.bagsButton:SetPoint("LEFT", page.addButton, "RIGHT", gap, 0)

    page.itemsLabel = Kit.Label(itemsPanel, "Items", "highlight")
    placeIn(itemsPanel, page.itemsLabel, 0, 28)

    page.itemList = Kit.CreateList(itemsPanel, {
        inset = true,
        initRow = function(row, key)
            if not row.nameText then
                row.nameText = Kit.Label(row, "", "normal")
                row.nameText:SetPoint("LEFT", row, "LEFT", 6, 0)
                row.nameText:SetWidth(430)
                row.nameText:SetJustifyH("LEFT")
                row.removeButton = Kit.IconButton(row, "close", nil, "Remove from group")
                row.removeButton:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            end
            local text, quality = itemName(key)
            row.nameText:SetText(text)
            setQualityColor(row.nameText, quality)
            row.removeButton:SetEnabled(editable())
            row.removeButton:SetScript("OnClick", function()
                onRemove(key)
            end)
        end,
    })
    placeIn(itemsPanel, page.itemList.frame, 0, LIST_Y)
    page.itemList.frame:SetPoint("BOTTOMRIGHT", itemsPanel, "BOTTOMRIGHT", 0, 0)

    -- Add from bags. The bag list takes the place of the item list.

    local bagPanel = CreateFrame("Frame", nil, itemsPanel)
    placeIn(itemsPanel, bagPanel, 0, LIST_Y)
    bagPanel:SetPoint("BOTTOMRIGHT", itemsPanel, "BOTTOMRIGHT", 0, 0)
    bagPanel:Hide()
    page.bagPanel = bagPanel

    local function showBags(shown)
        bagPanel:SetShown(shown)
        page.itemList.frame:SetShown(not shown)
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
            say(text)
        end
        refresh()
        return ok ~= nil
    end

    page.bagList = Kit.CreateList(bagPanel, {
        inset = true,
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
            say("Select items first")
            return
        end
        local added, message = rules:AddItems(keys, page.selected)
        if report(added, message) then
            say("Added " .. added .. " items")
            showBags(false)
        end
        refresh()
    end)
    page.addSelectedButton:SetPoint("LEFT", page.selectAllButton, "RIGHT", gap, 0)

    page.bagsButton:SetScript("OnClick", function()
        showBags(false)
        local entries = deps.readBags and deps.readBags() or {}
        if #entries == 0 then
            say("No items found in bags")
            return
        end
        say("")
        page.bagEntries, page.bagSelected = entries, {}
        page.bagList:SetData(entries)
        showBags(true)
    end)

    -- The results window. The list stays until the next search.

    local function inGroupKeys()
        local exclude = {}
        for _, key in ipairs(rules:ItemsIn(page.selected)) do
            exclude[key] = true
        end
        return exclude
    end

    local function onAHResults(items, err)
        if not items then
            say(tostring(err or ""))
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
        say(added .. " items found in the Auction House")
    end

    local popup = Kit.CreateWindow(RESULTS_WINDOW, { width = 460, height = 420 })
    popup:SetFrameStrata("DIALOG")
    popup:SetToplevel(true)
    page.popup = popup
    local edge = pad + 8

    page.nameList = Kit.CreateList(popup, {
        inset = true,
        initRow = function(row, match)
            if not row.nameText then
                row.nameText = Kit.Label(row, "", "normal")
                row.nameText:SetPoint("LEFT", row, "LEFT", 6, 0)
                row.nameText:SetWidth(240)
                row.nameText:SetJustifyH("LEFT")
                row.sourceText = Kit.Label(row, "", "small")
                row.sourceText:SetPoint("LEFT", row, "LEFT", 252, 0)
                row.addButton = Kit.Button(row, "Add", 60, nil)
                row.addButton:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            end
            local inGroup = page.selected ~= BASE_ID and rules:GroupOf(match.key) == page.selected
            local text = match.name or match.key
            if match.key ~= string.format("%d", match.itemID or 0) then
                text = text .. " (" .. match.key .. ")"
            end
            row.nameText:SetText(text)
            setQualityColor(row.nameText, qualityOf(match.itemID))
            row.sourceText:SetText(SOURCE_LABELS[match.source] or "")
            row.addButton:SetText(inGroup and "Added" or "Add")
            row.addButton:SetEnabled(editable() and page.selected ~= BASE_ID and not inGroup)
            row.addButton:SetScript("OnClick", function()
                addKey(match.key)
            end)
        end,
    })
    page.nameList.frame:SetPoint("TOPLEFT", popup, "TOPLEFT", edge, -40)
    page.nameList.frame:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -edge, 124)

    popup.status = Kit.Label(popup, "", "small")
    popup.status:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", edge, 102)
    popup.status:SetWidth(460 - 2 * edge)
    popup.status:SetJustifyH("LEFT")

    page.ahButton = Kit.Button(popup, "Search the Auction House", 190, function()
        if not deps.ahNameSearch then
            return
        end
        local query = page.query
        if not query or query.raw == "" then
            say("type a name first")
            return
        end
        say("")
        deps.ahNameSearch:Find(query.raw, onAHResults, { exact = query.exact })
    end)
    page.ahButton:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", edge, 72)
    page.ahHint = Kit.Label(popup, AH_HINT, "small")
    page.ahHint:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", edge, 44)
    page.ahHint:SetWidth(460 - 2 * edge)
    page.ahHint:SetJustifyH("LEFT")
    if not deps.ahNameSearch then
        page.ahButton:Hide()
        page.ahHint:Hide()
    end

    page.popupClose = Kit.Button(popup, CLOSE, 100, function()
        popup:Hide()
    end)
    page.popupClose:SetPoint("BOTTOM", popup, "BOTTOM", 0, pad + 4)

    -- Find the matches of a text and list them. Returns the matches and the count of names still loading.
    local function find(text)
        local matches, pending = index:Find(text, MAX_RESULTS, { exclude = inGroupKeys() })
        local note = pending > 0 and ("\n" .. pending .. " item names are still loading") or ""
        return matches, note
    end

    local function noMatch(text)
        return 'no item named "' .. ns.ItemNameIndex.ParseQuery(text).raw .. '"'
    end

    local function showResults(text, matches, note)
        local query = ns.ItemNameIndex.ParseQuery(text)
        page.query = query
        page.results = matches
        page.nameList:SetData(matches)
        if popup.SetTitle then
            popup:SetTitle(query.raw)
        end
        popup:Show()
        popup:Raise()
        if #matches == 0 then
            say(noMatch(text) .. note)
        else
            say(#matches .. " items found" .. note)
        end
    end

    -- Work out what the player typed and act on it.
    function page.Submit()
        showBags(false)
        local text = trim(page.addInput:GetText())
        if text == "" then
            say("type an item name, link or id")
            return
        end
        if page.selected == BASE_ID then
            say("select a group first")
            return
        end
        local key
        if ns.ItemString.IsItemLink(text) then
            key = deps.keyFor and deps.keyFor(text) or ns.ItemString.ToExactKey(text)
            if not key then
                say("not an item link")
                return
            end
        elseif text:match("^%d+$") then
            key = ns.ItemString.ToBaseKey(text)
            if not key then
                say("not an item id")
                return
            end
        end
        if key then
            if addKey(key) then
                page.addInput:SetText("")
            end
            return
        end
        if not index then
            say("item names are not available")
            return
        end
        local matches, note = find(text)
        if ns.ItemNameIndex.ParseQuery(text).exact then
            if #matches == 1 then
                if addKey(matches[1].key) then
                    page.addInput:SetText("")
                end
                return
            elseif #matches == 0 then
                say(noMatch(text) .. note)
                return
            end
        end
        showResults(text, matches, note)
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
        -- The roots are the top-level groups. Base stays hidden; its node "[No group]" holds the rules that
        -- every group and every item of no group inherits.
        local roots = {}
        for _, childID in ipairs(rules:Children(BASE_ID)) do
            roots[#roots + 1] = nodeFor(childID)
        end
        roots[#roots + 1] = { id = BASE_ID, text = NO_GROUP_TEXT, children = {} }
        page.tree:SetNodes(roots)
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
        -- Base is hidden: the path starts below it, and the Base node reads "[No group]".
        local names = {}
        for position, name in ipairs(rules:Path(id) or {}) do
            if position > 1 then
                names[#names + 1] = name
            end
        end
        page.header:SetText(isBase and NO_GROUP_TEXT or table.concat(names, " > "))

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
        setEnabled(page.newRootButton, canEdit)
        setEnabled(page.importButton, canShare and canEdit)
        setEnabled(page.bagsButton, canAdd)
        setEnabled(page.addInput, canAdd)
        setEnabled(page.addButton, canAdd)
        setEnabled(page.ahButton, canAdd)
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
            if type(link) == "string" and page.addInput:HasFocus() then
                page.addInput:SetText(link)
                page.Submit()
            end
        end)
    end

    refresh()
    return page
end
