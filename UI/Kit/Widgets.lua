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
function Kit.Input(parent, width, onEnter, onFocusLost)
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

-- Create a horizontal divider line from a client atlas.
function Kit.Divider(parent)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetAtlas(Kit.Theme.divider)
    line:SetHeight(4)
    return line
end

-- Create a money text. Call :SetCopper(copper) with a number or nil.
function Kit.Money(parent)
    local text = parent:CreateFontString(nil, "ARTWORK", Kit.Font("highlight"))
    function text:SetCopper(copper)
        if copper == nil then
            self:SetText("-")
        else
            self:SetText(GetMoneyString(copper))
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

-- Create a drop-down. options: items = { { value, text } }, value, onChange(value).
-- Methods: SetItems(items), SetValue(value), GetValue(). SetValue does not call onChange.
function Kit.Dropdown(parent, width, options)
    options = options or {}
    local ok, dropdown = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    local menu = ok and dropdown.SetupMenu ~= nil
    if not menu then
        dropdown = Kit.Button(parent, "", width, function(self)
            local items = self.items
            if #items == 0 then
                return
            end
            local index = 0
            for i, item in ipairs(items) do
                if item.value == self.value then
                    index = i
                end
            end
            self:SetValue(items[index % #items + 1].value)
            if options.onChange then
                options.onChange(self.value)
            end
        end)
    else
        dropdown:SetWidth(width or 120)
    end
    dropdown.items = options.items or {}
    dropdown.value = options.value

    local function refresh(self)
        if menu then
            if self.GenerateMenu then
                self:GenerateMenu()
            end
            return
        end
        local text = ""
        for _, item in ipairs(self.items) do
            if item.value == self.value then
                text = item.text
            end
        end
        self:SetText(text)
    end

    function dropdown:SetItems(items)
        self.items = items or {}
        refresh(self)
    end
    function dropdown:SetValue(value)
        self.value = value
        refresh(self)
    end
    function dropdown:GetValue()
        return self.value
    end

    if menu then
        local function isSelected(value)
            return dropdown.value == value
        end
        local function setSelected(value)
            dropdown.value = value
            if options.onChange then
                options.onChange(value)
            end
        end
        dropdown:SetupMenu(function(_, root)
            for _, item in ipairs(dropdown.items) do
                root:CreateRadio(item.text, isSelected, setSelected, item.value)
            end
        end)
    end
    refresh(dropdown)
    return dropdown
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
    StaticPopup_Show(dialogName, text)
end