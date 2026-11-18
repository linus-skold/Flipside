local _, ns = ...

-- The parts of a buy that the Buying tab and the Selling tab share: the cover plan, the text and the options of the
-- confirm box, the check of an auction before the buy, the event rules and the check that only one buy is open.
-- The box itself is in Shared/Features/Buying/BuyDialog.lua.
-- Each tab keeps its own buy state (tab.buy). The protected AH calls stay in the click handlers of the tabs (D26).
local BuyFlow = {}
ns.BuyFlow = BuyFlow

-- The time left codes 1 to 4 of the legacy client list rows.
local TIME_LEFT = { "Short", "Medium", "Long", "Very long" }

local function money(copper)
    return GetMoneyString(math.floor((copper or 0) + 0.5))
end

BuyFlow.Money = money

function BuyFlow.IsOwn(row)
    return row.isOwn == true or row.ownerItem == true
end

-- The key of a level: the group key of a stack group, else the unit price.
function BuyFlow.LevelId(level)
    return level.id or level.unitPrice
end

function BuyFlow.BuyoutOf(row)
    return row.buyout or math.floor(row.unitPrice * (row.quantity or 1) + 0.5)
end

-- True if two auctions are the same stack for sale: same item, seller, buyout and stack size.
function BuyFlow.SameAuction(a, b)
    return ns.BuyingPlan.GroupKey(a) == ns.BuyingPlan.GroupKey(b)
end

-- The first auction of a stack group that is not yours, or nil.
function BuyFlow.FirstFree(level)
    for _, row in ipairs(level.rows) do
        if not BuyFlow.IsOwn(row) then
            return row
        end
    end
    return nil
end

-- The cheapest level that is not yours, or nil.
function BuyFlow.CheapestFree(levels)
    for _, level in ipairs(levels or {}) do
        if not level.own and BuyFlow.FirstFree(level) then
            return level
        end
    end
    return nil
end

-- The units that one purchase covers. For a commodity, the purchase takes the cheapest units first: from the level
-- first up to the level target, and at most amount units (nil means all). For an item, it is one stack of target.
-- Returns { quantity, cost, covered = { [unitPrice] = true }, last = the highest level reached, levels = count,
-- complete = true if the last level is taken whole, own = true if a level in the range is yours }.
function BuyFlow.CoverPlan(levels, first, target, amount, isItem)
    local plan = { quantity = 0, cost = 0, covered = {}, levels = 0, complete = true, own = false, isItem = isItem }
    if isItem then
        local size = target.stackSize or target.quantity
        plan.quantity, plan.cost = size, target.unitPrice * size
        plan.covered[BuyFlow.LevelId(target)], plan.last, plan.levels = true, target, 1
        return plan
    end
    local left = amount or math.huge
    for _, level in ipairs(levels) do
        if level.unitPrice >= first.unitPrice and level.unitPrice <= target.unitPrice and left > 0 then
            local take = math.min(level.quantity, left)
            left = left - take
            plan.quantity = plan.quantity + take
            plan.cost = plan.cost + take * level.unitPrice
            plan.covered[level.unitPrice] = true
            plan.last, plan.levels = level, plan.levels + 1
            plan.complete = take == level.quantity
            plan.own = plan.own or level.own
        end
    end
    return plan
end

-- The text of the confirm box. label is the item link or the item name. note is an optional first line (item buy).
-- Returns the text, true if the total is above the max price of the entry, true if the price jumped.
function BuyFlow.QuoteText(buy, label, note)
    local lines = {
        string.format("Buy %d x %s", buy.quantity, label),
        string.format("Unit price: %s   Total: %s", money(buy.unit), money(buy.total)),
    }
    if buy.isItem then
        lines[1] = string.format("Buy one stack: %d x %s", buy.quantity, label)
        local owner, left = buy.row.owner, ns.Flavour and ns.Flavour.hasCommodityMarket == false
            and TIME_LEFT[buy.row.timeLeft or 0] or nil
        if owner or left then
            lines[#lines + 1] = string.format("Seller: %s   Time left: %s", owner or "?", left or "?")
        end
        lines[#lines + 1] = "Available: " .. ns.BuyingPlan.AvailableText(buy.stacks or 1, buy.quantity)
        if note then
            table.insert(lines, 1, note)
        end
    end
    if not buy.isItem and buy.left then
        lines[#lines + 1] = "Quote time left: " .. buy.left .. " s"
    end
    local limit = nil
    if not buy.entry.noMax then
        limit = (buy.entry.maxPrice or 0) * buy.quantity
    end
    local over = limit ~= nil and buy.total > limit
    if over then
        lines[#lines + 1] = "Above your max price: " .. money(limit)
    end
    if buy.jump then
        lines[#lines + 1] = string.format("Price jumps from %s to %s (+%.0f%%)", money(buy.jump.prev),
            money(buy.unit), buy.jump.percent)
    end
    return table.concat(lines, "\n"), over, buy.jump ~= nil
end

-- The title and the labels of the confirm box. chain is true while a run of item buys goes on.
function BuyFlow.ConfirmOptions(buy, over, jumped, chain)
    local preview = buy.phase == "preview"
    local yes = preview and "Get quote" or (over and "Buy anyway" or "Confirm")
    if buy.isItem then
        yes = chain and "Buy next" or "Buy"
    end
    return {
        title = preview and "Next purchase" or "Confirm purchase", yes = yes, no = "Cancel", red = over or jumped,
        keep = true,
    }
end

-- The list index of an auction like buy.row (same item, stack size, buyout and seller) in rows, or nil.
-- It never gives your own auction or an auction of another price or stack size. The shown auction comes first.
function BuyFlow.Refind(rows, buy)
    local found
    for _, row in ipairs(rows or {}) do
        if not BuyFlow.IsOwn(row) and BuyFlow.SameAuction(row, buy.row) then
            if row.auctionID == buy.row.auctionID then
                return row.auctionID
            end
            found = found or row.auctionID
        end
    end
    return found
end

-- The event rules: a buy takes an event only in the phase that waits for it.
function BuyFlow.QuoteApplies(buy)
    return buy ~= nil and not buy.isItem and (buy.phase == "quoting" or buy.phase == "quoted")
end

function BuyFlow.CommodityResultApplies(buy)
    return buy ~= nil and buy.phase == "confirming" and not buy.isItem
end

function BuyFlow.ItemDoneApplies(buy, auctionID)
    return buy ~= nil and buy.phase == "confirming" and buy.isItem == true and auctionID == buy.auctionID
end

function BuyFlow.ItemErrorApplies(buy)
    return buy ~= nil and buy.phase == "confirming" and buy.isItem == true
end

-- One buy at a time across both tabs: each tab registers a function that tells if its buy is open.
local holders = {}

-- Register the buy state of a tab. kind is "buying" or "selling"; a new tab of a kind replaces the old one.
function BuyFlow.Register(kind, isOpen)
    holders[kind] = isOpen
end

-- True if the tab of another kind has a buy open.
function BuyFlow.OtherOpen(kind)
    for other, isOpen in pairs(holders) do
        if other ~= kind and isOpen() then
            return true
        end
    end
    return false
end
