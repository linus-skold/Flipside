local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("EventBus")))("Flipside", ns)
assert(loadfile(manifest.path("MailTotal")))("Flipside", ns)

local EVENT = "Flipside.MailMoneyTaken"

describe("MailTotal", function()
    local bus, lines, enabled, logs

    before_each(function()
        bus = ns.EventBus.New({})
        lines, enabled, logs = {}, true, 0
        ns.MailTotal.Attach({
            bus = bus,
            event = EVENT,
            print = function(text)
                lines[#lines + 1] = text
            end,
            format = function(copper)
                return copper .. "c"
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
        assert.are.same({ "You collected 400c from 3 mails." }, lines)
        assert.are.equal(1, logs)
    end)

    it("uses the singular for one mail", function()
        bus:Emit(EVENT, 100)
        bus:Emit("MAIL_CLOSED")
        assert.are.same({ "You collected 100c from 1 mail." }, lines)
    end)

    it("prints nothing when the total is 0", function()
        bus:Emit("MAIL_CLOSED")
        assert.are.equal(0, #lines)
    end)

    it("ignores an amount that is not a positive number", function()
        bus:Emit(EVENT, 0)
        bus:Emit(EVENT, -5)
        bus:Emit(EVENT, "x")
        bus:Emit("MAIL_CLOSED")
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
end)
