local _, ns = ...

-- Auto rules (SPEC 5.2a): a global ordered list of rules that put bag items of no group into a group.
-- A rule has a target group and these filters: a name pattern, a lowest and a highest rarity, and item types.
-- All filters that a rule sets must match. The first rule that matches an item wins.
-- The logic is pure: no WoW call. AutoRules.Attach is the runner; it takes all client calls as arguments.
local AutoRules = {}
ns.AutoRules = AutoRules

AutoRules.MAX_RULES = 50
AutoRules.MAX_PATTERN = 200

local MAX_QUALITY = 5
local DEBOUNCE_SECONDS = 0.5
local OWNER = "Flipside.AutoRules"

local function Trim(text)
    return (text:match("^%s*(.-)%s*$"))
end

local function Quality(value, default)
    value = tonumber(value)
    if not value then
        return default
    end
    return math.max(0, math.min(MAX_QUALITY, math.floor(value)))
end

local function IsID(value)
    return type(value) == "number" and value >= 1 and value % 1 == 0 and value ~= math.huge
end

-- Returns a clean copy of a rule: { group, pattern, minQuality, maxQuality, classes }. Returns nil if rule is no table.
-- A missing rarity means no limit. classes is a text such as "2,4" (empty means any type).
function AutoRules.Normalize(rule)
    if type(rule) ~= "table" then
        return nil
    end
    local pattern = type(rule.pattern) == "string" and Trim(rule.pattern) or ""
    return {
        group = IsID(rule.group) and rule.group or nil,
        pattern = pattern,
        minQuality = Quality(rule.minQuality, 0),
        maxQuality = Quality(rule.maxQuality, MAX_QUALITY),
        classes = ns.MailingPlan.FormatClasses(ns.MailingPlan.ParseClasses(rule.classes)),
    }
end

-- True if a normalized rule sets at least one filter. Rarity Poor to Legendary is no filter.
function AutoRules.HasFilter(rule)
    return rule.pattern ~= "" or rule.minQuality > 0 or rule.maxQuality < MAX_QUALITY or rule.classes ~= ""
end

local compiled, compiledCount = {}, 0

-- Returns the matcher of a name pattern, or nil and a message. Returns nil and nil if there is no regex engine.
local function Matcher(pattern)
    if not ns.NameRegex then
        return nil, nil
    end
    local found = compiled[pattern]
    if found then
        return found
    end
    local matcher, err = ns.NameRegex.Compile(pattern)
    if not matcher then
        return nil, tostring(err or "invalid pattern")
    end
    if compiledCount >= 64 then
        compiled, compiledCount = {}, 0
    end
    compiled[pattern], compiledCount = matcher, compiledCount + 1
    return matcher
end

-- Returns true if the rule can save. Otherwise returns false and a message. The target group is not checked here.
function AutoRules.Validate(rule)
    local clean = AutoRules.Normalize(rule)
    if not clean then
        return false, "the rule is not a table"
    end
    if not AutoRules.HasFilter(clean) then
        return false, "set a name pattern, a rarity or an item type"
    end
    if clean.minQuality > clean.maxQuality then
        return false, "the lowest rarity is above the highest rarity"
    end
    if #clean.pattern > AutoRules.MAX_PATTERN then
        return false, "the name pattern is too long"
    end
    if clean.pattern ~= "" then
        local matcher, err = Matcher(clean.pattern)
        if not matcher and err then
            return false, err
        end
    end
    return true
end

