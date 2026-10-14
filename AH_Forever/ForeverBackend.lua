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

function Backend.CanTargetSearch()
    return has("SendSearchQuery") and has("MakeItemKey")
end

-- Search the listings of one item by item key; the capture events carry the result.
function Backend.TargetedSearch(itemID)
    return call("SendSearchQuery", call("MakeItemKey", itemID), {}, true)
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

-- Live search (Buying tab). Doc: AuctionHouseDocumentation.lua.
local SEARCH_LIMIT = 100 -- SendSearchQuery: 100 calls per minute (doc line 1018)
local SEARCH_WINDOW = 60
local searchTimes = {}

function Backend.CanLiveSearch()
    return has("SendSearchQuery") and has("MakeItemKey") and has("GetItemKeyInfo")
end

-- One targeted search for an item key (doc 1015-1028). Gives true, or false and a text if the rate guard stops it.
function Backend.LiveSearch(itemID)
    local now = GetTime()
    local kept = {}
    for _, t in ipairs(searchTimes) do
        if now - t < SEARCH_WINDOW then
            kept[#kept + 1] = t
        end
    end
    searchTimes = kept
    if #searchTimes >= SEARCH_LIMIT then
        return false, "search limit, wait"
    end
    searchTimes[#searchTimes + 1] = now
    call("SendSearchQuery", call("MakeItemKey", itemID), {}, true)
    return true
end

-- Result events: COMMODITY_SEARCH_RESULTS_UPDATED (doc 1397-1405), ITEM_SEARCH_RESULTS_UPDATED (doc 1447-1456).
function Backend.LiveResultEvents()
    return "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED"
end

local function byPrice(a, b)
    if a.unitPrice ~= b.unitPrice then
        return a.unitPrice < b.unitPrice
    end
    return (a.auctionID or 0) < (b.auctionID or 0)
end

-- Rows of the last search of an item, cheapest unit price first. Commodity: GetNumCommoditySearchResults (doc 488)
-- and GetCommoditySearchResultInfo (doc 240). Item: GetNumItemSearchResults (doc 503) and GetItemSearchResultInfo
-- (doc 358); a row with no buyout is skipped and the unit price is buyoutAmount / quantity.
function Backend.LiveRows(itemID)
    local rows = {}
    local isCommodity = Backend.ItemIsCommodity(itemID)
    if isCommodity then
        for i = 1, call("GetNumCommoditySearchResults", itemID) do
            local r = call("GetCommoditySearchResultInfo", itemID, i)
            if r and r.unitPrice and (r.quantity or 0) > 0 then
                rows[#rows + 1] = {
                    auctionID = r.auctionID, unitPrice = r.unitPrice, quantity = r.quantity, isCommodity = true,
                    ownerItem = r.containsOwnerItem == true, timeLeft = r.timeLeftSeconds,
                }
            end
        end
    else
        local key = call("MakeItemKey", itemID)
        for i = 1, call("GetNumItemSearchResults", key) do
            local r = call("GetItemSearchResultInfo", key, i)
            local buyout, quantity = r and r.buyoutAmount, r and r.quantity
            if buyout and buyout > 0 and quantity and quantity > 0 then
                rows[#rows + 1] = {
                    auctionID = r.auctionID, unitPrice = buyout / quantity, quantity = quantity, buyout = buyout,
                    isCommodity = false, ownerItem = r.containsOwnerItem == true,
                    timeLeft = r.timeLeftSeconds or r.timeLeft, itemLink = r.itemLink,
                }
            end
        end
    end
    table.sort(rows, byPrice)
    return rows
end

-- Doc 809-816: true when the client can send a throttled message.
function Backend.IsReady()
    return call("IsThrottledMessageSystemReady")
end

-- Doc 1291-1296.
function Backend.ReadyEvent()
    return "AUCTION_HOUSE_THROTTLED_SYSTEM_READY"
end

-- Ask for a fresh owned list (doc 898; argument: sorts table). OWNED_AUCTIONS_UPDATED follows.
function Backend.RefreshOwned()
    return call("QueryOwnedAuctions", {})
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

-- Buy block (Buying tab). Doc: AuctionHouseDocumentation.lua.
-- Start, Confirm and BuyItem are protected: the caller runs them in a click. Cancel is not protected.
function Backend.CanBuy()
    return has("StartCommoditiesPurchase") and has("ConfirmCommoditiesPurchase") and has("PlaceBid")
end

-- Ask for a quote (doc 1063-1073). COMMODITY_PRICE_UPDATED(unitPrice, totalPrice) follows (doc 1346-1356).
function Backend.StartCommodityPurchase(itemID, quantity)
    return call("StartCommoditiesPurchase", itemID, quantity)
end

-- Buy at the quote (doc 83-92). COMMODITY_PURCHASE_SUCCEEDED or COMMODITY_PURCHASE_FAILED follows (doc 1357-1368).
function Backend.ConfirmCommodityPurchase(itemID, quantity)
    return call("ConfirmCommoditiesPurchase", itemID, quantity)
end

-- Drop the quote (doc 71-73).
function Backend.CancelCommodityPurchase()
    return call("CancelCommoditiesPurchase")
end

-- Seconds left of the quote (doc 584-591); 0 means the quote ended.
function Backend.QuoteSecondsLeft()
    return call("GetQuoteDurationRemaining")
end

-- Buy one item auction at the buyout price (doc 836-846). Blizzard's own call is the same, after its pop-up
-- BUYOUT_AUCTION (Blizzard_AuctionHouseFrame.lua 10-12). AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID) (doc 1203-1211)
-- or AUCTION_HOUSE_SHOW_ERROR(error) (doc 1236-1244) follows.
function Backend.BuyItemAuction(auctionID, buyout)
    return call("PlaceBid", auctionID, buyout)
end

function Backend.BuyEvents()
    return {
        priceUpdated = "COMMODITY_PRICE_UPDATED",
        priceUnavailable = "COMMODITY_PRICE_UNAVAILABLE",
        commoditySucceeded = "COMMODITY_PURCHASE_SUCCEEDED",
        commodityFailed = "COMMODITY_PURCHASE_FAILED",
        itemCompleted = "AUCTION_HOUSE_PURCHASE_COMPLETED",
        itemError = "AUCTION_HOUSE_SHOW_ERROR",
    }
end
ns.AuctionClient.Use(Backend)
