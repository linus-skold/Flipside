local manifest = require("Tests.manifest")

describe("LedgerCsv", function()
    local ns

    before_each(function()
        ns = {}
        for _, name in ipairs({ "LedgerRecord", "LedgerCsv" }) do
            assert(loadfile(manifest.path(name)))("Flipside", ns)
        end
    end)

    describe("TimeText", function()
        it("writes UTC as YYYY-MM-DD HH:MM:SS", function()
            assert.are.equal("1970-01-01 00:00:00", ns.LedgerCsv.TimeText(0))
            assert.are.equal("2023-11-14 22:13:20", ns.LedgerCsv.TimeText(1700000000))
            assert.are.equal("2024-02-29 23:59:59", ns.LedgerCsv.TimeText(1709251199))
        end)
    end)

    describe("Escape", function()
        it("leaves plain text and numbers as they are", function()
            assert.are.equal("Linen Cloth", ns.LedgerCsv.Escape("Linen Cloth"))
            assert.are.equal("-200", ns.LedgerCsv.Escape(-200))
        end)

        it("gives nil as an empty cell", function()
            assert.are.equal("", ns.LedgerCsv.Escape(nil))
        end)

        it("quotes a comma, a quote and a line break, and doubles the quotes", function()
            assert.are.equal('"a,b"', ns.LedgerCsv.Escape("a,b"))
            assert.are.equal('"say ""hi"""', ns.LedgerCsv.Escape('say "hi"'))
            assert.are.equal('"a\nb"', ns.LedgerCsv.Escape("a\nb"))
            assert.are.equal('"a\r\nb"', ns.LedgerCsv.Escape("a\r\nb"))
        end)
    end)

    describe("Build", function()
        local function lines(text)
            local out = {}
            for line in text:gmatch("([^\r\n]*)\r\n") do
                out[#out + 1] = line
            end
            return out
        end

        local sale = {
            time = 1700000000, char = "A-R", type = "sale", source = "ahSale", item = "2589",
            itemName = "Linen Cloth", qty = 20, money = 500, counterparty = "Bob", bid = 400, deposit = 50, cut = 20,
        }

        it("has the header of the fixed columns and CR LF line ends", function()
            local text = ns.LedgerCsv.Build({}, {})
            assert.are.equal(table.concat(ns.LedgerCsv.COLUMNS, ",") .. "\r\n", text)
            assert.are.equal(18, #ns.LedgerCsv.COLUMNS)
        end)

        it("writes a sale with the money in as a positive number", function()
            local out = lines(ns.LedgerCsv.Build({ sale }, {}))
            assert.are.equal(2, #out)
            local expected = "2023-11-14 22:13:20,A-R,sale,ahSale,2589,Linen Cloth,20,500,1,Bob,400,,50,20,,,,"
            assert.are.equal(expected, out[2])
        end)

        it("writes the text that charText gives for a character key, not the key", function()
            local guid = "Player-1-0000000A"
            local record = { time = 5, char = guid, type = "sale", source = "ahSale", money = 1 }
            local sum = {
                char = guid, day = 1, source = "ahSale", item = "7", count = 2, qty = 3, moneyIn = 4, moneyOut = 0,
            }
            local out = lines(ns.LedgerCsv.Build({ record }, { sum }, function(key)
                return key == guid and "Bob Smith" or key
            end))
            assert.are.equal(3, #out)
            for index = 2, 3 do
                assert.matches(",Bob Smith,", out[index])
                assert.is_nil(out[index]:find("Player-", 1, true))
            end
        end)

        it("writes the money out as a negative number", function()
            local out = lines(ns.LedgerCsv.Build({
                { time = 5, char = "A-R", type = "purchase", source = "ahPurchase", item = "7", qty = 1, money = 200 },
            }, {}))
            assert.matches(",purchase,ahPurchase,7,,1,%-200,1,", out[2])
        end)

        it("writes a reconcile gain as positive and a reconcile loss as negative", function()
            local out = lines(ns.LedgerCsv.Build({
                { time = 5, char = "A-R", type = "income", source = "reconcile", money = 70 },
                { time = 6, char = "A-R", type = "expense", source = "reconcile", money = 30 },
            }, {}))
            assert.matches(",income,reconcile,,,,70,1,", out[2])
            assert.matches(",expense,reconcile,,,,%-30,1,", out[3])
        end)

        it("leaves the money empty for a type with no money flow", function()
            local out = lines(ns.LedgerCsv.Build({
                { time = 5, char = "A-R", type = "post", source = "ahPost", item = "7", qty = 3, money = 90 },
            }, {}))
            assert.matches(",post,ahPost,7,,3,,1,", out[2])
        end)

        it("quotes a note and skips log records", function()
            local out = lines(ns.LedgerCsv.Build({
                { time = 5, char = "A-R", type = "loot", source = "loot", money = 7, mob = "Wolf, Alpha",
                    note = 'a "b"' },
                { time = 6, char = "A-R", type = "log" },
            }, {}))
            assert.are.equal(2, #out)
            assert.matches(',"Wolf, Alpha",,"a ""b"""$', out[2])
        end)

        it("writes a daily sum as one line with the type daily, and sorts oldest first", function()
            local out = lines(ns.LedgerCsv.Build({ sale }, {
                { char = "A-R", day = 19675, source = "vendorSale", item = "", count = 3, qty = 7, moneyIn = 100,
                    moneyOut = 40 },
            }))
            assert.are.equal(3, #out)
            assert.are.equal("2023-11-14 00:00:00,A-R,daily,vendorSale,,,7,60,3,,,,,,,,,", out[2])
            assert.matches("^2023%-11%-14 22:13:20,", out[3])
        end)

        it("keeps the order of records with the same time", function()
            local out = lines(ns.LedgerCsv.Build({
                { time = 5, char = "A-R", type = "income", source = "quest", money = 1 },
                { time = 5, char = "A-R", type = "income", source = "quest", money = 2 },
            }, {}))
            assert.matches(",1,1,", out[2])
            assert.matches(",2,1,", out[3])
        end)
    end)
end)
