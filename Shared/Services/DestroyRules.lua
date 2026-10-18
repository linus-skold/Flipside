local _, ns = ...

-- The rules of the Destroy window. This module has no frame code and reads no client global.
-- An item matches if its quality is in the range AND (the level rule matches OR the unequippable rule matches).
-- A sub-rule that is off does not count. If both sub-rules are off, the quality alone decides.
local DestroyRules = {}
ns.DestroyRules = DestroyRules

-- Item quality numbers of the client, and the item classes that a player can disenchant.
local UNCOMMON, EPIC = 2, 4
local CLASS_WEAPON, CLASS_ARMOR = 2, 4
local ARMOR_COSMETIC, WEAPON_FISHING_POLE = 5, 20
local MAX_LEVEL_GAP = 80

DestroyRules.QUALITIES = {
    { value = 2, text = "Uncommon" },
    { value = 3, text = "Rare" },
    { value = 4, text = "Epic" },
}

local SETTING_RULES = "destroy.rules"
local SETTING_IGNORED = "destroy.ignored"

-- The armor and weapon subclasses that each class can ever equip, at any level (a skill that a trainer teaches
-- counts). Armor 0 is Miscellaneous (rings, necks, trinkets): all classes use it. Weapon 14 is Miscellaneous.
local function set(list)
    local result = {}
    for _, value in ipairs(list) do
        result[value] = true
    end
    return result
end

local PROFICIENCY = {
    WARRIOR = {
        armor = set({ 0, 1, 2, 3, 4, 6 }),
        weapon = set({ 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 13, 14, 15, 16, 18 }),
    },
    PALADIN = { armor = set({ 0, 1, 2, 3, 4, 6, 7 }), weapon = set({ 0, 1, 4, 5, 6, 7, 8, 14 }) },
    HUNTER = {
        armor = set({ 0, 1, 2, 3 }),
        weapon = set({ 0, 1, 2, 3, 6, 7, 8, 10, 13, 14, 15, 16, 18 }),
    },
    ROGUE = { armor = set({ 0, 1, 2 }), weapon = set({ 0, 2, 3, 4, 7, 13, 14, 15, 16, 18 }) },
    PRIEST = { armor = set({ 0, 1 }), weapon = set({ 4, 10, 14, 15, 19 }) },
    SHAMAN = { armor = set({ 0, 1, 2, 3, 6, 9 }), weapon = set({ 0, 1, 4, 5, 10, 13, 14, 15 }) },
    MAGE = { armor = set({ 0, 1 }), weapon = set({ 7, 10, 14, 15, 19 }) },
    WARLOCK = { armor = set({ 0, 1 }), weapon = set({ 7, 10, 14, 15, 19 }) },
    DRUID = { armor = set({ 0, 1, 2, 8 }), weapon = set({ 4, 5, 6, 10, 13, 14, 15 }) },
}

-- Item slots that no player can disenchant.
local NO_DISENCHANT_SLOTS = { INVTYPE_BODY = true, INVTYPE_TABARD = true }

function DestroyRules.Defaults()
    return {
        minQuality = UNCOMMON,
        maxQuality = EPIC,
        levelRule = true,
        levelGap = 1,
        unequippableRule = true,
    }
end

local function clampInteger(value, low, high, default)
    if type(value) ~= "number" or value ~= value then
        return default
    end
    value = math.floor(value)
    if value < low then
        return low
    elseif value > high then
        return high
    end
    return value
end

-- Return a valid copy of a saved config. A missing or bad field gets its default.
-- The quality range stays inside Uncommon to Epic: Legendary is never in the range.
function DestroyRules.Normalize(saved)
    local config = DestroyRules.Defaults()
    if type(saved) ~= "table" then
        return config
    end
    config.minQuality = clampInteger(saved.minQuality, UNCOMMON, EPIC, config.minQuality)
    config.maxQuality = clampInteger(saved.maxQuality, UNCOMMON, EPIC, config.maxQuality)
    if config.maxQuality < config.minQuality then
        config.maxQuality = config.minQuality
    end
    if saved.levelRule ~= nil then
        config.levelRule = saved.levelRule == true
    end
    config.levelGap = clampInteger(saved.levelGap, 0, MAX_LEVEL_GAP, config.levelGap)
    if saved.unequippableRule ~= nil then
        config.unequippableRule = saved.unequippableRule == true
    end
    return config
end

-- Return true if the player class can never equip the item, false if it can, nil if the class is not known.
-- classToken is the class file name (for example "MAGE"). classID and subclassID are the item class numbers.
function DestroyRules.CanEquip(classToken, classID, subclassID)
    local proficiency = PROFICIENCY[classToken]
    if not proficiency then
        return nil
    end
    if classID == CLASS_ARMOR then
        return proficiency.armor[subclassID] == true
    elseif classID == CLASS_WEAPON then
        return proficiency.weapon[subclassID] == true
    end
    return nil
