local _, ns = ...

-- Finds the scan record for an item link, item string, item id or digit string.
local FormulaLookup = {}
ns.FormulaLookup = FormulaLookup

-- Index of the exact-key variants of a store: base key -> list of keys. It is built again when the store version
-- changes (each Put and Remove), so a lookup that finds nothing does one table read.
local indexes = setmetatable({}, { __mode = "k" })

local function variantIndex(store)
    if type(store.Keys) ~= "function" or type(store.GetVersion) ~= "function" then
        return nil
    end
    local version = store:GetVersion()
    local index = indexes[store]
    if index and index.version == version then
        return index.map
    end
    local map = {}
    for _, key in ipairs(store:Keys()) do
        local base = key:match("^(%d+)#")
        if base then
            map[base] = map[base] or {}
            map[base][#map[base] + 1] = key
        end
    end
    indexes[store] = { version = version, map = map }
    return map
end

-- Returns the record and key of the exact-key variant of an item (gear is stored under "<id>#...") that has
-- the lowest latest minimum buyout. Returns nil if the item has no variant with data.
function FormulaLookup.FindVariant(store, base)
    local map = variantIndex(store)
    local keys = map and map[base]
    if not keys then
        return nil
    end
    local bestRecord, bestKey, bestMin
    for _, key in ipairs(keys) do
        local record = store:Get(key)
        local min = record and record.latest and record.latest.min
        if min and (not bestMin or min < bestMin) then
            bestRecord, bestKey, bestMin = record, key, min
        end
    end
    return bestRecord, bestKey
end

-- Returns record, key, itemID; nil, nil, itemID if no record; nil if input is not an item.
-- options.itemIdVariants (formula and tooltip lookups only): for a bare item ID with no base record, use the
-- cheapest exact-key variant. Selling and Buying do not set it, so they keep the base-key rule.
function FormulaLookup.Find(store, input, options)
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
    if options and options.itemIdVariants
        and (type(input) == "number" or (type(input) == "string" and input:match("^%d+$"))) then
        local variant, variantKey = FormulaLookup.FindVariant(store, base)
        if variant then
            return variant, variantKey, itemID
        end
    end
    return nil, nil, itemID
end
