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

BuyingPlan.VENDOR_FORMULA = "vendorsell"
BuyingPlan.VENDOR_PATH = "Vendor"

-- The items that the AH sells below their max price. deps: store (ScanStore-like: Keys, Get), itemCache
-- (GetState(itemID) must not ask the client; Get(itemID) returns the info of a loaded item), formulaRun,
-- formula (the max price formula text), since (server time: older records do not count).
-- job is optional: it gets one checkpoint for each record.
-- Only a record from a full scan at or after since counts. An item with no vendor price is skipped. An item whose
-- data is not loaded is skipped and counted. This function asks for no item data. It lists the items that the caller
-- can request (stats.queue, state "unknown") and the items with an open request (stats.waiting).
-- Returns the entries, sorted by profit for each unit (max price - ScanMin), highest first, and the stats
-- { records, unknown, queue = { itemID }, waiting = { itemID } }.
function BuyingPlan.VendorEntries(deps, job)
    local store, cache, run = deps.store, deps.itemCache, deps.formulaRun
    local since = deps.since or 0
    local entries = {}
    local stats = { records = 0, unknown = 0, queue = {}, waiting = {} }
    local seen = {}
    for _, key in ipairs(store:Keys()) do
        local record = store:Get(key)
        local latest = record and record.latest
        local parsed = latest and ns.ItemString.ParseKey(key)
        if parsed and not latest.partial and latest.time >= since and latest.min > 0 then
            stats.records = stats.records + 1
            local itemID = parsed.itemID
            local state = cache:GetState(itemID)
            local info = state == "loaded" and cache:Get(itemID) or nil
            if info == nil then
                stats.unknown = stats.unknown + 1
                if not seen[itemID] then
                    seen[itemID] = true
                    if state == "unknown" then
                        stats.queue[#stats.queue + 1] = itemID
                    elseif state == "requested" then
                        stats.waiting[#stats.waiting + 1] = itemID
                    end
                end
            elseif type(info.sellPrice) == "number" and info.sellPrice > 0 then
                local max = run:Evaluate(deps.formula, key)
                if type(max) == "number" and max > latest.min then
                    entries[#entries + 1] = {
                        key = key,
                        itemID = parsed.itemID,
                        groupPath = BuyingPlan.VENDOR_PATH,
                        operationName = BuyingPlan.VENDOR_PATH,
                        showAboveMax = false,
                        maxPrice = max,
                        scanMin = latest.min,
                        profit = max - latest.min,
                    }
                end
            end
        end
        if job then
            job:Checkpoint(1)
        end
    end
    table.sort(entries, function(a, b)
        if a.profit ~= b.profit then
            return a.profit > b.profit
        end
        return a.key < b.key
    end)
    return entries, stats
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

-- The group key of an auction row: item, seller, buyout and stack size. Auctions with the same key are the same
-- stack for sale, so a buy of one is as good as a buy of another.
function BuyingPlan.GroupKey(row)
    local link = row.itemLink
    local item = link and (ns.ItemString and ns.ItemString.ToExactKey(link) or link) or ""
    local buyout = row.buyout or math.floor(row.unitPrice * (row.quantity or 1) + 0.5)
    return string.format("%s|%s|%d|%d", item, row.owner or "", buyout, row.quantity or 1)
end

-- The key that Buy next follows from one bought stack to the next: buyout and stack size only. It leaves out the link
-- and the seller, which a client can give late or not at all, so a stack keeps its key between two reads.
function BuyingPlan.ChainKey(row)
    local buyout = row.buyout or math.floor(row.unitPrice * (row.quantity or 1) + 0.5)
    return string.format("%d|%d", buyout, row.quantity or 1)
end

-- The text of the Available column of a stack group: "50 stacks of 1", or "1 stack of 20".
function BuyingPlan.AvailableText(stacks, stackSize)
    return string.format("%d %s of %d", stacks, stacks == 1 and "stack" or "stacks", stackSize)
end

local function ByPageThenID(a, b)
    if a.unitPrice ~= b.unitPrice then
        return a.unitPrice < b.unitPrice
    end
    if (a.quantity or 1) ~= (b.quantity or 1) then
        return (a.quantity or 1) < (b.quantity or 1)
    end
    if (a.page or 0) ~= (b.page or 0) then
        return (a.page or 0) < (b.page or 0)
    end
    return (a.auctionID or 0) < (b.auctionID or 0)
end

-- Sort rows by unit price, then stack size, then page, then list index. Returns the same table.
function BuyingPlan.SortRows(rows)
    table.sort(rows, ByPageThenID)
    return rows
end

-- Replace the rows of the pages first to last (0-based) by fresh rows. Rows of a page at or after pageCount are
-- dropped, because the list has become shorter. Returns a new sorted list.
function BuyingPlan.MergePages(rows, first, last, fresh, pageCount)
    local out = {}
    for _, row in ipairs(rows or {}) do
        local page = row.page or 0
        if (page < first or page > last) and (pageCount == nil or page < pageCount) then
            out[#out + 1] = row
        end
    end
    for _, row in ipairs(fresh or {}) do
        out[#out + 1] = row
    end
    return BuyingPlan.SortRows(out)
end

-- Group item auctions (isCommodity = false) by GroupKey. One level for each group:
-- { id = key, unitPrice, stackSize, stacks, quantity (all items), listings = stacks, own, owner, timeLeft, rows }.
-- A group of your own auctions is apart from the others. timeLeft is the lowest code of the group.
local function StackLevels(rows, opts)
    local byKey, levels = {}, {}
    for _, row in ipairs(rows) do
        if type(row.unitPrice) == "number" then
            local own = IsOwn(row, opts)
            local key = BuyingPlan.GroupKey(row) .. (own and "|own" or "")
            local level = byKey[key]
            if not level then
                level = {
                    id = key, unitPrice = row.unitPrice, stackSize = row.quantity or 1, stacks = 0, quantity = 0,
                    listings = 0, own = own, owner = row.owner, timeLeft = row.timeLeft, rows = {},
                }
                byKey[key] = level
                levels[#levels + 1] = level
            end
            level.stacks = level.stacks + 1
            level.listings = level.stacks
            level.quantity = level.quantity + (row.quantity or 1)
            level.rows[#level.rows + 1] = row
            if row.timeLeft and (not level.timeLeft or row.timeLeft < level.timeLeft) then
                level.timeLeft = row.timeLeft
            end
        end
    end
    table.sort(levels, function(a, b)
        if a.unitPrice ~= b.unitPrice then
            return a.unitPrice < b.unitPrice
        end
        if a.stackSize ~= b.stackSize then
            return a.stackSize < b.stackSize
        end
        if (a.owner or "") ~= (b.owner or "") then
            return (a.owner or "") < (b.owner or "")
        end
        return a.id < b.id
    end)
    return levels
end

-- Group live rows. rows: { auctionID, unitPrice, quantity, isCommodity, ownerItem, owner, buyout, itemLink }.
-- Item auctions (isCommodity = false) form one level for each seller, price and stack size (see StackLevels).
-- Other rows (commodities) form one level for each unit price:
-- Returns levels, cheapest first: { unitPrice, quantity, listings, own, rows }. own is true if one row is yours.
function BuyingPlan.PriceLevels(rows, opts)
    opts = opts or {}
    local byPrice, levels = {}, {}
    if rows and rows[1] and rows[1].isCommodity == false then
        return StackLevels(rows, opts)
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
