describe("ItemString", function()
    local IS

    before_each(function()
        local ns = {}
        assert(loadfile("Core/ItemString.lua"))("Flipside", ns)
        IS = ns.ItemString
    end)

    it("parses a link with only the id", function()
        local r = IS.ParseLink("item:12345")
        assert.are.equal(12345, r.itemID)
        assert.are.equal(0, r.enchantID)
        assert.are.equal(0, r.instanceDifficultyID)
        assert.are.same({}, r.bonusIDs)
        assert.are.same({}, r.extra)
    end)

    it("parses enchant, gems and a negative suffix", function()
        local r = IS.ParseLink("item:100:5:11:12:13:14:-37:99")
        assert.are.equal(5, r.enchantID)
        assert.are.equal(11, r.gemID1)
        assert.are.equal(12, r.gemID2)
        assert.are.equal(13, r.gemID3)
        assert.are.equal(14, r.gemID4)
        assert.are.equal(-37, r.suffixID)
        assert.are.equal(99, r.uniqueID)
    end)

    it("parses link level, specialization and later fields", function()
        local r = IS.ParseLink("item:100::::::::70:250:3:15:0")
        assert.are.equal(70, r.linkLevel)
        assert.are.equal(250, r.specializationID)
        assert.are.equal(3, r.upgradeTypeID)
        assert.are.equal(15, r.instanceDifficultyID)
    end)

    it("parses 3 bonus ids", function()
        local r = IS.ParseLink("item:100::::::::::::3:4786:1520:6652")
        assert.are.same({ 4786, 1520, 6652 }, r.bonusIDs)
        assert.are.same({}, r.extra)
    end)

    it("takes the fields that exist if the count is too large", function()
        local r = IS.ParseLink("item:100::::::::::::5:1:2")
        assert.are.same({ 1, 2 }, r.bonusIDs)
        assert.are.same({}, r.extra)
    end)

    it("puts fields after the bonus ids into extra unchanged", function()
        local r = IS.ParseLink("item:100::::::::::::2:7:8:9::abc:1")
        assert.are.same({ 7, 8 }, r.bonusIDs)
        assert.are.same({ "9", "", "abc", "1" }, r.extra)
    end)

    it("removes trailing empty fields", function()
        local r = IS.ParseLink("item:12345::::::::70:::::")
        assert.are.equal(12345, r.itemID)
        assert.are.equal(70, r.linkLevel)
        assert.are.same({}, r.bonusIDs)
        assert.are.same({}, r.extra)
        r = IS.ParseLink("item:100::::::::::::0:4::")
        assert.are.same({ "4" }, r.extra)
    end)

    it("parses number and digit-string input", function()
        assert.are.equal(777, IS.ParseLink(777).itemID)
        assert.are.equal(777, IS.ParseLink("777").itemID)
    end)

    it("parses both colour forms", function()
        local a = IS.ParseLink("|cffa335ee|Hitem:100::::::::70:::::|h[Some Name]|h|r")
        local b = IS.ParseLink("|cnIQ4:|Hitem:100::::::::70:::::|h[Some Name]|h|r")
        assert.are.equal(100, a.itemID)
        assert.are.same(a, b)
    end)

    it("parses the first link in a longer text", function()
        local text = "WTS |cff0070dd|Hitem:111:::::::|h[A]|h|r and |cff0070dd|Hitem:222|h[B]|h|r pm me"
        assert.are.equal(111, IS.ParseLink(text).itemID)
    end)

    it("rejects input that is not an item", function()
        assert.is_nil(IS.ParseLink(nil))
        assert.is_nil(IS.ParseLink(true))
        assert.is_nil(IS.ParseLink({}))
        assert.is_nil(IS.ParseLink(""))
        assert.is_nil(IS.ParseLink("hello world"))
        assert.is_nil(IS.ParseLink("|cff71d5ff|Hspell:1234|h[Spell]|h|r"))
        assert.is_nil(IS.ParseLink("|cffffd000|Hbattlepet:1:2:3|h[Pet]|h|r"))
        assert.is_nil(IS.ParseLink("|Hcurrency:1000:0|h[Coin]|h"))
    end)

    it("rejects a bad item id", function()
        assert.is_nil(IS.ParseLink("item:"))
        assert.is_nil(IS.ParseLink("item::5"))
        assert.is_nil(IS.ParseLink("item:0"))
        assert.is_nil(IS.ParseLink("item:abc"))
        assert.is_nil(IS.ParseLink("item:-5"))
        assert.is_nil(IS.ParseLink("|Hitem:|h[X]|h"))
        assert.is_nil(IS.ParseLink(0))
        assert.is_nil(IS.ParseLink(-5))
        assert.is_nil(IS.ParseLink(1.5))
        assert.is_nil(IS.ParseLink(math.huge))
        assert.is_nil(IS.ParseLink("0"))
        assert.is_nil(IS.ParseLink("12.5"))
    end)

    it("rejects a field that is not a valid number", function()
        assert.is_nil(IS.ParseLink("item:100:x"))
        assert.is_nil(IS.ParseLink("item:100:-5"))
        assert.is_nil(IS.ParseLink("item:100::::::abc"))
        assert.is_nil(IS.ParseLink("item:100::::::::::::z"))
        assert.is_nil(IS.ParseLink("item:100::::::::::::2:1:q"))
    end)

    it("checks links with IsItemLink", function()
        assert.is_true(IS.IsItemLink("item:100"))
        assert.is_true(IS.IsItemLink("|cffffffff|Hitem:100|h[X]|h|r"))
        assert.is_true(IS.IsItemLink("see |Hitem:100|h[X]|h"))
        assert.is_false(IS.IsItemLink(100))
        assert.is_false(IS.IsItemLink("100"))
        assert.is_false(IS.IsItemLink("item:abc"))
        assert.is_false(IS.IsItemLink("|Hspell:5|h[S]|h"))
        assert.is_false(IS.IsItemLink(nil))
        assert.is_false(IS.IsItemLink({}))
    end)

    it("is pure and returns separate tables", function()
        local input = "|cffa335ee|Hitem:100::::::::::::1:55|h[N]|h|r"
        local copy = input
        local a = IS.ParseLink(input)
        local b = IS.ParseLink(input)
        assert.are.equal(copy, input)
        assert.are.same(a, b)
        assert.are_not.equal(a, b)
        assert.are_not.equal(a.bonusIDs, b.bonusIDs)
        assert.are_not.equal(a.extra, b.extra)
    end)
end)

