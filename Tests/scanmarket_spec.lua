describe("ScanMarket", function()
    local SM

    before_each(function()
        local ns = {}
        assert(loadfile("Services/ScanMarket.lua"))("Flipside", ns)
        SM = ns.ScanMarket
    end)

    -- Builds auctions with count 1 from a list of unit prices.
    local function Make(prices)
        local list = {}
        for i, p in ipairs(prices) do
            list[i] = { unitPrice = p, count = 1 }
        end
        return list
    end

    -- Returns a list of `n` copies of `price`.
    local function Rep(price, n)
        local t = {}
        for i = 1, n do
            t[i] = price
        end
        return t
    end

    -- Appends list b to list a and returns a.
    local function Cat(a, b)
        for _, v in ipairs(b) do
            a[#a + 1] = v
        end
        return a
    end

    it("reduces one auction", function()
        -- N=1: keep=1, base=1. Market = 100.
        local r = SM.Reduce({ { unitPrice = 100, count = 5 } })
        assert.are.same({ min = 100, market = 100, qty = 5, auctions = 1 }, r)
    end)

    it("reduces two auctions to the lowest price", function()
        -- N=2: keep=ceil(0.6)=1. Only 50 remains.
        local r = SM.Reduce(Make({ 80, 50 }))
        assert.are.same({ min = 50, market = 50, qty = 2, auctions = 2 }, r)
    end)

    it("handles 10 equal prices", function()
        -- N=10: keep=3, base=2. Prices 100,100,100. SD 0. Market 100.
        local r = SM.Reduce(Make(Rep(100, 10)))
        assert.are.same({ min = 100, market = 100, qty = 10, auctions = 10 }, r)
    end)

    it("cuts at a jump inside the 30% window", function()
        -- N=10: keep=3, base=2. Index 3 is 130 >= 1.2*100, so cut. Left 100,100. Market 100.
        local r = SM.Reduce(Make(Cat({ 100, 100, 130 }, Rep(200, 7))))
        assert.are.equal(100, r.market)
        assert.are.equal(100, r.min)
    end)

    it("does not cut at a jump inside the first 15%", function()
        -- N=20: keep=6, base=3. Jump 100->125 is at index 3, inside base, so no cut.
        -- Left 100,100,125,125,125,125. Mean 700/6=116.67. SD=11.79, limit 17.68, none dropped.
        -- Market = 116.67 -> 117.
        local r = SM.Reduce(Make(Cat({ 100, 100, 125, 125, 125, 125 }, Rep(1000, 14))))
        assert.are.equal(117, r.market)
    end)

    it("removes an outlier with the SD step", function()
        -- N=40: keep=12, base=6. Window 10,100 x11 (no jump after base).
        -- Mean 1110/12=92.5. Variance (82.5^2 + 11*7.5^2)/12=618.75. SD 24.875, limit 37.31.
        -- 10 is 82.5 away, so it is dropped. Market = 100.
        local r = SM.Reduce(Make(Cat(Cat({ 10 }, Rep(100, 11)), Rep(1000, 28))))
        assert.are.equal(100, r.market)
        assert.are.equal(10, r.min)
    end)

    it("drops nothing when the SD is 0", function()
        -- N=20: keep=6, base=3. Six prices of 77. SD 0. Market 77.
        local r = SM.Reduce(Make(Cat(Rep(77, 6), Rep(500, 14))))
        assert.are.equal(77, r.market)
    end)

    it("keeps values when the SD limit is tight but nothing is far away", function()
        -- Two prices 100,110 (N=4, keep=2, base=1, 110 < 120). Mean 105, SD 5, limit 7.5.
        -- Both are 5 away, so both stay. Market 105. (The drop-everything fallback cannot
        -- happen for real numbers: some price is always within 1 SD of the mean.)
        local r = SM.Reduce(Make({ 100, 110, 500, 600 }))
        assert.are.equal(105, r.market)
    end)

    it("rounds half up with fractional unit prices", function()
        -- 10.5 -> 11, 10.49 -> 10, 0.2 -> 1 (minimum 1).
        local r = SM.Reduce({ { unitPrice = 10.5, count = 1 } })
        assert.are.equal(11, r.min)
        assert.are.equal(11, r.market)
        r = SM.Reduce({ { unitPrice = 10.49, count = 1 } })
        assert.are.equal(10, r.min)
        assert.are.equal(10, r.market)
        r = SM.Reduce({ { unitPrice = 0.2, count = 1 } })
        assert.are.equal(1, r.min)
        assert.are.equal(1, r.market)
    end)

    it("rounds a fractional average half up", function()
        -- N=4: keep=2, base=1. Prices 10, 11 (11 < 12, no cut). Mean 10.5, SD 0.5, both inside.
        -- Market = 10.5 -> 11.
        local r = SM.Reduce(Make({ 10, 11, 90, 95 }))
        assert.are.equal(11, r.market)
    end)

    it("sums counts into qty without weighting the market", function()
        -- N=4: keep=2. Prices 100 (count 1), 110 (count 100). 110 < 120, no cut.
        -- Mean 105, SD 5, limit 7.5, both stay. Market 105 (weighted would be about 110). Qty 103.
        local r = SM.Reduce({
            { unitPrice = 100, count = 1 },
            { unitPrice = 110, count = 100 },
            { unitPrice = 500, count = 1 },
            { unitPrice = 600, count = 1 },
        })
        assert.are.same({ min = 100, market = 105, qty = 103, auctions = 4 }, r)
    end)

    it("ignores invalid auctions", function()
        local r = SM.Reduce({
            { unitPrice = 0, count = 1 },
            { unitPrice = -5, count = 1 },
            { unitPrice = "x", count = 1 },
            { unitPrice = 0 / 0, count = 1 },
            { unitPrice = math.huge, count = 1 },
            { unitPrice = 100, count = 0 },
            { unitPrice = 100, count = 1.5 },
            { unitPrice = 100 },
            { count = 1 },
            "junk",
            { unitPrice = 40, count = 2 },
        })
        assert.are.same({ min = 40, market = 40, qty = 2, auctions = 1 }, r)
    end)

    it("returns nil for empty or fully invalid input", function()
        assert.is_nil(SM.Reduce({}))
        assert.is_nil(SM.Reduce({ { unitPrice = 0, count = 1 } }))
    end)

    it("does not change the input", function()
        local input = {
            { unitPrice = 300, count = 2 },
            { unitPrice = 100, count = 1 },
            { unitPrice = 200, count = 3 },
        }
        SM.Reduce(input)
        assert.are.same({
            { unitPrice = 300, count = 2 },
            { unitPrice = 100, count = 1 },
            { unitPrice = 200, count = 3 },
        }, input)
    end)

    it("sorts unsorted input", function()
        -- Same as the outlier case, in reverse order.
        local prices = Cat(Cat({ 10 }, Rep(100, 11)), Rep(1000, 28))
        local reversed = {}
        for i = #prices, 1, -1 do
            reversed[#reversed + 1] = prices[i]
        end
        assert.are.equal(100, SM.Reduce(Make(reversed)).market)
    end)

    it("handles 5000 auctions", function()
        -- Prices 5000 down to 1. N=5000: keep=1500, base=750. No jump after index 5.
        -- Window 1..1500, mean 750.5, SD sqrt((1500^2-1)/12)=433.0, limit 649.5.
        -- Kept 101..1400 (1300 values), mean 750.5 -> market 751.
        local prices = {}
        for i = 5000, 1, -1 do
            prices[#prices + 1] = i
        end
        local r = SM.Reduce(Make(prices))
        assert.are.same({ min = 1, market = 751, qty = 5000, auctions = 5000 }, r)
    end)
end)
