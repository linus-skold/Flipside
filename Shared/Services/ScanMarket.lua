local _, ns = ...

-- Reduces the auctions of one item in one scan to a snapshot of numbers.
-- Rules for the market value (the numbers 30%, 15%, 20% and 1.5 come from the spec reference):
-- 1. Sort the auctions by unit price, lowest first. Keep the lowest 30% (by auction count, at least 1).
-- 2. The first 15% (at least 1) are always kept. After them, cut at the first unit price
--    that is 20% or more above the previous one.
-- 3. Drop unit prices more than 1.5 standard deviations (population, divide by N) from the mean.
--    If this drops every price, or the deviation is 0, keep the set from step 2.
-- 4. Market value is the plain average of the rest, rounded half up to whole copper.
local ScanMarket = {}
ns.ScanMarket = ScanMarket

local KEEP_PERCENT = 30
local BASE_PERCENT = 15
local OUTLIER_DEVIATIONS = 1.5

local function RoundHalfUp(value)
    local rounded = math.floor(value + 0.5)
    if rounded < 1 then
        return 1
    end
    return rounded
end

local function CeilPercent(count, percent)
    return math.max(1, math.ceil(count * percent / 100))
end

local function IsValid(auction)
    if type(auction) ~= "table" then
        return false
    end
    local price, count = auction.unitPrice, auction.count
    if type(price) ~= "number" or type(count) ~= "number" then
        return false
    end
    -- The price test also rejects NaN, because NaN > 0 is false.
    if not (price > 0 and price < math.huge) then
        return false
    end
    return count >= 1 and count < math.huge and count == math.floor(count)
end

-- Returns the prices that remain after the sd step; prices is not changed.
local function FilterOutliers(prices, last)
    local sum = 0
    for i = 1, last do
        sum = sum + prices[i]
    end
    local mean = sum / last
    local squares = 0
    for i = 1, last do
        local diff = prices[i] - mean
        squares = squares + diff * diff
    end
    local limit = OUTLIER_DEVIATIONS * math.sqrt(squares / last)
    if limit == 0 then
        return prices, last
    end
    local kept, n = {}, 0
    for i = 1, last do
        if math.abs(prices[i] - mean) <= limit then
            n = n + 1
            kept[n] = prices[i]
        end
    end
    if n == 0 then
        return prices, last
    end
    return kept, n
end

local function MarketValue(prices, total)
    local keep = CeilPercent(total, KEEP_PERCENT)
    local base = CeilPercent(total, BASE_PERCENT)
    local last = math.min(keep, total)
    for i = base + 1, last do
        -- price >= 1.2 * previous, written in integers to avoid float error.
        if prices[i] * 5 >= prices[i - 1] * 6 then
            last = i - 1
            break
        end
    end
    local kept, n = FilterOutliers(prices, last)
    local sum = 0
    for i = 1, n do
        sum = sum + kept[i]
    end
    return RoundHalfUp(sum / n)
end

-- Returns { min, market, qty, auctions } in whole copper, or nil if no auction is valid.
function ScanMarket.Reduce(auctions)
    local prices, total, qty = {}, 0, 0
    for _, auction in ipairs(auctions or {}) do
        if IsValid(auction) then
            total = total + 1
            prices[total] = auction.unitPrice
            qty = qty + auction.count
        end
    end
    if total == 0 then
        return nil
    end
    table.sort(prices)
    return {
        min = RoundHalfUp(prices[1]),
        market = MarketValue(prices, total),
        qty = qty,
        auctions = total,
    }
end
