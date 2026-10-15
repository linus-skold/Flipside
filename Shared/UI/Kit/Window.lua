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

-- The screen size, or nil when UIParent has no size yet.
local function screenSize()
    local width = UIParent.GetWidth and UIParent:GetWidth()
    local height = UIParent.GetHeight and UIParent:GetHeight()
    if type(width) == "number" and width > 0 and type(height) == "number" and height > 0 then
        return width, height
    end
    return nil
end

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

-- Make a window resizable with a grip in the bottom-right corner. See Kit.CreateWindow for the options.
-- Newer clients have SetResizeBounds; older clients have SetMinResize and SetMaxResize.
function Kit.MakeResizable(window, options)
    local minWidth, minHeight = options.minWidth or 100, options.minHeight or 100
    local function bounds()
        local screenWidth, screenHeight = screenSize()
        local maxWidth = options.maxWidth or screenWidth or 4096
        local maxHeight = options.maxHeight or screenHeight or 4096
        return minWidth, minHeight, math.max(minWidth, maxWidth), math.max(minHeight, maxHeight)
    end
    local function applyBounds()
        local lowW, lowH, highW, highH = bounds()
        if window.SetResizeBounds then
            window:SetResizeBounds(lowW, lowH, highW, highH)
        else
            if window.SetMinResize then
                window:SetMinResize(lowW, lowH)
            end
            if window.SetMaxResize then
                window:SetMaxResize(highW, highH)
            end
        end
        return lowW, lowH, highW, highH
    end
    window:SetResizable(true)
    local lowW, lowH, highW, highH = applyBounds()
    local saved = options.get and options.get()
    if type(saved) == "table" and type(saved.width) == "number" and type(saved.height) == "number"
        and saved.width == saved.width and saved.height == saved.height then
        window:SetSize(clamp(saved.width, lowW, highW), clamp(saved.height, lowH, highH))
    end
    window:HookScript("OnShow", applyBounds)

    local grip = CreateFrame("Button", nil, window)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -4, 4)
    grip:SetFrameLevel(window:GetFrameLevel() + 10)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        applyBounds()
        window:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        window:StopMovingOrSizing()
        if options.set then
            options.set({ width = window:GetWidth(), height = window:GetHeight() })
        end
    end)
    window.ResizeGrip = grip
    return grip
end

-- Create a hidden, movable window from a client frame template.
-- options: width, height, title, portrait (texture path or nil), strata (default "MEDIUM"),
-- square (true gives the plain square frame with no portrait and no round ring),
-- savePosition ({ get = fn, set = fn }: get() gives the saved { point, relativePoint, x, y } or nil;
-- set(position) saves it when a drag stops, and set(nil) clears it),
-- resize ({ minWidth, minHeight, maxWidth, maxHeight, get, set }: a grip in the bottom-right corner resizes the window.
-- The maximum is the screen size unless given. get() gives the saved { width, height } or nil; set(size) saves it
-- when the drag stops).
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

    if options.resize then
        Kit.MakeResizable(window, options.resize)
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
