describe("Scheduler", function()
    local ns, now, sched, errors

    local function newScheduler(extra)
        local options = { clock = function() return now end, onError = function(job, msg)
            errors[#errors + 1] = { job = job, msg = msg }
        end }
        for k, v in pairs(extra or {}) do
            options[k] = v
        end
        return ns.Scheduler.New(options)
    end

    local function ticksUntilIdle(s, limit)
        local n = 0
        while not s:IsIdle() and n < (limit or 100) do
            s:Tick()
            n = n + 1
        end
        return n
    end

    before_each(function()
        ns = {}
        assert(loadfile("Core/Scheduler.lua"))("Flipside", ns)
        now = 0
        errors = {}
        sched = newScheduler({ frameBudgetMs = 10, unitsPerFrame = 1000 })
    end)

    it("needs a clock", function()
        assert.has_error(function() ns.Scheduler.New({}) end)
        assert.has_error(function() ns.Scheduler.New() end)
    end)

    it("runs 2500 units in 3 ticks with progress", function()
        local seen = {}
        local job = sched:Start("rows", function(j)
            for i = 1, 2500 do
                j:SetProgress(i, 2500)
                j:Checkpoint()
            end
            return "ok"
        end)
        sched:Tick()
        local d, t = job:GetProgress()
        assert.are.equal(1000, d)
        assert.are.equal(2500, t)
        assert.are.equal("running", job:GetStatus())
        sched:Tick()
        seen[1], seen[2] = job:GetProgress()
        assert.are.equal(2000, seen[1])
        assert.are.equal("running", job:GetStatus())
        sched:Tick()
        d = job:GetProgress()
        assert.are.equal(2500, d)
        assert.are.equal("done", job:GetStatus())
        assert.is_true(sched:IsIdle())
    end)

    it("has nil progress before the first set", function()
        local job = sched:Start("p", function() end)
        local d, t = job:GetProgress()
        assert.is_nil(d)
        assert.is_nil(t)
    end)

    it("counts the units passed to Checkpoint", function()
        local job = sched:Start("units", function(j)
            j:Checkpoint(600)
            j:Checkpoint(600)
            j:Checkpoint(1)
        end)
        sched:Tick()
        assert.are.equal("running", job:GetStatus())
        sched:Tick()
        assert.are.equal("done", job:GetStatus())
    end)

    it("yields when the time budget is used before the unit limit", function()
        local count = 0
        local job = sched:Start("slow", function(j)
            for _ = 1, 10 do
                now = now + 4
                count = count + 1
                j:Checkpoint()
            end
        end)
        sched:Tick()
        assert.are.equal(3, count)
        sched:Tick()
        assert.are.equal(6, count)
        ticksUntilIdle(sched)
        assert.are.equal(10, count)
        assert.are.equal("done", job:GetStatus())
    end)

    it("Yield always ends the frame", function()
        local steps = 0
        sched:Start("y", function(j)
            steps = steps + 1
            j:Yield()
            steps = steps + 1
            j:Yield()
            steps = steps + 1
        end)
        sched:Tick()
        assert.are.equal(1, steps)
        sched:Tick()
        assert.are.equal(2, steps)
        sched:Tick()
        assert.are.equal(3, steps)
        assert.is_true(sched:IsIdle())
    end)

    it("runs a job without checkpoints in one tick", function()
        local job = sched:Start("plain", function() return 1 end)
        sched:Tick()
        assert.are.equal("done", job:GetStatus())
    end)

    it("runs jobs in FIFO order and starts the next in the same tick", function()
        local log = {}
        local a = sched:Start("a", function(j)
            log[#log + 1] = "a1"
            j:Yield()
            log[#log + 1] = "a2"
        end)
        local b = sched:Start("b", function(j)
            log[#log + 1] = "b1"
            j:Yield()
            log[#log + 1] = "b2"
        end)
        local c = sched:Start("c", function() log[#log + 1] = "c" end)
        assert.are.equal("queued", b:GetStatus())
        sched:Tick()
        assert.are.same({ "a1" }, log)
        assert.are.equal("queued", b:GetStatus())
        sched:Tick()
        assert.are.same({ "a1", "a2", "b1" }, log)
        assert.are.equal("done", a:GetStatus())
        assert.are.equal("running", b:GetStatus())
        sched:Tick()
        assert.are.same({ "a1", "a2", "b1", "b2", "c" }, log)
        assert.are.equal("done", c:GetStatus())
    end)

    it("does not start the next job when the budget is used", function()
        sched:Start("a", function() now = now + 10 end)
        local b = sched:Start("b", function() end)
        sched:Tick()
        assert.are.equal("queued", b:GetStatus())
        sched:Tick()
        assert.are.equal("done", b:GetStatus())
    end)

    it("passes arguments to the job function", function()
        local got
        sched:Start("args", function(_, x, y) got = x + y end, 2, 3)
        sched:Tick()
        assert.are.equal(5, got)
    end)

    it("sends return values to OnDone", function()
        local job = sched:Start("r", function() return 1, nil, 3 end)
        local status, n, a, b, c
        job:OnDone(function(_, s, ...)
            status, n = s, select("#", ...)
            a, b, c = ...
        end)
        sched:Tick()
        assert.are.equal("done", status)
        assert.are.equal(3, n)
        assert.are.equal(1, a)
        assert.is_nil(b)
        assert.are.equal(3, c)
    end)

    it("calls OnDone at once for an ended job and permits two callbacks", function()
        local job = sched:Start("r", function() return "v" end)
        local calls = {}
        job:OnDone(function(_, s, v) calls[#calls + 1] = "1" .. s .. v end)
        job:OnDone(function(_, s, v) calls[#calls + 1] = "2" .. s .. v end)
        sched:Tick()
        assert.are.same({ "1donev", "2donev" }, calls)
        job:OnDone(function(_, s, v) calls[#calls + 1] = "3" .. s .. v end)
        assert.are.same({ "1donev", "2donev", "3donev" }, calls)
    end)

    it("fails a job, calls onError and runs the next job", function()
        local bad = sched:Start("bad", function() error("boom text") end)
        local ran = false
        sched:Start("good", function() ran = true end)
        local status, msg
        bad:OnDone(function(_, s, m) status, msg = s, m end)
        sched:Tick()
        assert.are.equal("failed", bad:GetStatus())
        assert.are.equal("failed", status)
        assert.is_truthy(msg:find("boom text", 1, true))
        assert.is_truthy(msg:find("traceback", 1, true))
        assert.are.equal(1, #errors)
        assert.are.equal(bad, errors[1].job)
        assert.is_truthy(errors[1].msg:find("boom text", 1, true))
        assert.is_true(ran)
    end)

    it("works without onError", function()
        local s = ns.Scheduler.New({ clock = function() return now end })
        local job = s:Start("bad", function() error("x") end)
        s:Tick()
        assert.are.equal("failed", job:GetStatus())
    end)

    it("sends a failing callback to onError", function()
        local job = sched:Start("j", function() end)
        job:OnDone(function() error("cb fail") end)
        local after = false
        job:OnDone(function() after = true end)
        sched:Tick()
        assert.are.equal("done", job:GetStatus())
        assert.is_true(after)
        assert.are.equal(1, #errors)
        assert.is_truthy(errors[1].msg:find("cb fail", 1, true))
    end)

    it("cancels a queued job", function()
        local ran = false
        sched:Start("a", function(j) j:Yield() end)
        local b = sched:Start("b", function() ran = true end)
        local status
        b:OnDone(function(_, s) status = s end)
        b:Cancel()
        assert.are.equal("cancelled", b:GetStatus())
        assert.are.equal("cancelled", status)
        assert.are.equal(1, sched:GetQueueLength())
        ticksUntilIdle(sched)
        assert.is_false(ran)
    end)

    it("cancels a suspended job and starts the next one", function()
        local after = false
        local resumed = false
        local a = sched:Start("a", function(j)
            j:Yield()
            resumed = true
        end)
        sched:Start("b", function() after = true end)
        local status, extra
        a:OnDone(function(_, s, ...) status, extra = s, select("#", ...) end)
        sched:Tick()
        a:Cancel()
        assert.are.equal("cancelled", status)
        assert.are.equal(0, extra)
        sched:Tick()
        assert.is_false(resumed)
        assert.is_true(after)
    end)

    it("stops a job that cancels itself", function()
        local after = {}
        local job = sched:Start("self", function(j)
            j:Checkpoint()
            j:Cancel()
            assert.is_true(j:IsCancelled())
            j:Checkpoint()
            after[#after + 1] = "continued"
        end)
        local status
        job:OnDone(function(_, s) status = s end)
        sched:Tick()
        assert.are.equal("cancelled", job:GetStatus())
        assert.are.equal("cancelled", status)
        assert.is_true(sched:IsIdle())
        sched:Tick()
        assert.are.same({}, after)
    end)

    it("lets a job that starts another job queue it at the end", function()
        local log = {}
        sched:Start("parent", function(j)
            log[#log + 1] = "parent"
            local child = sched:Start("child", function() log[#log + 1] = "child" end)
            assert.are.equal("queued", child:GetStatus())
            j:Yield()
            log[#log + 1] = "parent end"
        end)
        sched:Start("other", function() log[#log + 1] = "other" end)
        ticksUntilIdle(sched)
        assert.are.same({ "parent", "parent end", "other", "child" }, log)
    end)

    it("lets a callback start and cancel jobs", function()
        local log = {}
        local victim = sched:Start("victim", function() log[#log + 1] = "victim" end)
        local a = sched:Start("a", function() end)
        a:OnDone(function()
            victim:Cancel()
            sched:Start("fresh", function() log[#log + 1] = "fresh" end)
        end)
        local first = sched:Start("first", function() log[#log + 1] = "first" end)
        first:OnDone(function() log[#log + 1] = "first done" end)
        -- Order is victim, a, first. Cancel victim before the first tick.
        victim:Cancel()
        ticksUntilIdle(sched)
        assert.are.same({ "first", "first done", "fresh" }, log)
        assert.are.equal("cancelled", victim:GetStatus())
    end)

    it("reports idle state and queue length", function()
        assert.is_true(sched:IsIdle())
        assert.are.equal(0, sched:GetQueueLength())
        sched:Start("a", function(j) j:Yield() end)
        sched:Start("b", function() end)
        assert.is_false(sched:IsIdle())
        assert.are.equal(2, sched:GetQueueLength())
        sched:Tick()
        assert.are.equal(2, sched:GetQueueLength())
        sched:Tick()
        assert.are.equal(0, sched:GetQueueLength())
        assert.is_true(sched:IsIdle())
    end)

    it("changes limits with SetBudget", function()
        local job = sched:Start("rows", function(j)
            for _ = 1, 100 do j:Checkpoint() end
        end)
        sched:SetBudget(10, 25)
        assert.are.equal(5, ticksUntilIdle(sched))
        assert.are.equal("done", job:GetStatus())
    end)

    it("uses defaults for nil or 0 units and none for math.huge", function()
        local s = newScheduler({ unitsPerFrame = 0 })
        assert.are.equal(1000, s.unitsPerFrame)
        s:SetBudget(nil, nil)
        assert.are.equal(1000, s.unitsPerFrame)
        assert.are.equal(10, s.frameBudgetMs)
        s:SetBudget(5, math.huge)
        local job = s:Start("all", function(j)
            for _ = 1, 5000 do j:Checkpoint() end
        end)
        s:Tick()
        assert.are.equal("done", job:GetStatus())
    end)

    it("raises an error when Checkpoint or Yield run outside the coroutine", function()
        local job = sched:Start("x", function() end)
        assert.has_error(function() job:Checkpoint() end)
        assert.has_error(function() job:Yield() end)
    end)

    it("raises an error when a job uses another job's Checkpoint", function()
        local other
        sched:Start("mine", function() other:Checkpoint() end)
        other = sched:Start("other", function(j) j:Yield() end)
        sched:Tick()
        assert.are.equal(1, #errors)
    end)

    it("keeps two schedulers independent", function()
        local s2 = newScheduler({ unitsPerFrame = 10 })
        local a = sched:Start("a", function(j) j:Yield() end)
        local b = s2:Start("b", function(j) j:Yield() end)
        s2:Tick()
        assert.are.equal("queued", a:GetStatus())
        assert.are.equal("running", b:GetStatus())
        assert.are.equal(1, sched:GetQueueLength())
    end)

    it("uses a custom traceback function", function()
        local gotCo, gotMsg
        local s = newScheduler({ traceback = function(co, msg)
            gotCo, gotMsg = co, msg
            return msg .. " [custom trace]"
        end })
        local job = s:Start("bad", function() error("boom", 0) end)
        local status, msg
        job:OnDone(function(_, st, m) status, msg = st, m end)
        s:Tick()
        assert.are.equal("failed", status)
        assert.are.equal("boom [custom trace]", msg)
        assert.are.equal("boom", gotMsg)
        assert.are.equal("thread", type(gotCo))
        assert.are.equal("boom [custom trace]", errors[1].msg)
    end)

    it("uses the plain message when the traceback function fails", function()
        local s = newScheduler({ traceback = function() error("trace fail") end })
        local bad = s:Start("bad", function() error("boom", 0) end)
        local ran = false
        s:Start("good", function() ran = true end)
        s:Tick()
        assert.are.equal("failed", bad:GetStatus())
        assert.are.equal("boom", errors[1].msg)
        assert.is_true(ran)
    end)

    it("uses the plain message when the traceback result is not a string", function()
        local s = newScheduler({ traceback = function() return 5 end })
        s:Start("bad", function() error("boom", 0) end)
        s:Tick()
        assert.are.equal("boom", errors[1].msg)
    end)

    describe("without the debug library", function()
        it("handles a failing job and keeps running", function()
            local fresh = {}
            local savedDebug = _G.debug
            rawset(_G, "debug", nil)
            local loaded, err = pcall(assert(loadfile("Core/Scheduler.lua")), "Flipside", fresh)
            rawset(_G, "debug", savedDebug)
            assert(loaded, err)
            local s = fresh.Scheduler.New({ clock = function() return now end, onError = function(_, msg)
                errors[#errors + 1] = { msg = msg }
            end })
            local bad = s:Start("bad", function() error("no debug boom", 0) end)
            local ran = false
            s:Start("later", function() ran = true end)
            s:Tick()
            assert.are.equal("failed", bad:GetStatus())
            assert.are.equal("no debug boom", errors[1].msg)
            assert.is_true(ran)
            local again = false
            s:Start("third", function() again = true end)
            s:Tick()
            assert.is_true(again)
        end)
    end)end)
