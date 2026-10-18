local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("LedgerRecord")))("Flipside", ns)
local R = ns.LedgerRecord

local function base(extra)
    local record = {
        time = 1000, char = "Alice-Realm", type = "sale", source = "ahSale", item = "25", qty = 2, money = 500,
    }
    for k, v in pairs(extra or {}) do
        record[k] = v
    end
    return record
end

describe("LedgerRecord", function()
    it("accepts a valid record", function()
        assert.is_true(R.Validate(base()))
    end)

    it("lists every source of the spec table", function()
        assert.are.same({ "ahCancelled", "ahDeposit", "ahDepositRefund",
            "ahExpired", "ahOutbidRefund", "ahPost",
            "ahPurchase", "ahSale",
            "loot", "mailMoney", "mailMoneySent", "mailPostage", "mailSent", "quest", "repair", "trade",
            "unknown", "vendorPurchase", "vendorSale" }, R.SOURCES)
    end)

    it("lists the types", function()
        assert.are.same({ "sale", "purchase", "post", "income", "expense", "loot", "expired", "cancelled", "log" },
            R.TYPES)
    end)

    it("rejects a record that is not a table", function()
        assert.is_false(R.Validate("x"))
    end)

    it("rejects a missing time, char or type", function()
        for _, name in ipairs({ "time", "char", "type" }) do
            local ok, message = R.Validate(base({ [name] = false }))
            assert.is_false(ok)
            assert.is_truthy(message)
            local record = base()
            record[name] = nil
            assert.is_false((R.Validate(record)))
        end
    end)

    it("rejects negative, fractional or non-number money and time", function()
        assert.is_false((R.Validate(base({ money = -1 }))))
        assert.is_false((R.Validate(base({ money = 1.5 }))))
        assert.is_false((R.Validate(base({ money = "5" }))))
        assert.is_false((R.Validate(base({ time = -3 }))))
        assert.is_false((R.Validate(base({ qty = 0.5 }))))
    end)

    it("rejects an unknown field, type or source", function()
        assert.is_false((R.Validate(base({ extra = 1 }))))
        assert.is_false((R.Validate(base({ type = "gift" }))))
        assert.is_false((R.Validate(base({ source = "gift" }))))
    end)

    it("rejects a source with a type that does not fit", function()
        local ok, message = R.Validate(base({ source = "ahPurchase" }))
        assert.is_false(ok)
        assert.is_truthy(message:find("cannot have type"))
    end)

    it("accepts the two types of trade and unknown", function()
        for _, source in ipairs({ "trade", "unknown" }) do
            assert.is_true(R.Validate(base({ source = source, type = "income", item = "", qty = 0 })))
            assert.is_true(R.Validate(base({ source = source, type = "expense", item = "", qty = 0 })))
        end
    end)

    it("needs an item when qty is above 0", function()
        assert.is_false((R.Validate(base({ item = "" }))))
        assert.is_true(R.Validate(base({ item = "", qty = 0 })))
    end)

    it("takes a log record without a source and rejects one with a source", function()
        assert.is_true(R.Validate({ time = 5, char = "A-R", type = "log", item = "25", qty = 1, money = 10 }))
        assert.is_false((R.Validate({ time = 5, char = "A-R", type = "log", source = "ahSale" })))
    end)

    it("accepts the invoice fields", function()
        local record = base({ fp = "abc", invoiceType = "seller", counterparty = "Bob", bid = 10, buyout = 20,
            deposit = 3, cut = 1, ctx = "mail:4", value = 7 })
        assert.is_true(R.Validate(record))
    end)

    describe("New", function()
        it("sets the defaults and copies the fields", function()
            local fields = { time = 1, char = "A-R", type = "income", source = "quest" }
            local record = R.New(fields)
            assert.are.equal("", record.item)
            assert.are.equal(0, record.qty)
            assert.are.equal(0, record.money)
            assert.is_nil(fields.item)
        end)

        it("sets the mob of a loot record to unknown", function()
            local record = R.New({ time = 1, char = "A-R", type = "loot", source = "loot", item = "9", qty = 1 })
            assert.are.equal("unknown", record.mob)
            local named = R.New({ time = 1, char = "A-R", type = "loot", source = "loot", mob = "Boar" })
            assert.are.equal("Boar", named.mob)
        end)

        it("returns nil and a message for a bad record", function()
            local record, message = R.New({ time = 1 })
            assert.is_nil(record)
            assert.is_truthy(message)
        end)
    end)

    it("gives the direction of the money", function()
        assert.are.equal("in", R.Direction("sale"))
        assert.are.equal("in", R.Direction("income"))
        assert.are.equal("in", R.Direction("loot"))
        assert.are.equal("out", R.Direction("purchase"))
        assert.are.equal("out", R.Direction("expense"))
        assert.is_nil(R.Direction("expired"))
        assert.is_nil(R.Direction("log"))
    end)

    it("gives the setting defaults as a new table each time", function()
        local d = R.Defaults()
        assert.are.same({ ["ledger.bufferCap"] = 500, ["ledger.hardLimit"] = 2000, ["ledger.retentionDays"] = 180,
            ["ledger.mobWindow"] = 60, ["ledger.logDays"] = 30, ["ledger.debug"] = false }, d)
        d["ledger.bufferCap"] = 1
        assert.are.equal(500, R.Defaults()["ledger.bufferCap"])
    end)

    it("accepts the edit fields and refuses wrong types for them", function()
        assert.is_true(R.Validate(base({ id = "3e8-0a1b2c", note = "x", edited = true, orig = { money = 1 } })))
        assert.is_false((R.Validate(base({ id = 5 }))))
        assert.is_false((R.Validate(base({ note = 5 }))))
        assert.is_false((R.Validate(base({ edited = false }))))
        assert.is_false((R.Validate(base({ orig = "x" }))))
    end)

    it("lists the editable fields", function()
        assert.are.same({ "source", "item", "qty", "money", "note" }, R.EDIT_FIELDS)
    end)

    it("makes an id from the time", function()
        local id = R.NewId(1000)
        assert.matches("^3e8%-%x%x%x%x%x%x$", id)
    end)

    it("keeps the type if the new source allows it, else picks one with the same direction", function()
        assert.are.equal("sale", R.TypeFor("ahSale", "sale"))
        assert.are.equal("income", R.TypeFor("trade", "income"))
        assert.are.equal("expense", R.TypeFor("trade", "expense"))
        assert.are.equal("income", R.TypeFor("trade", "sale"))
        assert.are.equal("expense", R.TypeFor("unknown", "purchase"))
        assert.are.equal("expense", R.TypeFor("repair", "sale"))
        assert.are.equal("post", R.TypeFor("ahPost", "sale"))
        assert.is_nil(R.TypeFor("nothing", "sale"))
    end)
end)