local _, ns = ...

-- The operations page of the Flipside window.

local OperationsPage = {}
ns.OperationsPage = OperationsPage

local LEFT_WIDTH = 250
local RIGHT_X = 260
local RIGHT_WIDTH = 510
local FIELD_ROW = 40
local CLASS_COLUMNS, CLASS_COLUMN_WIDTH, CLASS_ROW = 3, 165, 22
local CLASS_LABEL_HEIGHT = 22
local FOOTER_HEIGHT = 40
local DELETE_DIALOG = "FLIPSIDE_DELETE_OPERATION"
local NEW_PROMPT = "FlipsideNewOperationPrompt"
local RENAME_PROMPT = "FlipsideRenameOperationPrompt"
local COPY_PROMPT = "FlipsideCopyOperationPrompt"
local EDITOR_DIALOG ="FlipsideFormulaEditor"
local EDITOR_HELP = "Missing prices are invalid, never 0. Functions: min max avg first check ifgt iflt ifeq round."

local function trim(text)
    return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

local function setEnabled(widget, enabled)
    if widget and widget.SetEnabled then
        widget:SetEnabled(enabled)
    end
end

local function plural(count, word)
    return count .. " " .. word .. (count == 1 and "" or "s")
end

-- Build the page in the content frame.
-- deps: rules, formulaRun, itemCache, subscribe(fn) (all optional except rules).
function OperationsPage.Build(content, deps)
    local Kit, Schema = ns.Kit, ns.OperationSchema
    local rules, run = deps.rules, deps.formulaRun
    local gap = Kit.Theme.gap
    local page = {}
    local selected, filter

    local function stored(key)
        local op = selected and rules:GetOperation(selected)
        return op and op.settings[key]
    end

    -- Preview text of a formula.
    local function previewText(formula)
        if formula == "" then
            return "empty: no limit"
        end
        if not run then
            return "formulas are not available this session"
        end
        local compiled, err = run:Compile(formula)
        local info = compiled and { kind = "compiled", names = compiled.names, later = compiled.later }
        return table.concat(ns.FormulaPage.Describe(nil, info, err, formula), " - ")
    end

    -- Field rows.

    local commit

    local function updatePart(part)
        local field, value, ro = part.field, stored(part.field.key), rules:IsReadOnly()
        local kind = field.kind
        if kind == "formula" then
            part.input:SetText(value or "")
            -- A refusal message takes the place of the preview.
            part.preview:SetText((part.message:GetText() or "") == "" and previewText(value or "") or "")
            setEnabled(part.input, not ro)
            setEnabled(part.expand, not ro)
        elseif kind == "money" or kind == "number" then
            part.number:SetNumber(value)
            if kind == "money" then
                part.moneyText:SetText(ns.TooltipLines.FormatMoney(value or 0))
            end
            setEnabled(part.number, not ro)
        elseif kind == "text" then
            part.input:SetText(value or "")
            setEnabled(part.input, not ro)
        elseif kind == "choice" then
            part.choice:SetValue(value)
            setEnabled(part.choice, not ro)
        elseif kind == "bool" then
            part.check:SetChecked(value)
            setEnabled(part.check, not ro)
        elseif kind == "classes" then
            part.classes:SetValues(ns.MailingPlan.ParseClasses(value))
            setEnabled(part.classes, not ro)
        end
    end

    local function buildPart(row, field)
        local part = { field = field, all = {} }
        local function add(region)
            part.all[#part.all + 1] = region
            return region
        end
        local tip = { field.help }
        local function tipOn(frame)
            Kit.Tooltip(frame, field.label, tip)
            return frame
        end
        local kind = field.kind
        part.label = add(Kit.Label(row, field.label, "normal"))
        part.message = add(Kit.Label(row, "", "bad"))
        part.message:SetJustifyH("LEFT")
        if kind == "formula" then
            part.label:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -6)
            part.message:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -26)
            local function save(text)
                text = trim(text)
                if text ~= stored(field.key) then
                    commit(part, text)
                else
                    -- The old value again: clear an earlier refusal message.
                    part.message:SetText("")
                    updatePart(part)
                end
            end
            part.input = tipOn(add(Kit.Input(row, 270, save, save)))
            part.input:SetPoint("TOPLEFT", row, "TOPLEFT", 176, -4)
            part.expand = add(Kit.Button(row, "...", 30, function()
                local dialog = Kit.EditorDialog(EDITOR_DIALOG, { help = EDITOR_HELP })
                dialog:Open(field.label, stored(field.key) or "", function(text)
                    save((text:gsub("[\r\n]+", " ")))
                end)
            end))
            part.expand:SetPoint("TOPLEFT", row, "TOPLEFT", 454, -4)
            part.preview = add(Kit.Label(row, "", "small"))
            part.preview:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -26)
            part.preview:SetWidth(RIGHT_WIDTH - 40)
            part.preview:SetJustifyH("LEFT")
            if part.preview.SetMaxLines then
                part.preview:SetMaxLines(1)
            end
            return part
        end
        part.label:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -6)
        part.message:SetPoint("TOPLEFT", row, "TOPLEFT", 176, -27)
        if kind == "money" or kind == "number" then
            part.number = tipOn(add(Kit.NumberInput(row, 90, {
                min = field.min,
                max = field.max,
                onChange = function(number)
                    if number == nil then
                        number = tonumber(part.number:GetText())
                    end
                    commit(part, number)
                end,
            })))
            part.number:SetPoint("TOPLEFT", row, "TOPLEFT", 176, -4)
            if kind == "money" then
                part.moneyText = add(Kit.Label(row, "", "small"))
                part.moneyText:SetPoint("TOPLEFT", row, "TOPLEFT", 360, -8)
            end
        elseif kind == "text" then
            local function save(text)
                text = trim(text)
                if text ~= stored(field.key) then
                    commit(part, text)
                else
                    -- The old value again: clear an earlier refusal message.
                    part.message:SetText("")
                    updatePart(part)
                end
            end
            part.input = tipOn(add(Kit.Input(row, 220, save, save)))
            part.input:SetPoint("TOPLEFT", row, "TOPLEFT", 176, -4)
        elseif kind == "choice" then
            local items = {}
            for _, choice in ipairs(field.choices) do
                local text = field.quality and Kit.QualityText(choice.value, choice.label) or choice.label
                items[#items + 1] = { value = choice.value, text = text }
            end
            part.choice = tipOn(add(Kit.Dropdown(row, 160, {
                items = items,
                onChange = function(value)
                    commit(part, value)
                end,
            })))
            part.choice:SetPoint("TOPLEFT", row, "TOPLEFT", 170, -3)
        elseif kind == "bool" then
            part.check = tipOn(add(Kit.Check(row, "", function(checked)
                commit(part, checked)
            end)))
            part.check:SetPoint("TOPLEFT", row, "TOPLEFT", 170, -3)
        end
        return part
    end

    local function hidePart(part)
        for _, region in ipairs(part.all) do
            region:Hide()
        end
        if part.number then
            part.number.hint:Hide()
        end
    end

    local function showPart(row, field)
        row.parts = row.parts or {}
        if row.active and row.active.field ~= field then
            hidePart(row.active)
        end
        local part = row.parts[field]
        if not part then
            part = buildPart(row, field)
            row.parts[field] = part
        end
        for _, region in ipairs(part.all) do
            region:Show()
        end
        part.message:SetText("")
        row.active = part
        updatePart(part)
    end

    -- Saves one value. On a refusal the message shows and the widget gets the old value back.
    commit = function(part, value)
        local ok, message = rules:SetSetting(selected, part.field.key, value)
        part.message:SetText(ok and "" or tostring(message))
        updatePart(part)
    end

    -- Left side.

    local filterItems = { { value = "all", text = "All" } }
    local typeItems = {}
    for _, opType in ipairs(Schema.TYPES) do
        filterItems[#filterItems + 1] = { value = opType, text = Schema.TypeLabel(opType) }
        typeItems[#typeItems + 1] = { value = opType, text = Schema.TypeLabel(opType) }
    end

    local refresh, openMenu

    page.filter = Kit.Dropdown(content, 150, {
        items = filterItems,
        value = "all",
        onChange = function(value)
            filter = value ~= "all" and value or nil
            local op = selected and rules:GetOperation(selected)
            if op and filter and op.type ~= filter then
                selected = nil
            end
            refresh()
        end,
    })
    page.filter:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)

    page.list = Kit.CreateList(content, {
        inset = true,
        initRow = function(row, data)
            if not row.nameText then
                row.nameText = Kit.Label(row, "", "normal")
                row.nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
            end
            row.nameText:SetText(data.name .. " (" .. Schema.TypeLabel(data.type) .. ")")
            row.nameText:SetFontObject(Kit.Font(data.id == selected and "highlight" or "normal"))
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row:SetScript("OnClick", function(self, button)
                selected = data.id
                refresh()
                if button == "RightButton" then
                    openMenu(data, self)
                end
            end)
        end,
    })
    page.list.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(22 + gap))
    page.list.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMLEFT", LEFT_WIDTH, 58)

    page.status = Kit.Label(content, "", "bad")
    page.status:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 32)
    page.status:SetWidth(LEFT_WIDTH)
    page.status:SetJustifyH("LEFT")

    -- Shows a message in the bad style, or in the good style for a success.
    local function showStatus(text, good)
        page.status:SetFontObject(Kit.Font(good and "good" or "bad"))
        page.status:SetText(text)
    end

    -- Selects the operation of a store call that gave an id, and shows it. Returns the store message on a refusal.
    local function finish(id, message)
        if id == nil then
            return tostring(message)
        end
        page.status:SetText("")
        selected = id
        local op = rules:GetOperation(id)
        if op and filter and op.type ~= filter then
            filter = op.type
            page.filter:SetValue(filter)
        end
        refresh()
    end

    -- New: the prompt asks for the type first, then the name.
    page.newButton = Kit.Button(content, "New", 120, function()
        page.newPrompt = Kit.Prompt(NEW_PROMPT)
        page.newPrompt:Open({
            title = "New operation",
            choiceLabel = "Type",
            choices = typeItems,
            choice = filter or Schema.TYPES[1],
            label = "Name",
            onOK = function(name, opType)
                return finish(rules:CreateOperation(opType, name))
            end,
        })
    end)
    page.newButton:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 4)

    -- Import: the import flow of the Groups page, with Base as the parent.
    page.importButton = Kit.Button(content, "Import", 120, function()
        page.importDialog = ns.RulesImport.Open(deps, {
            parentID = 1,
            say = showStatus,
            refresh = function()
                refresh(true)
            end,
        })
    end)
    page.importButton:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 126, 4)

    local function onRename(id)
        local op = rules:GetOperation(id)
        page.renamePrompt = Kit.Prompt(RENAME_PROMPT)
        page.renamePrompt:Open({
            title = "Rename operation",
            label = "New name",
            text = op and op.name or "",
            onOK = function(name)
                local ok, message = rules:RenameOperation(id, name)
                return finish(ok and id or nil, message)
            end,
        })
    end

    local function onDuplicate(id)
        local op = rules:GetOperation(id)
        page.copyPrompt = Kit.Prompt(COPY_PROMPT)
        page.copyPrompt:Open({
            title = "Duplicate operation",
            label = "Name of the copy",
            text = op and (op.name .. " copy") or "",
            onOK = function(name)
                return finish(rules:DuplicateOperation(id, name))
            end,
        })
    end

    local function onDelete(id)
        local op = rules:GetOperation(id)
        if not op then
            return
        end
        local used = rules:GroupsUsing(id)
        local text = string.format('Delete the operation "%s" (%s)? %s.', op.name, Schema.TypeLabel(op.type),
            #used == 0 and "No group uses it" or ("It is used by " .. plural(#used, "group")))
        Kit.Confirm(DELETE_DIALOG, text, function()
            local ok, message = rules:DeleteOperation(id)
            if ok == nil then
                showStatus(tostring(message))
                return
            end
            if selected == id then
                selected = nil
            end
            page.status:SetText("")
            refresh()
        end)
    end

    -- Right-click menu of a list row.
    openMenu = function(data, row)
        local locked = rules:IsReadOnly()
        page.menu = Kit.ContextMenu(row, {
            { text = "Rename", onClick = function() onRename(data.id) end, disabled = locked },
            { text = "Duplicate", onClick = function() onDuplicate(data.id) end, disabled = locked },
            { text = "Delete", onClick = function() onDelete(data.id) end, disabled = locked },
        }, { title = data.name })
    end

    -- Right side.

    local right = CreateFrame("Frame", nil, content)
    right:SetSize(RIGHT_WIDTH, 468)
    right:SetPoint("TOPLEFT", content, "TOPLEFT", RIGHT_X, 0)
    page.right = right

    page.header = Kit.Label(right, "", "title")
    page.header:SetPoint("TOPLEFT", right, "TOPLEFT", 0, 0)
    page.readOnly = Kit.Label(right, "Settings are read-only", "bad")
    page.readOnly:SetPoint("TOPRIGHT", right, "TOPRIGHT", 0, -4)

    -- The item types of a mailing operation: check boxes in the editor, below the field list.
    local classes = {}
    if ns.MailClient and ns.MailingPlan and _G.C_Item and _G.C_Item.GetItemClassInfo then
        -- The client gives the item types, so each flavour shows its own.
        classes = ns.MailClient.ItemClasses(_G.Enum and _G.Enum.ItemClass, _G.C_Item.GetItemClassInfo)
    end
    local classesHeight = 0
    local classesPart
    if #classes > 0 then
        classesHeight = CLASS_LABEL_HEIGHT + math.ceil(#classes / CLASS_COLUMNS) * CLASS_ROW + gap
        classesPart = { all = {} }
        classesPart.label = Kit.Label(right, "", "normal")
        classesPart.label:SetPoint("BOTTOMLEFT", right, "BOTTOMLEFT", 4,
            FOOTER_HEIGHT + classesHeight - CLASS_LABEL_HEIGHT)
        classesPart.help = Kit.Label(right, "", "small")
        classesPart.help:SetPoint("LEFT", classesPart.label, "RIGHT", gap * 2, 0)
        classesPart.message = Kit.Label(right, "", "bad")
        classesPart.message:SetPoint("LEFT", classesPart.help, "RIGHT", gap, 0)
        classesPart.classes = Kit.CheckGrid(right, {
            items = classes,
            columns = CLASS_COLUMNS,
            columnWidth = CLASS_COLUMN_WIDTH,
            rowHeight = CLASS_ROW,
            onChange = function(set)
                commit(classesPart, ns.MailingPlan.FormatClasses(set))
            end,
        })
        classesPart.classes:SetPoint("BOTTOMLEFT", right, "BOTTOMLEFT", 4, FOOTER_HEIGHT + gap)
        classesPart.all = { classesPart.label, classesPart.help, classesPart.message, classesPart.classes }
    end

    local function showClasses(field)
        if not classesPart then
            return
        end
        classesPart.field = field
        for _, region in ipairs(classesPart.all) do
            region:SetShown(field ~= nil)
        end
        if field then
            classesPart.label:SetText(field.label)
            classesPart.help:SetText(field.help)
            classesPart.message:SetText("")
            updatePart(classesPart)
        end
    end

    page.footer = Kit.Label(right, "", "normal")
    page.footer:SetPoint("BOTTOMLEFT", right, "BOTTOMLEFT", 0, 0)
    page.footer:SetWidth(RIGHT_WIDTH)
    page.footer:SetJustifyH("LEFT")

    page.fieldList = Kit.CreateList(right, {
        inset = true,
        rowHeight = FIELD_ROW,
        initRow = function(row, field)
            showPart(row, field)
        end,
    })
    page.fieldList.frame:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -(28 + gap))

    local function footerText(id)
        local paths = {}
        for _, groupID in ipairs(rules:GroupsUsing(id)) do
            paths[#paths + 1] = table.concat(rules:Path(groupID) or {}, " > ")
        end
        return "Used by: " .. (#paths > 0 and table.concat(paths, ", ") or "no groups")
    end

    -- Redraws the lists and the right side. keepStatus keeps the left message.
    refresh = function(keepStatus)
        local ro = rules:IsReadOnly()
        if not keepStatus then
            page.status:SetText("")
        end
        if selected and not rules:GetOperation(selected) then
            selected = nil
        end
        page.list:SetData(rules:ListOperations(filter))
        local op = selected and rules:GetOperation(selected)
        page.header:SetText(op and (op.name .. " (" .. Schema.TypeLabel(op.type) .. ")") or "No operation selected")
        page.fieldList.frame:SetShown(op ~= nil)
        local fields, classesField = {}, nil
        for _, field in ipairs(op and Schema.Fields(op.type) or {}) do
            if field.kind == "classes" and classesPart then
                classesField = field
            elseif field.kind ~= "classes" then
                fields[#fields + 1] = field
            end
        end
        -- The list ends above the item type boxes, when the operation has them.
        page.fieldList.frame:ClearAllPoints()
        page.fieldList.frame:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -(28 + gap))
        page.fieldList.frame:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", 0,
            FOOTER_HEIGHT + (classesField and classesHeight or 0))
        page.fieldList:SetData(fields)
        showClasses(classesField)
        page.footer:SetText(op and footerText(selected) or "")
        page.readOnly:SetShown(ro)
        setEnabled(page.newButton, not ro)
        setEnabled(page.importButton, not ro and deps.customSources ~= nil)
    end

    -- Public refresh: redraws.
    function page.Refresh()
        refresh()
    end

    -- Returns the part of the field row that shows the field key, or nil.
    function page.FieldPart(key)
        if classesPart and classesPart.field and classesPart.field.key == key then
            return classesPart
        end
        for _, row in ipairs(page.fieldList.rows or {}) do
            if row:IsShown() and row.active and row.active.field.key == key then
                return row.active
            end
        end
    end

    function page.Select(id)
        selected = id
        refresh()
    end

    if deps.subscribe then
        deps.subscribe(page.Refresh)
    end

    refresh()
    return page
end
