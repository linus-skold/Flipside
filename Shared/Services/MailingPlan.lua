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
--          slots = { { key, bag, slot, count, soulbound, quest, unmailable }, ... }, self = "Name" }.
-- A group lists its own items and has the effective mailing operation (inherited from its parents).
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
        for _, key in ipairs(group.items or {}) do
            local slots = slotsByKey[key]
            if slots and not seen[key] then
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
        out[#out + 1] = { id = id, items = rules:ItemsIn(id), operation = op and op.settings or nil }
        for _, child in ipairs(rules:Children(id) or {}) do
            visit(child)
        end
    end
    for _, id in ipairs(groupIDs) do
        visit(id)
    end
    return out
end
