local _, ns = ...

local EventBus = {}
ns.EventBus = EventBus

local Bus = {}
Bus.__index = Bus

-- Create a new, independent bus.
function EventBus.New(options)
    options = options or {}
    local self = setmetatable({}, Bus)
    self.entries = {}
    self.onError = options.onError
    self.onEmit = options.onEmit
    self.onFirstSubscriber = options.onFirstSubscriber
    self.onLastUnsubscribed = options.onLastUnsubscribed
    -- Handler timing (SPEC 7.5): clock() gives milliseconds. Without a clock, no handler is timed. A handler that
    -- takes slowMs or more calls onSlow(event, ownerName, ms).
    self.clock = type(options.clock) == "function" and options.clock or nil
    self.slowMs = options.slowMs or EventBus.SLOW_MS
    self.onSlow = options.onSlow
    return self
end

-- The default limit of the handler timing, in milliseconds.
EventBus.SLOW_MS = 25

-- A readable name of an owner for the log: a string is its own name, a table can have the field ownerName.
function EventBus.OwnerName(owner)
    if type(owner) == "string" then
        return owner
    end
    if type(owner) == "table" and type(owner.ownerName) == "string" then
        return owner.ownerName
    end
    return tostring(owner)
end

-- Set or clear the function that receives handler failures.
function Bus:SetErrorHandler(fn)
    if fn ~= nil and type(fn) ~= "function" then
        error("SetErrorHandler: fn must be a function or nil", 2)
    end
    self.onError = fn
end

-- Add a handler, or replace the handler of the same (event, owner) pair.
function Bus:Subscribe(event, owner, handler)
    if type(event) ~= "string" or event == "" then
        error("Subscribe: event must be a non-empty string", 2)
    end
    if owner == nil then
        error("Subscribe: owner must not be nil", 2)
    end
    if type(handler) ~= "function" then
        error("Subscribe: handler must be a function", 2)
    end
    local list = self.entries[event]
    if not list then
        list = {}
        self.entries[event] = list
    end
    for i = 1, #list do
        if list[i].owner == owner then
            list[i].handler = handler
            return
        end
    end
    list[#list + 1] = { owner = owner, handler = handler, active = true }
    if #list == 1 and self.onFirstSubscriber then
        self.onFirstSubscriber(event)
    end
end

-- Remove one entry from an event list and fire the last-unsubscribed hook.
local function removeAt(self, event, list, index)
    list[index].active = false
    table.remove(list, index)
    if #list == 0 then
        self.entries[event] = nil
        if self.onLastUnsubscribed then
            self.onLastUnsubscribed(event)
        end
    end
end

-- Remove the handler of one (event, owner) pair.
function Bus:Unsubscribe(event, owner)
    local list = self.entries[event]
    if not list then
        return
    end
    for i = 1, #list do
        if list[i].owner == owner then
            removeAt(self, event, list, i)
            return
        end
    end
end

-- Remove all handlers of an owner.
function Bus:UnsubscribeAll(owner)
    local events = {}
    for event in pairs(self.entries) do
        events[#events + 1] = event
    end
    for _, event in ipairs(events) do
        self:Unsubscribe(event, owner)
    end
end

-- Return true if the event has at least one handler.
function Bus:HasSubscribers(event)
    return self.entries[event] ~= nil
end

-- Call the handlers of an event in order, with all arguments unchanged.
function Bus:Emit(event, ...)
    local list = self.entries[event]
    if not list then
        return
    end
    local snapshot = {}
    for i = 1, #list do
        snapshot[i] = list[i]
    end
    local count = select("#", ...)
    local args = { ... }
    if self.onEmit then
        pcall(self.onEmit, event, ...)
    end
    local stack
    local function keepStack(err)
        stack = type(debugstack) == "function" and debugstack(3, 6, 0) or nil
        return err
    end
    local entry
    local function run()
        return entry.handler(event, unpack(args, 1, count))
    end
    local clock = self.clock
    for i = 1, #snapshot do
        entry = snapshot[i]
        if entry.active then
            stack = nil
            local started = clock and clock()
            local ok, err = xpcall(run, keepStack)
            if not ok and self.onError then
                pcall(self.onError, event, entry.owner, err, stack)
            end
            if started and self.onSlow then
                local elapsed = clock() - started
                if elapsed >= self.slowMs then
                    pcall(self.onSlow, event, EventBus.OwnerName(entry.owner), elapsed)
                end
            end
        end
    end
end
