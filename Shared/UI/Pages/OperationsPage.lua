local _, ns = ...

-- The operations page of the Flipside window.

local OperationsPage = {}
ns.OperationsPage = OperationsPage

local LEFT_WIDTH = 250
local RIGHT_X = 260
local RIGHT_WIDTH = 510
local FIELD_ROW = 72
local DELETE_DIALOG = "FLIPSIDE_DELETE_OPERATION"
local EDITOR_DIALOG = "FlipsideFormulaEditor"
local EDITOR_HELP = "Missing prices are invalid, never 0. Functions: min max avg first check ifgt iflt ifeq round."

local function trim(text)
    return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

local function isItem(text)
    return text:match("^%d+$") or (text:match("^|[cH]") and text:find("|Hitem:", 1, true))
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
-- deps: rules, formulaRun, itemNameIndex, itemCache, subscribe(fn) (all optional except rules).
function OperationsPage.Build(content, deps)
    local Kit, Schema = ns.Kit, ns.OperationSchema
    local rules, run, index = deps.rules, deps.formulaRun, deps.itemNameIndex
    local gap = Kit.Theme.gap
    local page = {}
    local selected, filter, newType, example

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
        local lines
        if example then
            local copper, info = run:Evaluate(formula, example)
            lines = ns.FormulaPage.Describe(copper, info, nil, formula)
            if copper ~= nil then
                lines[1] = ns.TooltipLines.FormatMoney(copper)
            end
        else
            local compiled, err = run:Compile(formula)
            local info = compiled and { kind = "compiled", names = compiled.names, later = compiled.later }
            lines = ns.FormulaPage.Describe(nil, info, err, formula)
        end
        return table.concat(lines, " - ")
    end

    -- Field rows.

    local commit

    local function updatePart(part)
        local field, value, ro = part.field, stored(part.field.key), rules:IsReadOnly()
        local kind = field.kind
        if kind == "formula" then
            part.input:SetText(value or "")
            part.preview:SetText(previewText(value or ""))
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
            part.label:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -2)
            part.message:SetPoint("TOPLEFT", row, "TOPLEFT", 200, -2)
            local function save(text)
                text = trim(text)
                if text ~= stored(field.key) then
                    commit(part, text)
                end
            end
            part.input = tipOn(add(Kit.Input(row, 440, save, save)))
            part.input:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -18)
            part.expand = add(Kit.Button(row, "...", 30, function()
                local dialog = Kit.EditorDialog(EDITOR_DIALOG, { help = EDITOR_HELP })
                dialog:Open(field.label, stored(field.key) or "", function(text)
                    save((text:gsub("[\r\n]+", " ")))
                end)
            end))
            part.expand:SetPoint("TOPLEFT", row, "TOPLEFT", 454, -18)
            part.preview = add(Kit.Label(row, "", "small"))
            part.preview:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -40)
            part.preview:SetWidth(RIGHT_WIDTH - 40)
            part.preview:SetJustifyH("LEFT")
            return part
        end
        part.label:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -6)
        part.message:SetPoint("TOPLEFT", row, "TOPLEFT", 176, -30)
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
                end
            end
            part.input = tipOn(add(Kit.Input(row, 220, save, save)))
            part.input:SetPoint("TOPLEFT", row, "TOPLEFT", 176, -4)
        elseif kind == "choice" then
            local items = {}
            for _, choice in ipairs(field.choices) do
                items[#items + 1] = { value = choice.value, text = choice.label }
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
    newType = Schema.TYPES[1]

    local refresh

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
            row:SetScript("OnClick", function()
                selected = data.id
                refresh()
            end)
        end,
    })
    page.list.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(22 + gap))
    page.list.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMLEFT", LEFT_WIDTH, 112)

    page.status = Kit.Label(content, "", "bad")
    page.status:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 86)
    page.status:SetWidth(LEFT_WIDTH)
    page.status:SetJustifyH("LEFT")

    page.newType = Kit.Dropdown(content, 110, {
        items = typeItems,
        value = newType,
        onChange = function(value)
            newType = value
        end,
    })
    page.newType:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 58)
    page.nameInput = Kit.Input(content, 124, nil, nil, { placeholder = "<operation name>" })
    page.nameInput:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 122, 58)

    local function typedName()
        local name = trim(page.nameInput:GetText())
        if name == "" then
            page.status:SetText("Type a name first.")
            return nil
        end
        return name
    end

    -- Runs a store call that gives an id. Selects that id on success.
    local function finish(id, message)
        if id == nil then
            page.status:SetText(tostring(message))
            return
        end
        page.status:SetText("")
        page.nameInput:SetText("")
        selected = id
        local op = rules:GetOperation(id)
        if op and filter and op.type ~= filter then
            filter = op.type
            page.filter:SetValue(filter)
        end
        refresh()
    end

    page.newButton = Kit.Button(content, "New", 120, function()
        local name = typedName()
        if name then
            finish(rules:CreateOperation(newType, name))
        end
    end)
    page.newButton:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 30)
    page.duplicateButton = Kit.Button(content, "Duplicate", 120, function()
        local name = selected and typedName()
        if name then
            finish(rules:DuplicateOperation(selected, name))
        end
    end)
    page.duplicateButton:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 126, 30)
    page.renameButton = Kit.Button(content, "Rename", 120, function()
        local name = selected and typedName()
        if name then
            local ok, message = rules:RenameOperation(selected, name)
            finish(ok and selected or nil, message)
        end
    end)
    page.renameButton:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 4)
    page.deleteButton = Kit.Button(content, "Delete", 120, function()
        local op = selected and rules:GetOperation(selected)
        if not op then
            return
        end
        local id = selected
        local used = rules:GroupsUsing(id)
        local text = string.format('Delete the operation "%s" (%s)? %s.', op.name, Schema.TypeLabel(op.type),
            #used == 0 and "No group uses it" or ("It is used by " .. plural(#used, "group")))
        Kit.Confirm(DELETE_DIALOG, text, function()
            local ok, message = rules:DeleteOperation(id)
            if ok == nil then
                page.status:SetText(tostring(message))
                return
            end
            if selected == id then
                selected = nil
            end
            page.status:SetText("")
            refresh()
        end)
    end)
    page.deleteButton:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 126, 4)

    -- Right side.

    local right = CreateFrame("Frame", nil, content)
    right:SetSize(RIGHT_WIDTH, 468)
    right:SetPoint("TOPLEFT", content, "TOPLEFT", RIGHT_X, 0)
    page.right = right

    page.header = Kit.Label(right, "", "title")
    page.header:SetPoint("TOPLEFT", right, "TOPLEFT", 0, 0)
    page.readOnly = Kit.Label(right, "Settings are read-only", "bad")
    page.readOnly:SetPoint("TOPRIGHT", right, "TOPRIGHT", 0, -4)

    page.exampleLabel = Kit.Label(right, index and "Example item (name, link or id)" or "Example item (link or id)",
        "highlight")
    page.exampleLabel:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -28)
    page.exampleStatus = Kit.Label(right, "", "small")
    page.exampleStatus:SetPoint("TOPLEFT", right, "TOPLEFT", 190, -50)
    page.exampleStatus:SetWidth(RIGHT_WIDTH - 190)
    page.exampleStatus:SetJustifyH("LEFT")

    -- Sets example from the item box. An unclear item gives no example and a message.
    local function resolveExample()
        local text = trim(page.exampleInput:GetText())
        local message = ""
        example = nil
        if text == "" then
            page.exampleStatus:SetText("")
            return
        end
        if isItem(text) then
            example = text
        elseif not index then
            message = "not an item: " .. text
        else
            local result = index:Resolve(text)
            if result.kind == "error" then
                message = result.message
            elseif result.kind == "item" then
                example = text
            else
                local matches = result.matches
                if #matches == 1 then
                    example = ns.ItemNameIndex.ToInput(matches[1].key)
                elseif #matches == 0 then
                    message = 'no item named "' .. text .. '" in the scan data'
                else
                    message = #matches .. " items match, type more of the name"
                end
                if result.pendingCount > 0 then
                    message = message .. (message ~= "" and " - " or "") .. result.pendingCount
                        .. " item names are still loading"
                end
            end
        end
        page.exampleStatus:SetText(message)
    end

    local function onExample()
        resolveExample()
        refresh(true)
    end
    page.exampleInput = Kit.Input(right, 180, onExample, onExample, { placeholder = "Item name, link or id" })
    page.exampleInput:SetPoint("TOPLEFT", page.exampleLabel, "BOTTOMLEFT", 6, -2)

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
    page.fieldList.frame:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -(76 + gap))
    page.fieldList.frame:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", 0, 40)

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
        page.fieldList:SetData(op and Schema.Fields(op.type) or {})
        page.footer:SetText(op and footerText(selected) or "")
        page.readOnly:SetShown(ro)
        for _, button in ipairs({ page.newButton, page.duplicateButton, page.renameButton, page.deleteButton }) do
            setEnabled(button, not ro)
        end
        setEnabled(page.nameInput, not ro)
        setEnabled(page.newType, not ro)
    end

    -- Public refresh: reads the example item again, then redraws.
    function page.Refresh()
        resolveExample()
        refresh()
    end

    -- Returns the part of the field row that shows the field key, or nil.
    function page.FieldPart(key)
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

    local hook, insertLink = _G.hooksecurefunc, _G.ChatEdit_InsertLink
    if hook and insertLink then
        hook("ChatEdit_InsertLink", function(link)
            if type(link) == "string" and page.exampleInput:HasFocus() then
                page.exampleInput:SetText(link)
            end
        end)
    end
    refresh()
    return page
end
