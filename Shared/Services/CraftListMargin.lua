local _, ns = ...

-- The margin of a craft list: the cost of the materials, the value of the results and the difference.
-- No frame code and no client call. The caller gives the price functions.
local CraftListMargin = {}
ns.CraftListMargin = CraftListMargin

CraftListMargin.AH_CUT = 0.05

local function round(number)
    return math.floor(number + 0.5)
end

-- The AH cut of a gross price in copper (5%, rounded half up).
function CraftListMargin.Cut(gross)
    return round(gross * CraftListMargin.AH_CUT)
end

-- Returns the cost in copper of the cheapest needed units of the levels, or nil if the levels hold fewer units.
-- levels: { { unitPrice, quantity, own } }, cheapest first. A level that is yours does not count.
-- A commodity level counts for the units that are needed from it only. A stack level (it has stackSize and stacks)
-- is bought in whole stacks: the walk takes ceil(left / stackSize) stacks, at most the stacks of the level, and the
-- cost counts every unit of these stacks, also the units above the need.
function CraftListMargin.WalkLevels(levels, needed)
    if type(needed) ~= "number" or needed < 1 then
        return nil
    end
    local left, cost = needed, 0
    for _, level in ipairs(levels or {}) do
        if not level.own and type(level.unitPrice) == "number" then
            local take
            if level.stackSize and level.stackSize > 0 then
                local stacks = math.min(math.ceil(left / level.stackSize), level.stacks or 1)
                take = stacks * level.stackSize
            else
                take = math.min(left, level.quantity or 1)
            end
            cost = cost + take * level.unitPrice
            left = left - take
            if left <= 0 then
                return cost
            end
        end
    end
    return nil
end

-- The age of a scan as text: "12 min ago", "3 h ago" or "2 d ago". Empty text without an age.
local function ageText(hours)
    if type(hours) ~= "number" or hours < 0 then
        return ""
    end
    local minutes = math.floor(hours * 60 + 0.5)
    if minutes < 60 then
        return minutes .. " min ago"
    elseif hours < 48 then
        return math.floor(hours) .. " h ago"
    end
    return math.floor(hours / 24) .. " d ago"
end

local SOURCE_LABEL = { scanRecent = "latest scan", scanMarket = "14-day average", scanMin = "lowest listing" }

-- The text of the price source: for example "latest scan, 12 min ago". field is the ScanSources field that gave the price.
function CraftListMargin.PriceSource(values, field)
    local label = SOURCE_LABEL[field]
    if not label then
        return nil
    end
    local age = type(values) == "table" and ageText(values.scanAge) or ""
    return age ~= "" and (label .. ", " .. age) or label
end

-- The scan price of the needed units of a material: ScanRecent (the latest scan) times the units, else ScanMarket
-- times the units. The second value is true (it is an estimate). The third value is the source text.
-- values is the output of ScanSources.Compute for the item, or nil. It gives nil if there is neither value.
function CraftListMargin.ScanMaterialPrice(values, needed)
    if type(values) ~= "table" then
        return nil
    end
    for _, field in ipairs({ "scanRecent", "scanMarket" }) do
        if values[field] then
            return values[field] * needed, true, CraftListMargin.PriceSource(values, field)
        end
    end
    return nil
end

-- The scan price of one unit of a result: ScanRecent, else ScanMarket, else ScanMin. Else nil.
-- The second value is the source text.
function CraftListMargin.ScanResultPrice(values)
    if type(values) ~= "table" then
        return nil
    end
    for _, field in ipairs({ "scanRecent", "scanMarket", "scanMin" }) do
        if values[field] then
            return values[field], CraftListMargin.PriceSource(values, field)
        end
    end
    return nil
end

