local _, ns = ...

-- Coroutine scheduler: runs queued jobs one at a time in slices of one frame each.
local Scheduler = {}
Scheduler.__index = Scheduler
ns.Scheduler = Scheduler

local Job = {}
Job.__index = Job

-- Provisional defaults; tune them after tests in the game.
local DEFAULT_FRAME_BUDGET_MS = 10
local DEFAULT_UNITS_PER_FRAME = 1000

local function removeFromQueue(queue, job)
    for i = 1, #queue do
        if queue[i] == job then
            table.remove(queue, i)
            return
        end
    end
end

local function reportError(scheduler, job, message)
    if scheduler.onError then
        pcall(scheduler.onError, job, message)
    end
end

local function runCallback(job, callback)
    local results = job.results
    local ok, err = pcall(callback, job, job.status, unpack(results, 1, results.n))
    if not ok then
        reportError(job.scheduler, job, err)
    end
end

-- Ends a job once: stores the result, leaves the queue, calls the callbacks.
local function finish(job, status, ...)
    if job.status == "done" or job.status == "failed" or job.status == "cancelled" then
        return
    end
    job.status = status
    job.results = { n = select("#", ...), ... }
    removeFromQueue(job.scheduler.queue, job)
    local callbacks = job.callbacks
    job.callbacks = {}
    for i = 1, #callbacks do
        runCallback(job, callbacks[i])
    end
end

local function afterResume(job, ok, ...)
    if not ok then
        local message = debug.traceback(job.co, tostring((...)))
        reportError(job.scheduler, job, message)
        finish(job, "failed", message)
    elseif coroutine.status(job.co) == "dead" then
        finish(job, "done", ...)
    end
end

local function frameBudgetLeft(scheduler)
    return scheduler.unitsUsed < scheduler.unitsPerFrame
        and scheduler.clock() - scheduler.frameStart < scheduler.frameBudgetMs
end

local function checkInsideJob(job, name)
    if coroutine.running() ~= job.co then
        error("Job:" .. name .. " must be called inside the job's own coroutine", 3)
    end
end

function Scheduler.New(options)
    options = options or {}
    assert(type(options.clock) == "function", "Scheduler.New: options.clock must be a function")
    local self = setmetatable({}, Scheduler)
    self.clock = options.clock
    self.onError = options.onError
    self.queue = {}
    self.frameStart = 0
    self.unitsUsed = 0
    self.ticking = false
    self:SetBudget(options.frameBudgetMs, options.unitsPerFrame)
    return self
end

-- A nil or 0 value selects the default; math.huge removes the unit limit.
function Scheduler:SetBudget(frameBudgetMs, unitsPerFrame)
    self.frameBudgetMs = frameBudgetMs or DEFAULT_FRAME_BUDGET_MS
    if unitsPerFrame == nil or unitsPerFrame == 0 then
        unitsPerFrame = DEFAULT_UNITS_PER_FRAME
    end
    self.unitsPerFrame = unitsPerFrame
end

function Scheduler:Start(name, fn, ...)
    local job = setmetatable({}, Job)
    job.scheduler = self
    job.name = name
    job.status = "queued"
    job.callbacks = {}
    job.results = { n = 0 }
    local args = { n = select("#", ...), ... }
    job.co = coroutine.create(function()
        return fn(job, unpack(args, 1, args.n))
    end)
    self.queue[#self.queue + 1] = job
    return job
end

-- Runs once per frame: resumes the first job until the frame ends.
function Scheduler:Tick()
    if self.ticking then
        return
    end
    self.ticking = true
    self.frameStart = self.clock()
    self.unitsUsed = 0
    local first = true
    while true do
        local job = self.queue[1]
        if not job or not (first or frameBudgetLeft(self)) then
            break
        end
        first = false
        job.status = "running"
        afterResume(job, coroutine.resume(job.co))
        if job.status == "running" then
            break
        end
    end
    self.ticking = false
end

function Scheduler:IsIdle()
    return #self.queue == 0
end

function Scheduler:GetQueueLength()
    return #self.queue
end

function Job:Checkpoint(units)
    checkInsideJob(self, "Checkpoint")
    local scheduler = self.scheduler
    scheduler.unitsUsed = scheduler.unitsUsed + (units or 1)
    if self.status == "cancelled" or not frameBudgetLeft(scheduler) then
        coroutine.yield()
    end
end

function Job:Yield()
    checkInsideJob(self, "Yield")
    coroutine.yield()
end

function Job:SetProgress(done, total)
    self.done = done
    self.total = total
end

function Job:GetProgress()
    return self.done, self.total
end

function Job:IsCancelled()
    return self.status == "cancelled"
end

function Job:Cancel()
    finish(self, "cancelled")
end

function Job:GetStatus()
    return self.status
end

function Job:OnDone(callback)
    local status = self.status
    if status == "done" or status == "failed" or status == "cancelled" then
        runCallback(self, callback)
    else
        self.callbacks[#self.callbacks + 1] = callback
    end
end
