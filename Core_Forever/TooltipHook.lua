local _, ns = ...

-- WoW: Forever tooltip hook. It installs the client post call and gives each item link to the shared Tooltip.
local TooltipHook = {}
ns.TooltipHook = TooltipHook

-- Returns the item link of the tooltip data, or nil.
function TooltipHook.LinkOf(data, itemLinkByGUID)
    if type(data) ~= "table" then
        return nil
    end
    if data.guid and itemLinkByGUID then
        local link = itemLinkByGUID(data.guid)
        if type(link) == "string" then
            return link
        end
    end
    if type(data.hyperlink) == "string" then
        return data.hyperlink
    end
    if type(data.id) == "number" then
        return string.format("item:%d", data.id)
    end
    return nil
end

-- Call onItem(tooltip, link) after each item tooltip. Returns the post call function, or nil on failure.
-- opts: report(message), and for tests processor, itemType, itemLinkByGUID.
function TooltipHook.Install(onItem, opts)
    opts = opts or {}
    local report = opts.report or function() end
    local processor = opts.processor or TooltipDataProcessor
    local itemType = opts.itemType
    if itemType == nil then
        itemType = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item
    end
    local itemLinkByGUID = opts.itemLinkByGUID or (C_Item and C_Item.GetItemLinkByGUID)
    if type(processor) ~= "table" or type(processor.AddTooltipPostCall) ~= "function" or itemType == nil then
        report("tooltip hook not available")
        return nil
    end
    local function postCall(tooltip, data)
        local ok, link = pcall(TooltipHook.LinkOf, data, itemLinkByGUID)
        if not ok then
            report("tooltip lines failed: " .. tostring(link))
            return
        end
        onItem(tooltip, link)
    end
    local ok, err = pcall(processor.AddTooltipPostCall, itemType, postCall)
    if not ok then
        report("tooltip hook failed: " .. tostring(err))
        return nil
    end
    return postCall
end