end

-- Return true if the item can be disenchanted at all: armor or weapon, Uncommon to Epic, no shirt or tabard.
-- item: quality, classID, subclassID, equipLoc.
function DestroyRules.IsCandidate(item)
    if type(item) ~= "table" then
        return false
    end
    if item.classID ~= CLASS_ARMOR and item.classID ~= CLASS_WEAPON then
        return false
    end
    if item.classID == CLASS_ARMOR and item.subclassID == ARMOR_COSMETIC then
        return false
    end
    if item.classID == CLASS_WEAPON and item.subclassID == WEAPON_FISHING_POLE then
        return false
    end
    if NO_DISENCHANT_SLOTS[item.equipLoc] then
        return false
    end
    local quality = item.quality
    return type(quality) == "number" and quality >= UNCOMMON and quality <= EPIC
end

-- Return true if the item matches the rules. config: a Normalize result. player: { level, class }.
function DestroyRules.Matches(item, config, player)
    if not DestroyRules.IsCandidate(item) then
        return false
    end
    if item.quality < config.minQuality or item.quality > config.maxQuality then
        return false
    end
    if not (config.levelRule or config.unequippableRule) then
        return true
    end
    if config.levelRule and type(player.level) == "number"
        and (item.minLevel or 0) <= player.level - config.levelGap then
        return true
    end
    if config.unequippableRule and DestroyRules.CanEquip(player.class, item.classID, item.subclassID) == false then
        return true
    end
    return false
end

-- The key that the Skip action uses. A skipped item shows again if it moves to another slot.
function DestroyRules.SkipKey(bag, slot, itemID)
    return bag .. ":" .. slot .. ":" .. itemID
end

-- Build the rows of the window. stacks: array of { bag, slot, itemID, link, count }.
-- infoOf(itemID) gives the item info (name, quality, minLevel, classID, subclassID, equipLoc, icon) or nil.
-- ignored: set itemID -> true. skipped: set SkipKey -> true.
-- Returns the rows, sorted by bag and slot, and a set of the item ids that have no info yet.
function DestroyRules.Rows(stacks, infoOf, config, player, ignored, skipped)
    local rows, pending = {}, {}
    for _, stack in ipairs(stacks) do
        local itemID = stack.itemID
        local skipKey = DestroyRules.SkipKey(stack.bag, stack.slot, itemID)
        if not (ignored and ignored[itemID]) and not (skipped and skipped[skipKey]) then
            local info = infoOf(itemID)
            if not info then
                pending[itemID] = true
            elseif DestroyRules.Matches(info, config, player) then
                rows[#rows + 1] = {
                    key = skipKey,
                    itemID = itemID,
                    link = stack.link,
                    name = info.name,
                    quality = info.quality,
                    minLevel = info.minLevel or 0,
                    icon = info.icon,
                    bag = stack.bag,
                    slot = stack.slot,
                }
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.bag ~= b.bag then
            return a.bag < b.bag
        end
        return a.slot < b.slot
    end)
    return rows, pending
end

-- Return the item ids of an ignore set, sorted.
function DestroyRules.IgnoredIDs(ignored)
    local list = {}
    for itemID, flag in pairs(ignored or {}) do
        if flag and type(itemID) == "number" then
            list[#list + 1] = itemID
        end
    end
    table.sort(list)
    return list
end

-- The saved rules and the saved ignore list. Both live in the account scope of the settings DB, so every
-- character of the account uses the same rules and the same ignore list.
-- Methods: Config(), SetConfig(config), Ignored() (a copy of the set), SetIgnored(itemID, flag).
-- SetConfig and SetIgnored give false if the settings are read-only.
function DestroyRules.NewStore(db)
    local store = {}

    function store.Config()
        return DestroyRules.Normalize(db:Get("account", SETTING_RULES))
    end

    function store.SetConfig(config)
        return db:Set("account", SETTING_RULES, DestroyRules.Normalize(config))
    end

    function store.Ignored()
        local saved = db:Get("account", SETTING_IGNORED)
        local copy = {}
        if type(saved) == "table" then
            for itemID, flag in pairs(saved) do
                if flag == true and type(itemID) == "number" then
                    copy[itemID] = true
                end
            end
        end
        return copy
    end

    function store.SetIgnored(itemID, flag)
        local ignored = store.Ignored()
        ignored[itemID] = flag and true or nil
        return db:Set("account", SETTING_IGNORED, ignored)
    end

    return store
end