-- list: { materials = { { key, itemID, count } }, results = { { key, itemID, name, min, max } },
--   resultMode = "all" (default) or "oneOf" }.
-- A material with no count needs 1 unit. options:
--   crafts: the number of crafts (a whole number, default 1). It scales the materials and the results.
--   materialPrice(material, needed): the total cost in copper of the needed units, true if it is an estimate, and
--     an optional source text. It gives nil if there is no price.
--   resultPrice(result): the price in copper of one unit (or nil) and an optional source text. It must not include
--     the AH cut.
--   cut(gross): the AH cut in copper (default 5%).
-- Returns a table:
--   crafts, materials: one entry for each material { key, itemID, needed, total, estimate }.
--   cost: the sum of the priced materials. costKnown: false if a material has no price (the cost is a lower limit).
--   estimate: true if a material price is an estimate.
--   results: one entry for each result { key, itemID, min, max, avg, unit, net = { min, avg, max } }. net is the
--     value after the cut for the units of the three yields, for all crafts. unit and net are nil without a price.
--   valueKnown: false if a result has no price.
--   value: { min, avg, max }: the sum of the net values of the priced results. In mode "oneOf" (list.resultMode) it is:
--     min = the lowest net value at the min yield of one result, max = the highest net value at the max yield of one
--     result, avg = the mean of the avg-yield net values (each result has the same chance).
--   resultMode: "all" or "oneOf". pick = { min, max }: in "oneOf" mode, the place in results of the result that sets
--     the min and of the result that sets the max (the first one wins a tie).
--   margin: { min, avg, max } = value - cost, or nil if the cost or the value is not known for all.
--   percent: { min, avg, max } = margin / cost * 100, or nil if the margin is nil or the cost is 0.
function CraftListMargin.Compute(list, options)
    local crafts = options.crafts
    if type(crafts) ~= "number" or crafts < 1 or crafts % 1 ~= 0 then
        crafts = 1
    end
    local cut = options.cut or CraftListMargin.Cut
    local oneOf = list.resultMode == "oneOf"
    local out = {
        crafts = crafts, materials = {}, cost = 0, costKnown = true, estimate = false,
        results = {}, valueKnown = true, value = { min = 0, avg = 0, max = 0 },
        resultMode = oneOf and "oneOf" or "all", pick = { min = 1, max = 1 },
    }
    for index, material in ipairs(list.materials or {}) do
        local needed = (material.count or 1) * crafts
        local total, estimate, source = options.materialPrice(material, needed)
        out.materials[index] = {
            key = material.key, itemID = material.itemID, needed = needed, total = total,
            estimate = total ~= nil and estimate == true, source = total ~= nil and source or nil,
        }
        if total == nil then
            out.costKnown = false
        else
            out.cost = out.cost + total
            out.estimate = out.estimate or estimate == true
        end
    end
    for index, result in ipairs(list.results or {}) do
        local avg = (result.min + result.max) / 2
        local unit, source = options.resultPrice(result)
        local line = { key = result.key, itemID = result.itemID, name = result.name, min = result.min,
            max = result.max, avg = avg, unit = unit, source = unit ~= nil and source or nil }
        if unit == nil then
            out.valueKnown = false
        else
            line.net = {}
            for name, yield in pairs({ min = result.min, avg = avg, max = result.max }) do
                local gross = round(unit * yield * crafts)
                line.net[name] = gross - cut(gross)
                if not oneOf then
                    out.value[name] = out.value[name] + line.net[name]
                end
            end
        end
        out.results[index] = line
    end
    if oneOf and out.valueKnown and #out.results > 0 then
        local low, high, sum = out.results[1], out.results[1], 0
        for index, line in ipairs(out.results) do
            sum = sum + line.net.avg
            if line.net.min < low.net.min then
                low, out.pick.min = line, index
            end
            if line.net.max > high.net.max then
                high, out.pick.max = line, index
            end
        end
        out.value = { min = low.net.min, avg = sum / #out.results, max = high.net.max }
    end
    if out.costKnown and out.valueKnown then
        out.margin, out.percent = {}, out.cost > 0 and {} or nil
        for _, name in ipairs({ "min", "avg", "max" }) do
            out.margin[name] = out.value[name] - out.cost
            if out.percent then
                out.percent[name] = out.margin[name] / out.cost * 100
            end
        end
    end
    return out
end
