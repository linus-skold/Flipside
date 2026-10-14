local _, ns = ...

local ScanItemLoad = {}
ns.ScanItemLoad = ScanItemLoad

local function noop() end

-- Count the items by state. Returns done, loaded set, missing set.
local function collect(cache, itemIDs)
    local loaded, missing = {}, {}
    local done = 0
    for itemID in pairs(itemIDs) do
        local state = cache:GetState(itemID)
        if state == "loaded" then
            loaded[itemID] = true
            done = done + 1
        else
            missing[itemID] = true
            if state == "failed" then
                done = done + 1
            end
        end
    end
    return done, loaded, missing
end

-- Run inside a scheduler job. Returns loaded, missing, timedOut; nil if cancelled.
function ScanItemLoad.Run(job, cache, itemIDs, options)
    options = options or {}
    local clock = options.clock
    if type(clock) ~= "function" then
        error("options.clock must be a function", 2)
    end
    local timeout = options.timeoutSeconds or ns.ScanClock.ITEM_LOAD_TIMEOUT_SECONDS
    local perCheckpoint = options.requestsPerCheckpoint or 1

    local total = 0
    for _ in pairs(itemIDs) do
        total = total + 1
    end
    if total == 0 then
        return {}, {}, false
    end

    local startTime = clock()
    for itemID in pairs(itemIDs) do
        cache:Request(itemID, noop)
        job:Checkpoint(perCheckpoint)
        if job:IsCancelled() then
            return nil
        end
    end

    while true do
        local done, loaded, missing = collect(cache, itemIDs)
        job:SetProgress(done, total)
        if done >= total then
            return loaded, missing, false
        end
        if clock() - startTime >= timeout then
            return loaded, missing, true
        end
        job:Yield()
        if job:IsCancelled() then
            return nil
        end
    end
end
