local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("EventBus")))("Flipside", ns)
assert(loadfile(manifest.path("MailTotal")))("Flipside", ns)

describe("MailTotal", function()
    local bus, lines, enabled, timers, gold

    -- Run the timers that are due after the given seconds.
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

    before_each(function()
        bus = ns.EventBus.New({})
        lines, enabled, timers, gold = {}, true, {}, 1000
        ns.MailTotal.Attach({
            bus = bus,
            money = function()
                return gold
            end,
            print = function(text)
                lines[#lines + 1] = text
            end,
            format = function(copper)
                return copper .. "c"
            end,
            after = function(seconds, fn)
                timers[#timers + 1] = { left = seconds, fn = fn }
            end,
            enabled = function()
                return enabled
            end,
        })
    end)

    it("prints one line with the gain after the wait", function()
        bus:Emit("MAIL_SHOW")
        gold = 1250
        bus:Emit("MAIL_CLOSED")
        assert.are.equal(0, #lines)
        advance(ns.MailTotal.WAIT)
        assert.are.same({ "You collected 250c from the mailbox." }, lines)
    end)

    it("prints nothing when the money is the same", function()
        bus:Emit("MAIL_SHOW")
        bus:Emit("MAIL_CLOSED")
        advance(1)
        assert.are.equal(0, #lines)
    end)

    it("prints nothing when the money is lower", function()
        bus:Emit("MAIL_SHOW")
        gold = 400
        bus:Emit("MAIL_CLOSED")
        advance(1)
        assert.are.equal(0, #lines)
    end)

    it("counts money that arrives during the wait", function()
        bus:Emit("MAIL_SHOW")
        gold = 1100
        bus:Emit("MAIL_CLOSED")
        advance(0.25)
        gold = 1300
        advance(0.25)
        assert.are.same({ "You collected 300c from the mailbox." }, lines)
    end)

    it("prints the old result at once when the mailbox opens again", function()
        bus:Emit("MAIL_SHOW")
        gold = 1100
        bus:Emit("MAIL_CLOSED")
        bus:Emit("MAIL_SHOW")
        assert.are.same({ "You collected 100c from the mailbox." }, lines)
        advance(1)
        assert.are.equal(1, #lines)
        gold = 1150
        bus:Emit("MAIL_CLOSED")
        advance(1)
        assert.are.equal("You collected 50c from the mailbox.", lines[2])
    end)

    it("starts a new count at each open", function()
        bus:Emit("MAIL_SHOW")
        gold = 1100
        bus:Emit("MAIL_CLOSED")
        advance(1)
        bus:Emit("MAIL_SHOW")
        bus:Emit("MAIL_CLOSED")
        advance(1)
        assert.are.equal(1, #lines)
    end)

    it("prints nothing when the setting is off", function()
        enabled = false
        bus:Emit("MAIL_SHOW")
        gold = 1100
        bus:Emit("MAIL_CLOSED")
        advance(1)
        assert.are.equal(0, #lines)
    end)

    it("prints nothing and gives no error for MAIL_CLOSED without MAIL_SHOW", function()
        gold = 5000
        assert.has_no.errors(function()
            bus:Emit("MAIL_CLOSED")
            advance(1)
        end)
        assert.are.equal(0, #lines)
    end)
end)
