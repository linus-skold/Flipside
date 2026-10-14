local _, ns = ...

local BagItems = {}
ns.BagItems = BagItems

local FIRST_BAG, LAST_BAG = 0, 5 -- default bag ids; options.bagIDs overrides them

-- Returns the group key of a slot item, or nil if no key can be made.
local function KeyOf(resolver, itemID, link)
    if resolver then
        local ok, key = pcall(resolver.KeyFor, resolver, itemID, link)
        return ok and key or nil
    end
    return ns.ItemString.ToExactKey(link)
end

-- Reads all bag slots. Returns sorted items { key, itemID, link, name, count, bound } and stats.
-- If options.stacks is true, each item also has stacks = { { bag, slot, count, link, bound } } sorted by bag, slot.
function BagItems.Read(api, resolver, options)
    local includeBound = options ~= nil and options.includeBound == true
    local wantStacks = options ~= nil and options.stacks == true
    local stats = { slots = 0, skipped = 0, errors = 0 }
    local byKey, list = {}, {}

    local bagIDs = options and options.bagIDs
    if not bagIDs then
        bagIDs = {}
        for bag = FIRST_BAG, LAST_BAG do
            bagIDs[#bagIDs + 1] = bag
        end
    end

    for _, bag in ipairs(bagIDs) do
        local ok, numSlots = pcall(api.numSlots, bag)
        if not ok then
            stats.errors = stats.errors + 1
        elseif type(numSlots) == "number" then
            for slot = 1, numSlots do
                stats.slots = stats.slots + 1
                local okInfo, info = pcall(api.itemInfo, bag, slot)
                if not okInfo then
                    stats.errors = stats.errors + 1
                elseif type(info) ~= "table" then
                    stats.skipped = stats.skipped + 1
                else
                    local link, itemID = info.hyperlink, info.itemID
                    local key
                    if type(link) == "string" and type(itemID) == "number"
                        and not ns.ScanKey.IsBattlePet(link) then
                        key = KeyOf(resolver, itemID, link)
                    end
                    if not key or (info.isBound and not includeBound) then
                        stats.skipped = stats.skipped + 1
                    else
                        local entry = byKey[key]
                        if not entry then
                            entry = {
                                key = key, itemID = itemID, link = link,
                                name = info.itemName or "", count = 0, bound = false,
                            }
                            byKey[key] = entry
                            list[#list + 1] = entry
                        end
                        entry.count = entry.count + (tonumber(info.stackCount) or 1)
                        entry.bound = entry.bound or info.isBound == true
                        if wantStacks then
                            entry.stacks = entry.stacks or {}
                            entry.stacks[#entry.stacks + 1] = {
                                bag = bag, slot = slot, count = tonumber(info.stackCount) or 1,
                                link = link, bound = info.isBound == true,
                            }
                        end
                    end
                end
            end
        end
    end

    table.sort(list, function(a, b)
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.key < b.key
    end)
    if wantStacks then
        for _, entry in ipairs(list) do
            table.sort(entry.stacks, function(a, b)
                if a.bag ~= b.bag then
                    return a.bag < b.bag
                end
                return a.slot < b.slot
            end)
        end
    end
    return list, stats
end
