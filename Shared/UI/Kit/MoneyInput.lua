local _, ns = ...
ns.Kit = ns.Kit or {}
local Kit = ns.Kit

local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD = 10000
local BOX_HEIGHT = 20
local ICON_SIZE = 14
local GAP = 4
-- Client atlases of the coin icons (the money input of the Auction House uses them).
local DEFAULT_ICONS = { gold = "coin-gold", silver = "coin-silver", copper = "coin-copper" }

-- Split an amount of copper into gold, silver and copper.
function Kit.SplitMoney(copper)
    copper = math.max(0, math.floor((tonumber(copper) or 0) + 0.5))
    return math.floor(copper / COPPER_PER_GOLD), math.floor((copper % COPPER_PER_GOLD) / COPPER_PER_SILVER),
        copper % COPPER_PER_SILVER
end

-- Join gold, silver and copper (numbers or texts) into copper. An empty or bad value counts as 0.
function Kit.JoinMoney(gold, silver, copper)
    local function whole(value)
        return math.max(0, math.floor(tonumber(value) or 0))
    end
    return whole(gold) * COPPER_PER_GOLD + whole(silver) * COPPER_PER_SILVER + whole(copper)
end

-- Create a money input: three number boxes (gold, silver, copper), each followed by its coin icon.
-- options: onChange(copper) runs when the user types, icons = { gold, silver, copper } atlas names,
-- goldLetters (default 7).
-- Fields: .gold, .silver, .copper (the boxes). Methods: SetCopper(copper or nil) (does not call onChange),
-- GetCopper() (empty boxes count as 0), SetEnabled(enabled).
function Kit.MoneyInput(parent, options)
    options = options or {}
    local icons = options.icons or DEFAULT_ICONS
    local frame = CreateFrame("Frame", nil, parent)
    local widths = { gold = 56, silver = 30, copper = 30 }
    local letters = { gold = options.goldLetters or 7, silver = 2, copper = 2 }
    local silent = false
    local x = 0
    for _, key in ipairs({ "gold", "silver", "copper" }) do
        local box = Kit.Input(frame, widths[key])
        box:SetNumeric(true)
        box:SetMaxLetters(letters[key])
        box:SetPoint("LEFT", frame, "LEFT", x + 6, 0)
        local icon = frame:CreateTexture(nil, "ARTWORK")
        icon:SetSize(ICON_SIZE, ICON_SIZE)
        icon:SetPoint("LEFT", box, "RIGHT", GAP, 0)
        icon:SetAtlas(icons[key] or DEFAULT_ICONS[key])
        box:SetScript("OnTextChanged", function()
            if not silent and options.onChange then
                options.onChange(frame:GetCopper())
            end
        end)
        frame[key] = box
        frame[key .. "Icon"] = icon
        x = x + widths[key] + ICON_SIZE + 2 * GAP
    end
    frame:SetSize(x + 6, BOX_HEIGHT)

    function frame:GetCopper()
        return Kit.JoinMoney(self.gold:GetText(), self.silver:GetText(), self.copper:GetText())
    end

    -- Show an amount. A part of 0 shows as an empty box. nil clears all boxes.
    function frame:SetCopper(amount)
        local gold, silver, copper = Kit.SplitMoney(amount)
        local function show(box, value)
            box:SetText((amount == nil or value == 0) and "" or tostring(value))
        end
        silent = true
        show(self.gold, gold)
        show(self.silver, silver)
        show(self.copper, copper)
        silent = false
    end

    function frame:SetEnabled(enabled)
        for _, key in ipairs({ "gold", "silver", "copper" }) do
            self[key]:SetEnabled(enabled)
        end
    end

    return frame
end
