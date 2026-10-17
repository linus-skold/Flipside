local _, ns = ...
ns.Kit = ns.Kit or {}
local Kit = ns.Kit

-- Create a button with the client button template.
function Kit.Button(parent, text, width, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width or 100, 22)
    button:SetText(text or "")
    if onClick then
        button:SetScript("OnClick", function(self, ...)
            onClick(self, ...)
        end)
    end
    return button
end

-- Create a text label. The role picks the font from the theme.
function Kit.Label(parent, text, role)
    local label = parent:CreateFontString(nil, "ARTWORK", Kit.Font(role))
    label:SetText(text or "")
    return label
end

-- Create a text box. Enter calls onEnter(text). Escape clears focus.
-- The optional onFocusLost(text) runs when the box loses focus.
-- options.placeholder is a grey text that shows while the box is empty and has no focus.
function Kit.Input(parent, width, onEnter, onFocusLost, options)
    local input = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    input:SetSize(width or 120, 20)
    input:SetAutoFocus(false)
    input:SetScript("OnEnterPressed", function(self)
        if onEnter then
            onEnter(self:GetText())
        end
        self:ClearFocus()
    end)
    input:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    if onFocusLost then
        input:SetScript("OnEditFocusLost", function(self)
            onFocusLost(self:GetText())
        end)
    end
    if options and options.placeholder then
        local hint = Kit.Label(input, options.placeholder, "disabled")
        hint:SetPoint("LEFT", input, "LEFT", 6, 0)
        input.placeholder = hint
        local focused = false
        local function update(self)
            local text = self:GetText()
            hint:SetShown(not focused and (text == nil or text == ""))
        end
        input:HookScript("OnTextChanged", update)
        input:HookScript("OnEditFocusGained", function(self)
            focused = true
            update(self)
        end)
        input:HookScript("OnEditFocusLost", function(self)
            focused = false
            update(self)
        end)
        update(input)
    end
    return input
end

-- Create a check box with a label. onChange(checked) runs on each click.
function Kit.Check(parent, label, onChange)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    if check.Text then
        check.Text:SetText(label or "")
    end
    check:SetScript("OnClick", function(self)
        if onChange then
            onChange(self:GetChecked() and true or false)
        end
    end)
    return check
end

