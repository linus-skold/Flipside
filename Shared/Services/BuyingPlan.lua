local _, ns = ...

-- Pure buying logic: the shopping list, the evaluation of live rows and a session log.

local BuyingPlan = {}
ns.BuyingPlan = BuyingPlan

local BASE_ID = 1
local LOG_CAP = 200

local function PriceReason(info)
    if info and info.kind == "error" then
        return "formula error: " .. tostring(info.message)
    end
    return "no data"
end

-- Build the entry of one item for an operation. op is { name, settings }.
local function MakeEntry(run, key, groupID, path, opID, op)
    local parsed = ns.ItemString.ParseKey(key)
    local formula = op.settings.maxPrice
    local noMax = type(formula) ~= "string" or formula:match("^%s*$") ~= nil
    local copper, info
    if not noMax then
        copper, info = run:Evaluate(formula, key)
    end
    local entry = {
        key = key,
        itemID = parsed and parsed.itemID,
        groupID = groupID,
        groupPath = path,
        operationID = opID,
        operationName = op.name,
        showAboveMax = op.settings.showAboveMax == true,
    }
    if noMax then
        entry.noMax = true
    elseif copper ~= nil and copper > 0 then
        entry.maxPrice = copper
    else
        entry.reason = PriceReason(info)
    end
    return entry
end