-- Prepare the rules for matching. groupExists(id) tells if a rule can use its group (optional).
-- Returns a list of { rule, index, classes (set), matcher }. A rule that cannot match is left out.
local function Prepare(rules, groupExists)
    local list = {}
    for index, raw in ipairs(rules or {}) do
        local rule = AutoRules.Normalize(raw)
        if rule and rule.group and (not groupExists or groupExists(rule.group))
            and AutoRules.Validate(rule) then
            local entry = { rule = rule, index = index, classes = ns.MailingPlan.ParseClasses(rule.classes) }
            if rule.pattern ~= "" then
                entry.matcher = Matcher(rule.pattern)
            end
            -- With no regex engine a rule with a pattern never matches.
            if rule.pattern == "" or entry.matcher then
                list[#list + 1] = entry
            end
        end
    end
    return list
end

-- True if the item passes all filters of a prepared rule. An unknown rarity or type does not pass its filter.
local function Passes(entry, item)
    local rule = entry.rule
    if rule.minQuality > 0 or rule.maxQuality < MAX_QUALITY then
        local quality = item.quality
        -- Legendary (5) has no upper limit, so Artifact and Heirloom items pass it.
        local tooHigh = rule.maxQuality < MAX_QUALITY and quality ~= nil and quality > rule.maxQuality
        if quality == nil or quality < rule.minQuality or tooHigh then
            return false
        end
    end
    if rule.classes ~= "" and not (item.class ~= nil and entry.classes[item.class]) then
        return false
    end
    if entry.matcher then
        local name = item.name
        if type(name) ~= "string" or not entry.matcher:Match(name) then
            return false
        end
    end
    return true
end

-- Returns the first rule that matches the item { name, quality, class }, and its index. Returns nil for no match.
function AutoRules.Match(rules, item, groupExists)
    for _, entry in ipairs(Prepare(rules, groupExists)) do
        if Passes(entry, item) then
            return entry.rule, entry.index
        end
    end
    return nil
end

-- True if name, rarity and type of the item are all known.
local function IsKnown(item)
    return type(item.name) == "string" and item.name ~= "" and item.quality ~= nil and item.class ~= nil
end

-- Plans the moves. items = { { key, name, quality, class }, ... }. groupOf(key) gives the group id of a key
-- (Base for an item of no group). Returns { { key, groupID, ruleIndex, name }, ... } in the order of items,
-- and the count of items skipped because their data is not known yet.
function AutoRules.Plan(rules, items, groupOf, groupExists)
    local prepared = Prepare(rules, groupExists)
    local plan, unknown, seen = {}, 0, {}
    if #prepared == 0 then
        return plan, 0
    end
    for _, item in ipairs(items or {}) do
        if item.key and not seen[item.key] and groupOf(item.key) == ns.GroupTree.BASE_ID then
            seen[item.key] = true
            if not IsKnown(item) then
                unknown = unknown + 1
            else
                for _, entry in ipairs(prepared) do
                    if Passes(entry, item) then
                        plan[#plan + 1] = {
                            key = item.key, groupID = entry.rule.group, ruleIndex = entry.index, name = item.name,
                        }
                        break
                    end
                end
            end
        end
    end
    return plan, unknown
end

-- Turns bag entries { key, itemID } into items { key, name, quality, class } with data from the item cache.
-- An item that is not loaded gets no name, and the cache loads it.
function AutoRules.Collect(entries, itemCache)
    local items = {}
    for _, entry in ipairs(entries or {}) do
        local item = { key = entry.key }
        local info = itemCache and entry.itemID and itemCache:Get(entry.itemID)
        if info then
            item.name, item.quality, item.class = info.name, info.quality, info.classID
        elseif itemCache and entry.itemID and itemCache.Request then
            itemCache:Request(entry.itemID)
        end
        items[#items + 1] = item
    end
    return items
end

-- The plan for the current bags, from the rules of a RulesStore. Returns the plan and the count of unknown items.
function AutoRules.PlanBags(store, entries, itemCache)
    return AutoRules.Plan(store:AutoRules(), AutoRules.Collect(entries, itemCache), function(key)
        return store:GroupOf(key)
    end, function(id)
        return store:AutoRuleTarget(id)
    end)
end

-- Adds the items of a plan to their groups. Returns the count of items added.
function AutoRules.Apply(store, plan)
    local byGroup, order = {}, {}
    for _, move in ipairs(plan) do
        if not byGroup[move.groupID] then
            byGroup[move.groupID] = {}
            order[#order + 1] = move.groupID
        end
        local keys = byGroup[move.groupID]
        keys[#keys + 1] = move.key
    end
    local added = 0
    for _, groupID in ipairs(order) do
        added = added + (store:AddItems(byGroup[groupID], groupID) or 0)
    end
    return added
end

-- Attaches the runner. On each bag change it adds the bag items of no group that match a rule.
-- deps: bus, rules (RulesStore), readBags() (entries { key, itemID }), itemCache, after, print(text) (optional).
function AutoRules.Attach(deps)
    local runner = { pending = false }

    function runner.Run()
        local store = deps.rules
        if store:IsReadOnly() or not store:AutoRulesEnabled() or #store:AutoRules() == 0 then
            return 0
        end
        local plan = AutoRules.PlanBags(store, deps.readBags(), deps.itemCache)
        if #plan == 0 then
            return 0
        end
        local added = AutoRules.Apply(store, plan)
        if added > 0 and deps.print then
            local noun = added == 1 and "item" or "items"
            deps.print(string.format("%d %s added to groups by the auto rules", added, noun))
        end
        return added
    end

    local function schedule()
        if runner.pending then
            return
        end
        runner.pending = true
        deps.after(DEBOUNCE_SECONDS, function()
            runner.pending = false
            runner.Run()
        end)
    end

    deps.bus:Subscribe("BAG_UPDATE_DELAYED", OWNER, schedule)
    schedule()
    return runner
end
