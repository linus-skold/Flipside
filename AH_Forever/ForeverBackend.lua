local _, ns = ...

-- Forever auction backend: C_AuctionHouse (replicate scan and item keys).
-- Each call reads C_AuctionHouse at call time, as the client can change it.
local Backend = {}

local function ah()
    return C_AuctionHouse
end

-- Call a C_AuctionHouse function by name; a missing function gives a clear error.
local function call(name, ...)
    local api = ah()
    local fn = api and api[name]
    if type(fn) ~= "function" then
        error("C_AuctionHouse." .. name .. " is not available", 0)
    end
    return fn(...)
end

local function has(name)
    local api = ah()
    return api ~= nil and type(api[name]) == "function"
end

function Backend.CanScan()
    return has("ReplicateItems")
end

function Backend.StartScan()
    return call("ReplicateItems")
end

function Backend.ScanDoneEvent()
    return "REPLICATE_ITEM_LIST_UPDATE"
end

function Backend.RowCount()
    return call("GetNumReplicateItems")
end

-- Returns count, buyout, itemID, hasAllInfo of row i (0-based); no values for a missing row.
function Backend.ReadRow(i)
    local info = { call("GetReplicateItemInfo", i) }
    return info[3], info[10], info[17], info[18]
end

function Backend.RowLink(i)
    return call("GetReplicateItemLink", i)
end

-- Returns true if row i is a battle pet.
function Backend.RowIsPet(i)
    return call("GetReplicateItemBattlePetInfo", i) ~= nil
end

function Backend.HasCommodityCheck()
    return has("MakeItemKey") and has("GetItemKeyInfo")
end

-- Commodity flag of an item id; nil if the client does not know it.
function Backend.ItemIsCommodity(itemID)
    local info = call("GetItemKeyInfo", call("MakeItemKey", itemID))
    if type(info) == "table" and type(info.isCommodity) == "boolean" then
        return info.isCommodity
    end
    return nil
end

-- Name search: a browse query. The results event comes after the query.
function Backend.NameSearch(text)
    return call("SendBrowseQuery", { searchString = tostring(text or ""), sorts = {} })
end

function Backend.NameResultEvent()
    return "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"
end

function Backend.NameResults()
    return call("GetBrowseResults")
end

function Backend.NameItemKeyInfo(itemKey)
    return call("GetItemKeyInfo", itemKey)
end

-- Search result reads and events for the capture.
function Backend.Capture()
    local api = ah()
    if not api then
        return nil
    end
    return {
        api = {
            commodityNum = api.GetNumCommoditySearchResults,
            commodityInfo = api.GetCommoditySearchResultInfo,
            commodityFull = api.HasFullCommoditySearchResults,
            itemNum = api.GetNumItemSearchResults,
            itemInfo = api.GetItemSearchResultInfo,
            itemFull = api.HasFullItemSearchResults,
        },
        commodityEvent = "COMMODITY_SEARCH_RESULTS_UPDATED",
        itemEvent = "ITEM_SEARCH_RESULTS_UPDATED",
    }
end

function Backend.CanReadOwned()
    return has("GetOwnedAuctions")
end

function Backend.OwnedAuctions()
    return call("GetOwnedAuctions")
end

function Backend.OwnedEvent()
    return "OWNED_AUCTIONS_UPDATED"
end

function Backend.OpenEvent()
    return "AUCTION_HOUSE_SHOW"
end

function Backend.CloseEvent()
    return "AUCTION_HOUSE_CLOSED"
end

ns.AuctionClient.Use(Backend)
