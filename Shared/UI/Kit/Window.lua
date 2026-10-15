local _, ns = ...
ns.Kit = ns.Kit or {}
local Kit = ns.Kit

local function createFrame(name)
    local ok, frame = pcall(CreateFrame, "Frame", name, UIParent, "PortraitFrameTemplate")
    if ok then
        return frame, true
    end
    return CreateFrame("Frame", name, UIParent, "ButtonFrameTemplate"), false
end

-- Create a hidden, movable window from a client frame template.
-- options: width, height, title, portrait (texture path or nil), strata (default "MEDIUM").
function Kit.CreateWindow(name, options)
    options = options or {}
    local window, hasPortrait = createFrame(name)
    window:SetSize(options.width or 400, options.height or 300)
    window:SetPoint("CENTER")
    if window.SetTitle then
        window:SetTitle(options.title or "")
    end
    if hasPortrait and window.SetPortraitTextureRaw then
        if options.portrait then
            window:SetPortraitTextureRaw(options.portrait)
        elseif window.SetPortraitShown then
            window:SetPortraitShown(false)
        end
    end

    window:SetFrameStrata(options.strata or "MEDIUM")
    window:SetToplevel(true)
    window:HookScript("OnShow", function(self)
        self:Raise()
    end)
    window:SetMovable(true)
    window:SetClampedToScreen(true)
    window:EnableMouse(true)
    local handle = window.TitleContainer or window
    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", function()
        window:StartMoving()
    end)
    handle:SetScript("OnDragStop", function()
        window:StopMovingOrSizing()
    end)

    table.insert(UISpecialFrames, name)
    window:Hide()

    function window:Toggle()
        if self:IsShown() then
            self:Hide()
        else
            self:Show()
        end
    end
    return window
end
