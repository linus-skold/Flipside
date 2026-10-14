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
                    auctionID = r.auctionID, unitPrice = buyout / quantity, quantity = quantity,
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

-- Posting (Selling tab). Doc: AuctionHouseDocumentation.lua. PostItem and PostCommodity are protected.
-- The duration argument is a luaIndex. The SellFrame menu lists AUCTION_DURATION_ONE, TWO and THREE as index 1, 2, 3.
-- The mapping 12 h = 1, 24 h = 2, 48 h = 3 is NOT verified: the hour text of those strings is not in the source.
local DURATION_INDEX = { [12] = 1, [24] = 2, [48] = 3 }

local function durationIndex(hours)
    local index = DURATION_INDEX[hours]
    if not index then
        error("duration must be 12, 24 or 48 hours", 0)
    end
    return index
end

-- ItemLocation of a bag slot (Blizzard_ObjectAPI ItemLocation.lua line 9).
local function location(bag, slot)
    return ItemLocation:CreateFromBagAndSlot(bag, slot)
end

function Backend.CanPost()
    return type(ItemLocation) == "table" and type(ItemLocation.CreateFromBagAndSlot) == "function"
        and has("PostItem") and has("PostCommodity") and has("ConfirmPostItem") and has("ConfirmPostCommodity")
        and has("CalculateItemDeposit") and has("CalculateCommodityDeposit") and has("GetAvailablePostCount")
end

-- PostItem (doc 867-885). Gives needsConfirmation. Protected: call it from a click only.
function Backend.PostItem(bag, slot, duration, quantity, bid, buyout)
    return call("PostItem", location(bag, slot), durationIndex(duration), quantity, bid, buyout)
end

-- PostCommodity (doc 848-865). Gives needsConfirmation. Protected: call it from a click only.
function Backend.PostCommodity(bag, slot, duration, quantity, unitPrice)
    return call("PostCommodity", location(bag, slot), durationIndex(duration), quantity, unitPrice)
end

-- ConfirmPostItem (doc 108-121). Protected: call it from a click only.
function Backend.ConfirmPostItem(bag, slot, duration, quantity, bid, buyout)
    return call("ConfirmPostItem", location(bag, slot), durationIndex(duration), quantity, bid, buyout)
end

-- ConfirmPostCommodity (doc 94-106). Protected: call it from a click only.
function Backend.ConfirmPostCommodity(bag, slot, duration, quantity, unitPrice)
    return call("ConfirmPostCommodity", location(bag, slot), durationIndex(duration), quantity, unitPrice)
end

-- CalculateCommodityDeposit (doc 11-26, itemID) or CalculateItemDeposit (doc 28-43, ItemLocation). Gives copper or nil.
function Backend.Deposit(bag, slot, duration, quantity, isCommodity)
    local where = location(bag, slot)
    if isCommodity then
        return call("CalculateCommodityDeposit", C_Item.GetItemID(where), durationIndex(duration), quantity)
    end
    return call("CalculateItemDeposit", where, durationIndex(duration), quantity)
end

-- GetAvailablePostCount (doc 162-175).
function Backend.AvailablePostCount(bag, slot)
    return call("GetAvailablePostCount", location(bag, slot))
end

-- IsSellItemValid (doc 793-807); false means no error text in the chat.
function Backend.IsSellItemValid(bag, slot)
    return call("IsSellItemValid", location(bag, slot), false)
end

-- AUCTION_HOUSE_AUCTION_CREATED (doc 1098-1107; payload auctionID).
function Backend.PostedEvent()
    return "AUCTION_HOUSE_AUCTION_CREATED"
end

ns.AuctionClient.Use(Backend)
