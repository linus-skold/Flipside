local _, ns = ...

-- Send queue with its own rate limit (D18: no library). It sends at most `rate` messages each second,
-- with a burst of `burst` messages. If the client refuses a message for a throttle reason, the queue waits
-- and tries the same message again, with a longer wait each time.

local Queue = {}
ns.GuildSyncQueue = Queue

-- Values of Enum.SendAddonMessageResult (Forever and TBC Anniversary client source, ChatConstantsDocumentation).
Queue.RESULT = {
    Success = 0,
    AddonMessageThrottle = 3,
    ChannelThrottle = 8,
    AddOnMessageLockdown = 11,
}

Queue.RATE = 1
Queue.BURST = 4
Queue.RETRY_SECONDS = 5
Queue.MAX_RETRY_SECONDS = 60
Queue.MAX_TRIES = 6
Queue.MAX_LENGTH = 300

local RETRY = {
    [Queue.RESULT.AddonMessageThrottle] = true,
    [Queue.RESULT.ChannelThrottle] = true,
    [Queue.RESULT.AddOnMessageLockdown] = true,
}

local Q = {}
Q.__index = Q

-- options: send(text) -> result code, after(seconds, fn), clock() -> seconds (fractions allowed), rate, burst,
-- onSent(text), onDrop(text, reason, result). A nil, true or 0 result from send means success.
function Queue.New(options)
    return setmetatable({
        send = options.send,
        after = options.after,
        clock = options.clock,
        rate = options.rate or Queue.RATE,
        burst = options.burst or Queue.BURST,
        onSent = options.onSent,
        onDrop = options.onDrop,
        items = {},
        tokens = options.burst or Queue.BURST,
        last = options.clock(),
        tries = 0,
        scheduled = false,
        generation = 0,
    }, Q)
end

function Q:Pending()
    return #self.items
end

-- Remove all waiting messages.
function Q:Clear()
    self.items = {}
    self.tries = 0
    self.generation = self.generation + 1
    self.scheduled = false
end

-- Add a message to the end of the queue. Return false when the queue is full.
function Q:Push(text)
    if #self.items >= Queue.MAX_LENGTH then
        if self.onDrop then
            self.onDrop(text, "full")
        end
        return false
    end
    self.items[#self.items + 1] = text
    self:_Pump()
    return true
end

function Q:_Refill()
    local now = self.clock()
    self.tokens = math.min(self.burst, self.tokens + (now - self.last) * self.rate)
    self.last = now
end

function Q:_Wake(seconds)
    if self.scheduled then
        return
    end
    self.scheduled = true
    local generation = self.generation
    self.after(seconds, function()
        if generation ~= self.generation then
            return
        end
        self.scheduled = false
        self:_Pump()
    end)
end

function Q:_Pump()
    if self.scheduled then
        return
    end
    self:_Refill()
    while #self.items > 0 do
        if self.tokens < 1 then
            self:_Wake((1 - self.tokens) / self.rate)
            return
        end
        local text = self.items[1]
        local result = self.send(text)
        if result == nil or result == true or result == Queue.RESULT.Success then
            table.remove(self.items, 1)
            self.tokens = self.tokens - 1
            self.tries = 0
            if self.onSent then
                self.onSent(text)
            end
        elseif RETRY[result] and self.tries + 1 < Queue.MAX_TRIES then
            self.tries = self.tries + 1
            self:_Wake(math.min(Queue.MAX_RETRY_SECONDS, Queue.RETRY_SECONDS * 2 ^ (self.tries - 1)))
            return
        else
            table.remove(self.items, 1)
            self.tries = 0
            if self.onDrop then
                self.onDrop(text, RETRY[result] and "retries" or "refused", result)
            end
        end
    end
end
