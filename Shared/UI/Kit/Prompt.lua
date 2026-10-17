local _, ns = ...
ns.Kit = ns.Kit or {}
local Kit = ns.Kit

local prompts = {}

local function trim(text)
    return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

-- Create an input window with a text box, an optional choice list, and OK and Cancel buttons.
-- One window for each name. options: width.
-- dialog:Open(config) shows it. config:
--   title, label (text above the box), text (start text),
--   choices ({ { value, text } }: a drop-down above the box), choice (start value), choiceLabel,
--   validate(text, choice) (optional: gives an error text, or nil when the text is good),
--   onOK(text, choice) (runs on OK with the trimmed text; if it gives a text, that text shows as an error
--   under the box and the window stays open).
-- OK is off while the trimmed text is empty or validate gives an error. Enter is OK. Escape is Cancel.
function Kit.Prompt(name, options)
    if prompts[name] then
        return prompts[name]
    end
    options = options or {}
    local pad = Kit.Theme.padding
    local width = options.width or 320
    local inner = width - 2 * pad - 16
    local dialog = Kit.CreateWindow(name, { width = width, height = 150 })
    prompts[name] = dialog
    dialog:SetFrameStrata("DIALOG")
    dialog:SetToplevel(true)

    dialog.choiceLabel = Kit.Label(dialog, "", "highlight")
    dialog.label = Kit.Label(dialog, "", "highlight")
    dialog.error = Kit.Label(dialog, "", "bad")
    dialog.error:SetWidth(inner)
    dialog.error:SetJustifyH("LEFT")

    local update

    dialog.choice = Kit.Dropdown(dialog, 180, {
        items = {},
        onChange = function(value)
            dialog.choiceValue = value
            dialog.submitError = nil
            update()
        end,
    })
    dialog.input = Kit.Input(dialog, inner - 8)

    local function close()
        dialog.config = nil
        dialog:Hide()
    end

    local function submit()
        local config = dialog.config
        if not config or not dialog.canSubmit then
            return
        end
        local message = config.onOK and config.onOK(trim(dialog.input:GetText()), dialog.choiceValue)
        if type(message) == "string" and message ~= "" then
            dialog.submitError = message
            update()
            return
        end
        close()
    end

    update = function()
        local config = dialog.config
        if not config then
            return
        end
        local text = trim(dialog.input:GetText())
        local message = text ~= "" and config.validate and config.validate(text, dialog.choiceValue) or nil
        dialog.error:SetText(message or dialog.submitError or "")
        dialog.canSubmit = text ~= "" and not message
        dialog.okButton:SetEnabled(dialog.canSubmit)
    end

    dialog.input:SetScript("OnEnterPressed", submit)
    dialog.input:SetScript("OnEscapePressed", close)
    dialog.input:SetScript("OnTextChanged", function()
        dialog.submitError = nil
        update()
    end)

    dialog.okButton = Kit.Button(dialog, ACCEPT, 100, submit)
    dialog.okButton:SetPoint("BOTTOM", dialog, "BOTTOM", -55, pad + 4)
    dialog.cancelButton = Kit.Button(dialog, CANCEL, 100, close)
    dialog.cancelButton:SetPoint("BOTTOM", dialog, "BOTTOM", 55, pad + 4)
    dialog:HookScript("OnHide", function()
        dialog.config = nil
    end)

    local function place(frame, y)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", dialog, "TOPLEFT", pad + 8, -y)
    end

    function dialog:Open(config)
        self.config = config
        self.submitError = nil
        local choices = config.choices
        local y = 36
        if self.SetTitle then
            self:SetTitle(config.title or "")
        end
        self.choiceLabel:SetShown(choices ~= nil)
        self.choice:SetShown(choices ~= nil)
        if choices then
            self.choiceLabel:SetText(config.choiceLabel or "Type")
            place(self.choiceLabel, y)
            self.choice:SetItems(choices)
            self.choiceValue = config.choice or (choices[1] and choices[1].value)
            self.choice:SetValue(self.choiceValue)
            place(self.choice, y + 16)
            y = y + 52
        else
            self.choiceValue = nil
        end
        self.label:SetText(config.label or "")
        place(self.label, y)
        place(self.input, y + 16)
        place(self.error, y + 42)
        self:SetHeight(y + 42 + 20 + 40)
        self:Show()
        self:Raise()
        self.input:SetText(config.text or "")
        update()
        self.input:SetFocus()
        self.input:HighlightText()
    end
    return dialog
end
