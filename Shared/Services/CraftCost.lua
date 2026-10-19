local _, ns = ...

-- Craft cost and profit of one recipe. No frame code and no client call.
local CraftCost = {}
ns.CraftCost = CraftCost

local function round(number)
    return math.floor(number + 0.5)
end

-- Return the average number of items that one craft makes. A bad range gives 1.
function CraftCost.AverageMade(madeMin, madeMax)
    local low = type(madeMin) == "number" and madeMin > 0 and madeMin or nil
    local high = type(madeMax) == "number" and madeMax > 0 and madeMax or nil
    low = low or high or 1
    high = high or low
    if high < low then
        high = low
    end
    return (low + high) / 2
end

-- recipe: { reagents = { { itemID, count, name, icon } }, itemID (nil for an enchant), madeMin, madeMax }.
-- options: reagentPrice(itemID) and itemPrice(itemID) give copper or nil; cut(gross) gives the AH cut in copper.
-- Returns a table:
--   lines: one entry for each reagent, with unit (copper or nil) and total (copper or nil).
--   cost: the sum of the priced lines. partial: true if a reagent has no price (the cost is a lower limit).
--   hasItem: true if the recipe makes an item. made: the average number made.
--   unitValue and value: the AH value of one item and of the average made (nil if there is no price).
--   cutAmount, profit and percent: nil if there is no item or no item price. percent is profit / cost * 100.
function CraftCost.Compute(recipe, options)
    local result = { lines = {}, cost = 0, partial = false, hasItem = false }
    for index, reagent in ipairs(recipe.reagents or {}) do
        local count = reagent.count or 0
        local unit = options.reagentPrice(reagent.itemID)
        local total = unit ~= nil and unit * count or nil
        result.lines[index] = {
            itemID = reagent.itemID,
            name = reagent.name,
            icon = reagent.icon,
            count = count,
            unit = unit,
            total = total,
        }
        if total == nil then
            result.partial = true
        else
            result.cost = result.cost + total
        end
    end
    if recipe.itemID == nil then
        return result
    end
    result.hasItem = true
    result.made = CraftCost.AverageMade(recipe.madeMin, recipe.madeMax)
    local unitValue = options.itemPrice(recipe.itemID)
    if unitValue == nil then
        return result
    end
    result.unitValue = unitValue
    result.value = round(unitValue * result.made)
    result.cutAmount = options.cut(result.value)
    result.profit = result.value - result.cutAmount - result.cost
    if result.cost > 0 then
        result.percent = result.profit / result.cost * 100
    end
    return result
end
