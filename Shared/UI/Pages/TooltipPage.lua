local _, ns = ...

-- The tooltip page of the Flipside window.

local TooltipPage = {}
ns.TooltipPage = TooltipPage

local LEFT_WIDTH = 300
local RIGHT_X = 312
local RIGHT_WIDTH = 460
local GRID_COLUMNS, GRID_ROWS = 3, 4
local GRID_BASE_WIDTH = math.floor(RIGHT_WIDTH / GRID_COLUMNS)
local GRID_ROW_HEIGHT, GRID_WRAP_ROW_HEIGHT = 24, 32
local GRID_BOX, GRID_GAP, GRID_PAD = 26, 4, 8
local GRID_BOTTOM = 32
local REMOVE_DIALOG = "FLIPSIDE_REMOVE_TOOLTIP_LINE"
local RESET_DIALOG = "FLIPSIDE_RESET_TOOLTIP"
local EDITOR_DIALOG = "FlipsideFormulaEditor"
local EDITOR_HELP = "Missing prices are invalid, never 0. Functions: min max avg first check ifgt iflt ifeq round."
local NEW_LABEL, NEW_FORMULA = "New line", "scanmarket"
local READ_ONLY = "Settings are read-only"
local ALT_HINT = "Hold Alt over an item to see the value of the whole stack."

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

local DEFAULT_COLOR = { 1, 1, 1 }

-- Opens the client colour picker. Forever has ColorPickerFrame:SetupColorPickerAndShow(info); an older client
-- (TBC) takes the func and cancelFunc fields. onChange(r, g, b) runs on each change; onCancel(r, g, b) gives
-- the old colour back. Returns false if the client has no picker.
local function showColorPicker(color, onChange, onCancel)
    local picker = _G.ColorPickerFrame
    if type(picker) ~= "table" then
        return false
    end
    local function cancel(previous)
        previous = type(previous) == "table" and previous or {}
        onCancel(previous.r or previous[1] or color[1], previous.g or previous[2] or color[2],
            previous.b or previous[3] or color[3])
    end
    if type(picker.SetupColorPickerAndShow) == "function" then
        picker:SetupColorPickerAndShow({
            r = color[1], g = color[2], b = color[3],
            swatchFunc = function()
                onChange(picker:GetColorRGB())
            end,
            cancelFunc = cancel,
        })
        return true
    end
    picker.func = function()
        onChange(picker:GetColorRGB())
    end
    picker.cancelFunc = cancel
    picker.hasOpacity = false
    picker.opacityFunc = nil
    picker.previousValues = { color[1], color[2], color[3] }
    picker:SetColorRGB(color[1], color[2], color[3])
    picker:Hide()
    picker:Show()
    return true
end

local function findLine(data, id)
    for _, line in ipairs(data.lines) do
        if line.id == id then
            return line
        end
    end
end

