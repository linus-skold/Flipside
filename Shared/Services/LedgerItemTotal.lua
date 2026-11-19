local _, ns = ...

-- The net result of one item in the ledger (SPEC 5.8 point 9, "Item detail"). Pure: no frame code, no write.
local LedgerItemTotal = {}
ns.LedgerItemTotal = LedgerItemTotal

-- Returns the totals of one item from full records. itemKey is the item key (D20), matched exactly.
-- sums are the daily sums of the same range (optional). They hold no split by item for old records, so they are not
-- counted. The result only tells with `hasSums` that they exist.
-- Money rules, each record counted once:
--   sold: type sale (money is what the seller got: the price minus the cut, plus the deposit back).
--   bought: type purchase, minus the outbid refunds (source ahOutbidRefund).
--   deposits: source ahDeposit, minus the deposit refunds (source ahDepositRefund).
--   cut: the `cut` field of a sale. It is only shown. The sale money does not hold it, so net does not
--   subtract it again.
--   A post record has a `deposit` field, but the money of the deposit is in the ahDeposit record. It is not counted.
--   post, expired, cancelled and log records have no money flow.
-- net = sold money - bought money - deposits.
function LedgerItemTotal.Compute(records, sums, itemKey)
    local total = {
        soldQty = 0, soldMoney = 0, boughtQty = 0, boughtMoney = 0, deposits = 0, cut = 0, net = 0,
        count = 0, hasSums = sums ~= nil and #sums > 0,
    }
    if type(itemKey) ~= "string" or itemKey == "" then
        return total
    end
    for _, record in ipairs(records or {}) do
        if record.item == itemKey and record.type ~= "log" then
            local direction = ns.LedgerRecord.Direction(record.type)
            local money = record.money or 0
            if record.type == "sale" then
                total.soldQty = total.soldQty + (record.qty or 0)
                total.soldMoney = total.soldMoney + money
                total.cut = total.cut + (record.cut or 0)
                total.count = total.count + 1
            elseif record.type == "purchase" then
                total.boughtQty = total.boughtQty + (record.qty or 0)
                total.boughtMoney = total.boughtMoney + money
                total.count = total.count + 1
            elseif record.source == "ahDeposit" and direction == "out" then
                total.deposits = total.deposits + money
                total.count = total.count + 1
            elseif record.source == "ahDepositRefund" and direction == "in" then
                total.deposits = total.deposits - money
                total.count = total.count + 1
            elseif record.source == "ahOutbidRefund" and direction == "in" then
                total.boughtMoney = total.boughtMoney - money
                total.count = total.count + 1
            end
        end
    end
    total.net = total.soldMoney - total.boughtMoney - total.deposits
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