describe("ItemString keys", function()
    local IS

    before_each(function()
        local ns = {}
        assert(loadfile("Core/ItemString.lua"))("Flipside", ns)
        IS = ns.ItemString
    end)

    it("builds keys without suffix and bonus ids", function()
        assert.are.equal("12345", IS.ToExactKey("item:12345"))
        assert.are.equal("12345", IS.ToBaseKey("item:12345"))
    end)

    it("adds the suffix id", function()
        assert.are.equal("12345#s-34", IS.ToExactKey("item:12345::::::-34"))
        assert.are.equal("12345", IS.ToBaseKey("item:12345::::::-34"))
    end)

    it("adds sorted bonus ids", function()
        assert.are.equal("12345#b1520,6646", IS.ToExactKey("item:12345::::::::::::2:6646:1520"))
    end)

    it("adds suffix and bonus ids", function()
        assert.are.equal("12345#s-34#b1520,6646", IS.ToExactKey("item:12345::::::-34::::::2:1520:6646"))
    end)

    it("ignores enchant, gems, unique id, level and specialization", function()
        local full = "|cffa335ee|Hitem:12345:5:11:12:13:14:-34:999:70:250:0:0:2:6646:1520|h[Name]|h|r"
        local bare = "item:12345::::::-34::::::2:1520:6646"
        assert.are.equal(IS.ToExactKey(bare), IS.ToExactKey(full))
        assert.are.equal("12345#s-34#b1520,6646", IS.ToExactKey(full))
    end)

    it("ignores the bonus order in the link", function()
        local a = IS.ToExactKey("item:1::::::::::::3:5:1:3")
        local b = IS.ToExactKey("item:1::::::::::::3:3:5:1")
        assert.are.equal(a, b)
        assert.are.equal("1#b1,3,5", a)
    end)

    it("keeps duplicate bonus ids", function()
        assert.are.equal("1#b7,7", IS.ToExactKey("item:1::::::::::::2:7:7"))
    end)

    it("accepts a fields table", function()
        local fields = IS.ParseLink("item:12345::::::-34::::::2:6646:1520")
        assert.are.equal("12345#s-34#b1520,6646", IS.ToExactKey(fields))
        assert.are.equal("12345", IS.ToBaseKey(fields))
        assert.are.equal("9#b2", IS.ToExactKey({ itemID = 9, bonusIDs = { 2 } }))
    end)

    it("accepts a number and a digit string", function()
        assert.are.equal("12345", IS.ToExactKey(12345))
        assert.are.equal("12345", IS.ToBaseKey("12345"))
        assert.are.equal("12345", IS.ToExactKey("12345"))
    end)

    it("ToKey picks the base or exact key", function()
        local link = "item:12345::::::-34::::::1:1520"
        assert.are.equal("12345", IS.ToKey(link, true))
        assert.are.equal("12345#s-34#b1520", IS.ToKey(link, false))
        assert.are.equal("12345#s-34#b1520", IS.ToKey(link))
    end)

    it("returns nil for non-item input", function()
        local bad = { nil, false, true, "", "hello", "item:0", "item:abc", 0, -5, 1.5, {}, { itemID = 0 },
            { itemID = 5, bonusIDs = { -1 } }, { itemID = 5, bonusIDs = { "x" } }, "|Hbattlepet:1:2|h[x]|h" }
        for i = 1, 15 do
            local input = bad[i]
            assert.is_nil(IS.ToExactKey(input))
            assert.is_nil(IS.ToBaseKey(input))
            assert.is_nil(IS.ToKey(input, true))
            assert.is_nil(IS.ToKey(input, false))
        end
    end)

    it("does not change the caller's tables", function()
        local fields = { itemID = 5, suffixID = 0, bonusIDs = { 9, 3, 6 } }
        IS.ToExactKey(fields)
        assert.are.same({ 9, 3, 6 }, fields.bonusIDs)
        assert.are.same({ itemID = 5, suffixID = 0, bonusIDs = { 9, 3, 6 } }, fields)
    end)

    it("parses valid keys", function()
        assert.are.same({ itemID = 12345, suffixID = 0, bonusIDs = {} }, IS.ParseKey("12345"))
        assert.are.same({ itemID = 12345, suffixID = -34, bonusIDs = {} }, IS.ParseKey("12345#s-34"))
        assert.are.same({ itemID = 12345, suffixID = 0, bonusIDs = { 1520, 6646 } }, IS.ParseKey("12345#b1520,6646"))
        assert.are.same({ itemID = 12345, suffixID = 5, bonusIDs = { 7, 7 } }, IS.ParseKey("12345#s5#b7,7"))
    end)

    it("rejects invalid keys", function()
        local bad = { "", "012345", "0", "12345#x5", "12345#s", "12345#s5#s6", "12345#b1#b2", "12345#b1#s5",
            "12345#b", "12345#b2,1", "12345#b1.5", "12345#b-1", "12345#s1.5", "12345#sx", "12345#", "12345#b1,",
            "12345#b1,,2", "12345#s05", "12345#s0", "-5", "1.5", "item:12345", "i:12345", "12345:s5", " 12345" }
        for _, key in ipairs(bad) do
            assert.is_nil(IS.ParseKey(key), key)
        end
        for _, key in ipairs({ false, true, 12345, {} }) do
            assert.is_nil(IS.ParseKey(key))
        end
        assert.is_nil(IS.ParseKey())
    end)

    it("round trips 5 items", function()
        local links = { "item:1", "item:20::::::-5", "item:300::::::::::::1:9", "item:4000::::::7::::::3:30:10:20",
            "item:50000::::::-1::::::2:8:8" }
        for _, link in ipairs(links) do
            local fields = IS.ParseLink(link)
            local parsed = IS.ParseKey(IS.ToExactKey(link))
            local sorted = { unpack(fields.bonusIDs) }
            table.sort(sorted)
            assert.are.equal(fields.itemID, parsed.itemID)
            assert.are.equal(fields.suffixID, parsed.suffixID)
            assert.are.same(sorted, parsed.bonusIDs)
            assert.are.equal(IS.ToExactKey(link), IS.ToExactKey(parsed))
        end
    end)

    it("KeyToBaseKey returns the base key", function()
        assert.are.equal("12345", IS.KeyToBaseKey("12345#s-34#b1,2"))
        assert.are.equal("12345", IS.KeyToBaseKey("12345"))
        assert.is_nil(IS.KeyToBaseKey("012345"))
        assert.is_nil(IS.KeyToBaseKey(nil))
        assert.is_nil(IS.KeyToBaseKey("12345#b2,1"))
    end)
end)
