local ns = {}
assert(loadfile("Core/ItemInfoCache.lua"))("Flipside", ns)
assert(loadfile("Services/ScanClock.lua"))("Flipside", ns)
assert(loadfile("Services/ScanItemLoad.lua"))("Flipside", ns)
local ScanItemLoad = ns.ScanItemLoad

-- World: fake client data, cache, clock and job.
-- onYield(world, frameNumber) runs at each Yield; the clock moves 1 s per frame.
local function MakeWorld(onYield)
    local w = { now = 0, frames = 0, known = {}, requested = {}, checkpoints = {}, progress = {} }
    w.cache = ns.ItemInfoCache.New({
        getInfo = function(id)
            if w.known[id] then
                return { name = "Item" .. id, link = "item:" .. id }
            end
        end,
        requestLoad = function(id)
            w.requested[#w.requested + 1] = id
        end,
    })
    w.clock = function() return w.now end
    w.cancelled = false
    w.job = {
        Yield = function()
            w.frames = w.frames + 1
            w.now = w.now + 1
            if onYield then
                onYield(w, w.frames)
            end
        end,
        Checkpoint = function(_, units)
            w.checkpoints[#w.checkpoints + 1] = units
        end,
        IsCancelled = function() return w.cancelled end,
        SetProgress = function(_, done, total)
            w.progress[#w.progress + 1] = { done, total }
        end,
    }
    return w
end

local function Load(w, id)
    w.known[id] = true
    w.cache:OnLoadResult(id, true)
end

local function Count(set)
    local n = 0
    for _ in pairs(set) do
        n = n + 1
    end
    return n
end

describe("ScanItemLoad.Run", function()
    it("returns empty sets at once for an empty set", function()
        local w = MakeWorld()
        local loaded, missing, timedOut = ScanItemLoad.Run(w.job, w.cache, {}, { clock = w.clock })
        assert.are.equal(0, Count(loaded))
        assert.are.equal(0, Count(missing))
        assert.is_false(timedOut)
        assert.are.equal(0, w.frames)
    end)

    it("needs a clock", function()
        local w = MakeWorld()
        assert.has_error(function()
            ScanItemLoad.Run(w.job, w.cache, { [1] = true }, {})
        end)
    end)

    it("does not wait when all items are loaded", function()
        local w = MakeWorld()
        w.known[1], w.known[2] = true, true
        local loaded, missing, timedOut = ScanItemLoad.Run(w.job, w.cache, { [1] = true, [2] = true },
            { clock = w.clock })
        assert.is_true(loaded[1] and loaded[2])
        assert.are.equal(0, Count(missing))
        assert.is_false(timedOut)
        assert.are.equal(0, w.frames)
        assert.are.equal(0, #w.requested)
    end)

    it("loads items over three frames", function()
        local w = MakeWorld(function(world, frame)
            Load(world, frame)
        end)
        local loaded, missing, timedOut = ScanItemLoad.Run(w.job, w.cache, { [1] = true, [2] = true, [3] = true },
            { clock = w.clock })
        assert.are.equal(3, Count(loaded))
        assert.are.equal(0, Count(missing))
        assert.is_false(timedOut)
        assert.are.equal(3, w.frames)
    end)

    it("reports a failed item as missing without timeout", function()
        local w = MakeWorld(function(world)
            Load(world, 1)
            world.cache:OnLoadResult(2, false)
        end)
        local loaded, missing, timedOut = ScanItemLoad.Run(w.job, w.cache, { [1] = true, [2] = true },
            { clock = w.clock })
        assert.is_true(loaded[1])
        assert.is_nil(loaded[2])
        assert.is_true(missing[2])
        assert.is_false(timedOut)
        assert.are.equal(1, w.frames)
    end)

    it("times out after 30 s when an item never answers", function()
        local w = MakeWorld(function(world)
            Load(world, 1)
        end)
        local loaded, missing, timedOut = ScanItemLoad.Run(w.job, w.cache, { [1] = true, [2] = true },
            { clock = w.clock })
        assert.is_true(loaded[1])
        assert.is_true(missing[2])
        assert.is_true(timedOut)
        assert.are.equal(30, w.frames)
        assert.are.equal("requested", w.cache:GetState(2))
    end)

    it("uses a custom timeout", function()
        local w = MakeWorld()
        local _, missing, timedOut = ScanItemLoad.Run(w.job, w.cache, { [5] = true },
            { clock = w.clock, timeoutSeconds = 5 })
        assert.is_true(missing[5])
        assert.is_true(timedOut)
        assert.are.equal(5, w.frames)
    end)

    it("measures the timeout from the first request", function()
        local w = MakeWorld()
        w.now = 1000
        local _, _, timedOut = ScanItemLoad.Run(w.job, w.cache, { [5] = true },
            { clock = w.clock, timeoutSeconds = 3 })
        assert.is_true(timedOut)
        assert.are.equal(3, w.frames)
    end)

    it("returns nil when cancelled during the wait", function()
        local w = MakeWorld(function(world, frame)
            if frame == 2 then
                world.cancelled = true
            end
        end)
        local loaded, missing, timedOut = ScanItemLoad.Run(w.job, w.cache, { [1] = true }, { clock = w.clock })
        assert.is_nil(loaded)
        assert.is_nil(missing)
        assert.is_nil(timedOut)
        assert.are.equal(2, w.frames)
    end)

    it("returns nil when cancelled during the requests", function()
        local w = MakeWorld()
        w.cancelled = true
        local loaded = ScanItemLoad.Run(w.job, w.cache, { [1] = true, [2] = true }, { clock = w.clock })
        assert.is_nil(loaded)
        assert.are.equal(1, #w.requested)
    end)

    it("spreads requests with a checkpoint after each request", function()
        local w = MakeWorld()
        w.known[1], w.known[2], w.known[3] = true, true, true
        ScanItemLoad.Run(w.job, w.cache, { [1] = true, [2] = true, [3] = true },
            { clock = w.clock, requestsPerCheckpoint = 2 })
        assert.are.same({ 2, 2, 2 }, w.checkpoints)
    end)

    it("uses one unit per checkpoint by default", function()
        local w = MakeWorld()
        w.known[1] = true
        ScanItemLoad.Run(w.job, w.cache, { [1] = true }, { clock = w.clock })
        assert.are.same({ 1 }, w.checkpoints)
    end)

    it("updates progress while it waits", function()
        local w = MakeWorld(function(world, frame)
            Load(world, frame)
        end)
        ScanItemLoad.Run(w.job, w.cache, { [1] = true, [2] = true, [3] = true }, { clock = w.clock })
        assert.are.same({ { 0, 3 }, { 1, 3 }, { 2, 3 }, { 3, 3 } }, w.progress)
    end)
end)
