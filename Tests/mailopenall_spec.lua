local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

describe("MailOpenAll", function()
    local ns, bus, timers, take, run, mails, looted, free, said, changes, blockedText, removeOnTake, ended

    local FULL = "Inventory is full."

    -- A mail: items, money, cod and gm are optional.
    local function mail(fields)
        return { items = fields.items or 0, money = fields.money or 0, cod = fields.cod or 0, gm = fields.gm }
    end

    -- Runs the timers that exist now, once. A timer that a callback adds waits for the next call.
    local function pump()
        local batch = timers
        timers = {}
        for _, timer in ipairs(batch) do
            timer.fn()
        end
    end

    -- The take of one mail ends (the quiet timer), and the next step runs (the zero timer).
    local function nextMail()
        pump()
        pump()
    end

    before_each(function()
        mock.reset()
        ns = {}
        for _, name in ipairs({ "EventBus", "MailTake", "MailOpenAll" }) do
            assert(loadfile(manifest.path(name)))("Flipside", ns)
        end
        bus = ns.EventBus.New({})
        timers, looted, free, said, changes, blockedText, removeOnTake, ended = {}, {}, 10, {}, 0, nil, true, 0
        mails = {}
        take = ns.MailTake.New({
            bus = bus,
            after = function(seconds, fn)
                timers[#timers + 1] = { seconds = seconds, fn = fn }
            end,
        })
        bus:Subscribe(ns.MailTake.EVENT_ENDED, "spec", function()
            ended = ended + 1
        end)
        run = ns.MailOpenAll.New({
            api = {
                numItems = function()
                    return #mails
                end,
                header = function(index)
                    local m = mails[index]
                    return "pkg", "stat", "Sender" .. index, "Subject", m.money, m.cod, 10, m.items, false, false,
                        false, true, m.gm
                end,
                autoLoot = function(index)
                    looted[#looted + 1] = index
                    if removeOnTake then
                        table.remove(mails, index)
                    end
                end,
                freeSlots = function()
                    return free
                end,
            },
            bus = bus,
            after = function(seconds, fn)
                timers[#timers + 1] = { seconds = seconds, fn = fn }
            end,
            take = take,
            formatMoney = function(copper)
                return copper .. "c"
            end,
            fullText = FULL,
            showError = function(text)
                ns.MailOpenAll.ShowError(_G.UIErrorsFrame, text)
            end,
            say = function(text)
                said[#said + 1] = text
            end,
            blocked = function()
                return blockedText
            end,
            onChange = function()
                changes = changes + 1
            end,
        })
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("order", function()
        it("works from the last mail to the first and keeps the index right when mails go", function()
            mails = { mail({ items = 1 }), mail({ money = 5 }), mail({ items = 2, money = 7 }) }
            assert.is_true(run.Start())
            assert.are.same({ 3 }, looted)
            nextMail()
            assert.are.same({ 3, 2 }, looted)
            nextMail()
            assert.are.same({ 3, 2, 1 }, looted)
            nextMail()
            assert.is_false(run.IsRunning())
            assert.are.equal("Opened 3 mails, took 12c", run.Status())
        end)

        it("works through mails that stay in the inbox", function()
            removeOnTake = false
            mails = { mail({ items = 1 }), mail({ items = 1 }) }
            run.Start()
            nextMail()
            nextMail()
            assert.are.same({ 2, 1 }, looted)
            assert.is_false(run.IsRunning())
        end)

        it("never reads past the end of the inbox when the count drops", function()
            removeOnTake = false
            mails = { mail({ items = 1 }), mail({ items = 1 }), mail({ items = 1 }) }
            run.Start()
            mails = { mails[1] }
            nextMail()
            assert.are.same({ 3, 1 }, looted)
        end)
    end)

    describe("skip rules", function()
        it("skips a COD mail, never pays it and counts it", function()
            mails = { mail({ items = 1 }), mail({ items = 1, cod = 500 }) }
            run.Start()
            assert.are.same({ 1 }, looted)
            nextMail()
            assert.is_false(run.IsRunning())
            assert.are.equal("Opened 1 mail, took 0c, skipped 1", run.Status())
        end)

        it("skips a GM mail", function()
            mails = { mail({ items = 1, gm = true }), mail({ money = 3 }) }
            run.Start()
            nextMail()
            assert.are.same({ 2 }, looted)
            assert.are.equal("Opened 1 mail, took 3c, skipped 1", run.Status())
        end)

        it("skips a mail with nothing to take and does not count it", function()
            mails = { mail({ items = 1 }), mail({}), mail({}) }
            run.Start()
            assert.are.same({ 1 }, looted)
            nextMail()
            assert.are.equal("Opened 1 mail, took 0c", run.Status())
        end)

        it("ends at once when no mail can be taken", function()
            mails = { mail({}), mail({ cod = 9, items = 1 }) }
            assert.is_true(run.Start())
            assert.is_false(run.IsRunning())
            assert.are.same({}, looted)
            assert.are.equal("Opened 0 mails, took 0c, skipped 1", run.Status())
        end)
    end)

    describe("start", function()
        it("does not start with an empty inbox", function()
            local ok, reason = run.Start()
            assert.is_false(ok)
            assert.are.equal("The inbox is empty", reason)
            assert.is_false(run.IsRunning())
        end)

        it("does not start while a mailing run blocks it", function()
            mails = { mail({ items = 1 }) }
            blockedText = "Wait for the mailing run to end"
            local ok, reason = run.Start()
            assert.is_false(ok)
            assert.are.equal("Wait for the mailing run to end", reason)
            assert.are.equal("Wait for the mailing run to end", run.Status())
            assert.are.same({}, looted)
        end)

        it("does not start while a mail take goes", function()
            mails = { mail({ items = 1 }) }
            take.Begin()
            local ok = run.Start()
            assert.is_false(ok)
            assert.are.same({}, looted)
        end)

        it("does not start twice", function()
            mails = { mail({ items = 1 }), mail({ items = 1 }) }
            assert.is_true(run.Start())
            assert.is_false(run.Start())
            assert.are.same({ 2 }, looted)
        end)

        it("is busy from the start to the end, also between two mails", function()
            mails = { mail({ items = 1 }), mail({ items = 1 }) }
            run.Start()
            assert.is_true(run.IsRunning())
            pump()
            assert.is_false(take.IsActive())
            assert.is_true(run.IsRunning())
            pump()
            nextMail()
            assert.is_false(run.IsRunning())
        end)

        it("waits for the take to end before the next mail", function()
            mails = { mail({ items = 1 }), mail({ items = 1 }) }
            run.Start()
            bus:Emit("MAIL_INBOX_UPDATE")
            assert.are.same({ 2 }, looted)
            assert.is_true(take.IsActive())
        end)
    end)

    describe("stop", function()
        it("stops after the mail in progress", function()
            mails = { mail({ items = 1 }), mail({ items = 1 }), mail({ items = 1 }) }
            run.Start()
            run.Stop()
            assert.is_true(run.IsRunning())
            assert.are.equal("Stopping after this mail", run.Status())
            nextMail()
            assert.is_false(run.IsRunning())
            assert.are.same({ 3 }, looted)
            assert.are.equal("Stopped. Opened 1 mail, took 0c", run.Status())
        end)

        it("does nothing when no run goes", function()
            run.Stop()
            assert.is_false(run.IsRunning())
            assert.are.equal("", run.Status())
        end)

        it("ends on MAIL_CLOSED and takes no more mails", function()
            mails = { mail({ items = 1 }), mail({ items = 1 }) }
            run.Start()
            bus:Emit("MAIL_CLOSED")
            assert.is_false(run.IsRunning())
            pump()
            pump()
            assert.are.same({ 2 }, looted)
            assert.are.equal("Mailbox closed. Opened 1 mail, took 0c", run.Status())
        end)
    end)

    describe("bags full", function()
        it("stops before a mail with items, shows the error and says how many mails are left", function()
            mails = { mail({ items = 1 }), mail({ items = 2 }), mail({ items = 1 }) }
            free = 0
            run.Start()
            assert.is_false(run.IsRunning())
            assert.are.same({}, looted)
            assert.are.equal(1, #mock.uiErrors)
            assert.are.equal(FULL, mock.uiErrors[1].text)
            assert.are.same({ FULL .. " 3 mails left to open" }, said)
            assert.are.equal("Bags are full. Opened 0 mails, took 0c", run.Status())
        end)

        it("counts only the mails that it would take", function()
            mails = { mail({ items = 1 }), mail({ cod = 5, items = 1 }), mail({ items = 1 }) }
            free = 0
            run.Start()
            assert.are.same({ FULL .. " 2 mails left to open" }, said)
        end)

        it("stops through the client error during the take", function()
            removeOnTake = false
            mails = { mail({ items = 1 }), mail({ items = 1 }) }
            run.Start()
            assert.are.same({ 2 }, looted)
            bus:Emit("UI_ERROR_MESSAGE", 1, FULL)
            assert.is_false(run.IsRunning())
            assert.are.equal(1, #mock.uiErrors)
            assert.are.same({ FULL .. " 2 mails left to open" }, said)
            assert.are.equal("Bags are full. Opened 0 mails, took 0c", run.Status())
            pump()
            pump()
            assert.are.same({ 2 }, looted)
        end)

        it("ignores other client errors and errors after the run", function()
            mails = { mail({ items = 1 }) }
            run.Start()
            bus:Emit("UI_ERROR_MESSAGE", 2, "Something else.")
            assert.is_true(run.IsRunning())
            nextMail()
            bus:Emit("UI_ERROR_MESSAGE", 1, FULL)
            assert.are.same({}, mock.uiErrors)
        end)

        it("takes a mail with only money when the bags are full", function()
            mails = { mail({ items = 1 }), mail({ money = 9 }) }
            free = 0
            run.Start()
            assert.are.same({ 2 }, looted)
            nextMail()
            assert.is_false(run.IsRunning())
            assert.are.same({ 2 }, looted)
            assert.are.equal("Bags are full. Opened 1 mail, took 9c", run.Status())
            assert.are.same({ FULL .. " 1 mail left to open" }, said)
        end)
    end)

    describe("status", function()
        it("sums the mails and the money of the run", function()
            mails = { mail({ money = 100 }), mail({ items = 1, money = 250 }), mail({ items = 4 }) }
            run.Start()
            nextMail()
            nextMail()
            nextMail()
            assert.are.equal("Opened 3 mails, took 350c", run.Status())
        end)

        it("tells the progress while the run goes and calls onChange", function()
            mails = { mail({ items = 1 }), mail({ items = 1 }) }
            run.Start()
            assert.are.equal("Opening mails: 0 opened", run.Status())
            assert.is_true(changes > 0)
            nextMail()
            assert.are.equal("Opening mails: 1 opened", run.Status())
        end)

        it("leaves the take state clean for the readers of the mail events", function()
            mails = { mail({ items = 1 }) }
            run.Start()
            assert.is_true(take.IsActive())
            pump()
            assert.is_false(take.IsActive())
            assert.are.equal(1, ended)
        end)
    end)

    describe("ShowError", function()
        it("uses the client function for an external error when it exists", function()
            assert.is_true(ns.MailOpenAll.ShowError(_G.UIErrorsFrame, "Text"))
            assert.are.equal("AddExternalErrorMessage", mock.uiErrors[1].call)
            assert.are.equal("Text", mock.uiErrors[1].text)
        end)

        it("falls back to AddMessage in client red", function()
            local added
            local frame = {
                AddMessage = function(_, text, r, g, b, a)
                    added = { text, r, g, b, a }
                end,
            }
            assert.is_true(ns.MailOpenAll.ShowError(frame, "Text"))
            assert.are.same({ "Text", 1, 0.1, 0.1, 1 }, added)
        end)

        it("does nothing without a frame", function()
            assert.is_false(ns.MailOpenAll.ShowError(nil, "Text"))
        end)
    end)
end)
