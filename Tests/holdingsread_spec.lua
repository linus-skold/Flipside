describe("HoldingsRead", function()
    local ns, H, resolver, bags, failBag, failSlot

    local function link(id, suffix)
        return "|cff1eff00|Hitem:" .. id .. "::::::" .. (suffix or "") .. "::::::|h[x]|h|r"
    end

    local function bagApi()
        return {
            numSlots = function(bag)
                if bag == failBag then error("bag") end
                return bags[bag] and #bags[bag] or 0
            end,
            itemInfo = function(bag, slot)
                if bag == failSlot[1] and slot == failSlot[2] then error("slot") end
                return bags[bag][slot] or nil
            end,
        }
    end

    before_each(function()
        ns = {}
        for _, name in ipairs({ "Core/ItemString", "Services/ScanKey", "Services/HoldingsRead" }) do
            assert(loadfile(name .. ".lua"))("Flipside", ns)
        end
        H = ns.HoldingsRead
        failBag, failSlot = nil, {}
        resolver = ns.ScanKey.New({
            clientIsCommodity = function(id)
                if id == 10 then return true end
                if id == 20 then return false end
                return nil
            end,
        })
        bags = {
            [0] = {
                { hyperlink = link(10), itemID = 10, stackCount = 20 },
                { hyperlink = link(20, "-37"), itemID = 20, stackCount = 1 },
                false,
                { hyperlink = "|Hbattlepet:1:2|h[Pet]|h", itemID = 82800, stackCount = 1 },
            },
            [5] = { { hyperlink = link(10), itemID = 10, stackCount = 5 } },
            [6] = { { hyperlink = link(10), itemID = 10, stackCount = 7 } },
            [15] = { { hyperlink = link(10), itemID = 10, stackCount = 100 } },
        }
    end)

    it("lists the Forever character bank tabs", function()
        assert.are.same({ 6, 7, 8, 9, 10, 11, 12, 13, 14 }, H.BANK_BAGS)
    end)

    it("sums bag stacks and uses the right keys", function()
        local items, stats = H.Bags(bagApi(), resolver)
        assert.are.same({ ["10"] = 25, ["20#s-37"] = 1 }, items)
        assert.are.equal(5, stats.slots)
        assert.are.equal(2, stats.skipped)
        assert.are.equal(0, stats.errors)
    end)

    it("counts failing calls in the bags", function()
        failBag = 5
        failSlot = { 0, 2 }
        local items, stats = H.Bags(bagApi(), resolver)
        assert.are.same({ ["10"] = 20 }, items)
        assert.are.equal(2, stats.errors)
    end)

    it("reads the bank tabs only", function()
        local items = H.Bank(bagApi(), resolver, H.BANK_BAGS)
        assert.are.same({ ["10"] = 7 }, items)
        items = H.Bank(bagApi(), resolver)
        assert.are.same({ ["10"] = 7 }, items)
    end)

    it("falls back to the link key without a resolver", function()
        local items = H.Bags(bagApi(), nil)
        assert.are.equal(25, items["10"])
        assert.are.equal(1, items["20#s-37"])
    end)

    describe("Mail", function()
        local mails
        local function mailApi()
            return {
                numItems = function() return #mails end,
                itemLink = function(i, a)
                    if mails[i].fail == a then error("x") end
                    return mails[i][a] and mails[i][a].link or nil
                end,
                itemInfo = function(i, a)
                    return "n", 1, "t", mails[i][a].count
                end,
            }
        end

        it("sums several attachments and ignores money-only mails", function()
            mails = {
                { { link = link(10), count = 5 }, { link = link(20, "-1"), count = 1 },
                    { link = link(10), count = 3 } },
                {},
                { { link = "|Hbattlepet:1:2|h[Pet]|h", count = 1 } },
            }
            local items, stats = H.Mail(mailApi(), resolver)
            assert.are.same({ ["10"] = 8, ["20#s-1"] = 1 }, items)
            assert.are.equal(3, stats.rows)
            assert.are.equal(1, stats.skipped)
            assert.are.equal(0, stats.errors)
        end)

        it("counts failing calls", function()
            mails = { { { link = link(10), count = 2 }, fail = 2 } }
            local items, stats = H.Mail(mailApi(), resolver)
            assert.are.same({ ["10"] = 2 }, items)
            assert.are.equal(1, stats.errors)
            local _, s2 = H.Mail({ numItems = function() error("x") end }, resolver)
            assert.are.equal(1, s2.errors)
        end)
    end)

    describe("Auctions", function()
        it("skips sold rows and pets", function()
            local rows = {
                { itemLink = link(10), quantity = 40, status = 0 },
                { itemLink = link(10), quantity = 9, status = 1 },
                { itemLink = link(20, "-5"), quantity = 1, status = 0 },
                { itemLink = "|Hbattlepet:1:2|h[Pet]|h", quantity = 1, status = 0 },
                { itemKey = { itemID = 10 }, quantity = 2, status = 0 },
            }
            local items, stats = H.Auctions({ owned = function() return rows end }, resolver)
            assert.are.same({ ["10"] = 42, ["20#s-5"] = 1 }, items)
            assert.are.equal(5, stats.rows)
            assert.are.equal(2, stats.skipped)
        end)

        it("counts a failing call", function()
            local items, stats = H.Auctions({ owned = function() error("x") end }, resolver)
            assert.are.same({}, items)
            assert.are.equal(1, stats.errors)
        end)
    end)
end)
