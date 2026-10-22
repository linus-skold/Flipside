local manifest = require("Tests.manifest")

describe("MailTake", function()
    local ns, bus, timers, take, ended

    local function fireLast()
        local timer = table.remove(timers)
        timer.fn()
    end

    before_each(function()
        ns = {}
        for _, name in ipairs({ "EventBus", "MailTake" }) do
            assert(loadfile(manifest.path(name)))("Flipside", ns)
        end
        bus = ns.EventBus.New({})
        timers, ended = {}, 0
        bus:Subscribe(ns.MailTake.EVENT_ENDED, "spec", function()
            ended = ended + 1
        end)
        take = ns.MailTake.New({
            bus = bus,
            after = function(seconds, fn)
                timers[#timers + 1] = { seconds = seconds, fn = fn }
            end,
        })
    end)

    it("is off until Begin", function()
        assert.is_false(take.IsActive())
        bus:Emit("MAIL_INBOX_UPDATE")
        assert.are.equal(0, #timers)
    end)

    it("ends once after the quiet time", function()
        take.Begin()
        assert.is_true(take.IsActive())
        assert.are.equal(0.5, timers[1].seconds)
        fireLast()
        assert.is_false(take.IsActive())
        assert.are.equal(1, ended)
    end)

    it("stays on while mail and bag events keep coming", function()
        take.Begin()
        bus:Emit("MAIL_INBOX_UPDATE")
        bus:Emit("BAG_UPDATE_DELAYED")
        assert.are.equal(3, #timers)
        timers[1].fn()
        timers[2].fn()
        assert.is_true(take.IsActive())
        assert.are.equal(0, ended)
        timers[3].fn()
        assert.is_false(take.IsActive())
        assert.are.equal(1, ended)
    end)

    it("ends at once on MAIL_CLOSED, and the old timer then does nothing", function()
        take.Begin()
        bus:Emit("MAIL_CLOSED")
        assert.is_false(take.IsActive())
        assert.are.equal(1, ended)
        fireLast()
        assert.are.equal(1, ended)
    end)

    it("does not emit on MAIL_CLOSED when no take runs", function()
        bus:Emit("MAIL_CLOSED")
        assert.are.equal(0, ended)
    end)

    it("starts a new take after one ended", function()
        take.Begin()
        fireLast()
        take.Begin()
        assert.is_true(take.IsActive())
        fireLast()
        assert.are.equal(2, ended)
    end)
end)
