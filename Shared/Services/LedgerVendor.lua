local _, ns = ...

-- The item detail of the merchant money changes (SPEC 5.8). The money tracker writes the record. This module gives
-- it the item and the quantity of a vendor sale (from the buyback list), of a vendor purchase (from the
-- BuyMerchantItem post-hook) and tells it when a spend is a repair (the cost read at the merchant).
-- All reads go through a pcall, so a nil or a failing API gives no detail and never an error.
local LedgerVendor = {}
ns.LedgerVendor = LedgerVendor

local OWNER = "Flipside.LedgerVendor"

-- The seconds that a purchase call waits for its money change.
LedgerVendor.PURCHASE_SECONDS = 10

local function number(value)
    return type(value) == "number" and value or nil
end

-- Call fn in a pcall. Returns the results of fn, or nothing if fn is missing or fails.
local function call(fn, ...)
    if type(fn) ~= "function" then
        return
    end
    local results = { pcall(fn, ...) }
    if not results[1] then
        return
    end
    return unpack(results, 2, table.maxn(results))
end

-- deps: bus, tracker (LedgerMoney), now() (GetTime), itemKey(link) and api with these functions (all optional):
-- buybackCount(), buyback(index) (name, texture, price, quantity), buybackLink(index), merchantLink(index),
-- merchantInfo(index) (price, stackCount) and repairCost() (cost, canRepair).
-- Returns { Match = fn(delta), OnBuy = fn(index, quantity), Pending = fn }.
function LedgerVendor.New(deps)
    local vendor = {}
    local api = deps.api
    local used = {}
    local purchases = {}
    local repairCost

    -- Read the buyback list as { sig, link, price, qty } entries, oldest first.
    local function readBuyback()
        local entries = {}
        local count = number((call(api.buybackCount))) or 0
        for index = 1, count do
            local _, _, price, quantity = call(api.buyback, index)
            local link = call(api.buybackLink, index)
            if number(price) then
                local qty = (number(quantity) and quantity >= 1) and math.floor(quantity) or 1
                entries[#entries + 1] = {
                    sig = tostring(link) .. "|" .. price .. "|" .. qty, link = link, price = price, qty = qty,
                }
            end
        end
        return entries
    end

    local function present(entries)
        local counts = {}
        for _, entry in ipairs(entries) do
            counts[entry.sig] = (counts[entry.sig] or 0) + 1
        end
        return counts
    end

    -- An entry that left the list (bought back) is no longer used.
    local function clamp(entries)
        local counts = present(entries)
        for sig, count in pairs(used) do
            used[sig] = math.min(count, counts[sig] or 0)
        end
        return counts
    end

    local function readRepair()
        local cost = number((call(api.repairCost)))
        if cost and cost > 0 then
            repairCost = cost
        end
    end

    local function onShow()
        -- The entries that are already in the list are not sales of this visit.
        used = present(readBuyback())
        repairCost = nil
        readRepair()
    end

    local function onUpdate()
        clamp(readBuyback())
        readRepair()
    end

    local function onClosed()
        used, purchases, repairCost = {}, {}, nil
    end

    -- A sale: the newest buyback entry that nobody used yet and that has the price of the money change.
    -- The price is the total of the stack. An entry with a per-unit price also matches.
    local function matchSale(delta)
        local entries = readBuyback()
        local counts = clamp(entries)
        for index = #entries, 1, -1 do
            local entry = entries[index]
            if (counts[entry.sig] or 0) > (used[entry.sig] or 0)
                and (entry.price == delta or entry.price * entry.qty == delta) then
                used[entry.sig] = (used[entry.sig] or 0) + 1
                return { item = entry.link and deps.itemKey(entry.link) or nil, qty = entry.qty }
            end
        end
        return nil
    end

    local function matchPurchase(delta)
        local now = deps.now()
        local keep = {}
        local found
        for _, purchase in ipairs(purchases) do
            if now - purchase.time <= LedgerVendor.PURCHASE_SECONDS then
                if not found and (purchase.amounts[1] == -delta or purchase.amounts[2] == -delta) then
                    found = purchase
                else
                    keep[#keep + 1] = purchase
                end
            end
        end
        purchases = keep
        if found then
            return { item = found.item, qty = found.qty }
        end
        return nil
    end

    -- A spend: a bought item first, then a repair of the cost that was read at the merchant.
    local function matchSpend(delta)
        local purchase = matchPurchase(delta)
        if purchase then
            return purchase
        end
        if repairCost and repairCost == -delta then
            repairCost = nil
            return { source = "repair" }
        end
        return nil
    end

    -- Called by the tracker for each money change in the merchant context. Returns { item, qty, source } or nil.
    function vendor.Match(delta)
        if delta > 0 then
            return matchSale(delta)
        end
        return matchSpend(delta)
    end

    -- Called right after BuyMerchantItem(index, quantity). The quantity counts items; without it the client buys
    -- one stack. The price is for one stack (Blizzard_UIPanels_Game MerchantFrame.lua: cost per stack times
    -- the number of items divided by the stack size).
    function vendor.OnBuy(index, quantity)
        local link = call(api.merchantLink, index)
        local price, stack = call(api.merchantInfo, index)
        price = number(price)
        stack = (number(stack) and stack >= 1) and math.floor(stack) or 1
        if not price or price <= 0 then
            return false
        end
        local qty = (number(quantity) and quantity >= 1) and math.floor(quantity) or stack
        local exact = price * qty / stack
        purchases[#purchases + 1] = {
            item = link and deps.itemKey(link) or nil, qty = qty, time = deps.now(),
            amounts = { math.floor(exact), math.ceil(exact) },
        }
        return true
    end

    function vendor.Pending()
        return #purchases
    end

    if deps.bus then
        deps.bus:Subscribe("MERCHANT_SHOW", OWNER, onShow)
        deps.bus:Subscribe("MERCHANT_UPDATE", OWNER, onUpdate)
        deps.bus:Subscribe("MERCHANT_CLOSED", OWNER, onClosed)
    end
    if deps.tracker and deps.tracker.SetMerchantMatcher then
        deps.tracker:SetMerchantMatcher(vendor.Match)
    end
    return vendor
end
