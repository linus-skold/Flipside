local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("EventBus")))("Flipside", ns)
assert(loadfile(manifest.path("MailTotal")))("Flipside", ns)

local EVENT = "Flipside.MailMoneyTaken"

describe("MailTotal", function()
    local bus, lines, enabled, logs, timers, pending

    local function advance(seconds)
        local due = timers
        timers = {}
        for _, timer in ipairs(due) do
            timer.left = timer.left - seconds
            if timer.left <= 0 then
                timer.fn()
            else
                timers[#timers + 1] = timer
            end
        end
    end

    -- Run the timers in small steps, as the clock does.
    local function wait(seconds)
        for _ = 1, seconds / 0.25 do
            advance(0.25)
        end
    end

    before_each(function()
        bus = ns.EventBus.New({})
        lines, enabled, logs, timers, pending = {}, true, 0, {}, false
        ns.MailTotal.Attach({
            bus = bus,
            event = EVENT,
            print = function(text)
                lines[#lines + 1] = text
            end,
            format = function(copper)
                return copper .. "c"
            end,
            after = function(seconds, fn)
                timers[#timers + 1] = { left = seconds, fn = fn }
            end,
            pending = function()
                return pending
            end,
            enabled = function()
                return enabled
            end,
            log = function()
                logs = logs + 1
            end,
        })
    end)

    it("adds the money of several mails and prints one line at MAIL_CLOSED", function()
        bus:Emit(EVENT, 100)
        bus:Emit(EVENT, 250)
        bus:Emit(EVENT, 50)
        assert.are.equal(0, #lines)
        bus:Emit("MAIL_CLOSED")
        wait(3)
        assert.are.same({ "You collected 400c from 3 mails." }, lines)
        assert.are.equal(1, logs)
    end)

    it("prints at once when nothing is pending", function()
        bus:Emit(EVENT, 100)
        bus:Emit("MAIL_CLOSED")
        assert.are.same({ "You collected 100c from 1 mail." }, lines)
    end)

    it("prints nothing when the total is 0", function()
        bus:Emit("MAIL_CLOSED")
        wait(3)
        assert.are.equal(0, #lines)
    end)

    it("ignores an amount that is not a positive number", function()
        bus:Emit(EVENT, 0)
        bus:Emit(EVENT, -5)
        bus:Emit(EVENT, "x")
        bus:Emit("MAIL_CLOSED")
        wait(3)
        assert.are.equal(0, #lines)
    end)

    it("resets the total after the close", function()
        bus:Emit(EVENT, 100)
        bus:Emit("MAIL_CLOSED")
        bus:Emit("MAIL_CLOSED")
        bus:Emit(EVENT, 7)
        bus:Emit("MAIL_CLOSED")
        assert.are.same({ "You collected 100c from 1 mail.", "You collected 7c from 1 mail." }, lines)
    end)

    it("prints nothing when the setting is off, and still resets", function()
        enabled = false
        bus:Emit(EVENT, 100)
        bus:Emit("MAIL_CLOSED")
        enabled = true
        bus:Emit("MAIL_CLOSED")
        assert.are.equal(0, #lines)
    end)

    describe("a take that the ledger confirms after the close", function()
        it("is in the line, and the line prints after the wait", function()
            bus:Emit(EVENT, 100)
            pending = true
            bus:Emit("MAIL_CLOSED")
            assert.are.equal(0, #lines)
            wait(0.5)
            assert.are.equal(0, #lines)
            bus:Emit(EVENT, 40)
            pending = false
            wait(0.5)
            assert.are.same({ "You collected 140c from 2 mails." }, lines)
        end)

        it("prints after the longest wait when the ledger stays pending", function()
            bus:Emit(EVENT, 100)
            pending = true
            bus:Emit("MAIL_CLOSED")
            wait(1.75)
            assert.are.equal(0, #lines)
            wait(0.5)
            assert.are.same({ "You collected 100c from 1 mail." }, lines)
        end)

        it("waits when the total is 0 and counts a late take", function()
            pending = true
            bus:Emit("MAIL_CLOSED")
            bus:Emit(EVENT, 60)
            pending = false
            wait(0.5)
            assert.are.same({ "You collected 60c from 1 mail." }, lines)
        end)

        it("prints the old total at once when the mailbox opens again", function()
            bus:Emit(EVENT, 100)
            pending = true
            bus:Emit("MAIL_CLOSED")
            bus:Emit("MAIL_SHOW")
            assert.are.same({ "You collected 100c from 1 mail." }, lines)
            bus:Emit(EVENT, 5)
            wait(3)
            assert.are.equal(1, #lines)
            bus:Emit("MAIL_CLOSED")
            wait(3)
            assert.are.equal("You collected 5c from 1 mail.", lines[2])
        end)
    end)
end)
