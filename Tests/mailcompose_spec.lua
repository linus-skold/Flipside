local manifest = require("Tests.manifest")

describe("MailCompose", function()
    local ns, Compose

    local function items(...)
        local list = {}
        for _, entry in ipairs({ ... }) do
            list[#list + 1] = { index = entry[1], name = entry[2], count = entry[3] or 1 }
        end
        return list
    end

    before_each(function()
        ns = {}
        assert(loadfile(manifest.path("MailCompose")))("Flipside", ns)
        Compose = ns.MailCompose
    end)

    describe("the default subject", function()
        it("is the name of the first slot, with the stack size if it is more than 1", function()
            assert.are.equal("", Compose.DefaultSubject({}))
            assert.are.equal("Linen Cloth", Compose.DefaultSubject(items({ 1, "Linen Cloth" })))
            assert.are.equal("Linen Cloth (20)", Compose.DefaultSubject(items({ 1, "Linen Cloth", 20 })))
            assert.are.equal("Wool", Compose.DefaultSubject(items({ 4, "Silk" }, { 2, "Wool" })))
        end)

        it("fills an empty subject and follows the first item while the user does not edit it", function()
            local subject, previous = Compose.SubjectUpdate("", "", items({ 1, "Wool", 5 }))
            assert.are.same({ "Wool (5)", "Wool (5)" }, { subject, previous })
            subject, previous = Compose.SubjectUpdate(subject, previous, items({ 1, "Silk" }))
            assert.are.same({ "Silk", "Silk" }, { subject, previous })
        end)

        it("keeps a subject that the user typed", function()
            local subject, previous = Compose.SubjectUpdate("My gift", "Wool", items({ 1, "Silk" }))
            assert.are.same({ "My gift", "Wool" }, { subject, previous })
        end)

        it("clears the default when the last item goes, and keeps a typed subject", function()
            local subject, previous = Compose.SubjectUpdate("Wool", "Wool", {})
            assert.are.same({ "", "" }, { subject, previous })
            subject, previous = Compose.SubjectUpdate("My gift", "Wool", {})
            assert.are.same({ "My gift", "" }, { subject, previous })
        end)
    end)

    describe("the money mode", function()
        it("allows cash on delivery only with an attachment", function()
            assert.are.equal("cod", Compose.Mode("cod", items({ 1, "Wool" })))
            assert.are.equal("money", Compose.Mode("cod", {}))
            assert.are.equal("money", Compose.Mode("money", items({ 1, "Wool" })))
            assert.are.equal("money", Compose.Mode(nil, {}))
        end)

        it("gives the money and the cash on delivery amount for the client", function()
            assert.are.same({ 500, 0 }, { Compose.Amounts("money", 500) })
            assert.are.same({ 0, 900 }, { Compose.Amounts("cod", 900) })
            assert.are.same({ 0, 0 }, { Compose.Amounts("cod", nil) })
            assert.are.same({ 0, 0 }, { Compose.Amounts("money", -5) })
        end)
    end)

    describe("the slots", function()
        it("lists 12 slots and marks the filled ones", function()
            local slots = Compose.Slots(items({ 2, "Wool" }, { 5, "Silk" }))
            assert.are.equal(12, #slots)
            assert.are.equal("Wool", slots[2].item.name)
            assert.is_nil(slots[1].item)
            assert.are.equal(5, slots[5].index)
        end)

        it("finds the first free slot, or none when all 12 are full", function()
            assert.are.equal(1, Compose.NextFree({}))
            assert.are.equal(3, Compose.NextFree(items({ 1, "A" }, { 2, "B" }, { 4, "D" })))
            local full = {}
            for index = 1, 12 do
                full[index] = { index = index, name = "I" .. index, count = 1 }
            end
            assert.is_nil(Compose.NextFree(full))
        end)
    end)

    describe("the recipient", function()
        local keys = { "Bank-Realm" }
        local function mailName(text)
            if text == "Me" then
                return nil, "log in to Me once"
            end
            return "full:" .. text
        end

        it("trims the text and gives the full name", function()
            assert.are.same({ text = "Bank", full = "full:Bank" }, Compose.Recipient("  Bank ", keys, mailName))
        end)

        it("gives the reason if there is no full name", function()
            assert.are.same({ text = "Me", reason = "log in to Me once" }, Compose.Recipient("Me", keys, mailName))
        end)

        it("gives no name and no reason for an empty text", function()
            assert.are.same({ text = "" }, Compose.Recipient("   ", keys, mailName))
            assert.are.same({ text = "" }, Compose.Recipient(nil, keys, mailName))
        end)

        it("uses the text as it is with no mailName function", function()
            assert.are.same({ text = "Bank", full = "Bank" }, Compose.Recipient("Bank", keys))
        end)
    end)

    describe("the autocomplete", function()
        local names = { "Alt One", "Bank Jones", "banker Smith" }

        it("gives the first longer name that starts with the text, with no regard to case", function()
            assert.are.equal("Bank Jones", Compose.Complete("ba", names))
            assert.are.equal("banker Smith", Compose.Complete("banke", names))
            assert.are.equal("Alt One", Compose.Complete("AL", names))
        end)

        it("gives nothing for no match, an empty text or a full name", function()
            assert.is_nil(Compose.Complete("x", names))
            assert.is_nil(Compose.Complete("", names))
            assert.is_nil(Compose.Complete("Alt One", names))
            assert.is_nil(Compose.Complete("ba", nil))
        end)
    end)

    describe("the checks", function()
        local function form(change)
            local base = {
                recipient = { text = "Bank", full = "Bank Jones" }, subject = "Gift", items = {}, mode = "money",
                copper = 0, running = false,
            }
            for key, value in pairs(change or {}) do
                base[key] = value
            end
            return base
        end

        it("accepts a mail with a recipient and a subject", function()
            assert.is_true(Compose.Validate(form()))
        end)

        it("needs a recipient with a full name, and shows the reason", function()
            local ok, reason = Compose.Validate(form({ recipient = { text = "" } }))
            assert.is_false(ok)
            assert.are.equal("Enter a recipient", reason)
            ok, reason = Compose.Validate(form({ recipient = { text = "Me", reason = "log in to Me once" } }))
            assert.is_false(ok)
            assert.are.equal("log in to Me once", reason)
        end)

        it("needs a subject", function()
            local ok, reason = Compose.Validate(form({ subject = "" }))
            assert.is_false(ok)
            assert.are.equal("Enter a subject", reason)
        end)

        it("needs an attachment for cash on delivery, and at most 10000 gold", function()
            local ok, reason = Compose.Validate(form({ mode = "cod", copper = 100 }))
            assert.is_false(ok)
            assert.are.equal("Cash on delivery needs an attachment", reason)
            local one = items({ 1, "Wool" })
            assert.is_true(Compose.Validate(form({ mode = "cod", copper = 100000000, items = one })))
            ok, reason = Compose.Validate(form({ mode = "cod", copper = 100000001, items = one }))
            assert.is_false(ok)
            assert.are.equal("Cash on delivery is 10000 gold at most", reason)
        end)

        it("does not limit the money of a plain send", function()
            assert.is_true(Compose.Validate(form({ mode = "money", copper = 999999999 })))
        end)

        it("refuses every send while a mailing run is active", function()
            local ok, reason = Compose.Validate(form({ running = true }))
            assert.is_false(ok)
            assert.are.equal("A mailing run is active", reason)
        end)
    end)

    describe("the subject with the money default", function()
        local function text(copper)
            return copper .. " copper"
        end

        local function subject(current, previous, list, mode, copper)
            local result, kept = Compose.SubjectFor(current, previous, list, mode, copper, text)
            return { result, kept }
        end

        it("puts the money text in an empty subject when only money is sent", function()
            assert.are.same({ "12345 copper", "12345 copper" }, subject("", "", {}, "money", 12345))
        end)

        it("follows the amount while the box holds the last default", function()
            assert.are.same({ "100 copper", "100 copper" }, subject("12345 copper", "12345 copper", {}, "money", 100))
        end)

        it("keeps a typed subject", function()
            assert.are.same({ "Thanks", "12345 copper" }, subject("Thanks", "12345 copper", {}, "money", 500))
            assert.are.same({ "Thanks", "" }, subject("Thanks", "", {}, "money", 500))
        end)

        it("takes the default away when the amount goes to 0", function()
            assert.are.same({ "", "" }, subject("12345 copper", "12345 copper", {}, "money", 0))
            assert.are.same({ "Thanks", "" }, subject("Thanks", "12345 copper", {}, "money", 0))
        end)

        it("fills the box again after the user empties it", function()
            assert.are.same({ "50 copper", "50 copper" }, subject("", "12345 copper", {}, "money", 50))
        end)

        it("lets an attachment win over the money", function()
            local list = items({ 1, "Wool", 5 })
            assert.are.same({ "Wool (5)", "Wool (5)" }, subject("", "", list, "money", 999))
            assert.are.same({ "Wool (5)", "Wool (5)" }, subject("999 copper", "999 copper", list, "money", 999))
            assert.are.same({ "Mine", "Wool (5)" }, subject("Mine", "Wool (5)", list, "money", 999))
        end)

        it("turns the item default into the money default when the last attachment goes", function()
            assert.are.same({ "70 copper", "70 copper" }, subject("Wool (5)", "Wool (5)", {}, "money", 70))
            assert.are.same({ "", "" }, subject("Wool (5)", "Wool (5)", {}, "money", 0))
        end)

        it("gives no default in cash on delivery mode or without a money formatter", function()
            assert.are.same({ "", "" }, subject("", "", {}, "cod", 500))
            assert.are.same({ "", "" }, { Compose.SubjectFor("", "", {}, "money", 500, nil) })
            assert.are.same({ "", "" }, { Compose.SubjectFor("", "", {}, "money", 500, function()
                return ""
            end) })
        end)
    end)

    describe("the clear on a tab switch", function()
        it("clears on the Inbox tab and on the Mailing rules tab", function()
            assert.is_true(Compose.ClearOnTab("inbox", false, false))
            assert.is_true(Compose.ClearOnTab("rules", false, false))
        end)

        it("does not clear on the Send tab or on an unknown tab", function()
            assert.is_false(Compose.ClearOnTab("send", false, false))
            assert.is_false(Compose.ClearOnTab(nil, false, false))
        end)

        it("does not clear while a mailing run is active or a send waits for its result", function()
            assert.is_false(Compose.ClearOnTab("inbox", true, false))
            assert.is_false(Compose.ClearOnTab("rules", false, true))
            assert.is_false(Compose.ClearOnTab("rules", true, true))
        end)
    end)
end)