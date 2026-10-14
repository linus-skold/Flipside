local _, ns = ...

-- The groups page of the Flipside window.

local GroupsPage = {}
ns.GroupsPage = GroupsPage

local BASE_ID = 1
local INHERIT = 0
local MAX_CHOICES = 5
local RIGHT = 260
local DELETE_DIALOG = "FLIPSIDE_DELETE_GROUP"
local TYPE_LABELS = { selling = "Selling", buying = "Buying", vendoring = "Vendoring" }

local function trim(text)
    return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

-- Build the page in the content frame.
-- deps: rules, itemCache, itemNameIndex, readBags(), keyFor(link) (optional), subscribe(fn) (optional).
function GroupsPage.Build(content, deps)
    local Kit = ns.Kit
    local rules, index = deps.rules, deps.itemNameIndex
    local gap = Kit.Theme.gap
    local page = { selected = BASE_ID, choices = {}, opRows = {}, bagEntries = {}, bagSelected = {} }

    local function place(frame, x, y)
        frame:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
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

    page.tree = Kit.CreateTree(content, {
        onSelect = function(node)
            page.selected = node.id
            page.RefreshPane()
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

    -- Header and operations.

    page.header = Kit.Label(content, "", "title")
    place(page.header, RIGHT, 0)

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
        local y = 26 + (position - 1) * 42
        local row = {}
        row.label = Kit.Label(content, TYPE_LABELS[opType] or opType, "highlight")
        place(row.label, RIGHT, y + 4)
        row.dropdown = Kit.Dropdown(content, 200, {
            items = { { value = INHERIT, text = "(inherit)" } },
            value = INHERIT,
            onChange = function(value)
                onOperation(opType, value)
            end,
        })
        place(row.dropdown, RIGHT + 80, y)
        row.using = Kit.Label(content, "", "small")
        place(row.using, RIGHT + 86, y + 24)
        page.opRows[opType] = row
    end

    -- Items.

    page.itemsLabel = Kit.Label(content, "Items", "highlight")
    place(page.itemsLabel, RIGHT, 154)

    local function onRemove(key)
        local ok, message = rules:RemoveItem(key)
        report(ok, message)
        refresh()
    end

    page.itemList = Kit.CreateList(content, {
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
    page.itemList.frame:SetSize(490, 80)
    place(page.itemList.frame, RIGHT, 172)

    -- Add items.

    local function hideChoices()
        for _, button in ipairs(page.choices) do
            button:Hide()
        end
    end

    local bagPanel = CreateFrame("Frame", nil, content)
    bagPanel:SetSize(490, 112)
    place(bagPanel, RIGHT, 330)
    bagPanel:Hide()
    page.bagPanel = bagPanel

    local function hidePanels()
        bagPanel:Hide()
        hideChoices()
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
        hidePanels()
        refresh()
    end

    page.bagsButton = Kit.Button(content, "Add from bags", 110, nil)
    place(page.bagsButton, RIGHT, 256)

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
            hidePanels()
        end
        refresh()
    end)
    page.addSelectedButton:SetPoint("LEFT", page.selectAllButton, "RIGHT", gap, 0)

    page.bagsButton:SetScript("OnClick", function()
        hidePanels()
        local entries = deps.readBags and deps.readBags() or {}
        if #entries == 0 then
            page.status:SetText("No items found in bags")
            return
        end
        page.status:SetText("")
        page.bagEntries, page.bagSelected = entries, {}
        page.bagList:SetData(entries)
        bagPanel:Show()
    end)

    local nameLabel = Kit.Label(content, "Add by name", "normal")
    place(nameLabel, RIGHT, 284)
    page.addNameInput = Kit.Input(content, 220, nil)
    place(page.addNameInput, RIGHT + 96, 280)

    local function onAddName()
        hidePanels()
        local text = trim(page.addNameInput:GetText())
        if not index then
            page.status:SetText("item names are not available")
            return
        end
        local matches, pending = index:Find(text, MAX_CHOICES)
        local note = pending > 0 and ("\n" .. pending .. " item names are still loading") or ""
        if #matches == 0 then
            page.status:SetText('no item named "' .. text .. '"' .. note)
        elseif #matches == 1 then
            addKey(matches[1].key)
            page.addNameInput:SetText("")
        else
            page.status:SetText(#matches .. " items match, pick one" .. note)
            for position, button in ipairs(page.choices) do
                local match = matches[position]
                if match then
                    button:SetText(string.format("%s (%s)", match.name or match.key, match.key))
                    button:SetScript("OnClick", function()
                        addKey(match.key)
                        page.addNameInput:SetText("")
                    end)
                    button:SetEnabled(editable() and page.selected ~= BASE_ID)
                    button:Show()
                else
                    button:Hide()
                end
            end
        end
    end
    page.addNameButton = Kit.Button(content, "Add", 60, onAddName)
    page.addNameButton:SetPoint("LEFT", page.addNameInput, "RIGHT", gap, 0)

    for position = 1, MAX_CHOICES do
        local button = Kit.Button(content, "", 360, nil)
        place(button, RIGHT, 330 + (position - 1) * 22)
        button:Hide()
        page.choices[position] = button
    end

    local linkLabel = Kit.Label(content, "Add by link", "normal")
    place(linkLabel, RIGHT, 310)
    page.linkInput = Kit.Input(content, 220, nil)
    place(page.linkInput, RIGHT + 96, 306)

    local function onAddLink()
        hidePanels()
        local link = trim(page.linkInput:GetText())
        local key = deps.keyFor and deps.keyFor(link) or ns.ItemString.ToExactKey(link)
        if not key then
            page.status:SetText("not an item link")
            return
        end
        addKey(key)
        page.linkInput:SetText("")
    end
    page.addLinkButton = Kit.Button(content, "Add", 60, onAddLink)
    page.addLinkButton:SetPoint("LEFT", page.linkInput, "RIGHT", gap, 0)

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
        page.itemsLabel:SetText(isBase and "Items (select a group to add items)" or "Items")

        setEnabled(page.nameInput, canEdit)
        setEnabled(page.newButton, canEdit)
        setEnabled(page.renameButton, canEdit and not isBase)
        setEnabled(page.deleteButton, canEdit and not isBase)
        page.moveDropdown:SetItems(moveTargets(id))
        page.moveDropdown:SetValue(nil)
        setEnabled(page.moveDropdown, canEdit and not isBase)
        setEnabled(page.bagsButton, canAdd)
        setEnabled(page.addNameInput, canAdd)
        setEnabled(page.addNameButton, canAdd)
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

    refresh()
    return page
end
