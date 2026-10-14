local _, ns = ...

local ScanRows = {}
ns.ScanRows = ScanRows

local PROGRESS_EVERY = 1000

-- NOT verified in game: buyoutPrice is treated as the TOTAL for the auction.
-- If the client returns a price per unit, change this one function to return buyoutPrice.
local function UnitPriceFromBuyout(buyoutPrice, count)
    return buyoutPrice / count
end

local function IsPositiveInteger(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

local function RecordError(stats, err)
    if stats.firstError == nil then
        stats.firstError = tostring(err)
    end
end

local function CountKeys(map)
    local n = 0
    for _ in pairs(map) do
        n = n + 1
    end
    return n
end

-- Calls fn(index) in pcall. Returns ok, then the first two results.
local function Call(stats, fn, index)
    if type(fn) ~= "function" then
        return true
    end
    local ok, a, b = pcall(fn, index)
    if not ok then
        RecordError(stats, a)
        return false
    end
    return true, a, b
end

-- Reads all rows inside a job. Returns the result table, or nil if the job is cancelled.
function ScanRows.Read(job, api)
    local stats = {
        rows = 0, kept = 0, empty = 0, bidOnly = 0, pet = 0, badCount = 0,
        items = 0, pendingItems = 0,
    }
    local result = { byItem = {}, pending = {}, stats = stats }

    local okNum, n = pcall(api.getNum)
    if not okNum then
        RecordError(stats, n)
        n = 0
    end
    if type(n) ~= "number" then
        n = 0
    end
    stats.rows = n

    for index = 0, n - 1 do
        local done = index + 1
        if index % PROGRESS_EVERY == 0 and job:IsCancelled() then
            return nil
        end
        job:Checkpoint(1)

        -- readRow gives count, buyout, itemID, hasAllInfo. A getInfo api gives the raw client tuple.
        local info, count, buyout, itemID, hasAllInfo
        if api.readRow then
            info = { pcall(api.readRow, index) }
            count, buyout, itemID, hasAllInfo = info[2], info[3], info[4], info[5]
        else
            info = { pcall(api.getInfo, index) }
            count, buyout, itemID, hasAllInfo = info[4], info[11], info[18], info[19]
        end
        if not info[1] then
            RecordError(stats, info[2])
            stats.empty = stats.empty + 1
        elseif itemID == nil then
            stats.empty = stats.empty + 1
        elseif buyout == nil or buyout == 0 then
            stats.bidOnly = stats.bidOnly + 1
        else
            local okLink, link = Call(stats, api.getLink, index)
            local okPet, petName = Call(stats, api.getPetInfo, index)
            if not okLink or not okPet then
                stats.empty = stats.empty + 1
            elseif petName ~= nil or ns.ScanKey.IsBattlePet(link) then
                stats.pet = stats.pet + 1
            elseif not IsPositiveInteger(count) then
                stats.badCount = stats.badCount + 1
            else
                local list = result.byItem[itemID]
                if not list then
                    list = {}
                    result.byItem[itemID] = list
                end
                list[#list + 1] = {
                    index = index,
                    unitPrice = UnitPriceFromBuyout(buyout, count),
                    count = count,
                    link = link or nil,
                }
                stats.kept = stats.kept + 1
                if hasAllInfo ~= true or link == nil then
                    result.pending[itemID] = true
                end
            end
        end

        if done % PROGRESS_EVERY == 0 then
            job:SetProgress(done, n)
        end
    end

    if n % PROGRESS_EVERY ~= 0 or n == 0 then
        job:SetProgress(n, n)
    end
    stats.items = CountKeys(result.byItem)
    stats.pendingItems = CountKeys(result.pending)
    return result
end

-- Returns an empty result, the same shape as ScanRows.Read gives.
function ScanRows.NewResult()
    return {
        byItem = {}, pending = {},
        stats = {
            rows = 0, kept = 0, empty = 0, bidOnly = 0, pet = 0, badCount = 0,
            items = 0, pendingItems = 0,
        },
    }
end

-- Adds the rows and the counts of one page result to the total result.
function ScanRows.Merge(into, page)
    for itemID, list in pairs(page.byItem) do
        local target = into.byItem[itemID]
        if target then
            for _, row in ipairs(list) do
                target[#target + 1] = row
            end
        else
            into.byItem[itemID] = list
        end
    end
    for itemID in pairs(page.pending) do
        into.pending[itemID] = true
    end
    for name, value in pairs(page.stats) do
        if type(value) == "number" then
            into.stats[name] = (into.stats[name] or 0) + value
        elseif into.stats[name] == nil then
            into.stats[name] = value
        end
    end
    into.stats.items = CountKeys(into.byItem)
    into.stats.pendingItems = CountKeys(into.pending)
end

-- Reads the links again for the given item ids. Removes pets and clears pending.
-- If onlyMissing is true, it reads only the rows that have no link.
function ScanRows.RereadLinks(job, api, result, itemIDs, onlyMissing)
    local stats = result.stats
    for _, itemID in ipairs(itemIDs) do
        local list = result.byItem[itemID]
        if list then
            local kept = {}
            local allLinked = true
            for _, row in ipairs(list) do
                job:Checkpoint(1)
                if not (onlyMissing and row.link ~= nil) then
                    local ok, link = Call(stats, api.getLink, row.index)
                    if ok and link ~= nil then
                        row.link = link
                    end
                end
                if ns.ScanKey.IsBattlePet(row.link) then
                    stats.pet = stats.pet + 1
                    stats.kept = stats.kept - 1
                else
                    kept[#kept + 1] = row
                    if row.link == nil then
                        allLinked = false
                    end
                end
            end
            if #kept == 0 then
                result.byItem[itemID] = nil
                result.pending[itemID] = nil
            else
                result.byItem[itemID] = kept
                if allLinked then
                    result.pending[itemID] = nil
                end
            end
        else
            result.pending[itemID] = nil
        end
    end
    stats.items = CountKeys(result.byItem)
    stats.pendingItems = CountKeys(result.pending)
end
