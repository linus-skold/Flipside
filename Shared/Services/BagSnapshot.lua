local _, ns = ...

-- A cache for the container reads of the client. The inventory capture, the auto rules and the mailing view read the
-- bags after the same BAG_UPDATE_DELAYED burst. They read through one snapshot, so the client is called once for each
-- bag and slot in a burst. The cache is empty again after BAG_UPDATE_DELAYED or ITEM_LOCK_CHANGED.
local BagSnapshot = {}
ns.BagSnapshot = BagSnapshot

local OWNER = "Flipside.BagSnapshot"
BagSnapshot.EVENTS = { "BAG_UPDATE_DELAYED", "ITEM_LOCK_CHANGED" }

-- api: { numSlots(bag), itemInfo(bag, slot) }. bus is optional: with it, the cache clears on the events above.
-- Returns { numSlots, itemInfo, Invalidate, calls } where numSlots and itemInfo have the signature of the api.
-- calls is the count of client calls so far.
function BagSnapshot.New(api, bus)
    local snapshot = { calls = 0 }
    local counts, infos = {}, {}

    function snapshot.Invalidate()
        counts, infos = {}, {}
    end

    function snapshot.numSlots(bag)
        local count = counts[bag]
        if count == nil then
            count = api.numSlots(bag) or 0
            snapshot.calls = snapshot.calls + 1
            counts[bag] = count
        end
        return count
    end

    function snapshot.itemInfo(bag, slot)
        local bagInfos = infos[bag]
        if not bagInfos then
            bagInfos = {}
            infos[bag] = bagInfos
        end
        local info = bagInfos[slot]
        if info == nil then
            info = api.itemInfo(bag, slot) or false
            snapshot.calls = snapshot.calls + 1
            bagInfos[slot] = info
        end
        return info or nil
    end

    if bus then
        for _, event in ipairs(BagSnapshot.EVENTS) do
            bus:Subscribe(event, OWNER, snapshot.Invalidate)
        end
    end
    return snapshot
end
