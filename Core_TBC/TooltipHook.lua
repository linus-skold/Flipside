local _, ns = ...

-- WoW: TBC Anniversary tooltip hook. The tooltip frames have no TooltipDataProcessor, so this hooks OnTooltipSetItem.
local TooltipHook = {}
ns.TooltipHook = TooltipHook

-- Required frames report if missing. Shopping (compare) tooltips are optional.
local REQUIRED = { "GameTooltip", "ItemRefTooltip" }
local OPTIONAL = { "ShoppingTooltip1", "ShoppingTooltip2" }

local hooked = {}

-- Returns the item link of the tooltip, or nil.
function TooltipHook.LinkOf(tooltip)
    if type(tooltip.GetItem) ~= "function" then
        return nil
    end
    local _, link = tooltip:GetItem()
    return type(link) == "string" and link or nil
end

-- Returns the stack count of a ContainerFrame or main bank item button that owns the tooltip, or nil.
-- The TBC button has no GetBagID: the bag ID is the ID of the parent ContainerFrame.
function TooltipHook.StackCountOf(tooltip, containerItemInfo)
    if not (containerItemInfo and tooltip.GetOwner) then
        return nil
    end
    local owner = tooltip:GetOwner()
    if type(owner) ~= "table" or not owner.GetID then
        return nil
    end
    local ownerName = owner.GetName and owner:GetName()
    if type(ownerName) == "string" and ownerName:match("^BankFrameItem%d+$") then
        -- A slot of the main bank: the bank container has the ID -1.
        local info = containerItemInfo(type(BANK_CONTAINER) == "number" and BANK_CONTAINER or -1, owner:GetID())
        return type(info) == "table" and type(info.stackCount) == "number" and info.stackCount or nil
    end
    local parent = owner.GetParent and owner:GetParent()
    local name = type(parent) == "table" and parent.GetName and parent:GetName()
    if type(name) ~= "string" or not name:match("^ContainerFrame%d+$") then
        return nil
    end
    local info = containerItemInfo(parent:GetID(), owner:GetID())
    return type(info) == "table" and type(info.stackCount) == "number" and info.stackCount or nil
end

-- Call onItem(tooltip, link, stackCount) after each item tooltip. Returns a table, or nil if GameTooltip is not hooked.
-- opts: report(message), and for tests frames (name to frame), isAltDown, containerItemInfo.
function TooltipHook.Install(onItem, opts)
    opts = opts or {}
    local report = opts.report or function() end
    local frames = opts.frames or _G
    local isAltDown = opts.isAltDown or IsAltKeyDown
    local containerItemInfo = opts.containerItemInfo or (C_Container and C_Container.GetContainerItemInfo)

    local function handler(tooltip)
        local ok, link = pcall(TooltipHook.LinkOf, tooltip)
        if not ok then
            report("tooltip lines failed: " .. tostring(link))
            return
        end
        local stackCount
        if link and isAltDown and isAltDown() then
            local okStack, count = pcall(TooltipHook.StackCountOf, tooltip, containerItemInfo)
            stackCount = okStack and count or nil
        end
        onItem(tooltip, link, stackCount)
    end

    local function hook(name, required)
        local frame = frames[name]
        if type(frame) ~= "table" or type(frame.HookScript) ~= "function" then
            if required then
                report("tooltip hook not available")
            end
            return false
        end
        if hooked[frame] then
            return true
        end
        local ok, err = pcall(frame.HookScript, frame, "OnTooltipSetItem", handler)
        if not ok then
            report("tooltip hook failed: " .. tostring(err))
            return false
        end
        hooked[frame] = true
        return true
    end

    local main = false
    for _, name in ipairs(REQUIRED) do
        local done = hook(name, true)
        main = main or (name == "GameTooltip" and done)
    end
    for _, name in ipairs(OPTIONAL) do
        hook(name, false)
    end
    if not main then
        return nil
    end
    return { handler = handler }
end
