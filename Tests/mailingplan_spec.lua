local manifest = require("Tests.manifest")

describe("MailingPlan", function()
    local ns, P

    local function load(name)
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end

    -- A slot in the bags. The first bag number is 0.
    local function slot(key, bag, index, count, flags)
        local s = { key = key, bag = bag, slot = index, count = count }
        for k, v in pairs(flags or {}) do
            s[k] = v
        end
        return s
    end

    local function op(recipient, keep, maxSend)
        return { recipient = recipient, keep = keep or 0, maxSend = maxSend or 0 }
    end

    local function build(groups, slots)
        return P.Build({ groups = groups, slots = slots, self = "Me" })
    end

    local function counts(mail)
        local out = {}
        for _, a in ipairs(mail.attachments) do
            out[#out + 1] = a.count
        end
        return out
    end

    local function reasons(plan)
        local out = {}
        for _, s in ipairs(plan.skipped) do
            out[#out + 1] = s.reason
        end
        return out
    end

    before_each(function()
        ns = {}
        load("ItemString")
        load("MailingPlan")
        P = ns.MailingPlan
    end)

    it("sends all of an item with keep 0 and no limit", function()
        local plan = build({ { items = { "100" }, operation = op("Alt") } },
            { slot("100", 0, 1, 20), slot("100", 0, 2, 5) })
        assert.equal(1, #plan.mails)
        assert.equal("Alt", plan.mails[1].recipient)
        assert.same({ 20, 5 }, counts(plan.mails[1]))
        assert.same({ bag = 0, slot = 1, key = "100", count = 20 }, plan.mails[1].attachments[1])
        assert.same({}, plan.skipped)
    end)

    it("keeps K in bags", function()
        local plan = build({ { items = { "100" }, operation = op("Alt", 5) } },
            { slot("100", 0, 1, 20), slot("100", 0, 2, 5), slot("100", 0, 3, 3) })
        -- 28 in bags, 23 sendable: 20 fits, 5 does not (3 left), 3 fits.
        assert.same({ 20, 3 }, counts(plan.mails[1]))
        assert.same({ "keep" }, reasons(plan))
        assert.equal(5, plan.skipped[1].count)
    end)

    it("skips an item whose stock is at or below keep", function()
        local plan = build({ { items = { "100" }, operation = op("Alt", 20) } }, { slot("100", 0, 1, 20) })
        assert.same({}, plan.mails)
        assert.same({ "keep" }, reasons(plan))
    end)

    it("caps the send by maxSend and sends no partial slot", function()
        local plan = build({ { items = { "100" }, operation = op("Alt", 0, 25) } },
            { slot("100", 0, 1, 20), slot("100", 0, 2, 10), slot("100", 0, 3, 5) })
        -- Largest first: 20 fits (5 left), 10 does not, 5 fits.
        assert.same({ 20, 5 }, counts(plan.mails[1]))
        assert.same({ "send limit" }, reasons(plan))
    end)

    it("never exceeds keep and maxSend together", function()
        local plan = build({ { items = { "100" }, operation = op("Alt", 10, 15) } },
            { slot("100", 0, 1, 20), slot("100", 0, 2, 10), slot("100", 0, 3, 8) })
        -- 38 in bags, 28 free, capped at 15: 20 does not fit, 10 fits, 8 does not fit in the 5 left.
        local sent = 0
        for _, n in ipairs(counts(plan.mails[1])) do
            sent = sent + n
        end
        assert.is_true(sent <= 15)
        assert.same({ 10 }, counts(plan.mails[1]))
    end)

    it("counts flagged slots in the total for keep", function()
        local plan = build({ { items = { "100" }, operation = op("Alt", 10) } },
            { slot("100", 0, 1, 10, { soulbound = true }), slot("100", 0, 2, 12) })
        -- 22 in bags, 12 sendable.
        assert.same({ 12 }, counts(plan.mails[1]))
        assert.same({ "soulbound" }, reasons(plan))
    end)

    it("splits more than 12 slots into several mails", function()
        local slots = {}
        for i = 1, 30 do
            slots[#slots + 1] = slot("100", 0, i, 1)
        end
        local plan = build({ { items = { "100" }, operation = op("Alt") } }, slots)
        assert.equal(3, #plan.mails)
        assert.equal(12, #plan.mails[1].attachments)
        assert.equal(12, #plan.mails[2].attachments)
        assert.equal(6, #plan.mails[3].attachments)
        assert.equal("Alt", plan.mails[3].recipient)
    end)

    it("fills mails across items of one recipient", function()
        local slots = {}
        for i = 1, 8 do
            slots[#slots + 1] = slot("100", 0, i, 1)
            slots[#slots + 1] = slot("200", 1, i, 1)
        end
        local plan = build({ { items = { "100", "200" }, operation = op("Alt") } }, slots)
        assert.equal(2, #plan.mails)
        assert.equal(12, #plan.mails[1].attachments)
        assert.equal(4, #plan.mails[2].attachments)
    end)

    it("keeps one recipient in each mail", function()
        local plan = build({
            { items = { "100" }, operation = op("Alt") },
            { items = { "200" }, operation = op("Bank") },
            { items = { "300" }, operation = op("alt") },
        }, { slot("100", 0, 1, 1), slot("200", 0, 2, 1), slot("300", 0, 3, 1) })
        assert.equal(2, #plan.mails)
        assert.equal("Alt", plan.mails[1].recipient)
        assert.same({ "100", "300" }, { plan.mails[1].attachments[1].key, plan.mails[1].attachments[2].key })
        assert.equal("Bank", plan.mails[2].recipient)
        assert.equal(1, #plan.mails[2].attachments)
    end)

    it("skips soulbound, quest and unmailable slots with a reason", function()
        local plan = build({ { items = { "100" }, operation = op("Alt") } }, {
            slot("100", 0, 1, 1, { soulbound = true }),
            slot("100", 0, 2, 1, { quest = true }),
            slot("100", 0, 3, 1, { unmailable = true }),
            slot("100", 0, 4, 7),
        })
        assert.same({ 7 }, counts(plan.mails[1]))
        assert.same({ "soulbound", "quest item", "unmailable" }, reasons(plan))
        assert.equal(2, plan.skipped[2].slot)
    end)

    it("skips an item whose group has no recipient", function()
        local plan = build({
            { items = { "100" }, operation = nil },
            { items = { "200" }, operation = op("  ") },
        }, { slot("100", 0, 1, 3), slot("200", 0, 2, 3) })
        assert.same({}, plan.mails)
        assert.same({ "no recipient", "no recipient" }, reasons(plan))
    end)

    it("skips when the recipient is the own character", function()
        local plan = build({ { items = { "100" }, operation = op("me") } }, { slot("100", 0, 1, 3) })
        assert.same({}, plan.mails)
        assert.same({ "recipient is self" }, reasons(plan))
        local withRealm = P.Build({
            groups = { { items = { "100" }, operation = op("Me-Realm") } },
            slots = { slot("100", 0, 1, 3) }, self = "Me-Realm",
        })
        assert.same({ "recipient is self" }, reasons(withRealm))
        local otherRealm = P.Build({
            groups = { { items = { "100" }, operation = op("Me-Other") } },
            slots = { slot("100", 0, 1, 3) }, self = "Me-Realm",
        })
        assert.equal(1, #otherRealm.mails)
    end)

    it("leaves items of no group and items not in the bags alone", function()
        local plan = build({ { items = { "100", "999" }, operation = op("Alt") } },
            { slot("100", 0, 1, 3), slot("555", 0, 2, 3) })
        assert.equal(1, #plan.mails[1].attachments)
        assert.same({}, plan.skipped)
    end)

    it("lets an item follow its first group only", function()
        local plan = build({
            { items = { "100" }, operation = op("Alt") },
            { items = { "100" }, operation = op("Bank") },
        }, { slot("100", 0, 1, 3) })
        assert.equal(1, #plan.mails)
        assert.equal("Alt", plan.mails[1].recipient)
    end)

    it("uses D20 item keys with suffix and bonus ids", function()
        local suffix, bonus = "100#s-44", "100#b1,2"
        local plan = build({ { items = { suffix, bonus }, operation = op("Alt", 2) } }, {
            slot("100", 0, 1, 5), slot(suffix, 0, 2, 3), slot(bonus, 0, 3, 4),
        })
        -- Keep counts for each key on its own: 3 - 2 = 1 free (the slot of 3 does not fit), 4 - 2 = 2 free.
        assert.equal(0, #plan.mails)
        assert.same({ "keep", "keep" }, reasons(plan))
        local second = build({ { items = { suffix, bonus }, operation = op("Alt", 2) } }, {
            slot(suffix, 0, 2, 3), slot(suffix, 0, 4, 1), slot(bonus, 0, 3, 4),
        })
        assert.same({ 1 }, counts(second.mails[1]))
        local keys = {}
        for _, a in ipairs(second.mails[1].attachments) do
            keys[#keys + 1] = a.key
        end
        assert.same({ suffix }, keys)
    end)

    describe("GroupsFor", function()
        local rules

        before_each(function()
            load("SettingsDB")
            load("GroupTree")
            load("OperationSchema")
            load("RulesStore")
            local db = ns.SettingsDB.New({}, { character = "Me", schemaVersion = 1 })
            rules = ns.RulesStore.New(db, {})
        end)

        it("gives a subgroup the operation of its parent", function()
            local herbs = rules:CreateGroup(1, "Herbs")
            local flowers = rules:CreateGroup(herbs, "Flowers")
            local ore = rules:CreateGroup(1, "Ore")
            rules:AddItem("100", herbs)
            rules:AddItem("200", flowers)
            rules:AddItem("300", ore)
            local mailOp = rules:CreateOperation("mailing", "To bank")
            assert(rules:SetSetting(mailOp, "recipient", "Bank"))
            assert(rules:AttachOperation(herbs, "mailing", mailOp))

            local groups = P.GroupsFor(rules, { herbs })
            assert.equal(2, #groups)
            assert.equal("Bank", groups[2].operation.recipient)
            assert.same({ "200" }, groups[2].items)

            local plan = build(P.GroupsFor(rules, { herbs, ore }),
                { slot("100", 0, 1, 4), slot("200", 0, 2, 4), slot("300", 0, 3, 4) })
            assert.equal(1, #plan.mails)
            assert.equal("Bank", plan.mails[1].recipient)
            assert.equal(2, #plan.mails[1].attachments)
            assert.same({ "no recipient" }, reasons(plan))
        end)

        it("lists a group once when the user selects it and its parent", function()
            local herbs = rules:CreateGroup(1, "Herbs")
            local flowers = rules:CreateGroup(herbs, "Flowers")
            assert.equal(2, #P.GroupsFor(rules, { herbs, flowers }))
        end)
    end)
end)
