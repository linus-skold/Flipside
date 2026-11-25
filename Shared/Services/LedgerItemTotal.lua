local _, ns = ...

-- The net result of one item in the ledger (SPEC 5.8 point 9, "Item detail"). Pure: no frame code, no write.
local LedgerItemTotal = {}
ns.LedgerItemTotal = LedgerItemTotal

-- Returns the totals of one item from full records. itemKey is the item key (D20), matched exactly.
-- sums are the daily sums of the same range (optional). They hold no split by item for old records, so they are not
-- counted. The result only tells with `hasSums` that they exist.
-- Money rules, each record counted once:
--   payout: the `money` of a sale (price - cut + the deposit back).
--   depositBack: the `deposit` field of a sale, the part of the payout that is the deposit. A sale without the field
--     counts 0 (the invoice gave no split), so its whole payout stays in Sold.
--   paid: the ahDeposit records minus the deposit refunds (source ahDepositRefund).
--   bought: type purchase, minus the outbid refunds (source ahOutbidRefund).
--   cut: the `cut` field of a sale. It is only shown. It is already out of Sold.
-- Range edge: a sale in the range can return a deposit that was paid before the range. Then depositBack is
--   capped at paid (not below 0). The rest of the deposit stays in Sold, because its payment is outside the range.
--   So the deposit lost is never negative.
-- Sold = payout - depositBack (= price - cut). It does not hold the returned deposit.
-- Deposit states (the deposit records have no auction id, so the split uses quantities of the range):
--   open = posted qty - sold qty - expired qty - cancelled qty (not below 0): the units still on sale.
--   active: the deposit of the open units, taken from the newest post records (deposit / qty for each unit).
--     It is capped at paid - depositBack. It is money out, but it is not lost yet.
--   lost (`deposits`) = paid - depositBack - active. It is the deposit of expired and cancelled auctions.
-- net = Sold - bought - lost - active. This is the real money result of the range: payouts - bought - paid.
-- Counts: posted, sold, expired and cancelled are quantities of the range. A count is nil ("no data") if a record
--   of that kind has no quantity. A kind with no record counts 0.
function LedgerItemTotal.Compute(records, sums, itemKey)
    local total = {
        soldQty = 0, soldMoney = 0, boughtQty = 0, boughtMoney = 0, deposits = 0, activeDeposits = 0, cut = 0, net = 0,
        postedQty = 0, expiredQty = 0, cancelledQty = 0, count = 0, hasSums = sums ~= nil and #sums > 0,
    }
    if type(itemKey) ~= "string" or itemKey == "" then
        return total
    end
    local payout, depositBack, paid = 0, 0, 0
    local posts, unknown = {}, {}
    local function addQty(field, record)
        if type(record.qty) == "number" then
            total[field] = total[field] + record.qty
        else
            unknown[field] = true
        end
    end
    for _, record in ipairs(records or {}) do
        if record.item == itemKey and record.type ~= "log" then
            local direction = ns.LedgerRecord.Direction(record.type)
            local money = record.money or 0
            if record.type == "sale" then
                addQty("soldQty", record)
                payout = payout + money
                depositBack = depositBack + (record.deposit or 0)
                total.cut = total.cut + (record.cut or 0)
                total.count = total.count + 1
            elseif record.type == "purchase" then
                total.boughtQty = total.boughtQty + (record.qty or 0)
                total.boughtMoney = total.boughtMoney + money
                total.count = total.count + 1
            elseif record.source == "ahDeposit" and direction == "out" then
                paid = paid + money
                total.count = total.count + 1
            elseif record.source == "ahDepositRefund" and direction == "in" then
                paid = paid - money
                total.count = total.count + 1
            elseif record.source == "ahOutbidRefund" and direction == "in" then
                total.boughtMoney = total.boughtMoney - money
                total.count = total.count + 1
            elseif record.type == "post" then
                addQty("postedQty", record)
                posts[#posts + 1] = record
            elseif record.type == "expired" then
                addQty("expiredQty", record)
            elseif record.type == "cancelled" then
                addQty("cancelledQty", record)
            end
        end
    end
    depositBack = math.min(depositBack, math.max(paid, 0))
    local unresolved = math.max(paid - depositBack, 0)
    -- Open units: take the deposit from the newest posts first.
    local open = total.postedQty - total.soldQty - total.expiredQty - total.cancelledQty
    local active = 0
    table.sort(posts, function(a, b)
        return (a.time or 0) > (b.time or 0)
    end)
    for _, post in ipairs(posts) do
        if open <= 0 then
            break
        end
        local qty = post.qty or 0
        if qty > 0 then
            local used = math.min(open, qty)
            active = active + (post.deposit or 0) * used / qty
            open = open - used
        end
    end
    active = math.min(math.floor(active + 0.5), unresolved)
    total.soldMoney = payout - depositBack
    total.activeDeposits = active
    total.deposits = paid - depositBack - active
    total.net = total.soldMoney - total.boughtMoney - total.deposits - total.activeDeposits
    -- A count with a record that has no quantity is not known.
    if unknown.soldQty then
        total.soldQty = nil
    end
    for _, field in ipairs({ "postedQty", "expiredQty", "cancelledQty" }) do
        if unknown[field] then
            total[field] = nil
        end
    end
    return total
end

-- Returns the totals of one item from a ledger store. options: char (nil = all), fromTime, as for Store:Records.
-- keepChar(char) (optional) says whether a character counts (the server filter of TBC) when char is nil.
function LedgerItemTotal.ForStore(store, options, itemKey, keepChar)
    options = options or {}
    local records = {}
    for _, record in ipairs(store:Records(options)) do
        if options.char or keepChar == nil or keepChar(record.char) then
            records[#records + 1] = record
        end
    end
    local sums = {}
    local chars = options.char and { options.char } or store:Characters()
    for _, char in ipairs(chars) do
        if options.char or keepChar == nil or keepChar(char) then
            for _, sum in ipairs(store:Sums({ char = char, fromTime = options.fromTime })) do
                sums[#sums + 1] = sum
            end
        end
    end
    return LedgerItemTotal.Compute(records, sums, itemKey)
end
