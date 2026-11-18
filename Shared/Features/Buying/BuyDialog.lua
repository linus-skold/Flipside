local _, ns = ...

-- The box of a buy (frame code). BuyFlow has the rules; this module only draws the box.
local BuyDialog = {}
ns.BuyDialog = BuyDialog

local RED = { 1, 0.2, 0.2 }

-- The confirm boxes of a buy. The Buying tab and the Selling tab use the same box (one box for each name), so only one
-- buy can show a box at a time (see BuyFlow.OtherOpen).
local dialogs = {}

-- A small dialog with a text and two buttons, made from the Kit window. One dialog for each name.
-- dialog:Open(title, text, options): options.yes and options.no are the button labels, onYes and onNo run in the click.
-- Escape or the close button counts as "no". options.red shows the text in red.
-- options.keep keeps the box open after yes, with the yes button off, until the next Open.
function BuyDialog.Get(name)
    if dialogs[name] then
        return dialogs[name]
    end
    local Kit = ns.Kit
    local pad = Kit.Theme.padding
    local dialog = Kit.CreateWindow(name, { width = 380, height = 190, square = true })
    dialogs[name] = dialog
    dialog:SetFrameStrata("FULLSCREEN_DIALOG")
    dialog:SetToplevel(true)
    -- The text sits in a frame that takes hyperlinks, so an item link shows the item tooltip.
    local textWidth = 380 - 2 * pad - 16
    dialog.textFrame = CreateFrame("Frame", nil, dialog)
    dialog.textFrame:SetPoint("TOP", dialog, "TOP", 0, -40)
    dialog.textFrame:SetSize(textWidth, 20)
    dialog.textFrame:SetHyperlinksEnabled(true)
    dialog.textFrame:SetScript("OnHyperlinkEnter", function(frame, link)
        GameTooltip:SetOwner(frame, "ANCHOR_CURSOR")
        GameTooltip:SetHyperlink(link)
        GameTooltip:Show()
    end)
    dialog.textFrame:SetScript("OnHyperlinkLeave", function()
        GameTooltip:Hide()
    end)
    dialog.text = Kit.Label(dialog.textFrame, "", "normal")
    dialog.text:SetPoint("TOP", dialog.textFrame, "TOP", 0, 0)
    dialog.text:SetWidth(textWidth)
    dialog.text:SetJustifyH("CENTER")
    local function press(key)
        local callback = dialog[key]
        if key == "onYes" and dialog.keep then
            -- The box stays open. The yes button is off until the next Open.
            dialog.onYes = nil
            dialog.yesButton:SetEnabled(false)
            if callback then
                callback()
            end
            return
        end
        -- Run the callback first, in the click, then close the box (as the Selling box does). A callback that
        -- opens the box again keeps it.
        dialog.onYes, dialog.onNo = nil, nil
        local ok, err = true, nil
        if callback then
            ok, err = pcall(callback)
        end
        if not (dialog.onYes or dialog.onNo) then
            dialog:Hide()
        end
        if not ok then
            error(err, 0)
        end
    end
    dialog.yesButton = Kit.Button(dialog, "", 130, function()
        press("onYes")
    end)
    dialog.yesButton:SetPoint("BOTTOM", dialog, "BOTTOM", -70, pad + 4)
    dialog.noButton = Kit.Button(dialog, "", 100, function()
        press("onNo")
    end)
    dialog.noButton:SetPoint("BOTTOM", dialog, "BOTTOM", 70, pad + 4)
    dialog:HookScript("OnHide", function()
        local callback = dialog.onNo
        dialog.onYes, dialog.onNo = nil, nil
        if callback then
            callback()
        end
    end)

    function dialog:Open(title, text, options)
        self.onYes, self.onNo = options.onYes, options.onNo
        self.keep = options.keep == true
        self.yesButton:SetEnabled(true)
        if self.SetTitle then
            self:SetTitle(title or "")
        end
        self.text:SetText(text or "")
        -- Size the box so that the text fits above the buttons.
        local textHeight = self.text.GetStringHeight and self.text:GetStringHeight() or 14
        self.textFrame:SetHeight(textHeight)
        self:SetHeight(math.max(150, 40 + textHeight + 20 + 22 + pad + 8))
        if options.red then
            self.text:SetTextColor(RED[1], RED[2], RED[3])
        else
            self.text:SetTextColor(1, 1, 1)
        end
        self.yesButton:SetText(options.yes or "OK")
        self.noButton:SetText(options.no or "Cancel")
        self:Show()
        self:Raise()
    end
    -- Hide with no callback.
    function dialog:Close()
        self.onYes, self.onNo = nil, nil
        self:Hide()
    end
    return dialog
end

-- The open box of a name, or nil if it was never made.
function BuyDialog.Find(name)
    return dialogs[name]
end
