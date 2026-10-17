local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

describe("MailingPanel", function()
    local ns, panel, rules, slots, started, stopped, confirms, callbacks, running, characters

    local function loadModules()
        local env = { ReportError = function() end, Flavour = {} }
        for _, name in ipairs({ "EventBus", "MailingPlan", "Theme", "Widgets", "List", "MailingPanel" }) do
            assert(loadfile(manifest.path(name)))("Flipside", env)
        end
        return env
    end

    -- A fake rules store. Group 1 is Base, 2 and 3 are children of Base, 4 is a child of 2.
    local function makeRules()
        local names = { [1] = "Base", [2] = "Herbs", [3] = "Ore", [4] = "Peaceblooms" }
        local ops = { [2] = 20, [3] = 21, [4] = nil }
        local settings = {
            [20] = { recipient = "Bank-Realm", keep = 0, maxSend = 0 },
            [21] = { recipient = "Nobody", keep = 0, maxSend = 0 },
        }
        local items = { [2] = { "i:1" }, [3] = { "i:2" }, [4] = { "i:3" } }
        local children = { [1] = { 2, 3 }, [2] = { 4 } }
        return {
            Walk = function(_, fn)
                for _, id in ipairs({ 1, 2, 4, 3 }) do
                    fn(id, 0)
                end
            end,
            EffectiveOperation = function(_, id)
                local node = id
                while node do
                    if ops[node] then
                        return ops[node], node
                    end
                    node = node == 4 and 2 or (node ~= 1 and 1 or nil)
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
        panel = ns.MailingPanel.Create(CreateFrame("Frame", nil, UIParent), {
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
        })
        panel:Refresh()
    end)

    after_each(function()
        mock.teardown()
    end)

    it("lists the groups that have their own mailing operation, with the mails and items of each", function()
        assert.are.equal(2, #panel.groups)
        local herbs, ore = panel.groups[1], panel.groups[2]
        assert.are.equal("Herbs", herbs.name)
        assert.are.equal("Bank-Realm", herbs.recipient)
        -- Herbs also plans its subgroup Peaceblooms: 25 + 3 units in two slots and one slot.
        assert.are.equal(1, herbs.mails)
        assert.are.equal(28, herbs.items)
        assert.are.equal(1, ore.mails)
        assert.are.equal(10, ore.items)
    end)

    it("warns about a recipient that is not an own character", function()
        assert.is_nil(panel.groups[1].detail:find("not one of your characters"))
        assert.is_truthy(panel.groups[2].detail:find("not one of your characters"))
    end)

    it("matches a recipient without a realm to an own character name", function()
        assert.is_true(ns.MailingPanel.IsKnownCharacter("bank", characters))
        assert.is_true(ns.MailingPanel.IsKnownCharacter("BANK-REALM", characters))
        assert.is_false(ns.MailingPanel.IsKnownCharacter("Bank-Other", characters))
        assert.is_false(ns.MailingPanel.IsKnownCharacter("Stranger", characters))
    end)

    it("shows the summary of the ticked groups", function()
        assert.are.equal("0 mails, 0 items", panel.summaryText)
        panel:SetSelected(2, true)
        assert.are.equal("1 mail, 28 items", panel.summaryText)
        panel:SetSelected(3, true)
        assert.are.equal("2 mails, 38 items", panel.summaryText)
        panel:SetSelected(2, false)
        assert.are.equal("1 mail, 10 items", panel.summaryText)
    end)

    it("builds the confirm text with the number of mails and the recipients", function()
        panel:SetSelected(2, true)
        panel:SetSelected(3, true)
        panel:Send()
        assert.are.equal(1, #confirms)
        assert.are.equal("Send 2 mails to Bank-Realm, Nobody? The client charges the postage for each mail.",
            confirms[1].text)
        assert.are.equal(0, #started)
    end)

    it("starts the run only after the confirm", function()
        panel:SetSelected(2, true)
        panel:Send()
        confirms[1].accept()
        assert.are.equal(1, #started)
        assert.are.equal(1, #started[1].mails)
    end)

    it("does not ask for a confirm when nothing is ticked", function()
        panel:Send()
        assert.are.equal(0, #confirms)
    end)

    it("does not ask for a confirm while a run is active", function()
        panel:SetSelected(2, true)
        running = true
        panel:Send()
        assert.are.equal(0, #confirms)
    end)

    it("shows the progress and lets Stop reach the run", function()
        panel:ShowProgress({ state = "delay", index = 2, total = 3, sent = 1 })
        assert.are.equal("Mail 2 of 3 (1 sent)", panel.progressText)
        panel.stop.scripts.OnClick(panel.stop)
        assert.are.equal(1, stopped)
        panel:ShowProgress({ state = "idle", index = 3, total = 3, sent = 3 })
        assert.are.equal("", panel.progressText)
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
        }, panel.resultLines)
    end)
end)
