local _, ns = ...

-- Finds the scan record for an item link, item string, item id or digit string.
local FormulaLookup = {}
ns.FormulaLookup = FormulaLookup

-- Returns record, key, itemID; nil, nil, itemID if no record; nil if input is not an item.
function FormulaLookup.Find(store, input)
    local base = ns.ItemString.ToBaseKey(input)
    if not base then
        return nil
    end
    local itemID = tonumber(base)
    if type(input) == "string" and not input:match("^%d+$") then
        local exact = ns.ItemString.ToExactKey(input)
        if exact and exact ~= base then
            local record = store:Get(exact)
            if record then
                return record, exact, itemID
            end
        end
    end
    local record = store:Get(base)
    if record then
        return record, base, itemID
    end
    return nil, nil, itemID
end