-- Build the page in the content frame.
-- deps: tooltipConfig, formulaRun, itemNameIndex, rules, holdings, getRecord(key), subscribe(fn),
-- buildPreview(input, config) (the last four are optional). buildPreview gives rows like TooltipLines.Build.
function TooltipPage.Build(content, deps)
    local Kit = ns.Kit
    local tc, run, index = deps.tooltipConfig, deps.formulaRun, deps.itemNameIndex
    local page = {}
    local selected, example
    local refresh

    local function lineOf(id)
        return id and findLine(tc:Get(), id)
    end

    -- Left side.

    page.list = Kit.CreateList(content, {
        inset = true,
        initRow = function(row, data)
            row.data = data
            if not row.nameText then
                row.nameText = Kit.Label(row, "", "normal")
                row.nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
                row.nameText:SetWidth(90)
                row.nameText:SetJustifyH("LEFT")
                row.formulaText = Kit.Label(row, "", "disabled")
                row.formulaText:SetPoint("LEFT", row, "LEFT", 98, 0)
                row.formulaText:SetWidth(100)
                row.formulaText:SetJustifyH("LEFT")
                row.enabledCheck = Kit.Check(row, "", function(checked)
                    local ok, message = tc:UpdateLine(row.data.id, { enabled = checked })
                    refresh()
                    if not ok then
                        page.status:SetText(tostring(message))
                    end
                end)
                row.enabledCheck:SetSize(22, 22)
                row.enabledCheck:SetPoint("RIGHT", row, "RIGHT", -28, 0)
                row.removeButton = Kit.IconButton(row, "close", function()
                    local line = row.data
                    local id = line.id
                    Kit.Confirm(REMOVE_DIALOG, string.format('Remove the line "%s"?', line.label), function()
                        local ok, message = tc:RemoveLine(id)
                        refresh()
                        if not ok then
                            page.status:SetText(tostring(message))
                        end
                    end)
                end, "Remove line")
                row.removeButton:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            end
            row.nameText:SetText(data.label)
            row.nameText:SetFontObject(Kit.Font(data.id == selected and "highlight" or "normal"))
            row.formulaText:SetText(data.kind == "table" and "Min Avg Max Market" or data.formula)
            row.enabledCheck:SetChecked(data.enabled)
            local ro = tc:IsReadOnly()
            setEnabled(row.enabledCheck, not ro)
            setEnabled(row.removeButton, not ro and data.kind ~= "table")
            row:SetScript("OnClick", function()
                page.labelMessage:SetText("")
                page.formulaMessage:SetText("")
                page.Select(row.data.id)
            end)
        end,
    })
    page.list.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    page.list.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMLEFT", LEFT_WIDTH, 84)

    page.status = Kit.Label(content, "", "bad")
    page.status:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 62)
    page.status:SetWidth(LEFT_WIDTH)
    page.status:SetJustifyH("LEFT")

    local function change(fn, ...)
        local ok, message = fn(tc, ...)
        refresh()
        page.status:SetText(ok and "" or tostring(message))
        return ok
    end

    page.addButton = Kit.Button(content, "Add line", 96, function()
        if change(tc.AddLine, NEW_LABEL, NEW_FORMULA) then
            local lines = tc:Get().lines
            selected = lines[#lines].id
            refresh()
        end
    end)
    page.addButton:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 34)
    page.upButton = Kit.Button(content, "Move up", 96, function()
        if selected then
            change(tc.MoveLine, selected, -1)
        end
    end)
    page.upButton:SetPoint("LEFT", page.addButton, "RIGHT", 4, 0)
    page.downButton = Kit.Button(content, "Move down", 96, function()
        if selected then
            change(tc.MoveLine, selected, 1)
        end
    end)
    page.downButton:SetPoint("LEFT", page.upButton, "RIGHT", 4, 0)
    page.resetButton = Kit.Button(content, "Reset to defaults", 140, function()
        Kit.Confirm(RESET_DIALOG, "Reset the tooltip lines to the defaults?", function()
            change(tc.ResetDefaults)
        end)
    end)
    page.resetButton:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 8)

    -- Right side.

    local right = CreateFrame("Frame", nil, content)
    right:SetSize(RIGHT_WIDTH, 380)
    right:SetPoint("TOPLEFT", content, "TOPLEFT", RIGHT_X, 0)
    page.right = right

    page.header = Kit.Label(right, "", "title")
    page.header:SetPoint("TOPLEFT", right, "TOPLEFT", 0, 0)
    page.readOnly = Kit.Label(right, READ_ONLY, "bad")
    page.readOnly:SetPoint("TOPRIGHT", right, "TOPRIGHT", 0, -4)

    local function field(labelText, y)
        local label = Kit.Label(right, labelText, "highlight")
        label:SetPoint("TOPLEFT", right, "TOPLEFT", 0, y)
        local message = Kit.Label(right, "", "bad")
        message:SetPoint("TOPLEFT", right, "TOPLEFT", 120, y)
        message:SetWidth(RIGHT_WIDTH - 120)
        message:SetJustifyH("LEFT")
        return message
    end

    -- Saves one field. On a refusal the message shows and the box gets the stored value back.
    local function save(key, value, message, lineID)
        local id = lineID or selected
        if not id then
            return
        end
        local ok, err = tc:UpdateLine(id, { [key] = value })
        refresh()
        message:SetText(ok and "" or tostring(err))
    end

    page.labelMessage = field("Label", -30)
    page.labelInput = Kit.Input(right, 240, nil, nil, { placeholder = "<line label>" })
    page.labelInput:SetPoint("TOPLEFT", right, "TOPLEFT", 6, -48)
    local function saveLabel(text)
        local line = lineOf(selected)
        if line and trim(text) ~= line.label then
            save("label", trim(text), page.labelMessage)
        end
    end
    page.labelInput:SetScript("OnEnterPressed", function(self)
        saveLabel(self:GetText())
        self:ClearFocus()
    end)
    page.labelInput:SetScript("OnEditFocusLost", function(self)
        saveLabel(self:GetText())
    end)

    -- The colour swatch opens the client colour picker. The old colour comes back on Cancel.
    page.colorSwatch = CreateFrame("Button", nil, right)
    page.colorSwatch:SetSize(22, 22)
    page.colorSwatch:SetPoint("TOPLEFT", right, "TOPLEFT", 256, -46)
    page.colorBorder = page.colorSwatch:CreateTexture(nil, "BACKGROUND")
    page.colorBorder:SetAllPoints(page.colorSwatch)
    page.colorBorder:SetColorTexture(0.8, 0.8, 0.8, 1)
    page.colorTexture = page.colorSwatch:CreateTexture(nil, "ARTWORK")
    page.colorTexture:SetPoint("TOPLEFT", page.colorSwatch, "TOPLEFT", 2, -2)
    page.colorTexture:SetPoint("BOTTOMRIGHT", page.colorSwatch, "BOTTOMRIGHT", -2, 2)
    page.colorTexture:SetColorTexture(DEFAULT_COLOR[1], DEFAULT_COLOR[2], DEFAULT_COLOR[3], 1)
    page.colorSwatch:SetScript("OnClick", function()
        local id = selected
        local line = lineOf(id)
        if not line or line.kind == "table" or tc:IsReadOnly() then
            return
        end
        local old = line.color
        local show = deps.showColorPicker or showColorPicker
        show(old or DEFAULT_COLOR, function(r, g, b)
            save("color", { r, g, b }, page.status, id)
        end, function()
            save("color", old or false, page.status, id)
        end)
    end)
    page.colorReset = Kit.Button(right, "Default colour", 110, function()
        save("color", false, page.status)
    end)
    page.colorReset:SetPoint("LEFT", page.colorSwatch, "RIGHT", 8, 0)

    page.formulaMessage = field("Formula", -78)
    page.formulaInput = Kit.Input(right, 380, nil, nil)
    page.formulaInput:SetPoint("TOPLEFT", right, "TOPLEFT", 6, -96)
    local function saveFormula(text)
        local line = lineOf(selected)
        if line and trim(text) ~= line.formula then
            save("formula", trim(text), page.formulaMessage)
        end
    end
    page.formulaInput:SetScript("OnEnterPressed", function(self)
        saveFormula(self:GetText())
        self:ClearFocus()
    end)
    page.formulaInput:SetScript("OnEditFocusLost", function(self)
        saveFormula(self:GetText())
    end)
    page.expandButton = Kit.Button(right, "...", 30, function()
        local line = lineOf(selected)
        if not line then
            return
        end
        local dialog = Kit.EditorDialog(EDITOR_DIALOG, { help = EDITOR_HELP })
        dialog:Open(line.label, line.formula, function(text)
            saveFormula((text:gsub("[\r\n]+", " ")))
        end)
    end)
    page.expandButton:SetPoint("LEFT", page.formulaInput, "RIGHT", 6, 0)

    page.ageCheck = Kit.Check(right, "Show age", function(checked)
        save("showAge", checked, page.status)
    end)
    page.ageCheck:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -124)
    page.samplesCheck = Kit.Check(right, "Show days with data", function(checked)
        save("showSamples", checked, page.status)
    end)
    page.samplesCheck:SetPoint("TOPLEFT", right, "TOPLEFT", 160, -124)
    page.altCheck = Kit.Check(right, "Hold Alt for stack value", function(checked)
        save("altStack", checked, page.status)
    end)
    page.altCheck:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -142)

    -- Preview.

    page.previewLabel = Kit.Label(right, "Preview", "highlight")
    page.previewLabel:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -164)
    page.exampleInput = Kit.Input(right, 240, nil, nil, { placeholder = "Item name, link or id" })
    page.exampleInput:SetPoint("TOPLEFT", right, "TOPLEFT", 6, -182)
    page.exampleStatus = Kit.Label(right, "", "small")
    page.exampleStatus:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -206)
    page.exampleStatus:SetWidth(RIGHT_WIDTH)
    page.exampleStatus:SetJustifyH("LEFT")
    page.preview = Kit.Label(right, "", "normal")
    page.preview:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -226)
    page.preview:SetWidth(RIGHT_WIDTH)
    page.preview:SetJustifyH("LEFT")

    -- The table preview draws the same model as the tooltip, under the preview text.
    page.tableView = ns.TooltipTable and ns.TooltipTable.New(right)
    local TABLE_ROW_HEIGHT = 16

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
        refresh()
    end
    page.exampleInput:SetScript("OnEnterPressed", function(self)
        onExample()
        self:ClearFocus()
    end)
    page.exampleInput:SetScript("OnEditFocusLost", onExample)

    local function rowText(row)
        if row.kind == "table" then
            local texts = { row.header, "  " .. table.concat(row.columns, "  ") }
            for _, tableRow in ipairs(row.rows) do
                texts[#texts + 1] = "  " .. tableRow.label .. "  " .. table.concat(tableRow.cells, "  ")
            end
            return table.concat(texts, "\n")
        end
        return row.left .. (row.right and ("  " .. row.right) or "")
    end

    -- Draws the table of the rows under the preview text, or hides the table.
    local function drawTable(rows)
        local model = rows and rows[1]
        if not page.tableView or not model or model.kind ~= "table" then
            if page.tableView then
                page.tableView:Clear()
            end
            return false
        end
        page.tableView:Set(model)
        page.tableView:Place(function(row)
            return page.preview, -18 - (row - 1) * TABLE_ROW_HEIGHT
        end)
        return model.header
    end

    -- Returns the preview text of the selected line.
    local function previewText(line)
        if not run then
            return "formulas are not available this session"
        end
        if line.kind == "table" and not example then
            return "Enter an item above to preview the price table."
        end
        if not example then
            local compiled, err = run:Compile(line.formula)
            local info = compiled and { kind = "compiled", names = compiled.names, later = compiled.later }
            return table.concat(ns.FormulaPage.Describe(nil, info, err, line.formula), " - ")
        end
        local one = {}
        for k, v in pairs(line) do
            one[k] = v
        end
        one.enabled = true
        local data = tc:Get()
        local config = { lines = { one }, showGroup = false, showOperation = false, showCounts = false,
            showVendor = false, periods = data.periods, stats = data.stats }
        local rows
        if deps.buildPreview then
            rows = deps.buildPreview(example, config)
        else
            rows = ns.TooltipLines.Build({
                config = config,
                input = example,
                formulaRun = run,
                rules = deps.rules,
                holdings = deps.holdings,
                getRecord = deps.getRecord,
                now = (_G.GetServerTime or _G.time)(),
            })
        end
        local header = drawTable(rows)
        if header then
            return header
        end
        local texts = {}
        for _, row in ipairs(rows or {}) do
            texts[#texts + 1] = rowText(row)
        end
        return table.concat(texts, "\n")
    end

    -- Bottom.

    -- One grid of check boxes: 3 columns of equal width, filled row by row, same row height.
    local grid = CreateFrame("Frame", nil, content)
    grid:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", RIGHT_X, GRID_BOTTOM)
    page.grid = grid
    page.gridChecks = {}

    local function gridCheck(text, onChange)
        local check = Kit.Check(grid, text, onChange)
        page.gridChecks[#page.gridChecks + 1] = check
        return check
    end

    -- Sizes the columns from the widest label and places the boxes. If 3 wide columns do not fit in
    -- the right side, the columns keep the base width and long labels wrap to 2 lines.
    local function layoutGrid()
        local widest = 0
        for _, check in ipairs(page.gridChecks) do
            if check.Text and check.Text.GetStringWidth then
                widest = math.max(widest, check.Text:GetStringWidth())
            end
        end
        local needed = GRID_BOX + GRID_GAP + widest + GRID_PAD
        local columnWidth, rowHeight = GRID_BASE_WIDTH, GRID_ROW_HEIGHT
        if needed * GRID_COLUMNS <= RIGHT_WIDTH then
            columnWidth = math.max(needed, GRID_BASE_WIDTH)
        elseif needed > columnWidth then
            rowHeight = GRID_WRAP_ROW_HEIGHT
        end
        page.gridColumnWidth, page.gridRowHeight = columnWidth, rowHeight
        grid:SetSize(GRID_COLUMNS * columnWidth, GRID_ROWS * rowHeight)
        for position, check in ipairs(page.gridChecks) do
            local column, row = (position - 1) % GRID_COLUMNS, math.floor((position - 1) / GRID_COLUMNS)
            if check.Text and check.Text.SetWidth then
                check.Text:SetWidth(columnWidth - GRID_BOX - GRID_GAP)
                if check.Text.SetJustifyH then
                    check.Text:SetJustifyH("LEFT")
                end
                if check.Text.SetWordWrap then
                    check.Text:SetWordWrap(rowHeight == GRID_WRAP_ROW_HEIGHT)
                end
            end
            check:SetPoint("TOPLEFT", grid, "TOPLEFT", column * columnWidth, -row * rowHeight)
        end
    end

    -- Calls apply(name, checked) for each name whose box differs from the stored set.
    local function choiceGroup(items, stored, apply)
        local group = { checks = {} }
        local values = {}
        for position, item in ipairs(items) do
            group.checks[position] = gridCheck(item.text, function(checked)
                values[item.value] = checked or nil
                local current = stored()
                for _, other in ipairs(items) do
                    local on = values[other.value] == true
                    if on ~= current[other.value] then
                        change(apply, other.value, on)
                    end
                end
            end)
        end
        function group.SetValues(_, set)
            values = {}
            for position, item in ipairs(items) do
                values[item.value] = (set or {})[item.value] and true or nil
                group.checks[position]:SetChecked(values[item.value] == true)
            end
        end
        function group.SetEnabled(_, enabled)
            for _, check in ipairs(group.checks) do
                check:SetEnabled(enabled)
            end
        end
        return group
    end

    local function flagCheck(text, flag)
        return gridCheck(text, function(checked)
            change(tc.SetFlag, flag, checked)
        end)
    end

    page.stats = choiceGroup({ { value = "min", text = "Min" }, { value = "avg", text = "Avg" },
        { value = "max", text = "Max" }, { value = "market", text = "Market" } },
    function()
        return tc:Get().stats
    end, tc.SetStat)
    page.periods = choiceGroup({ { value = "1d", text = "1d" }, { value = "14d", text = "14d" },
        { value = "30d", text = "30d" }, { value = "60d", text = "60d" } },
    function()
        return tc:Get().periods
    end, tc.SetPeriod)
    page.group = flagCheck("Show group", "showGroup")
    page.operation = flagCheck("Show operations", "showOperation")
    page.counts = flagCheck("Show counts per character", "showCounts")
    page.vendor = flagCheck("Vendor", "showVendor")
    layoutGrid()

    page.hint =Kit.Label(content, ALT_HINT, "small")
    page.hint:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", RIGHT_X, 6)
    page.hint:SetWidth(RIGHT_WIDTH)
    page.hint:SetJustifyH("LEFT")

    -- Redraws the list and the right side. Messages stay until the next change.
    refresh = function()
        local data = tc:Get()
        local ro = tc:IsReadOnly()
        if not findLine(data, selected) then
            selected = data.lines[1] and data.lines[1].id or nil
        end
        page.list:SetData(data.lines)
        local line = findLine(data, selected)
        page.readOnly:SetShown(ro)
        page.header:SetText(line and line.label or "No line selected")
        page.labelInput:SetText(line and line.label or "")
        page.formulaInput:SetText(line and line.formula or "")
        page.ageCheck:SetChecked(line and line.showAge)
        page.samplesCheck:SetChecked(line and line.showSamples)
        page.altCheck:SetChecked(line and line.altStack ~= false)
        local color = line and line.color or DEFAULT_COLOR
        page.colorTexture:SetColorTexture(color[1], color[2], color[3], 1)
        if page.tableView then
            page.tableView:Clear()
        end
        page.preview:SetText(line and previewText(line) or "")
        local isTable = line ~= nil and line.kind == "table"
        local active = line ~= nil and not ro and not isTable
        local moveable = line ~= nil and not ro
        for _, widget in ipairs({ page.labelInput, page.formulaInput, page.expandButton, page.ageCheck,
            page.samplesCheck }) do
            setEnabled(widget, active)
        end
        setEnabled(page.altCheck, line ~= nil and not ro)
        setEnabled(page.colorSwatch, active)
        setEnabled(page.colorReset, active and line.color ~= nil)
        setEnabled(page.addButton, not ro)
        setEnabled(page.upButton, moveable)
        setEnabled(page.downButton, moveable)
        setEnabled(page.resetButton, not ro)
        page.group:SetChecked(data.showGroup)
        page.operation:SetChecked(data.showOperation)
        page.counts:SetChecked(data.showCounts)
        page.vendor:SetChecked(data.showVendor)
        page.periods:SetValues(data.periods)
        page.stats:SetValues(data.stats)
        for _, widget in ipairs({ page.group, page.operation, page.counts, page.vendor, page.periods, page.stats }) do
            setEnabled(widget, not ro)
        end
    end

    -- Public refresh: reads the example item again, then redraws.
    function page.Refresh()
        resolveExample()
        page.status:SetText("")
        page.labelMessage:SetText("")
        page.formulaMessage:SetText("")
        refresh()
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
