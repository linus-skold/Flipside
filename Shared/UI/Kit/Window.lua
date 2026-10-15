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

local ANCHORS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
    RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

-- Return a saved position that is safe to use, or nil.
-- A position is { point, relativePoint, x, y }. The offsets must be on the screen.
local function validPosition(saved)
    if type(saved) ~= "table" or not ANCHORS[saved.point] or not ANCHORS[saved.relativePoint] then
        return nil
    end
    local x, y = saved.x, saved.y
    if type(x) ~= "number" or type(y) ~= "number" or x ~= x or y ~= y then
        return nil
    end
    local width = UIParent.GetWidth and UIParent:GetWidth()
    local height = UIParent.GetHeight and UIParent:GetHeight()
    if type(width) == "number" and math.abs(x) > width then
        return nil
    end
    if type(height) == "number" and math.abs(y) > height then
        return nil
    end
    return saved
end

-- Create a hidden, movable window from a client frame template.
-- options: width, height, title, portrait (texture path or nil), strata (default "MEDIUM"),
-- square (true gives the plain square frame with no portrait and no round ring),
-- savePosition ({ get = fn, set = fn }: get() gives the saved { point, relativePoint, x, y } or nil;
-- set(position) saves it when a drag stops, and set(nil) clears it).
function Kit.CreateWindow(name, options)
    options = options or {}
    local window, hasPortrait = createFrame(name)
    local save = options.savePosition
    window:SetSize(options.width or 400, options.height or 300)
    local saved = save and save.get and validPosition(save.get())
    if saved then
        window:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x, saved.y)
    else
        window:SetPoint("CENTER")
    end
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

    if options.square and hasPortrait then
        -- The client function also swaps the border, so the round ring goes with the portrait.
        if ButtonFrameTemplate_HidePortrait then
            pcall(ButtonFrameTemplate_HidePortrait, window)
        end
        if window.SetPortraitShown then
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
        if save and save.set then
            local point, _, relativePoint, x, y = window:GetPoint()
            if point then
                save.set({ point = point, relativePoint = relativePoint, x = x, y = y })
            end
        end
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

    -- Put the window back in the centre and clear the saved position.
    function window:ResetPosition()
        self:ClearAllPoints()
        self:SetPoint("CENTER")
        if save and save.set then
            save.set(nil)
        end
    end
    return window
end
