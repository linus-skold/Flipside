local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

describe("MailingView", function()
    local ns, view, rules, slots, started, stopped, confirms, callbacks, running, characters

    local function loadModules()
        local env = { ReportError = function() end, Flavour = {} }
        for _, name in ipairs({ "EventBus", "MailingPlan", "Theme", "Widgets", "List", "Tree", "MailingView" }) do
            assert(loadfile(manifest.path(name)))("Flipside", env)
        end
        return env
    end

    -- A fake rules store. Group 1 is Base; 2, 3 and 5 are children of Base; 4 is a child of 2; 6 is a child of 5.
    -- Groups 2, 3 and 6 have their own mailing operation; 4 inherits the one of 2; 5 has none.
    local function makeRules()
        local names = { [1] = "Base", [2] = "Herbs", [3] = "Ore", [4] = "Peaceblooms", [5] = "Misc", [6] = "Cloth" }
        local ops = { [2] = 20, [3] = 21, [6] = 22 }
        local settings = {
            [20] = { recipient = "Bank-Realm", keep = 0, maxSend = 0 },
            [21] = { recipient = "Nobody", keep = 0, maxSend = 0 },
            [22] = { recipient = "Me-Realm", keep = 0, maxSend = 0 },
        }
        local items = { [2] = { "i:1" }, [3] = { "i:2" }, [4] = { "i:3" }, [6] = { "i:4" } }
        local children = { [1] = { 2, 3, 5 }, [2] = { 4 }, [5] = { 6 } }
        local parents = { [2] = 1, [3] = 1, [4] = 2, [5] = 1, [6] = 5 }
        return {
            EffectiveOperation = function(_, id)
                local node = id
                while node do
                    if ops[node] then
                        return ops[node], node
                    end
                    node = parents[node]
                end
            end,
            GetOperation = function(_, opID)
                return { settings = settings[opID] }
            end,
            Name = function(_, id)
                return names[id]
            end,
            ItemsIn = function(_, id)
                return items[id] or {}
            end,
            Children = function(_, id)
                return children[id] or {}
            end,
        }
    end

    -- The row frame that shows a node, or nil.
    local function rowOf(id)
        for _, row in ipairs(view.tree.list.rows) do
            if row.kitId == id then
                return row
            end
        end
    end

    before_each(function()
        mock.reset()
        _G.ScrollUtil = nil
        getmetatable(CreateFrame("Frame")).__index.SetJustifyH = function() end
        ns = loadModules()
        rules = makeRules()
        slots = {
            { key = "i:1", bag = 0, slot = 1, count = 20 }, { key = "i:1", bag = 0, slot = 2, count = 5 },
            { key = "i:2", bag = 0, slot = 3, count = 10 }, { key = "i:3", bag = 0, slot = 4, count = 3 },
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

    it("shows the groups that have a mailing operation, own or inherited, as a tree", function()
        assert.are.equal(3, #view.nodes)
        local herbs, ore, misc = view.nodes[1], view.nodes[2], view.nodes[3]
        assert.are.equal("Herbs", herbs.text)
        assert.are.equal("Ore", ore.text)
        assert.are.equal("Peaceblooms", herbs.children[1].text)
        assert.is_true(herbs.children[1].operated, "a subgroup shows the inherited operation")
        -- Misc has no operation: it shows only to hold Cloth, and a click does not select it.
        assert.is_false(misc.operated)
        assert.are.equal("Cloth", misc.children[1].text)
    end)

    it("shows the recipient, the mails and the items on each row", function()
        local herbs = view.nodes[1]
        assert.are.equal("Bank-Realm", herbs.recipient)
        -- Herbs also plans its subgroup Peaceblooms: 25 + 3 units in two slots and one slot.
        assert.are.equal(1, herbs.mails)
        assert.are.equal(28, herbs.items)
        assert.are.equal("> Bank-Realm, 1 mail, 28 items", herbs.detail)
        assert.are.equal("Bank-Realm", herbs.children[1].recipient, "the recipient comes from the inherited operation")
        assert.are.equal(10, view.nodes[2].items)
    end)

    it("warns about a recipient that is not an own character", function()
        assert.is_nil(view.nodes[1].detail:find("not one of your characters"))
        assert.is_truthy(view.nodes[2].detail:find("not one of your characters"))
    end)

    it("matches a recipient without a realm to an own character name", function()
        assert.is_true(ns.MailingView.IsKnownCharacter("bank", characters))
        assert.is_true(ns.MailingView.IsKnownCharacter("BANK-REALM", characters))
        assert.is_false(ns.MailingView.IsKnownCharacter("Bank-Other", characters))
        assert.is_false(ns.MailingView.IsKnownCharacter("Stranger", characters))
    end)

    it("selects a group on a click, adds another group, and clears a selected group on a click", function()
        view.tree:Select(2)
        assert.is_true(view.selected[2])
        assert.is_true(rowOf(2).selection:IsShown())
        assert.are.equal("1 mail, 28 items", view.summaryText)
        view.tree:Select(3)
        assert.is_true(view.selected[2] and view.selected[3])
        assert.is_true(rowOf(2).selection:IsShown(), "the first group stays selected")
        assert.is_true(rowOf(3).selection:IsShown())
        assert.are.equal("2 mails, 38 items", view.summaryText)
        view.tree:Select(2)
        assert.is_nil(view.selected[2])
        assert.is_false(rowOf(2).selection:IsShown())
        assert.are.equal("1 mail, 10 items", view.summaryText)
    end)

    it("plans the mails of all selected groups", function()
        view.tree:Select(2)
        view.tree:Select(3)
        local plan = view:Plan()
        assert.are.equal(2, #plan.mails)
        local recipients = { plan.mails[1].recipient, plan.mails[2].recipient }
        table.sort(recipients)
        assert.are.same({ "Bank-Realm", "Nobody" }, recipients)
    end)

    it("plans a subgroup once when the group and the subgroup are both selected", function()
        view.tree:Select(2)
        view.tree:Select(4)
        assert.are.equal("1 mail, 28 items", view.summaryText)
    end)

    it("does not select a group that has no mailing operation", function()
        view.tree:Select(5)
        assert.is_nil(view.selected[5])
        assert.are.equal("0 mails, 0 items", view.summaryText)
    end)

    it("keeps the selection when the tree is built again, but drops a group that is gone", function()
        view.tree:Select(2)
        view.tree:Select(3)
        view:Refresh()
        assert.is_true(view.selected[2])
        local children = rules.Children
        rules.Children = function(self, id)
            local list = children(self, id)
            if id == 1 then
                return { 3 }
            end
            return list
        end
        view:Refresh()
        assert.is_nil(view.selected[2])
        assert.is_true(view.selected[3])
    end)

    it("builds the confirm text with the number of mails and the recipients", function()
        view.tree:Select(2)
        view.tree:Select(3)
        view:Send()
        assert.are.equal(1, #confirms)
        assert.are.equal("Send 2 mails to Bank-Realm, Nobody? The client charges the postage for each mail.",
            confirms[1].text)
        assert.are.equal(0, #started)
    end)

    it("starts the run only after the confirm", function()
        view.tree:Select(2)
        view:Send()
        confirms[1].accept()
        assert.are.equal(1, #started)
        assert.are.equal(1, #started[1].mails)
    end)

    it("does not ask for a confirm when nothing is selected", function()
        view:Send()
        assert.are.equal(0, #confirms)
    end)

    it("does not ask for a confirm while a run is active", function()
        view.tree:Select(2)
        running = true
        view:Send()
        assert.are.equal(0, #confirms)
    end)

    it("shows the progress and lets Stop reach the run", function()
        view:ShowProgress({ state = "delay", index = 2, total = 3, sent = 1 })
        assert.are.equal("Mail 2 of 3 (1 sent)", view.progressText)
        view.stop.scripts.OnClick(view.stop)
        assert.are.equal(1, stopped)
        view:ShowProgress({ state = "idle", index = 3, total = 3, sent = 3 })
        assert.are.equal("", view.progressText)
    end)

    it("shows the result with the skips", function()
        callbacks.onDone({ sent = 2, postage = 60, stopped = "mailbox closed",
            recipients = { { name = "Bank-Realm", mails = 2, units = 30 } },
            skipped = { { key = "i:9", count = 4, reason = "soulbound" },
                { name = "Ore", count = 1, reason = "needs a confirm (cannot be returned)" } } })
        assert.are.same({
            "Sent 2 mails, postage 60c",
            "  Bank-Realm: 2 mails, 30 items",
            "|cffff6060Stopped: mailbox closed|r",
            "Skipped Name of i:9 x4: soulbound",
            "Skipped Ore x1: needs a confirm (cannot be returned)",
        }, view.resultLines)
    end)

    it("has no recipient input and no check box code", function()
        local handle = assert(io.open(manifest.path("MailingView"), "rb"))
        local source = handle:read("*a")
        handle:close()
        assert.is_nil(source:find("Kit%.Check"))
        assert.is_nil(source:find("Kit%.Input"))
        assert.is_nil(source:find("SetChecked"))
    end)
end)