-- deps.rules: RulesStore-like (Walk, ItemsIn, Path, Name, EffectiveOperation, GetOperation).
-- deps.formulaRun: FormulaRun-like (Evaluate(text, key) returns copper and info).
-- Returns one entry for each item of a group that has a buying operation.
function BuyingPlan.ShoppingList(deps)
    local rules, run = deps.rules, deps.formulaRun
    local list = {}
    local operations = {}
    rules:Walk(function(groupID)
        if groupID == BASE_ID then
            return
        end
        local opID = rules:EffectiveOperation(groupID, "buying")
        if not opID then
            return
        end
        local op = operations[opID]
        if op == nil then
            op = rules:GetOperation(opID) or false
            operations[opID] = op
        end
        if not op then
            return
        end
        local path = rules:Path(groupID)
        for _, key in ipairs(rules:ItemsIn(groupID)) do
            list[#list + 1] = MakeEntry(run, key, groupID, path, opID, op)
        end
    end)
    return list
end

-- The items of a search list as entries. items: { { itemID, key?, name? } }. deps as for ShoppingList.
-- An item uses the buying operation of its group (or of Base). With none, it uses the built-in Default settings.
-- deps.label is the text for groupPath of an item that is in no group.
function BuyingPlan.ListEntries(items, deps)
    local rules, run = deps.rules, deps.formulaRun
    local entries = {}
    for index, item in ipairs(items or {}) do
        local key = item.key or (item.itemID and string.format("%d", item.itemID))
        if key and ns.ItemString.ParseKey(key) then
            local groupID = rules and rules.GroupOf and rules:GroupOf(key) or nil
            local effective = groupID or BASE_ID
            local opID = rules and rules:EffectiveOperation(effective, "buying")
            local op = opID and rules:GetOperation(opID) or nil
            if not op then
                opID = nil
                local Schema = ns.OperationSchema
                op = { name = Schema.DEFAULT_BUYING_NAME, settings = Schema.DefaultBuyingSettings() }
            end
            local path = groupID and groupID ~= BASE_ID and rules:Path(groupID) or deps.label
            local entry = MakeEntry(run, key, groupID, path, opID, op)
            entry.name = item.name
            entry.listIndex = index
            entries[#entries + 1] = entry
        end
    end
    return entries
end
local function IsOwn(row, opts)
    if opts.isOwn then
        return opts.isOwn(row) == true
    end
    return row.isOwn == true or row.ownerItem == true
end

-- rows: live rows sorted by unitPrice. Rows: { auctionID, unitPrice, quantity, isCommodity, ownerItem }.
-- opts: isOwn(row), showAboveMax (default: entry.showAboveMax).
-- Returns { buyable, first, quantity, cost, aboveMax, stop, maxPrice }.
function BuyingPlan.Evaluate(entry, rows, opts)
    opts = opts or {}
    rows = rows or {}
    local result = { buyable = {}, aboveMax = {}, quantity = 0, cost = 0, maxPrice = entry.maxPrice }
    local showAbove = opts.showAboveMax
    if showAbove == nil then
        showAbove = entry.showAboveMax
    end
    local max = entry.maxPrice
    if not max and not entry.noMax then
        result.stop = "no max price"
        return result
    end
    if #rows == 0 then
        result.stop = "no results"
        return result
    end
    local foreign = 0
    for _, row in ipairs(rows) do
        if not IsOwn(row, opts) and type(row.unitPrice) == "number" then
            foreign = foreign + 1
            if max == nil or row.unitPrice <= max then
                local quantity = row.quantity or 1
                result.buyable[#result.buyable + 1] = row
                result.quantity = result.quantity + quantity
                result.cost = result.cost + row.unitPrice * quantity
            elseif showAbove then
                result.aboveMax[#result.aboveMax + 1] = row
            end
        end
    end
    result.first = result.buyable[1]
    if not result.first then
        result.stop = foreign == 0 and "own auction only" or "above max price"
    end
    return result
end

-- Group live rows by unit price. rows: { auctionID, unitPrice, quantity, isCommodity, ownerItem }.
-- Returns levels, cheapest first: { unitPrice, quantity, listings, own, rows }. own is true if one row is yours.
-- opts.group = false gives one level for each row (an auction): { id = row.auctionID, unitPrice, quantity, listings =
-- 1, own, rows = { row } }, sorted by unit price, then by stack size, then by auctionID.
function BuyingPlan.PriceLevels(rows, opts)
    opts = opts or {}
    local byPrice, levels = {}, {}
    if opts.group == false then
        for _, row in ipairs(rows or {}) do
            if type(row.unitPrice) == "number" then
                levels[#levels + 1] = {
                    id = row.auctionID, unitPrice = row.unitPrice, quantity = row.quantity or 1, listings = 1,
                    own = IsOwn(row, opts), rows = { row },
                }
            end
        end
        table.sort(levels, function(a, b)
            if a.unitPrice ~= b.unitPrice then
                return a.unitPrice < b.unitPrice
            end
            if a.quantity ~= b.quantity then
                return a.quantity < b.quantity
            end
            return (a.id or 0) < (b.id or 0)
        end)
        return levels
    end
    for _, row in ipairs(rows or {}) do
        if type(row.unitPrice) == "number" then
            local level = byPrice[row.unitPrice]
            if not level then
                level = { unitPrice = row.unitPrice, quantity = 0, listings = 0, own = false, rows = {} }
                byPrice[row.unitPrice] = level
                levels[#levels + 1] = level
            end
            level.quantity = level.quantity + (row.quantity or 1)
            level.listings = level.listings + 1
            level.rows[#level.rows + 1] = row
            if IsOwn(row, opts) then
                level.own = true
            end
        end
    end
    table.sort(levels, function(a, b)
        return a.unitPrice < b.unitPrice
    end)
    return levels
end

-- The next level to buy after lastPrice (the price of the level bought last, or nil).
-- A commodity level is gone after a buy, so only a higher price counts.
-- includeSame also lets the same price count (an item has one auction for each buy).
function BuyingPlan.NextLevel(levels, lastPrice, includeSame)
    for _, level in ipairs(levels or {}) do
        if lastPrice == nil or level.unitPrice > lastPrice or (includeSame and level.unitPrice == lastPrice) then
            return level
        end
    end
    return nil
end

-- Tell if nextPrice is more than percent above prevPrice. Returns { jump, percent }; percent is the rise in percent.
function BuyingPlan.JumpCheck(prevPrice, nextPrice, percent)
    if type(prevPrice) ~= "number" or type(nextPrice) ~= "number" or prevPrice <= 0 then
        return { jump = false, percent = 0 }
    end
    local rise = (nextPrice - prevPrice) / prevPrice * 100
    return { jump = rise > (percent or 0), percent = rise }
end
local Log = {}
Log.__index = Log

-- Returns a session log that keeps the newest cap entries.
function BuyingPlan.NewLog(cap)
    return setmetatable({ _cap = cap or LOG_CAP, _list = {}, _seq = 0 }, Log)
end

function Log:Add(entry, decision, reason)
    self._seq = self._seq + 1
    local list = self._list
    list[#list + 1] = {
        seq = self._seq,
        key = entry and entry.key,
        itemID = entry and entry.itemID,
        groupPath = entry and entry.groupPath,
        operationName = entry and entry.operationName,
        decision = decision,
        reason = reason,
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
BuyingPlan.Log = BuyingPlan.NewLog(LOG_CAP)
