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
function Kit.Input(parent, width, onEnter)
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
