local manifest = require("Tests.manifest")

describe("GuildSyncQueue", function()
    local Queue, clock, timers, sent, results, dropped, queue

    before_each(function()
        local ns = {}
        assert(loadfile(manifest.path("GuildSyncQueue")))("Flipside", ns)
        Queue = ns.GuildSyncQueue
        clock, timers, sent, results, dropped = 0, {}, {}, {}, {}
        queue = Queue.New({
            send = function(text)
                local result = table.remove(results, 1)
                if result == nil or result == 0 then
                    sent[#sent + 1] = text
                end
                return result
            end,
            after = function(seconds, fn)
                timers[#timers + 1] = { at = clock + seconds, fn = fn }
            end,
            clock = function()
                return clock
            end,
            rate = 1,
            burst = 3,
            onDrop = function(text, reason, result)
                dropped[#dropped + 1] = { text, reason, result }
            end,
        })
    end)

    -- Move the clock forward and run the timers that are due.
    local function advance(seconds)
        clock = clock + seconds
        local due, rest = {}, {}
        for _, t in ipairs(timers) do
            table.insert(t.at <= clock and due or rest, t)
        end
        timers = rest
        for _, t in ipairs(due) do
            t.fn()
        end
    end

    it("removes waiting messages with RemoveIf and keeps the others", function()
        for i = 1, 6 do
            queue:Push("m" .. i)
        end
        local removed = queue:RemoveIf(function(text)
            return text == "m4" or text == "m6"
        end)
        assert.are.equal(2, removed)
        assert.are.equal(1, queue:Pending())
        advance(5)
        assert.are.same({ "m1", "m2", "m3", "m5" }, sent)
    end)

    it("sends an urgent message before the waiting ones", function()
        for i = 1, 5 do
            queue:Push("m" .. i)
        end
        queue:Push("urgent", true)
        advance(1)
        assert.are.same({ "m1", "m2", "m3", "urgent" }, sent)
    end)

    it("keeps the message that waits for a retry in front of an urgent message", function()
        results = { 3 }
        queue:Push("m1")
        assert.is_true(queue:Waiting())
        queue:Push("urgent", true)
        advance(5)
        assert.are.same({ "m1", "urgent" }, sent)
        assert.is_false(queue:Waiting())
    end)

    it("tells if a text waits in the queue", function()
        for i = 1, 4 do
            queue:Push("m" .. i)
        end
        assert.is_false(queue:Has("m1"))
        assert.is_true(queue:Has("m4"))
    end)

    it("calls onSpace before each step so the owner can add messages", function()
        local extra = { "x1", "x2", "x3", "x4" }
        queue.onSpace = function()
            if queue:Pending() < 2 and #extra > 0 then
                queue:Push(table.remove(extra, 1))
            end
        end
        queue:Push("m1")
        assert.are.same({ "m1", "x1", "x2" }, sent)
        advance(1)
        assert.are.same({ "m1", "x1", "x2", "x3" }, sent)
        advance(1)
        assert.are.same({ "m1", "x1", "x2", "x3", "x4" }, sent)
        assert.are.equal(0, queue:Pending())
    end)

    it("sends a burst at once, then one message each second", function()
        for i = 1, 6 do
            queue:Push("m" .. i)
        end
        assert.are.equal(3, #sent)
        assert.are.equal(3, queue:Pending())
        advance(0.5)
        assert.are.equal(3, #sent)
        advance(0.5)
        assert.are.equal(4, #sent)
        advance(1)
        assert.are.equal(5, #sent)
        advance(1)
        assert.are.equal(6, #sent)
        assert.are.same({ "m1", "m2", "m3", "m4", "m5", "m6" }, sent)
        assert.are.equal(0, queue:Pending())
    end)

    it("never sends more than the rate allows over a long run", function()
        for i = 1, 20 do
            queue:Push("m" .. i)
        end
        for _ = 1, 10 do
            advance(1)
        end
        assert.is_true(#sent <= 3 + 10)
        assert.are.equal(13, #sent)
    end)

    it("waits and tries again when the client throttles a message", function()
        results = { 3 }
        queue:Push("a")
        queue:Push("b")
        assert.are.equal(0, #sent)
        assert.are.equal(2, queue:Pending())
        advance(Queue.RETRY_SECONDS - 1)
        assert.are.equal(0, #sent)
        advance(1)
        assert.are.same({ "a", "b" }, sent)
    end)

    it("waits longer after each refusal", function()
        results = { 3, 8 }
        queue:Push("a")
        advance(Queue.RETRY_SECONDS)
        assert.are.equal(0, #sent)
        advance(Queue.RETRY_SECONDS * 2 - 1)
        assert.are.equal(0, #sent)
        advance(1)
        assert.are.same({ "a" }, sent)
    end)

    it("drops a message after too many refusals", function()
        for _ = 1, Queue.MAX_TRIES do
            results[#results + 1] = 3
        end
        queue:Push("a")
        queue:Push("b")
        for _ = 1, Queue.MAX_TRIES do
            advance(Queue.MAX_RETRY_SECONDS)
        end
        assert.are.same({ "b" }, sent)
        assert.are.same({ { "a", "retries", 3 } }, dropped)
    end)

    it("drops a message that the client refuses for another reason and goes on", function()
        results = { 2 }
        queue:Push("a")
        queue:Push("b")
        assert.are.same({ "b" }, sent)
        assert.are.same({ { "a", "refused", 2 } }, dropped)
    end)

    it("clears the waiting messages and the timer", function()
        results = { 3 }
        queue:Push("a")
        queue:Clear()
        assert.are.equal(0, queue:Pending())
        advance(100)
        assert.are.equal(0, #sent)
    end)

    it("refuses a message when the queue is full", function()
        results = { 3 }
        queue:Push("first")
        for i = 1, Queue.MAX_LENGTH - 1 do
            assert.is_true(queue:Push("m" .. i))
        end
        assert.is_false(queue:Push("one too many"))
        assert.are.same({ { "one too many", "full" } }, dropped)
    end)
end)
