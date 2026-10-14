local _, ns = ...

local HoldingsRead = {}
ns.HoldingsRead = HoldingsRead

local BAG_FIRST, BAG_LAST = 0, 5
local ATTACHMENTS_MAX = 16
local STATUS_SOLD = 1

HoldingsRead.BANK_BAGS = { 6, 7, 8, 9, 10, 11, 12, 13, 14 }

local function NewStats(field)
    return { [field] = 0, skipped = 0, errors = 0 }
end

-- Returns the group key of an item, or nil if no key can be made.
local function KeyOf(resolver, itemID, link)
    if resolver then
        local ok, key = pcall(resolver.KeyFor, resolver, itemID, link)
        return ok and key or nil
    end
    return ns.ItemString.ToExactKey(link)
end

-- Returns the item id of a link, or nil.
local function ItemIDOf(link)
    local parsed = ns.ItemString.ParseLink(link)
    return parsed and parsed.itemID or nil
end

-- Adds count to the key of an item. Returns true if the item was counted.
local function Add(items, resolver, itemID, link, count)
    if type(link) ~= "string" or type(itemID) ~= "number" or ns.ScanKey.IsBattlePet(link) then
        return false
    end
    local key = KeyOf(resolver, itemID, link)
    if not key then
        return false
    end
    items[key] = (items[key] or 0) + (tonumber(count) or 1)
    return true
end

local function ReadBagList(api, resolver, bagIDs)
    local items, stats = {}, NewStats("slots")
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
                elseif type(info) ~= "table"
                    or not Add(items, resolver, info.itemID, info.hyperlink, info.stackCount) then
                    stats.skipped = stats.skipped + 1
                end
            end
        end
    end
    return items, stats
end

-- Reads the bags. api = { numSlots(bag), itemInfo(bag, slot) }.
function HoldingsRead.Bags(api, resolver)
    local bagIDs = {}
    for bag = BAG_FIRST, BAG_LAST do
        bagIDs[#bagIDs + 1] = bag
    end
    return ReadBagList(api, resolver, bagIDs)
end

-- Reads the bank bags. The bank must be open.
function HoldingsRead.Bank(api, resolver, bagIDs)
    return ReadBagList(api, resolver, bagIDs or HoldingsRead.BANK_BAGS)
end

-- Reads mail attachments. api = { numItems(), itemLink(index, attachment), itemInfo(index, attachment) }.
function HoldingsRead.Mail(api, resolver)
    local items, stats = {}, NewStats("rows")
    local okNum, numMails = pcall(api.numItems)
    if not okNum then
        stats.errors = 1
        return items, stats
    end
    for index = 1, tonumber(numMails) or 0 do
        stats.rows = stats.rows + 1
        for attachment = 1, ATTACHMENTS_MAX do
            local okLink, link = pcall(api.itemLink, index, attachment)
            if not okLink then
                stats.errors = stats.errors + 1
            elseif type(link) == "string" then
                local okInfo, _, _, _, count = pcall(api.itemInfo, index, attachment)
                if not okInfo then
                    stats.errors = stats.errors + 1
                elseif not Add(items, resolver, ItemIDOf(link), link, count) then
                    stats.skipped = stats.skipped + 1
                end
            end
        end
    end
    return items, stats
end

-- Reads the own auctions. api = { owned() } returns OwnedAuctionInfo rows.
function HoldingsRead.Auctions(api, resolver)
    local items, stats = {}, NewStats("rows")
    local ok, rows = pcall(api.owned)
    if not ok then
        stats.errors = 1
        return items, stats
    end
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        stats.rows = stats.rows + 1
        if type(row) ~= "table" or row.status == STATUS_SOLD then
            stats.skipped = stats.skipped + 1
        else
            local link = row.itemLink
            local itemID = type(link) == "string" and ItemIDOf(link) or nil
            if not itemID and type(row.itemKey) == "table" then
                itemID = row.itemKey.itemID
                link = type(itemID) == "number" and ("item:" .. string.format("%d", itemID)) or nil
            end
            if not Add(items, resolver, itemID, link, row.quantity) then
                stats.skipped = stats.skipped + 1
            end
        end
    end
    return items, stats
end
