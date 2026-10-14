describe("EventBus", function()
    local EventBus

    before_each(function()
        local ns = {}
        assert(loadfile("Core/EventBus.lua"))("Flipside", ns)
        EventBus = ns.EventBus
    end)

    it("calls handlers in subscription sequence with the event name", function()
        local bus = EventBus.New()
        local log = {}
        bus:Subscribe("E", "a", function(ev, x) log[#log + 1] = "a" .. ev .. x end)
        bus:Subscribe("E", "b", function(ev, x) log[#log + 1] = "b" .. ev .. x end)
        bus:Emit("E", 1)
        assert.same({ "aE1", "bE1" }, log)
    end)

    it("passes varargs with nil values unchanged", function()
        local bus = EventBus.New()
        local n, got
        bus:Subscribe("E", "a", function(_, ...)
            n = select("#", ...)
            got = { ... }
        end)
        bus:Emit("E", nil, 2, nil, nil)
        assert.equals(4, n)
        assert.is_nil(got[1])
        assert.equals(2, got[2])
        bus:Emit("E")
        assert.equals(0, n)
    end)

    it("replaces a handler for the same pair and keeps its position", function()
        local bus = EventBus.New()
        local log = {}
        bus:Subscribe("E", "a", function() log[#log + 1] = "a1" end)
        bus:Subscribe("E", "b", function() log[#log + 1] = "b" end)
        bus:Subscribe("E", "a", function() log[#log + 1] = "a2" end)
        bus:Emit("E")
        assert.same({ "a2", "b" }, log)
    end)

    it("unsubscribes one handler and ignores a missing one", function()
        local bus = EventBus.New()
        local log = {}
        bus:Subscribe("E", "a", function() log[#log + 1] = "a" end)
        bus:Subscribe("E", "b", function() log[#log + 1] = "b" end)
        bus:Unsubscribe("E", "a")
        assert.has_no.errors(function()
            bus:Unsubscribe("E", "a")
            bus:Unsubscribe("none", "a")
        end)
        bus:Emit("E")
        assert.same({ "b" }, log)
    end)

    it("UnsubscribeAll removes every handler of an owner", function()
        local bus = EventBus.New()
        local owner = {}
        local log = {}
        bus:Subscribe("E1", owner, function() log[#log + 1] = "o1" end)
        bus:Subscribe("E2", owner, function() log[#log + 1] = "o2" end)
        bus:Subscribe("E1", "other", function() log[#log + 1] = "x" end)
        bus:UnsubscribeAll(owner)
        bus:Emit("E1")
        bus:Emit("E2")
        assert.same({ "x" }, log)
        assert.is_false(bus:HasSubscribers("E2"))
        assert.is_true(bus:HasSubscribers("E1"))
    end)

    it("continues after a failing handler and reports it", function()
        local errs = {}
        local bus = EventBus.New({
            onError = function(ev, owner, msg) errs[#errs + 1] = { ev, owner, msg } end,
        })
        local called = false
        bus:Subscribe("E", "bad", function() error("boom", 0) end)
        bus:Subscribe("E", "good", function() called = true end)
        bus:Emit("E")
        assert.is_true(called)
        assert.same({ { "E", "bad", "boom" } }, errs)
    end)

    it("ignores failures without an error handler", function()
        local bus = EventBus.New()
        local called = false
        bus:Subscribe("E", "bad", function() error("boom") end)
        bus:Subscribe("E", "good", function() called = true end)
        assert.has_no.errors(function() bus:Emit("E") end)
        assert.is_true(called)
    end)

    it("sets the error handler later", function()
        local bus = EventBus.New()
        local msg
        bus:Subscribe("E", "bad", function() error("late", 0) end)
        bus:SetErrorHandler(function(_, _, m) msg = m end)
        bus:Emit("E")
        assert.equals("late", msg)
    end)

    it("survives a failing error handler", function()
        local bus = EventBus.New({ onError = function() error("worse") end })
        local called = false
        bus:Subscribe("E", "bad", function() error("boom") end)
        bus:Subscribe("E", "good", function() called = true end)
        assert.has_no.errors(function() bus:Emit("E") end)
        assert.is_true(called)
    end)

    it("lets a handler unsubscribe itself", function()
        local bus = EventBus.New()
        local count, other = 0, 0
        bus:Subscribe("E", "a", function()
            count = count + 1
            bus:Unsubscribe("E", "a")
        end)
        bus:Subscribe("E", "b", function() other = other + 1 end)
        bus:Emit("E")
        bus:Emit("E")
        assert.equals(1, count)
        assert.equals(2, other)
    end)

    it("does not call a handler removed during Emit", function()
        local bus = EventBus.New()
        local called = false
        bus:Subscribe("E", "a", function() bus:Unsubscribe("E", "b") end)
        bus:Subscribe("E", "b", function() called = true end)
        bus:Emit("E")
        assert.is_false(called)
    end)

    it("calls a handler added during Emit only in the next Emit", function()
        local bus = EventBus.New()
        local added = 0
        bus:Subscribe("E", "a", function()
            bus:Subscribe("E", "new", function() added = added + 1 end)
        end)
        bus:Emit("E")
        assert.equals(0, added)
        bus:Emit("E")
        assert.equals(1, added)
    end)

    it("supports nested Emit", function()
        local bus = EventBus.New()
        local log = {}
        bus:Subscribe("A", "x", function()
            log[#log + 1] = "A1"
            bus:Emit("B")
            log[#log + 1] = "A2"
        end)
        bus:Subscribe("B", "x", function() log[#log + 1] = "B" end)
        bus:Emit("A")
        assert.same({ "A1", "B", "A2" }, log)

        local depth, max = 0, 0
        bus:Subscribe("R", "x", function()
            depth = depth + 1
            max = math.max(max, depth)
            if depth < 3 then bus:Emit("R") end
            depth = depth - 1
        end)
        bus:Emit("R")
        assert.equals(3, max)
    end)

    it("reports HasSubscribers", function()
        local bus = EventBus.New()
        assert.is_false(bus:HasSubscribers("E"))
        bus:Subscribe("E", "a", function() end)
        assert.is_true(bus:HasSubscribers("E"))
        bus:Unsubscribe("E", "a")
        assert.is_false(bus:HasSubscribers("E"))
    end)

    it("calls source hooks once for each change", function()
        local first, last = {}, {}
        local bus = EventBus.New({
            onFirstSubscriber = function(ev) first[#first + 1] = ev end,
            onLastUnsubscribed = function(ev) last[#last + 1] = ev end,
        })
        bus:Subscribe("E", "a", function() end)
        bus:Subscribe("E", "b", function() end)
        bus:Subscribe("E", "a", function() end)
        assert.same({ "E" }, first)
        bus:Unsubscribe("E", "a")
        assert.same({}, last)
        bus:Unsubscribe("E", "b")
        assert.same({ "E" }, last)
        bus:Subscribe("E", "c", function() end)
        assert.same({ "E", "E" }, first)
        bus:UnsubscribeAll("c")
        assert.same({ "E", "E" }, last)
    end)

    it("calls source hooks for changes during Emit", function()
        local first, last = {}, {}
        local bus = EventBus.New({
            onFirstSubscriber = function(ev) first[#first + 1] = ev end,
            onLastUnsubscribed = function(ev) last[#last + 1] = ev end,
        })
        bus:Subscribe("E", "a", function()
            bus:Subscribe("F", "a", function() end)
            bus:Unsubscribe("E", "a")
        end)
        bus:Emit("E")
        assert.same({ "E", "F" }, first)
        assert.same({ "E" }, last)
    end)

    it("keeps two buses independent", function()
        local bus1, bus2 = EventBus.New(), EventBus.New()
        local c1, c2 = 0, 0
        bus1:Subscribe("E", "a", function() c1 = c1 + 1 end)
        bus2:Subscribe("E", "a", function() c2 = c2 + 1 end)
        bus1:Emit("E")
        assert.equals(1, c1)
        assert.equals(0, c2)
        bus1:UnsubscribeAll("a")
        assert.is_false(bus1:HasSubscribers("E"))
        assert.is_true(bus2:HasSubscribers("E"))
    end)

    it("validates Subscribe arguments", function()
        local bus = EventBus.New()
        local f = function() end
        assert.has_error(function() bus:Subscribe("", "a", f) end)
        assert.has_error(function() bus:Subscribe(5, "a", f) end)
        assert.has_error(function() bus:Subscribe("E", nil, f) end)
        assert.has_error(function() bus:Subscribe("E", "a", "no") end)
        assert.has_error(function() bus:Subscribe("E", "a") end)
        assert.has_error(function() bus:SetErrorHandler("no") end)
        assert.is_false(bus:HasSubscribers("E"))
    end)
end)
