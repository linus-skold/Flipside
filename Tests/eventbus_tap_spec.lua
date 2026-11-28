local manifest = require("Tests.manifest")

describe("EventBus tap and error stack", function()
    local EventBus

    before_each(function()
        local ns = {}
        assert(loadfile(manifest.path("EventBus")))("Flipside", ns)
        EventBus = ns.EventBus
    end)

    it("calls onEmit with the event and the arguments of an event that has handlers", function()
        local seen = {}
        local bus = EventBus.New({
            onEmit = function(...)
                seen[#seen + 1] = { ... }
            end,
        })
        bus:Emit("NO_HANDLER", 1)
        bus:Subscribe("E", "a", function() end)
        bus:Emit("E", 1, nil, 3)
        assert.are.equal(1, #seen)
        assert.are.equal("E", seen[1][1])
        assert.are.equal(1, seen[1][2])
        assert.are.equal(3, seen[1][4])
    end)

    it("keeps going when onEmit raises an error", function()
        local called = false
        local bus = EventBus.New({
            onEmit = function()
                error("tap failed")
            end,
        })
        bus:Subscribe("E", "a", function()
            called = true
        end)
        assert.has_no.errors(function()
            bus:Emit("E")
        end)
        assert.is_true(called)
    end)

    it("gives the error text and a stack to onError", function()
        local event, owner, err, stack
        _G.debugstack = function()
            return "stack text"
        end
        local bus = EventBus.New({
            onError = function(e, o, m, s)
                event, owner, err, stack = e, o, m, s
            end,
        })
        bus:Subscribe("E", "a", function()
            error("boom", 0)
        end)
        bus:Emit("E")
        _G.debugstack = nil
        assert.are.equal("E", event)
        assert.are.equal("a", owner)
        assert.are.equal("boom", err)
        assert.are.equal("stack text", stack)
    end)

    describe("handler timing", function()
        local now, slow

        local function timedBus(options)
            options = options or {}
            options.clock = function()
                return now
            end
            options.onSlow = function(event, name, ms)
                slow[#slow + 1] = { event, name, ms }
            end
            return EventBus.New(options)
        end

        before_each(function()
            now, slow = 0, {}
        end)

        it("reports a handler at the limit, with the event, the owner name and the time", function()
            local bus = timedBus()
            bus:Subscribe("E", "Owner.A", function()
                now = now + 25
            end)
            bus:Subscribe("E", "Owner.B", function()
                now = now + 24
            end)
            bus:Emit("E")
            assert.are.same({ { "E", "Owner.A", 25 } }, slow)
        end)

        it("uses the slowMs option", function()
            local bus = timedBus({ slowMs = 5 })
            bus:Subscribe("E", "a", function()
                now = now + 6
            end)
            bus:Emit("E")
            assert.are.equal(1, #slow)
        end)

        it("names a table owner by its ownerName field", function()
            local bus = timedBus()
            local owner = { ownerName = "Flipside.Thing" }
            bus:Subscribe("E", owner, function()
                now = now + 30
            end)
            bus:Emit("E")
            assert.are.equal("Flipside.Thing", slow[1][2])
            assert.is_string(EventBus.OwnerName({}))
        end)

        it("reports a slow handler that fails, and the next handler still runs", function()
            local bus = timedBus({ onError = function() end })
            local ran = false
            bus:Subscribe("E", "a", function()
                now = now + 40
                error("boom", 0)
            end)
            bus:Subscribe("E", "b", function()
                ran = true
            end)
            bus:Emit("E")
            assert.is_true(ran)
            assert.are.equal(1, #slow)
        end)

        it("times nothing without a clock", function()
            local bus = EventBus.New({ onSlow = function()
                error("must not run")
            end })
            bus:Subscribe("E", "a", function() end)
            assert.has_no.errors(function()
                bus:Emit("E")
            end)
        end)

        it("keeps going when onSlow raises an error", function()
            local bus = timedBus()
            bus.onSlow = function()
                error("sink failed")
            end
            local ran = false
            bus:Subscribe("E", "a", function()
                now = now + 30
            end)
            bus:Subscribe("E", "b", function()
                ran = true
            end)
            bus:Emit("E")
            assert.is_true(ran)
        end)
    end)

    it("calls the next handler after an error and passes the arguments", function()
        local got
        local bus = EventBus.New({ onError = function() end })
        bus:Subscribe("E", "a", function()
            error("boom", 0)
        end)
        bus:Subscribe("E", "b", function(_, x, y)
            got = { x, y }
        end)
        bus:Emit("E", 4, 5)
        assert.are.same({ 4, 5 }, got)
    end)
end)
