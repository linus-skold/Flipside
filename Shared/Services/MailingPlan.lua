local _, ns = ...

-- Plans the mails of the mailing operation (SPEC 5.5). Pure: no WoW call, all input is an argument.
local MailingPlan = {}
ns.MailingPlan = MailingPlan

MailingPlan.MAX_ATTACHMENTS = 12

-- Skip reasons.
MailingPlan.REASONS = {
    keep = "keep",
    sendLimit = "send limit",
    soulbound = "soulbound",
    quest = "quest item",
    unmailable = "unmailable",
    noRecipient = "no recipient",
    self = "recipient is self",
}

local REASONS = MailingPlan.REASONS

local function Trim(text)
    return (text:match("^%s*(.-)%s*$"))
end

-- True if the recipient is the own character. A name without a realm matches the name part only.
local function IsSelf(recipient, selfName)
    if not selfName or selfName == "" then
        return false
    end
    local a, b = recipient:lower(), selfName:lower()
    local nameA, realmA = a:match("^([^%-]+)%-(.+)$")
    local nameB, realmB = b:match("^([^%-]+)%-(.+)$")
    if realmA and realmB then
        return a == b
    end
    return (nameA or a) == (nameB or b)
end

-- Returns the settings of a mailing operation as a recipient and two whole numbers, or nil without a recipient.
local function ReadOperation(operation)
    if type(operation) ~= "table" then
        return nil
    end
    local recipient = type(operation.recipient) == "string" and Trim(operation.recipient) or ""
    if recipient == "" then
        return nil
    end
    local keep, maxSend = tonumber(operation.keep) or 0, tonumber(operation.maxSend) or 0
    return recipient, math.max(0, math.floor(keep)), math.max(0, math.floor(maxSend))
end

-- Item class ids are stored as a text such as "2,4" (a set; an empty text means any class).
function MailingPlan.ParseClasses(text)
    local set = {}
    if type(text) == "string" then
        for id in text:gmatch("%d+") do
            set[tonumber(id)] = true
        end
    end
    return set
end

function MailingPlan.FormatClasses(set)
    local ids = {}
    for id, on in pairs(set or {}) do
        if on then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

local MAX_QUALITY = 5

-- Returns the item filter of an operation. A missing field means no filter (an operation from an old save).
local function ReadFilter(operation)
    local filter = { min = 0, max = MAX_QUALITY, classes = {} }
    if type(operation) == "table" then
        filter.min = tonumber(operation.minQuality) or 0
        filter.max = tonumber(operation.maxQuality) or MAX_QUALITY
        filter.classes = MailingPlan.ParseClasses(operation.itemClasses)
    end
    filter.byQuality = filter.min > 0 or filter.max < MAX_QUALITY
    filter.byClass = next(filter.classes) ~= nil
    return filter
end

-- True if a bag slot passes the filter. An unknown rarity or class does not pass an active filter.
-- The highest rarity Legendary has no upper limit, so Artifact and Heirloom items pass it.
local function Passes(filter, slot)
    if filter.byQuality then
        local quality = slot.quality
        if quality == nil or quality < filter.min or (filter.max < MAX_QUALITY and quality > filter.max) then
            return false
        end
    end
    if filter.byClass and not (slot.class ~= nil and filter.classes[slot.class]) then
        return false
    end
    return true
end

