local _, ns = ...
ns.Kit = ns.Kit or {}
local Kit = ns.Kit

local atan2 = math.atan2 or math.atan

local DEFAULT_ANGLE = 225
local DEFAULT_RADIUS = 80
local RADIUS_PAD = 5
local BUTTON_SIZE = 31

-- Angle in degrees (0 to 360, counter-clockwise from the right) of a cursor point around a centre.
function Kit.MinimapAngle(cursorX, cursorY, centerX, centerY)
    return math.deg(atan2(cursorY - centerY, cursorX - centerX)) % 360
end

-- Offset x, y of a point on a circle of this radius, at this angle in degrees.
function Kit.MinimapOffset(angle, radius)
    local radians = math.rad(angle)
    return math.cos(radians) * radius, math.sin(radians) * radius
end

local function radiusOf(options, parent)
    if type(options.radius) == "function" then
        return options.radius()
    elseif type(options.radius) == "number" then
        return options.radius
    end
    local width = parent.GetWidth and parent:GetWidth()
    if type(width) == "number" and width > 0 then
        return width / 2 + RADIUS_PAD
    end
    return DEFAULT_RADIUS
end

-- Create a round button on the edge of a round minimap that the player can drag around it.
-- options: parent (the minimap frame, default UIParent), icon (texture path), title, lines (tooltip lines),
-- angle (degrees, default 225), radius (number or function; default from the parent width),
-- hidden (true hides the button), onClick(button, mouseButton), onAngleChanged(angle) (when a drag stops).
-- Methods: SetAngle(angle), GetAngle(), SetHidden(hidden).
function Kit.CreateMinimapButton(name, options)
    options = options or {}
    local parent = options.parent or UIParent
    local button = CreateFrame("Button", name, parent)
    button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -5)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -6)
    icon:SetTexture(options.icon)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")
    button.icon = icon

    local angle = tonumber(options.angle) or DEFAULT_ANGLE

    function button:SetAngle(value)
        angle = value % 360
        local x, y = Kit.MinimapOffset(angle, radiusOf(options, parent))
        self:ClearAllPoints()
        self:SetPoint("CENTER", parent, "CENTER", x, y)
    end

    function button.GetAngle()
        return angle
    end

    function button:SetHidden(hidden)
        self:SetShown(not hidden)
    end

    local function followCursor(self)
        local centerX, centerY = parent:GetCenter()
        if not centerX then
            return
        end
        local scale = parent:GetEffectiveScale()
        local cursorX, cursorY = GetCursorPosition()
        self:SetAngle(Kit.MinimapAngle(cursorX / scale, cursorY / scale, centerX, centerY))
    end

    button:SetScript("OnDragStart", function(self)
        self.dragging = true
        GameTooltip:Hide()
        self:SetScript("OnUpdate", followCursor)
    end)
    button:SetScript("OnDragStop", function(self)
        self.dragging = false
        self:SetScript("OnUpdate", nil)
        if options.onAngleChanged then
            options.onAngleChanged(angle)
        end
    end)
    button:SetScript("OnClick", function(self, mouseButton)
        if options.onClick then
            options.onClick(self, mouseButton)
        end
    end)
    button:SetScript("OnEnter", function(self)
        if self.dragging then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(options.title or "")
        for _, line in ipairs(options.lines or {}) do
            GameTooltip:AddLine(line, 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    button:SetAngle(angle)
    button:SetHidden(options.hidden)
    return button
end
