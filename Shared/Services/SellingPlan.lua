local _, ns = ...

-- Pure selling logic: the candidate items, the post decision for live rows and a session log.

local SellingPlan = {}
ns.SellingPlan = SellingPlan

local LOG_CAP = 200
local DEFAULT_UNDERCUT = 1
local DEFAULT_DURATION = 24
local DEFAULT_MAX_AGE = 72
local DEFAULT_SAMPLES = 3

-- The names of the missing sources that a scan can fill (not the "later" sources).
local function MissingSources(info)
    local later = {}
    for _, name in ipairs(info.later or {}) do
        later[name] = true
    end
    local names = {}
    for _, name in ipairs(info.missing or {}) do
        if not later[name] then
            names[#names + 1] = name
        end
    end
    return names
end

-- label names the price in the reason, for example "min price".
local function PriceFor(run, text, key, label)
    local copper, info = run:Evaluate(text, key)
    if copper ~= nil and copper > 0 then
        return copper
    end
    if info and info.kind == "error" then
        return nil, "formula error: " .. tostring(info.message), true
    end
    local reason = "no data for " .. label
    local names = info and MissingSources(info) or {}
    if #names > 0 then
        reason = reason .. ": " .. table.concat(names, ", ") .. " missing, scan again"
    end
    return nil, reason
end

-- Returns nil if the data is fresh and has enough samples, else a skip reason.
local function SafetyReason(settings, stats)
    if not stats then
        return nil
    end
    local maxAge = tonumber(settings.maxDataAgeHours) or DEFAULT_MAX_AGE
    local minSamples = tonumber(settings.minSamples) or DEFAULT_SAMPLES
    if stats.ageHours == nil then
        return "stale price: no data age"
    end
    if stats.ageHours > maxAge then
        return "stale price: data older than " .. maxAge .. " h"
    end
    if (stats.samples or 0) < minSamples then
        return "too few samples: " .. tostring(stats.samples or 0) .. " of " .. minSamples
    end
    return nil
end

-- deps.rules: RulesStore-like (GroupOf, Path, EffectiveOperation, GetOperation).
-- deps.formulaRun: FormulaRun-like (Evaluate(text, key) returns copper and info).
-- deps.bagItems: BagItems.Read result with stacks.
-- deps.owned: optional map key -> count of own auctions.
-- deps.dataStats: optional function(key) returning { ageHours, samples }.
-- Returns one candidate for each bag item whose group has a selling operation, own or inherited from Base.
function SellingPlan.Candidates(deps)
    local rules, run = deps.rules, deps.formulaRun
    local owned = deps.owned or {}
    local operations = {}
    local list = {}
    for _, item in ipairs(deps.bagItems or {}) do
        local groupID = rules:GroupOf(item.key)
        local opID = rules:EffectiveOperation(groupID, "selling")
        local op = opID and operations[opID]
        if opID and op == nil then
            op = rules:GetOperation(opID) or false
            operations[opID] = op
        end
        if op then
            local settings = op.settings or {}
            local candidate = {
                key = item.key,
                itemID = item.itemID,
                link = item.link,
                name = item.name,
                count = item.count,
                stacks = item.stacks,
                groupID = groupID,
                groupPath = rules:Path(groupID),
                operationID = opID,
                operationName = op.name,
                settings = settings,
                owned = owned[item.key] or 0,
            }
            local needData = settings.needScanData ~= false
            local reason
            candidate.minPrice, reason = PriceFor(run, settings.minPrice, item.key, "min price")
            candidate.reason = reason
            if not reason then
                local isError
                candidate.normalPrice, reason, isError = PriceFor(run, settings.normalPrice, item.key, "normal price")
                if reason and (needData or isError) then
                    candidate.reason = reason
                end
            end
            if not candidate.reason then
                local isError
                candidate.maxPrice, reason, isError = PriceFor(run, settings.maxPrice, item.key, "max price")
                if reason and (needData or isError) then
                    candidate.reason = reason
                end
            end
            if not candidate.reason and needData and deps.dataStats then
                candidate.reason = SafetyReason(settings, deps.dataStats(item.key))
            end
            list[#list + 1] = candidate
        end
    end
    return list
end
local function IsOwn(row, opts)
    if opts.isOwn then
        return opts.isOwn(row) == true
    end
    return row.isOwn == true or row.ownerItem == true
end

local function Skip(candidate, reason, extra)
    local d = {
        action = "skip", reason = reason, auctions = 0, quantity = 0,
        key = candidate.key,
    }
    for k, v in pairs(extra or {}) do
        d[k] = v
    end
    return d
end

-- rows: live rows sorted by unitPrice. Rows: { auctionID, unitPrice, quantity, isCommodity, ownerItem }.
-- opts: isOwn(row), maxStack (default 1), isCommodity (default: from the first row).
-- Returns { action, price, quantity, auctions, duration, reason, key, competitor }.
function SellingPlan.Decide(candidate, rows, opts)
    opts = opts or {}
    rows = rows or {}
    local s = candidate.settings or {}
    if candidate.reason then
        return Skip(candidate, candidate.reason)
    end
    local keep = tonumber(s.keepInBags) or 0
    local available = (candidate.count or 0) - keep
    if available <= 0 then
        return Skip(candidate, "keep in bags reached")
    end
    local cap = tonumber(s.postCap) or 0
    local room = cap > 0 and (cap - (candidate.owned or 0)) or math.huge
    if room <= 0 then
        return Skip(candidate, "post cap reached")
    end

    local competitor, ownLowest
    for _, row in ipairs(rows) do
        if type(row.unitPrice) == "number" then
            if IsOwn(row, opts) then
                ownLowest = ownLowest or row.unitPrice
            else
                competitor = competitor or row.unitPrice
            end
        end
    end

    local undercut = tonumber(s.undercut) or DEFAULT_UNDERCUT
    local info = { competitor = competitor, floor = candidate.minPrice }
    local price, why
    if competitor then
        price = competitor - undercut
        why = "undercut"
    elseif candidate.normalPrice then
        price = candidate.normalPrice
        why = "normal price"
    else
        return Skip(candidate, "no price: no competitor and no market value", info)
    end
    if candidate.maxPrice and price > candidate.maxPrice then
        if s.aboveMax == "postAtNormal" and candidate.normalPrice then
            price, why = candidate.normalPrice, "above max, at normal"
        else
            price, why = candidate.maxPrice, "above max, at max"
        end
    end
    if price < candidate.minPrice then
        if s.belowMin == "postAtMin" then
            price, why = candidate.minPrice, "below min, at min"
        else
            return Skip(candidate, "below minimum", info)
        end
    end
    price = math.max(1, math.floor(price))
    if ownLowest and ownLowest <= price then
        return Skip(candidate, "already lowest", info)
    end

    local commodity = opts.isCommodity
    if commodity == nil then
        commodity = rows[1] ~= nil and rows[1].isCommodity == true
    end
    local quantity, auctions
    if commodity then
        quantity, auctions = available, 1
    else
        local maxStack = math.max(1, tonumber(opts.maxStack) or 1)
        local size = tonumber(s.stackSize) or 0
        size = size > 0 and math.min(size, maxStack) or maxStack
        auctions = math.floor(available / size)
        quantity = size
        if auctions == 0 then
            quantity, auctions = available, 1
        end
        auctions = math.min(auctions, room)
    end
    return {
        action = "post", price = price, quantity = quantity, auctions = auctions,
        duration = tonumber(s.duration) or DEFAULT_DURATION, reason = why,
        key = candidate.key, competitor = competitor, commodity = commodity,
    }
end

local Log = {}
Log.__index = Log

-- Returns a session log that keeps the newest cap entries.
function SellingPlan.NewLog(cap)
    return setmetatable({ _cap = cap or LOG_CAP, _list = {}, _seq = 0 }, Log)
end

function Log:Add(candidate, decision)
    self._seq = self._seq + 1
    local list = self._list
    list[#list + 1] = {
        seq = self._seq,
        key = candidate and candidate.key,
        itemID = candidate and candidate.itemID,
        groupPath = candidate and candidate.groupPath,
        operationName = candidate and candidate.operationName,
        decision = decision and decision.action,
        reason = decision and decision.reason,
        price = decision and decision.price,
        quantity = decision and decision.quantity,
        auctions = decision and decision.auctions,
    }
    if #list > self._cap then
        table.remove(list, 1)
    end
end

-- Returns a copy of the entries, oldest first.
function Log:List()
    local out = {}
    for i, item in ipairs(self._list) do
        out[i] = item
    end
    return out
end

function Log:Clear()
    self._list = {}
end

-- The session log. It is not saved.
SellingPlan.Log = SellingPlan.NewLog(LOG_CAP)