-- Create a row of radio buttons. options: items = { { value, text } }, value, width (of one button with its text,
-- default 56), onChange(value). Methods: SetValue(value) (does not call onChange), GetValue(), SetEnabled(enabled).
-- A click on the chosen button keeps it chosen. The group uses the client radio template, else the check template.
function Kit.RadioGroup(parent, options)
    options = options or {}
    local width = options.width or 56
    local group = CreateFrame("Frame", nil, parent)
    local state = { value = options.value, buttons = {} }
    local function refresh()
        for _, button in ipairs(state.buttons) do
            button:SetChecked(button.value == state.value)
        end
    end
    for index, item in ipairs(options.items or {}) do
        local ok, button = pcall(CreateFrame, "CheckButton", nil, group, "UIRadioButtonTemplate")
        if not ok then
            button = CreateFrame("CheckButton", nil, group, "UICheckButtonTemplate")
        end
        button:SetSize(20, 20)
        button:SetPoint("LEFT", group, "LEFT", (index - 1) * width, 0)
        local text = Kit.Label(group, item.text, "small")
        text:SetPoint("LEFT", button, "RIGHT", 2, 0)
        button.value = item.value
        button:SetScript("OnClick", function(self)
            state.value = self.value
            refresh()
            if options.onChange then
                options.onChange(self.value)
            end
        end)
        state.buttons[index] = button
    end
    group:SetSize(math.max(1, #state.buttons * width), 22)
    function group.SetValue(_, value)
        state.value = value
        refresh()
    end
    function group.GetValue()
        return state.value
    end
    function group.SetEnabled(_, enabled)
        for _, button in ipairs(state.buttons) do
            button:SetEnabled(enabled)
        end
    end
    group.buttons = state.buttons
    refresh()
    return group
end

-- Create a horizontal divider line from a client atlas.
function Kit.Divider(parent)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetAtlas(Kit.Theme.divider)
    line:SetHeight(4)
    return line
end

-- Create a money text. Call :SetCopper(copper) with a number or nil. format(copper) is optional.
function Kit.Money(parent, format)
    local text = parent:CreateFontString(nil, "ARTWORK", Kit.Font("highlight"))
    function text:SetCopper(copper)
        if copper == nil then
            self:SetText("-")
        else
            self:SetText(format and format(copper) or GetMoneyString(copper))
        end
    end
    text:SetCopper(nil)
    return text
end

-- Show a tooltip on mouse over. lines is an optional array of strings.
function Kit.Tooltip(frame, title, lines)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title or "")
        for _, line in ipairs(lines or {}) do
            GameTooltip:AddLine(line, 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

-- Raise a normal Lua error when drop-down items are not an array of { value, text } with a string text.
local function checkItems(items, level)
    if type(items) ~= "table" then
        error("Kit.Dropdown: items must be a table", level + 1)
    end
    for index, item in ipairs(items) do
        if type(item) ~= "table" or item.value == nil or type(item.text) ~= "string" then
            error("Kit.Dropdown: item " .. index .. " needs a value and a string text", level + 1)
        end
    end
end

-- Create a drop-down. options: items = { { value, text } }, value, onChange(value).
-- Methods: SetItems(items), SetValue(value), GetValue(). SetValue does not call onChange.
-- The items and the value live in a local table, not on the client frame. The menu code of the
-- client reads only plain copies of the items, so a bad value gives a Lua error and not a crash.
function Kit.Dropdown(parent, width, options)
    options = options or {}
    if type(options) ~= "table" then
        error("Kit.Dropdown: options must be a table", 2)
    end
    if options.onChange ~= nil and type(options.onChange) ~= "function" then
        error("Kit.Dropdown: onChange must be a function", 2)
    end
    checkItems(options.items or {}, 2)

    local ok, dropdown = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    local menu = ok and dropdown.SetupMenu ~= nil
    local state = { items = {}, value = options.value }

    local function copyItems(items)
        local copy = {}
        for index, item in ipairs(items) do
            copy[index] = { value = item.value, text = item.text }
        end
        return copy
    end
    state.items = copyItems(options.items or {})

    if not menu then
        dropdown = Kit.Button(parent, "", width, function(self)
            local items = state.items
            if #items == 0 then
                return
            end
            local index = 0
            for i, item in ipairs(items) do
                if item.value == state.value then
                    index = i
                end
            end
            self:SetValue(items[index % #items + 1].value)
            if options.onChange then
                options.onChange(state.value)
            end
        end)
    else
        dropdown:SetWidth(width or 120)
    end

    local function refresh(self)
        if menu then
            if self.GenerateMenu then
                self:GenerateMenu()
            end
            return
        end
        local text = ""
        for _, item in ipairs(state.items) do
            if item.value == state.value then
                text = item.text
            end
        end
        self:SetText(text)
    end

    function dropdown:SetItems(items)
        items = items or {}
        checkItems(items, 2)
        state.items = copyItems(items)
        refresh(self)
    end
    function dropdown:SetValue(value)
        state.value = value
        refresh(self)
    end
    function dropdown.GetValue()
        return state.value
    end

    if menu then
        local function isSelected(value)
            return state.value == value
        end
        local function setSelected(value)
            state.value = value
            if options.onChange then
                options.onChange(value)
            end
        end
        dropdown:SetupMenu(function(_, root)
            for _, item in ipairs(state.items) do
                root:CreateRadio(item.text, isSelected, setSelected, item.value)
            end
        end)
    end
    refresh(dropdown)
    return dropdown
end

local GRID_COLUMN_WIDTH = 140
local GRID_ROW = 24

-- Create a grid of check boxes, placed row by row. It sits in the parent like any frame: place it with SetPoint.
-- options: items = { { value, text } }, columns (default 3), columnWidth (default 140), rowHeight (default 24),
-- onChange(set). set is a table value -> true.
-- The grid has the size of all its check boxes. grid.checks lists the check buttons in item order. Methods: SetValues(set) (does not call onChange), GetValues(),
-- SetEnabled(enabled).
function Kit.CheckGrid(parent, options)
    options = options or {}
    local items = options.items or {}
    local columns = math.max(1, options.columns or 3)
    local columnWidth = options.columnWidth or GRID_COLUMN_WIDTH
    local rowHeight = options.rowHeight or GRID_ROW
    local state = { values = {}, checks = {} }
    local grid = CreateFrame("Frame", nil, parent)
    grid.checks = state.checks
    grid:SetSize(columns * columnWidth, math.max(1, math.ceil(#items / columns)) * rowHeight)

    for index, item in ipairs(items) do
        local column, row = (index - 1) % columns, math.floor((index - 1) / columns)
        local check = Kit.Check(grid, item.text, function(checked)
            state.values[item.value] = checked or nil
            if options.onChange then
                options.onChange(state.values)
            end
        end)
        -- A long name must not run into the next column.
        if check.Text and check.Text.SetWidth then
            check.Text:SetWidth(columnWidth - 32)
            if check.Text.SetWordWrap then
                check.Text:SetWordWrap(false)
            end
        end
        check:SetPoint("TOPLEFT", grid, "TOPLEFT", column * columnWidth, -row * rowHeight)
        state.checks[index] = check
    end

    local function refresh()
        for index, item in ipairs(items) do
            state.checks[index]:SetChecked(state.values[item.value] == true)
        end
    end

    function grid.SetValues(_, set)
        state.values = {}
        for value, on in pairs(set or {}) do
            state.values[value] = on or nil
        end
        refresh()
    end
    function grid.GetValues()
        return state.values
    end
    function grid.SetEnabled(_, enabled)
        for _, check in ipairs(state.checks) do
            check:SetEnabled(enabled)
        end
    end
    refresh()
    return grid
end
-- Create a number box. options: min, max, allowNegative, hint, onChange(number or nil).
-- onChange runs on Enter and on focus loss when the number changed.
-- Methods: SetNumber(n), GetNumber(). GetNumber gives nil for empty, bad or out-of-range text.
function Kit.NumberInput(parent, width, options)
    options = options or {}
    local min, max = options.min, options.max
    local reported

    local input
    local function parse()
        local number = tonumber(input:GetText())
        if number == nil or (min and number < min) or (max and number > max) then
            return nil
        end
        return number
    end
    local function showHint()
        local text = input:GetText()
        input.hint:SetShown(text ~= nil and text ~= "" and parse() == nil)
    end
    local function report()
        showHint()
        local number = parse()
        if number ~= reported then
            reported = number
            if options.onChange then
                options.onChange(number)
            end
        end
    end

    input = Kit.Input(parent, width, report, report)
    if not options.allowNegative then
        input:SetNumeric(true)
    end
    input.hint = Kit.Label(parent, options.hint or ((min or "") .. " - " .. (max or "")), "bad")
    input.hint:SetPoint("LEFT", input, "RIGHT", Kit.Theme.gap, 0)
    input.hint:Hide()
    input:SetScript("OnTextChanged", showHint)

    function input:SetNumber(number)
        self:SetText(number == nil and "" or tostring(number))
        reported = parse()
        showHint()
    end
    function input.GetNumber()
        return parse()
    end
    return input
end

local pendingConfirm = {}

-- Show a confirm pop-up. dialogName is the StaticPopupDialogs key. onAccept runs once.
function Kit.Confirm(dialogName, text, onAccept)
    if not StaticPopupDialogs[dialogName] then
        StaticPopupDialogs[dialogName] = {
            text = "%s",
            button1 = ACCEPT,
            button2 = CANCEL,
            timeout = 0,
            hideOnEscape = true,
            whileDead = true,
            OnAccept = function()
                local callback = pendingConfirm[dialogName]
                pendingConfirm[dialogName] = nil
                if callback then
                    callback()
                end
            end,
            OnCancel = function()
                pendingConfirm[dialogName] = nil
            end,
        }
    end
    pendingConfirm[dialogName] = onAccept
    local popup = StaticPopup_Show(dialogName, text)
    if popup and popup.SetFrameStrata then
        popup:SetFrameStrata("FULLSCREEN_DIALOG")
        popup:Raise()
    end
end

-- Create a multi-line text box with a scroll bar. Use it as a frame.
-- options: onChange(text) runs on focus loss, readOnly selects all on focus and blocks edits.
-- Methods: SetText(text), GetText(), SetFocus(), HighlightAll().
function Kit.MultiLineInput(parent, width, height, options)
    options = options or {}
    local scroll = CreateFrame("ScrollFrame", nil, parent, "InputScrollFrameTemplate")
    scroll:SetSize(width or 300, height or 100)
    local box = scroll.EditBox
    box:SetWidth((width or 300) - 18)
    if scroll.CharCount then
        scroll.CharCount:Hide()
    end
    local stored = ""
    local restoring = false

    box:HookScript("OnTextChanged", function(self, userInput)
        if options.readOnly then
            if userInput and not restoring then
                restoring = true
                self:SetText(stored)
                restoring = false
            end
        else
            stored = self:GetText()
        end
    end)
    box:HookScript("OnEditFocusGained", function(self)
        if options.readOnly then
            self:HighlightText()
        end
    end)
    box:HookScript("OnEditFocusLost", function(self)
        if options.onChange and not options.readOnly then
            options.onChange(self:GetText())
        end
    end)

    function scroll.SetText(_, text)
        stored = text or ""
        box:SetText(stored)
    end
    function scroll.GetText()
        return box:GetText()
    end
    function scroll.SetFocus()
        box:SetFocus()
    end
    function scroll.HighlightAll()
        box:SetFocus()
        box:HighlightText()
    end
    return scroll
end

local editorDialogs = {}

-- Create a dialog with a title, a multi-line text box and buttons. One dialog for each name.
-- options: width, height, help (text line), readOnly (Close button only, text selected for copy).
-- dialog:Open(title, text, onSave) shows it. Save calls onSave(text) once and closes. Cancel closes.
function Kit.EditorDialog(name, options)
    if editorDialogs[name] then
        return editorDialogs[name]
    end
    options = options or {}
    local pad = Kit.Theme.padding
    local width, height = options.width or 440, options.height or 310
    local dialog = Kit.CreateWindow(name, { width = width, height = height })
    editorDialogs[name] = dialog
    dialog:SetFrameStrata("DIALOG")
    dialog:SetToplevel(true)

    if options.help then
        local help = Kit.Label(dialog, options.help, "small")
        help:SetPoint("TOPLEFT", dialog, "TOPLEFT", pad + 8, -34)
        help:SetWidth(width - 2 * pad - 16)
    end
    dialog.input = Kit.MultiLineInput(dialog, width - 2 * pad - 16, height - 120, { readOnly = options.readOnly })
    dialog.input:SetPoint("TOPLEFT", dialog, "TOPLEFT", pad + 8, -72)

    local function close()
        dialog.onSave = nil
        dialog:Hide()
    end
    if options.readOnly then
        dialog.closeButton = Kit.Button(dialog, CLOSE, 100, close)
        dialog.closeButton:SetPoint("BOTTOM", dialog, "BOTTOM", 0, pad + 4)
    else
        dialog.saveButton = Kit.Button(dialog, SAVE, 100, function()
            local callback = dialog.onSave
            dialog.onSave = nil
            dialog:Hide()
            if callback then
                callback(dialog.input:GetText())
            end
        end)
        dialog.saveButton:SetPoint("BOTTOM", dialog, "BOTTOM", -55, pad + 4)
        dialog.cancelButton = Kit.Button(dialog, CANCEL, 100, close)
        dialog.cancelButton:SetPoint("BOTTOM", dialog, "BOTTOM", 55, pad + 4)
    end
    dialog:HookScript("OnHide", function()
        dialog.onSave = nil
    end)

    function dialog:Open(title, text, onSave)
        self.onSave = onSave
        if self.SetTitle then
            self:SetTitle(title or "")
        end
        self:Show()
        self:Raise()
        self.input:SetText(text or "")
        if options.readOnly then
            self.input:HighlightAll()
        end
    end
    return dialog
end

-- Give a frame the client inset background and border. Use the result as a frame.
-- skin (optional) is { backgroundAtlas, stripeAtlases = { odd, even }, highlightAtlas, selectAtlas }.
-- All values are client atlas names.
-- A backgroundAtlas covers the inset background inside the border.
function Kit.Inset(parent, skin)
    local ok, inset = pcall(CreateFrame, "Frame", nil, parent, "InsetFrameTemplate")
    if not ok then
        inset = CreateFrame("Frame", nil, parent)
    end
    if skin and skin.backgroundAtlas then
        local background = inset:CreateTexture(nil, "BACKGROUND", nil, -4)
        background:SetAtlas(skin.backgroundAtlas)
        background:SetPoint("TOPLEFT", inset, "TOPLEFT", 3, -3)
        background:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -3, 3)
        inset.skinBackground = background
    end
    return inset
end

-- Skin a list row once: a stripe texture and a hover texture from the atlases of the skin.
-- alternate (optional) picks the stripe atlas: true gives the first, false the second.
-- Without a skin the row gets the Kit highlight texture. Returns true when the row has the skin.
function Kit.SkinRow(row, skin, alternate)
    if not (skin and (skin.stripeAtlases or skin.highlightAtlas)) then
        if not row.kitSkinned then
            row.kitSkinned = true
            row:SetHighlightTexture(Kit.Theme.rowHighlight, "ADD")
        end
        return false
    end
    if not row.kitSkinned then
        row.kitSkinned = true
        if skin.stripeAtlases then
            row.kitStripe = row:CreateTexture(nil, "BACKGROUND", nil, -2)
            row.kitStripe:SetAllPoints(row)
        end
        if skin.highlightAtlas then
            row.kitHover = row:CreateTexture(nil, "HIGHLIGHT")
            row.kitHover:SetAtlas(skin.highlightAtlas)
            row.kitHover:SetBlendMode("ADD")
            row.kitHover:SetAllPoints(row)
        else
            row:SetHighlightTexture(Kit.Theme.rowHighlight, "ADD")
        end
    end
    if row.kitStripe and alternate ~= nil then
        row.kitStripe:SetAtlas(alternate and skin.stripeAtlases[1] or skin.stripeAtlases[2])
    end
    return true
end

-- Create an additive selection texture over a row. A skin selectAtlas replaces the Kit highlight texture.
-- alpha is optional.
function Kit.SelectionTexture(row, skin, alpha)
    local texture = row:CreateTexture(nil, "BACKGROUND")
    if skin and skin.selectAtlas then
        texture:SetAtlas(skin.selectAtlas)
    else
        texture:SetTexture(Kit.Theme.rowHighlight)
    end
    texture:SetBlendMode("ADD")
    if alpha then
        texture:SetAlpha(alpha)
    end
    texture:SetAllPoints(row)
    return texture
end

-- Alternate the stripe atlas of the rows of a scroll box, as the client lists do.
function Kit.AlternateStripes(box, skin)
    if skin and skin.stripeAtlases and ScrollUtil and ScrollUtil.RegisterAlternateRowBehavior then
        ScrollUtil.RegisterAlternateRowBehavior(box, function(row, alternate)
            Kit.SkinRow(row, skin, alternate)
        end)
    end
end

local ICON_BUTTONS = {
    close = "UIPanelCloseButtonNoScripts",
}

-- Create a small icon button from a client template. kind is "close" (a red X).
-- onClick runs on each click. tooltipText is optional.
function Kit.IconButton(parent, kind, onClick, tooltipText)
    local template = ICON_BUTTONS[kind]
    if not template then
        error("Kit.IconButton: unknown kind " .. tostring(kind), 2)
    end
    local button = CreateFrame("Button", nil, parent, template)
    button:SetSize(20, 20)
    button:SetFrameLevel(parent:GetFrameLevel() + 2)
    if onClick then
        button:SetScript("OnClick", function(self, ...)
            onClick(self, ...)
        end)
    end
    if tooltipText then
        Kit.Tooltip(button, tooltipText)
    end
    return button
end

-- Open a right-click menu at the owner. entries: { { text, onClick, disabled } }.
-- options.title adds a title line. Does nothing when the client menu API is missing.
function Kit.ContextMenu(ownerFrame, entries, options)
    if not MenuUtil or not MenuUtil.CreateContextMenu then
        return
    end
    options = options or {}
    return MenuUtil.CreateContextMenu(ownerFrame, function(_, root)
        if options.title then
            root:CreateTitle(options.title)
        end
        for _, entry in ipairs(entries or {}) do
            local button = root:CreateButton(entry.text, entry.onClick)
            if entry.disabled then
                button:SetEnabled(false)
            end
        end
    end)
end