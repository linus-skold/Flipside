local _, ns = ...

-- The Auto rules tab of the groups page (SPEC 5.2a): the ordered rule list, the rule editor and Apply now.

local AutoRulesPanel = {}
ns.AutoRulesPanel = AutoRulesPanel

local EDITOR_WINDOW = "FlipsideAutoRuleWindow"
local APPLY_DIALOG = "FLIPSIDE_AUTO_RULES_APPLY"
local PREVIEW_LINES = 15
local EDITOR_WIDTH, EDITOR_BASE_HEIGHT = 480, 326
local CLASS_COLUMNS, CLASS_COLUMN_WIDTH, CLASS_ROW = 3, 146, 22
local QUALITIES = {
    { value = 0, text = "Poor" },
    { value = 1, text = "Common" },
    { value = 2, text = "Uncommon" },
    { value = 3, text = "Rare" },
    { value = 4, text = "Epic" },
    { value = 5, text = "Legendary" },
}
local BAD_COLOR = { 1, 0.3, 0.3 }
local GOOD_COLOR = { 1, 1, 1 }

local function qualityName(value)
    return QUALITIES[value + 1] and QUALITIES[value + 1].text or tostring(value)
end

-- Build the tab in panel. page gets RefreshAuto. hooks: say(text), report(ok, message), refresh(), editable().
-- deps: rules, itemCache, readBags().
function AutoRulesPanel.Build(panel, deps, page, hooks)
    local Kit = ns.Kit
    local rules = deps.rules
    local gap, pad = Kit.Theme.gap, Kit.Theme.padding
    local state = { editing = nil }

    -- The item types of the client, so each flavour shows its own.
    local classes = {}
    if ns.MailClient and ns.MailingPlan and _G.C_Item and _G.C_Item.GetItemClassInfo then
        classes = ns.MailClient.ItemClasses(_G.Enum and _G.Enum.ItemClass, _G.C_Item.GetItemClassInfo)
    end
    local classNames = {}
    for _, class in ipairs(classes) do
        classNames[class.value] = class.text
    end

    local function groupPath(id)
        local names = {}
        for position, name in ipairs(rules:Path(id) or {}) do
            if position > 1 then
                names[#names + 1] = name
            end
        end
        return #names > 0 and table.concat(names, " > ") or nil
    end

    -- The groups that a rule can use, as drop-down items.
    local function groupItems()
        local items = {}
        rules:Walk(function(id)
            if rules:AutoRuleTarget(id) then
                items[#items + 1] = { value = id, text = groupPath(id) or tostring(id) }
            end
        end)
        return items
    end

    -- The text of the filters of a rule.
    local function filterText(rule)
        local parts = {}
        if rule.pattern ~= "" then
            parts[#parts + 1] = "/" .. rule.pattern .. "/"
        end
        if rule.minQuality > 0 or rule.maxQuality < 5 then
            if rule.minQuality == rule.maxQuality then
                parts[#parts + 1] = qualityName(rule.minQuality)
            else
                parts[#parts + 1] = qualityName(rule.minQuality) .. " to " .. qualityName(rule.maxQuality)
            end
        end
        if rule.classes ~= "" then
            local names, count = {}, 0
            for id in pairs(ns.MailingPlan.ParseClasses(rule.classes)) do
                count = count + 1
                names[#names + 1] = classNames[id] or tostring(id)
            end
            table.sort(names)
            parts[#parts + 1] = count > 2 and (count .. " types") or table.concat(names, ", ")
        end
        return #parts > 0 and table.concat(parts, "  ") or "(no filter)"
    end

    -- True if a rule can match: it has a valid filter and a group that takes items.
    local function usable(rule)
        return ns.AutoRules.Validate(rule) and rules:AutoRuleTarget(rule.group) == true
    end

    -- Editor window.

    -- The rarity names in the colour of each rarity.
    local colored = {}
    for index, quality in ipairs(QUALITIES) do
        colored[index] = { value = quality.value, text = Kit.QualityText(quality.value, quality.text) }
    end
    -- The item type boxes need room: the window grows with the number of types.
    local gridHeight = math.max(1, math.ceil(#classes / CLASS_COLUMNS)) * CLASS_ROW
    local editor = Kit.CreateWindow(EDITOR_WINDOW, {
        width = EDITOR_WIDTH,
        height = EDITOR_BASE_HEIGHT + gridHeight,
    })
    editor:SetFrameStrata("DIALOG")
    editor:SetToplevel(true)
    page.autoEditor = editor
    local edge = pad + 8
    local fieldX = edge + 110

    local function row(y, text)
        local label = Kit.Label(editor, text, "highlight")
        label:SetPoint("TOPLEFT", editor, "TOPLEFT", edge, -y)
        return label
    end

    row(40, "Name pattern (regex, ignores case)")
    editor.pattern = Kit.Input(editor, EDITOR_WIDTH - 2 * edge - 6, nil, nil, {
        placeholder = "for example ^Linen (^ = start of the name)",
    })
    editor.pattern:SetPoint("TOPLEFT", editor, "TOPLEFT", edge + 6, -78)
    editor.error = Kit.Label(editor, "", "bad")
    editor.error:SetPoint("TOPLEFT", editor, "TOPLEFT", edge, -104)
    editor.error:SetWidth(EDITOR_WIDTH - 2 * edge)
    editor.error:SetJustifyH("LEFT")

    local updateEditor

    row(140, "Lowest rarity")
    editor.minQuality = Kit.Dropdown(editor, 160, { items = colored, value = 0, onChange = function()
        updateEditor()
    end })
    editor.minQuality:SetPoint("TOPLEFT", editor, "TOPLEFT", fieldX, -136)
    row(172, "Highest rarity")
    editor.maxQuality = Kit.Dropdown(editor, 160, { items = colored, value = 5, onChange = function()
        updateEditor()
    end })
    editor.maxQuality:SetPoint("TOPLEFT", editor, "TOPLEFT", fieldX, -168)
    row(206, "Item types")
    local typesHint = Kit.Label(editor, "none chosen = any type", "small")
    typesHint:SetPoint("TOPLEFT", editor, "TOPLEFT", fieldX, -208)
    editor.classes = Kit.CheckGrid(editor, {
        items = classes,
        columns = CLASS_COLUMNS,
        columnWidth = CLASS_COLUMN_WIDTH,
        rowHeight = CLASS_ROW,
        onChange = function()
            updateEditor()
        end,
    })
    editor.classes:SetPoint("TOPLEFT", editor, "TOPLEFT", edge, -228)
    local groupY = 236 + gridHeight
    row(groupY, "Add to group")
    editor.group = Kit.Dropdown(editor, 260, { items = {}, onChange = function()
        updateEditor()
    end })
    editor.group:SetPoint("TOPLEFT", editor, "TOPLEFT", fieldX, -(groupY - 4))

    local hint = Kit.Label(editor, "Every filter that you set must match. An item in a group never moves.", "small")
    hint:SetPoint("TOPLEFT", editor, "TOPLEFT", edge, -(groupY + 30))
    hint:SetWidth(EDITOR_WIDTH - 2 * edge)
    hint:SetJustifyH("LEFT")

    local function readEditor()
        return {
            group = editor.group:GetValue(),
            pattern = editor.pattern:GetText() or "",
            minQuality = editor.minQuality:GetValue(),
            maxQuality = editor.maxQuality:GetValue(),
            classes = ns.MailingPlan.FormatClasses(editor.classes:GetValues()),
        }
    end

    -- Show the first problem of the rule in the editor and enable Save when there is none.
    function updateEditor()
        local rule = readEditor()
        local ok, message = ns.AutoRules.Validate(rule)
        local text = ok and "" or tostring(message)
        if ok and rule.pattern ~= "" and not ns.NameRegex then
            text = "Name patterns are not available yet: this rule never matches."
        elseif ok and not rule.group then
            ok, text = false, "choose a group"
        end
        editor.error:SetText(text)
        editor.saveButton:SetEnabled(ok and hooks.editable())
        return ok
    end
    editor.pattern:HookScript("OnTextChanged", function()
        updateEditor()
    end)

    editor.saveButton = Kit.Button(editor, SAVE, 100, function()
        local rule = readEditor()
        local ok, message
        if state.editing then
            ok, message = rules:UpdateAutoRule(state.editing, rule)
        else
            ok, message = rules:AddAutoRule(rule)
        end
        if ok == nil then
            editor.error:SetText(tostring(message or ""))
            return
        end
        editor:Hide()
        hooks.refresh()
    end)
    editor.saveButton:SetPoint("BOTTOM", editor, "BOTTOM", -55, pad + 4)
    editor.cancelButton = Kit.Button(editor, CANCEL, 100, function()
        editor:Hide()
    end)
    editor.cancelButton:SetPoint("BOTTOM", editor, "BOTTOM", 55, pad + 4)

    -- Open the editor for a new rule (index nil) or for the rule at index.
    function page.OpenAutoEditor(index)
        local rule = index and rules:AutoRules()[index]
        if index and not rule then
            return
        end
        state.editing = index
        rule = rule or ns.AutoRules.Normalize({})
        editor.group:SetItems(groupItems())
        editor.group:SetValue(rules:AutoRuleTarget(rule.group) and rule.group or nil)
        editor.pattern:SetText(rule.pattern)
        editor.minQuality:SetValue(rule.minQuality)
        editor.maxQuality:SetValue(rule.maxQuality)
        editor.classes:SetValues(ns.MailingPlan.ParseClasses(rule.classes))
        if editor.SetTitle then
            editor:SetTitle(index and ("Edit auto rule " .. index) or "New auto rule")
        end
        updateEditor()
        editor:Show()
        editor:Raise()
    end

    -- Top row: switch, Add rule and Apply now.

    local topY = 0
    page.autoCheck = Kit.Check(panel, "Add new bag items to groups automatically", function(checked)
        hooks.report(rules:SetAutoRulesEnabled(checked))
        hooks.refresh()
    end)
    page.autoCheck:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -topY)
    Kit.Tooltip(page.autoCheck, "Automatic mode", {
        "When your bags change, each bag item that is in no group goes to the group of the first rule that matches.",
    })

    page.autoAddButton = Kit.Button(panel, "Add rule", 90, function()
        page.OpenAutoEditor(nil)
    end)
    page.autoAddButton:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -(topY + 30))

    -- Apply now: show what the rules would add from the bags, then add it after a confirm.
    local function applyNow()
        local entries = deps.readBags and deps.readBags() or {}
        local plan, unknown = ns.AutoRules.PlanBags(rules, entries, deps.itemCache)
        if #plan == 0 then
            hooks.say(unknown > 0 and (unknown .. " items are still loading; try again in a moment")
                or "No bag item matches the rules")
            return
        end
        local lines = { string.format("Add %d items to groups?", #plan) }
        for index = 1, math.min(#plan, PREVIEW_LINES) do
            lines[#lines + 1] = string.format("%s > %s", plan[index].name, tostring(groupPath(plan[index].groupID)))
        end
        if #plan > PREVIEW_LINES then
            lines[#lines + 1] = string.format("and %d more", #plan - PREVIEW_LINES)
        end
        Kit.Confirm(APPLY_DIALOG, table.concat(lines, "\n"), function()
            local now = ns.AutoRules.PlanBags(rules, deps.readBags and deps.readBags() or {}, deps.itemCache)
            local added = ns.AutoRules.Apply(rules, now)
            hooks.refresh()
            hooks.say(string.format("Added %d items to groups", added))
        end)
    end
    page.autoApplyButton = Kit.Button(panel, "Apply now", 90, applyNow)
    page.autoApplyButton:SetPoint("LEFT", page.autoAddButton, "RIGHT", gap, 0)
    Kit.Tooltip(page.autoApplyButton, "Apply now", { "Shows what the rules add from your bags now. You confirm it." })

    local help = Kit.Label(panel, "The first rule that matches an item wins. Up and Down change the order.", "small")
    help:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -(topY + 60))

    -- The rule list.

    page.autoList = Kit.CreateList(panel, {
        inset = true,
        initRow = function(listRow, entry)
            if not listRow.text then
                listRow.text = Kit.Label(listRow, "", "normal")
                listRow.text:SetPoint("LEFT", listRow, "LEFT", 6, 0)
                listRow.text:SetWidth(270)
                listRow.text:SetJustifyH("LEFT")
                listRow.deleteButton = Kit.Button(listRow, "Delete", 52, nil)
                listRow.deleteButton:SetPoint("RIGHT", listRow, "RIGHT", -4, 0)
                listRow.editButton = Kit.Button(listRow, "Edit", 40, nil)
                listRow.editButton:SetPoint("RIGHT", listRow.deleteButton, "LEFT", -2, 0)
                listRow.downButton = Kit.Button(listRow, "Down", 44, nil)
                listRow.downButton:SetPoint("RIGHT", listRow.editButton, "LEFT", -2, 0)
                listRow.upButton = Kit.Button(listRow, "Up", 32, nil)
                listRow.upButton:SetPoint("RIGHT", listRow.downButton, "LEFT", -2, 0)
            end
            local rule, index = entry.rule, entry.index
            local target = rules:AutoRuleTarget(rule.group) and groupPath(rule.group) or nil
            local text = string.format("%d. %s  >  %s", index, filterText(rule), target or "(no group)")
            listRow.text:SetText(text)
            local color = usable(rule) and GOOD_COLOR or BAD_COLOR
            listRow.text:SetTextColor(color[1], color[2], color[3])
            local canEdit = hooks.editable()
            listRow.upButton:SetEnabled(canEdit and index > 1)
            listRow.downButton:SetEnabled(canEdit and index < entry.total)
            listRow.editButton:SetEnabled(canEdit)
            listRow.deleteButton:SetEnabled(canEdit)
            listRow.upButton:SetScript("OnClick", function()
                hooks.report(rules:MoveAutoRule(index, -1))
                hooks.refresh()
            end)
            listRow.downButton:SetScript("OnClick", function()
                hooks.report(rules:MoveAutoRule(index, 1))
                hooks.refresh()
            end)
            listRow.editButton:SetScript("OnClick", function()
                page.OpenAutoEditor(index)
            end)
            listRow.deleteButton:SetScript("OnClick", function()
                hooks.report(rules:DeleteAutoRule(index))
                hooks.refresh()
            end)
        end,
    })
    page.autoList.frame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -(topY + 80))
    page.autoList.frame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)

    function page.RefreshAuto()
        local canEdit = hooks.editable()
        local list, entries = rules:AutoRules(), {}
        for index, rule in ipairs(list) do
            entries[index] = { rule = rule, index = index, total = #list }
        end
        page.autoList:SetData(entries)
        page.autoCheck:SetChecked(rules:AutoRulesEnabled())
        page.autoCheck:SetEnabled(canEdit)
        page.autoAddButton:SetEnabled(canEdit and #list < ns.AutoRules.MAX_RULES)
        page.autoApplyButton:SetEnabled(canEdit and #list > 0)
    end
    page.ApplyAutoNow = applyNow
end
