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
    if type(input) == "number" or (type(input) == "string" and input:match("^%d+$")) then
        local variant, variantKey = FormulaLookup.FindVariant(store, base)
        if variant then
            return variant, variantKey, itemID
        end
    end
    return nil, nil, itemID
end

-- Returns the record and key of the exact-key variant of an item (gear is stored under "<id>#...") that has
-- the lowest latest minimum buyout. Returns nil if the item has no variant with data.
function FormulaLookup.FindVariant(store, base)
    if type(store.Keys) ~= "function" then
        return nil
    end
    local prefix = base .. "#"
    local bestRecord, bestKey, bestMin
    for _, key in ipairs(store:Keys()) do
        if key:sub(1, #prefix) == prefix then
            local record = store:Get(key)
            local min = record and record.latest and record.latest.min
            if min and (not bestMin or min < bestMin) then
                bestRecord, bestKey, bestMin = record, key, min
            end
        end
    end
    return bestRecord, bestKey
end
