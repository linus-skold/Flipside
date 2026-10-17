local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

describe("MailingView", function()
    local ns, view, rules, slots, started, stopped, confirms, callbacks, running, characters, logged

    local function loadModules()
        local env = { ReportError = function() end, Flavour = {} }
        for _, name in ipairs({ "EventBus", "MailingPlan", "Theme", "Widgets", "List", "MailingView" }) do
            assert(loadfile(manifest.path(name)))("Flipside", env)
        end
        return env
    end

    -- A fake rules store. Group 1 is Base; 2, 3, 5, 7 and 8 are children of Base; 4 is a child of 2; 6 is a child
    -- of 5. Group 7 is All bag items. Operation 20 is on group 2 (group 4 inherits it), 21 on 3, 22 on 6, 23 on
    -- 7, 24 (no recipient) on 8. Operation 25 is on no group.
    local function makeRules()
        local names = { [1] = "Base", [2] = "Herbs", [3] = "Ore", [4] = "Peaceblooms", [5] = "Misc", [6] = "Cloth",
            [7] = "All bag items", [8] = "Gems" }
        local attached = { [2] = 20, [3] = 21, [6] = 22, [7] = 23, [8] = 24 }
        local opNames = { [20] = "Herbs to bank", [21] = "Ore to Nobody", [22] = "Cloth to me", [23] = "Leftovers",
            [24] = "Blank", [25] = "Unused" }
        local settings = {
            [20] = { recipient = "Bank-Realm", keep = 0, maxSend = 0 },
            [21] = { recipient = "Nobody", keep = 0, maxSend = 0 },
            [22] = { recipient = "Me-Realm", keep = 0, maxSend = 0 },
            [23] = { recipient = "Bank-Realm", keep = 0, maxSend = 0 },
            [24] = { recipient = "", keep = 0, maxSend = 0 },
            [25] = { recipient = "Bank-Realm", keep = 0, maxSend = 0 },
        }
        local items = { [2] = { "i:1" }, [3] = { "i:2" }, [4] = { "i:3" }, [6] = { "i:4" } }
        local children = { [1] = { 2, 3, 5, 7, 8 }, [2] = { 4 }, [5] = { 6 } }
        local parents = { [2] = 1, [3] = 1, [4] = 2, [5] = 1, [6] = 5, [7] = 1, [8] = 1 }
        local store = { settings = settings }
        function store.EffectiveOperation(_, id)
            local node = id
            while node do
                if attached[node] then
                    return attached[node], node
                end
                node = parents[node]
            end
        end
        function store.GetOperation(_, opID)
            return { id = opID, name = opNames[opID], type = "mailing", settings = settings[opID] }
        end
        function store.ListOperations()
            local list = {}
            for _, id in ipairs({ 20, 21, 22, 23, 24, 25 }) do
                list[#list + 1] = { id = id, name = opNames[id], type = "mailing" }
            end
            return list
        end
        function store.Name(_, id)
            return names[id]
        end
        function store.ItemsIn(_, id)
            return items[id] or {}
        end
        function store.Children(_, id)
            return children[id] or {}
        end
        function store.Walk(_, fn)
            local function visit(id, depth)
                fn(id, depth)
                for _, child in ipairs(children[id] or {}) do
                    visit(child, depth + 1)
                end
            end
            visit(1, 0)
        end
        function store.AllBagsGroup()
            return 7
        end
        function store.GroupOf(_, key)
            for group, keys in pairs(items) do
                for _, grouped in ipairs(keys) do
                    if grouped == key then
                        return group
                    end
                end
            end
            return 1
        end
        return store
    end

    -- The row frame that shows a rule, or nil.
    local function rowOf(id)
        for _, row in ipairs(view.list.rows) do
            if row.rule and row.rule.id == id and row:IsShown() then
                return row
            end
        end
    end

    local function recipientsOfPlan(plan)
        local names = {}
        for _, mail in ipairs(plan.mails) do
            names[#names + 1] = mail.recipient
        end
        return names
    end

    before_each(function()
        mock.reset()
        _G.ScrollUtil = nil
        ns = loadModules()
        logged = {}
        ns.Log = { Write = function(category, level, text)
            logged[#logged + 1] = { category, level, text }
        end }
        rules = makeRules()
        slots = {
            { key = "i:1", bag = 0, slot = 1, count = 20 }, { key = "i:1", bag = 0, slot = 2, count = 5 },
            { key = "i:2", bag = 0, slot = 3, count = 10 }, { key = "i:3", bag = 0, slot = 4, count = 3 },
            { key = "i:4", bag = 0, slot = 5, count = 2 }, { key = "i:9", bag = 0, slot = 6, count = 7 },
        }
        started, stopped, confirms, running = {}, 0, {}, false
        characters = { "Me-Realm", "Bank-Realm" }
        view = ns.MailingView.Create(CreateFrame("Frame", nil, UIParent), {
            rules = rules,
            client = { ReadSlots = function()
                return slots
            end },
            characters = function()
                return characters
            end,
            selfName = function()
                return "Me-Realm"
            end,
            itemName = function(key)
                return "Name of " .. key
            end,
            formatMoney = function(copper)
                return copper .. "c"
            end,
            confirm = function(text, onAccept)
                confirms[#confirms + 1] = { text = text, accept = onAccept }
            end,
            newRun = function(cb)
                callbacks = cb
                return {
                    IsRunning = function()
                        return running
                    end,
                    Start = function(_, plan)
                        started[#started + 1] = plan
                        return true
                    end,
                    Stop = function()
                        stopped = stopped + 1
                    end,
                }
            end,
        }, { width = 330, height = 420 })
        view:Refresh()
    end)

    after_each(function()
        mock.teardown()
    end)

    it("builds in any parent and takes its size from the argument", function()
        assert.are.equal(330, view.frame.width)
        assert.are.equal(420, view.frame.height)
        local other = ns.MailingView.Create(CreateFrame("Frame", nil, UIParent), {
            newRun = function()
                return { IsRunning = function()
                    return false
                end }
            end,
            client = {},
        })
        assert.is_not_nil(other.frame)
    end)

    it("shows one compact row for each mailing operation", function()
        assert.are.equal(6, #view.rules)
        local names = {}
        for _, rule in ipairs(view.rules) do
            names[#names + 1] = rule.name
        end
        assert.are.same({ "Herbs to bank", "Ore to Nobody", "Cloth to me", "Leftovers", "Blank", "Unused" }, names)
        local row = rowOf(20)
        assert.are.equal(18, row.height, "the row height is the Ledger row height")
        assert.are.equal("Herbs to bank", row.nameText:GetText())
        assert.are.equal("Bank-Realm", row.recipientText:GetText())
        assert.are.equal("2 groups", row.groupsText:GetText())
        assert.are.equal("any item", row.filterText:GetText())
        assert.are.equal("1 group", rowOf(21).groupsText:GetText())
    end)

    it("resolves the groups of a rule, with inheritance and the All bag items group", function()
        assert.are.same({ "Herbs", "Peaceblooms" }, view.byId[20].groupNames)
        assert.are.same({ "Ore" }, view.byId[21].groupNames)
        assert.are.same({ "All bag items" }, view.byId[23].groupNames)
        assert.are.same({}, view.byId[25].groupNames)
    end)

    it("plans the mails of each rule from its own groups", function()
        -- Herbs plans its subgroup Peaceblooms: 25 + 3 units in one mail.
        assert.are.equal(1, view.byId[20].mails)
        assert.are.equal(28, view.byId[20].items)
        assert.are.equal(10, view.byId[21].items)
        assert.are.equal(0, view.byId[22].mails, "a mail to the own character is skipped")
        assert.are.equal(7, view.byId[23].items, "All bag items takes the item that is in no group")
    end)

    it("lists the groups of a rule in the tooltip of its row", function()
        local row = rowOf(20)
        row.scripts.OnEnter(row)
        local lines = mock.tooltip.lines
        assert.are.equal("Herbs to bank", mock.tooltip.title)
        assert.are.equal("Recipient: Bank-Realm", lines[1])
        assert.are.equal("Groups:", lines[2])
        assert.are.equal("Herbs", lines[3])
        assert.are.equal("Peaceblooms", lines[4])
        assert.is_true(mock.tooltip.shown)
    end)

    it("warns about a recipient that is not an own character", function()
        assert.is_falsy(view.byId[20].unknown)
        assert.is_true(view.byId[21].unknown)
        local color = rowOf(21).recipientText.color
        assert.are.same({ 1, 0.4, 0.4 }, { color[1], color[2], color[3] })
    end)

    it("matches a recipient without a realm to an own character name", function()
        assert.is_true(ns.MailingView.IsKnownCharacter("bank", characters))
        assert.is_true(ns.MailingView.IsKnownCharacter("BANK-REALM", characters))
        assert.is_false(ns.MailingView.IsKnownCharacter("Bank-Other", characters))
        assert.is_false(ns.MailingView.IsKnownCharacter("Stranger", characters))
    end)

    it("shows a rule with no recipient or no groups as disabled, with the reason", function()
        assert.are.equal("no recipient", view.byId[24].reason)
        assert.are.equal("no groups", view.byId[25].reason)
        assert.is_false(rowOf(24).run.enabled)
        assert.are.equal("no recipient", rowOf(24).filterText:GetText())
        assert.is_false(rowOf(25).run.enabled)
        assert.are.equal("no groups", rowOf(25).filterText:GetText())
        assert.is_true(rowOf(20).run.enabled)
        view:RunRule(24)
        view:RunRule(25)
        assert.are.equal(0, #confirms)
    end)

    it("summarises the filter of a rule", function()
        local text = ns.MailingView.FilterText
        assert.are.equal("any item", (text({})))
        assert.are.equal("Unc-Epic, 2 types", (text({ minQuality = 2, maxQuality = 4, itemClasses = "2,4" })))
        assert.are.equal("Rare", (text({ minQuality = 3, maxQuality = 3 })))
        assert.are.equal("Poor-Com, 1 type", (text({ minQuality = 0, maxQuality = 1, itemClasses = "7" })))
        assert.are.equal("Rarity: Uncommon to Epic\nItem types: 2",
            select(2, text({ minQuality = 2, maxQuality = 4, itemClasses = "2,4" })))
        rules.settings[20].minQuality = 2
        rules.settings[20].itemClasses = "2,4"
        view:Refresh()
        assert.are.equal("Unc-Epic, 2 types", rowOf(20).filterText:GetText())
    end)

    it("asks for one confirm for a rule and then runs only that rule", function()
        view:RunRule(21)
        assert.are.equal(1, #confirms)
        assert.are.equal("Send 1 mail to Nobody? The client charges the postage for each mail.", confirms[1].text)
        assert.are.equal(0, #started)
        confirms[1].accept()
        assert.are.equal(1, #started)
        assert.are.same({ "Nobody" }, recipientsOfPlan(started[1]))
    end)

    it("runs the button of a row for that row only", function()
        local button = rowOf(20).run
        button.scripts.OnClick(button)
        assert.are.equal(1, #confirms)
        confirms[1].accept()
        assert.are.same({ "Bank-Realm" }, recipientsOfPlan(started[1]))
        assert.are.equal(1, #started[1].mails)
        assert.are.equal(3, #started[1].mails[1].attachments)
    end)

    it("runs every rule in order after one confirm with Run all", function()
        view.runAll.scripts.OnClick(view.runAll)
        assert.are.equal(1, #confirms)
        assert.are.equal("Send 3 mails to Bank-Realm, Nobody? The client charges the postage for each mail.",
            confirms[1].text)
        confirms[1].accept()
        assert.are.equal(1, #started)
        assert.are.same({ "Bank-Realm", "Nobody", "Bank-Realm" }, recipientsOfPlan(started[1]))
    end)

    it("reports a rule with nothing to send and starts no run", function()
        view:RunRule(22)
        assert.are.equal(0, #confirms)
        assert.are.equal("Nothing to send for Cloth to me", view.statusText)
        assert.are.equal("Nothing to send for Cloth to me", view.status:GetText())
        assert.are.equal("mail", logged[1][1])
    end)

    it("does not ask for a confirm while a run is active", function()
        running = true
        view:RunRule(20)
        view:RunAll()
        assert.are.equal(0, #confirms)
    end)

    it("shows the rule and mail count in the status line when idle", function()
        assert.are.equal("6 rules, 3 mails ready", view.statusText)
        assert.is_true(view.runAll.enabled)
    end)

    it("disables Run all when no rule can run", function()
        rules.ListOperations = function()
            return { { id = 25, name = "Unused", type = "mailing" } }
        end
        view:Refresh()
        assert.is_false(view.runAll.enabled)
    end)

    it("shows the progress and lets Stop reach the run", function()
        view:ShowProgress({ state = "delay", index = 2, total = 3, sent = 1 })
        assert.are.equal("Mail 2 of 3 (1 sent)", view.statusText)
        assert.is_true(view.stop.enabled)
        assert.is_false(view.runAll.enabled)
        view.stop.scripts.OnClick(view.stop)
        assert.are.equal(1, stopped)
        view:ShowProgress({ state = "idle", index = 3, total = 3, sent = 3 })
        assert.is_false(view.stop.enabled)
    end)

    it("has no bottom result box and no group tree", function()
        assert.is_nil(view.results)
        assert.is_nil(view.tree)
        assert.is_nil(view.selected)
        local handle = assert(io.open(manifest.path("MailingView"), "rb"))
        local source = handle:read("*a")
        handle:close()
        assert.is_nil(source:find("CreateTree", 1, true))
        assert.is_nil(source:find("view.results", 1, true))
        assert.is_nil(source:find("Kit%.Check"))
        assert.is_nil(source:find("Kit%.Input"))
    end)

    local result = { sent = 2, postage = 60, stopped = "mailbox closed",
        recipients = { { name = "Bank-Realm", mails = 2, units = 30 } },
        skipped = { { key = "i:9", count = 4, reason = "soulbound" },
            { name = "Ore", count = 1, reason = "needs a confirm (cannot be returned)" } } }

    it("shows the result as one status line", function()
        callbacks.onDone(result)
        assert.are.equal("Sent 2 mails, postage 60c, stopped: mailbox closed, 2 skipped", view.statusText)
        assert.are.equal(view.statusText, view.status:GetText())
    end)

    it("writes the detail lines of a result to the log", function()
        callbacks.onDone(result)
        local texts = {}
        for _, entry in ipairs(logged) do
            assert.are.equal("mail", entry[1])
            texts[#texts + 1] = entry[3]
        end
        assert.are.same({
            "Sent 2 mails, postage 60c",
            "  Bank-Realm: 2 mails, 30 items",
            "Stopped: mailbox closed",
            "Skipped Name of i:9 x4: soulbound",
            "Skipped Ore x1: needs a confirm (cannot be returned)",
        }, texts)
    end)

    it("builds the lines of a result", function()
        assert.are.same({
            "Sent 2 mails, postage 60c",
            "  Bank-Realm: 2 mails, 30 items",
            "|cffff6060Stopped: mailbox closed|r",
            "Skipped Name of i:9 x4: soulbound",
            "Skipped Ore x1: needs a confirm (cannot be returned)",
        }, ns.MailingView.ResultLines(result, function(key)
            return "Name of " .. key
        end, function(copper)
            return copper .. "c"
        end))
    end)
end)