-- The keys of the items of an All bag items group: the items that are in no group and have a slot that
-- is not soulbound. Soulbound items stay out of the list and the skip report.
local function AllBagKeys(slots, isGrouped)
    local keys, seen = {}, {}
    for _, slot in ipairs(slots) do
        if not seen[slot.key] and not slot.soulbound and not (isGrouped and isGrouped(slot.key)) then
            seen[slot.key] = true
            keys[#keys + 1] = slot.key
        end
    end
    return keys
end

local function SkipEntry(slot, reason)
    return { key = slot.key, bag = slot.bag, slot = slot.slot, count = slot.count, reason = reason }
end

-- Returns the reason that a bag slot can never be mailed, or nil.
local function FlagReason(slot)
    if slot.soulbound then
        return REASONS.soulbound
    elseif slot.quest then
        return REASONS.quest
    elseif slot.unmailable then
        return REASONS.unmailable
    end
    return nil
end

-- Orders slots largest first, then by bag and slot. Largest first needs the fewest attachments.
local function BySize(a, b)
    if a.count ~= b.count then
        return a.count > b.count
    end
    if a.bag ~= b.bag then
        return a.bag < b.bag
    end
    return a.slot < b.slot
end

-- Plans one item. Appends the chosen attachments to picked and the skipped slots to skipped.
-- Sendable = total in bags - keep, capped by maxSend. Whole slots only: a slot larger than what is left is not sent.
local function PlanItem(slots, keep, maxSend, picked, skipped)
    local total = 0
    for _, slot in ipairs(slots) do
        total = total + slot.count
    end
    local free = total - keep
    local limited = false
    if maxSend > 0 and maxSend < free then
        free = maxSend
        limited = true
    end

    local candidates = {}
    for _, slot in ipairs(slots) do
        local reason = FlagReason(slot)
        if reason then
            skipped[#skipped + 1] = SkipEntry(slot, reason)
        else
            candidates[#candidates + 1] = slot
        end
    end
    table.sort(candidates, BySize)

    local left = free
    for _, slot in ipairs(candidates) do
        if slot.count <= left then
            left = left - slot.count
            picked[#picked + 1] = { bag = slot.bag, slot = slot.slot, key = slot.key, count = slot.count }
        else
            skipped[#skipped + 1] = SkipEntry(slot, limited and REASONS.sendLimit or REASONS.keep)
        end
    end
end

-- Input: { groups = { { items = { key, ... }, operation = { recipient, keep, maxSend } or nil }, ... },
--          slots = { { key, bag, slot, count, soulbound, quest, unmailable, quality, class }, ... }, self = "Name" }.
-- A group lists its own items and has the effective mailing operation (inherited from its parents).
-- The operation can also have minQuality, maxQuality and itemClasses; an item must pass them (SPEC 5.5).
-- An allBags group lists no item: it takes every bag item for which isGrouped(key) is false.
-- An item in two groups follows the first group. Items that no group lists are left alone.
-- Output: { mails = { { recipient, attachments = { { bag, slot, key, count } } } }, skipped = { { key, bag, slot,
-- count, reason } } }. A mail has one recipient and up to MAX_ATTACHMENTS attachments.
function MailingPlan.Build(input)
    local slotsByKey = {}
    for _, slot in ipairs(input.slots or {}) do
        local list = slotsByKey[slot.key]
        if not list then
            list = {}
            slotsByKey[slot.key] = list
        end
        list[#list + 1] = slot
    end

    local mails, skipped = {}, {}
    local byRecipient, order, seen = {}, {}, {}
    for _, group in ipairs(input.groups or {}) do
        local recipient, keep, maxSend = ReadOperation(group.operation)
        local filter = ReadFilter(group.operation)
        local items = group.items or {}
        if group.allBags then
            items = recipient and AllBagKeys(input.slots or {}, group.isGrouped) or {}
        end
        for _, key in ipairs(items) do
            local slots = slotsByKey[key]
            -- An item that fails the filter is left alone, so a later group can still take it.
            if slots and not seen[key] and Passes(filter, slots[1]) then
                seen[key] = true
                if not recipient then
                    for _, slot in ipairs(slots) do
                        skipped[#skipped + 1] = SkipEntry(slot, REASONS.noRecipient)
                    end
                elseif IsSelf(recipient, input.self) then
                    for _, slot in ipairs(slots) do
                        skipped[#skipped + 1] = SkipEntry(slot, REASONS.self)
                    end
                else
                    local id = recipient:lower()
                    local entry = byRecipient[id]
                    if not entry then
                        entry = { recipient = recipient, picked = {} }
                        byRecipient[id] = entry
                        order[#order + 1] = entry
                    end
                    PlanItem(slots, keep, maxSend, entry.picked, skipped)
                end
            end
        end
    end

    for _, entry in ipairs(order) do
        local attachments
        for _, pick in ipairs(entry.picked) do
            if not attachments or #attachments == MailingPlan.MAX_ATTACHMENTS then
                attachments = {}
                mails[#mails + 1] = { recipient = entry.recipient, attachments = attachments }
            end
            attachments[#attachments + 1] = pick
        end
    end
    return { mails = mails, skipped = skipped }
end

-- Builds the groups of Build from the rules. groupIDs are the groups that the user selected.
-- Each group and its subgroups are listed with their own items and their effective mailing operation.
function MailingPlan.GroupsFor(rules, groupIDs)
    local out, done = {}, {}
    local function visit(id)
        if done[id] then
            return
        end
        done[id] = true
        local opID = rules:EffectiveOperation(id, "mailing")
        local op = opID and rules:GetOperation(opID)
        local entry = { id = id, items = rules:ItemsIn(id), operation = op and op.settings or nil }
        if rules.AllBagsGroup and rules:AllBagsGroup() == id then
            entry.allBags = true
            entry.isGrouped = function(key)
                -- An item in no group belongs to Base (group 1).
                return rules:GroupOf(key) ~= 1
            end
        end
        out[#out + 1] = entry
        for _, child in ipairs(rules:Children(id) or {}) do
            visit(child)
        end
    end
    for _, id in ipairs(groupIDs) do
        visit(id)
    end
    return out
end
