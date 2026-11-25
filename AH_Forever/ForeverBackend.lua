local _, ns = ...

-- Forever auction backend: C_AuctionHouse (replicate scan and item keys).
-- Each call reads C_AuctionHouse at call time, as the client can change it.
local Backend = {}

-- Write one line to the diagnostics log; the Log module can be missing in a spec.
local function log(level, fmt, ...)
    if ns.Log then
        ns.Log.Writef("scan", level, fmt, ...)
    end
end

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
    log("debug", "ReplicateItems called")
    return call("ReplicateItems")
end

function Backend.ScanDoneEvent()
    return "REPLICATE_ITEM_LIST_UPDATE"
end

-- The engine asks for the data of all unloaded items at once and reads their rows when the data arrives.
-- It stops the wait when no row was accepted for this long (not a cap on the whole wait).
local REFRESH_SECONDS = 15
local DIAG_KEEP = 5

function Backend.ScanRefreshSeconds()
    return REFRESH_SECONDS
end

-- Builds the diagnostics line of the finished scan and keeps the last 5 runs in the scan DB.
function Backend.ScanDiagnostics(summary)
    summary = summary or {}
    local entry = {
        time = type(GetServerTime) == "function" and GetServerTime() or 0,
        result = summary.result,
        rows = summary.rows, items = summary.items, keys = summary.keys,
        pending = summary.pending, failed = summary.failed, nilLink = summary.nilLink,
        notAllInfo = summary.notAllInfo, retried = summary.retried, refreshSeconds = summary.refreshSeconds,
        pendingRows = summary.pendingRows, readSeconds = summary.readSeconds,
        eventSeconds = summary.timeToEventMs and summary.timeToEventMs / 1000 or nil,
    }
    local flavour = ns.Flavour
    local db = flavour and flavour.savedVariables and _G[flavour.savedVariables.scan]
    if type(db) == "table" then
        if type(db.diag) ~= "table" then
            db.diag = {}
        end
        db.diag[#db.diag + 1] = entry
        while #db.diag > DIAG_KEEP do
            table.remove(db.diag, 1)
        end
    end
    local line = string.format(
        "rows %s, written %s, pending %s items (%s rows), failed %s, nilLink %s, notAllInfo %s, retried %s; "
            .. "wait %.1f s, read %.1f s, item load %.1f s",
        tostring(entry.rows), tostring(entry.keys), tostring(entry.pending), tostring(entry.pendingRows),
        tostring(entry.failed), tostring(entry.nilLink), tostring(entry.notAllInfo), tostring(entry.retried),
        entry.eventSeconds or 0, entry.readSeconds or 0, entry.refreshSeconds or 0)
    log("info", "scan details: %s", line)
    return line
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

-- GetItemKeyInfo gives nothing until the client has the item data, and it asks the client to load the data. A search
-- that goes out before that can come back with no rows. So a search waits for the key info: it checks again every
-- KEY_INFO_DELAY seconds, and it goes out anyway after KEY_INFO_TRIES checks. A newer search drops a waiting one.
local KEY_INFO_TRIES = 10
local KEY_INFO_DELAY = 0.2
local searchToken = 0

local function keyInfoKnown(itemKey)
    return not has("GetItemKeyInfo") or call("GetItemKeyInfo", itemKey) ~= nil
end

local liveWaiting = false -- true while a live search waits for the key info

-- Sends the search and tells the capture which search is the active one (it pages only that one).
local function sendSearch(itemID, itemKey)
    call("SendSearchQuery", itemKey, {}, true)
    local capture = ns.scanCapture
    if capture and capture.BeginSearch then
        local ok, err = pcall(capture.BeginSearch, capture, itemID, itemKey)
        if not ok then
            log("warn", "capture search start failed: %s", tostring(err))
        end
    end
end

-- Sends the search for itemID when the key info exists, or after the wait. A live search wins over a targeted
-- one (the tooltip refresh): the targeted search is dropped while a live search waits. Gives nothing.
local function sendWhenKnown(itemID, live)
    if live then
        liveWaiting = false
    elseif liveWaiting then
        return
    end
    searchToken = searchToken + 1
    local token = searchToken
    local itemKey = call("MakeItemKey", itemID)
    local timer = _G.C_Timer
    if keyInfoKnown(itemKey) or type(timer) ~= "table" or type(timer.After) ~= "function" then
        sendSearch(itemID, itemKey)
        return
    end
    liveWaiting = live == true
    local tries = 0
    local function check()
        if token ~= searchToken then
            return
        end
        tries = tries + 1
        if tries >= KEY_INFO_TRIES or keyInfoKnown(itemKey) then
            liveWaiting = false
            if ns.IsAuctionHouseOpen and not ns.IsAuctionHouseOpen() then
                return -- the AH closed during the wait
            end
            local ok, err = pcall(sendSearch, itemID, itemKey)
            if not ok then
                log("warn", "delayed search failed: %s", tostring(err))
            end
            return
        end
        timer.After(KEY_INFO_DELAY, check)
    end
    timer.After(KEY_INFO_DELAY, check)
end

-- Search the listings of one item by item key; the capture events carry the result.
function Backend.TargetedSearch(itemID)
    sendWhenKnown(itemID, false)
end

function Backend.NameResultEvent()
    return "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"
end

-- Later batches of a browse result come with this event; the payload is the added rows.
function Backend.NameAddedEvent()
    return "AUCTION_HOUSE_BROWSE_RESULTS_ADDED"
end

-- GetItemKeyInfo can give no name at first; this event comes when the info has loaded.
function Backend.NameInfoEvent()
    return "ITEM_KEY_ITEM_INFO_RECEIVED"
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
            -- Next page of a result (doc 939-966); isReady is the throttle gate (doc 809-816).
            commodityMore = api.RequestMoreCommoditySearchResults,
            itemMore = api.RequestMoreItemSearchResults,
            isReady = api.IsThrottledMessageSystemReady,
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
    sendWhenKnown(itemID, true)
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

-- The commodity flag of an item for the live rows. With no answer from the client it is "maximum stack size above
-- 1" (SPEC 5.1 point 5), but only when the item data is loaded: a size read before that is not a real answer.
local function commodityFlag(itemID)
    local flag = Backend.ItemIsCommodity(itemID)
    if flag ~= nil then
        return flag
    end
    local item = _G.C_Item
    if type(item) == "table" and type(item.IsItemDataCachedByID) == "function"
        and type(item.GetItemMaxStackSizeByID) == "function" and item.IsItemDataCachedByID(itemID) then
        local size = item.GetItemMaxStackSizeByID(itemID)
        if type(size) == "number" and size >= 1 then
            return size > 1
        end
    end
    return nil
end

-- Rows of the last search of an item, cheapest unit price first. Commodity: GetNumCommoditySearchResults (doc 488)
-- and GetCommoditySearchResultInfo (doc 240), where unitPrice is the price of one unit. Item: GetNumItemSearchResults
-- (doc 503) and GetItemSearchResultInfo (doc 358); a row with no buyout is skipped.
-- Forever prices an item auction for one item. The client source shows it: the item sell frame copies
-- searchResult.buyoutAmount into its price box, which is a price per item (PerItemPostfix), and posts
-- PostItem(item, duration, quantity, bid, buyout) with that price for each item (Blizzard_AuctionHouseUI/Shared/
-- Blizzard_AuctionHouseItemSellFrame.lua, lines 316-326, 337, 439-440 and 483-486; Ketho/wow-ui-source-forever,
-- branch forever). So unitPrice = buyoutAmount, with no division by quantity. buyout keeps the raw buyoutAmount: the
-- client buys with PlaceBid(auctionID, buyoutAmount) (Blizzard_AuctionHouseFrame.lua, line 11).
function Backend.LiveRows(itemID)
    local rows = {}
    local isCommodity = commodityFlag(itemID)
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
                    auctionID = r.auctionID, unitPrice = buyout, quantity = quantity, buyout = buyout,
                    isCommodity = false, perItem = true, ownerItem = r.containsOwnerItem == true,
                    timeLeft = r.timeLeftSeconds or r.timeLeft, itemLink = r.itemLink,
                    owner = type(r.owners) == "table" and #r.owners == 1 and r.owners[1] or nil,
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

-- The most item search results that the owner lookup reads.
local OWNER_SCAN_LIMIT = 500

-- The owner of an item auction. GetAuctionInfoByID has no owner. The result list of the last item search has it
-- (ItemSearchResultInfo.owners). Commodities have no owner, so they give nil. Nil if the result is not in the list.
local function ownerOf(itemKey, auctionID)
    if type(itemKey) ~= "table" or not (has("GetNumItemSearchResults") and has("GetItemSearchResultInfo")) then
        return nil
    end
    local ok, owner = pcall(function()
        for index = 1, math.min(call("GetNumItemSearchResults", itemKey), OWNER_SCAN_LIMIT) do
            local result = call("GetItemSearchResultInfo", itemKey, index)
            if result and result.auctionID == auctionID then
                local owners = result.owners
                return type(owners) == "table" and #owners == 1 and owners[1] or nil
            end
        end
        return nil
    end)
    return ok and type(owner) == "string" and owner ~= "" and owner or nil
end

-- Info of one auction by id (doc 132): itemKey, itemLink, buyoutAmount, and owner when the last item search has it.
-- Nil if the client has none.
function Backend.AuctionInfo(auctionID)
    if not has("GetAuctionInfoByID") then
        return nil
    end
    local ok, info = pcall(call, "GetAuctionInfoByID", auctionID)
    if not ok or type(info) ~= "table" then
        return nil
    end
    local owner = ownerOf(info.itemKey, auctionID)
    if owner then
        local copy = {}
        for name, value in pairs(info) do
            copy[name] = value
        end
        copy.owner = owner
        return copy
    end
    return info
end

-- The bid post-hook of the ledger (SPEC 5.8, user decision 2026-10-17). hook is hooksecurefunc; handler(auctionID)
-- runs after each PlaceBid call and only reads. Gives the hooked name, or nil if the client has no PlaceBid.
function Backend.HookBid(hook, handler)
    if not has("PlaceBid") then
        return nil
    end
    hook(ah(), "PlaceBid", function(auctionID)
        handler(auctionID)
    end)
    return "C_AuctionHouse.PlaceBid"
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
-- Posting (Selling tab). Doc: AuctionHouseDocumentation.lua. PostItem and PostCommodity are protected.
-- The duration argument is a luaIndex. The SellFrame menu lists AUCTION_DURATION_ONE, TWO and THREE as index 1, 2, 3.
-- The mapping 2 h = 1, 8 h = 2, 24 h = 3 is confirmed by the user (WoW: Forever, 2026-10-15).
local DURATION_INDEX = { [2] = 1, [8] = 2, [24] = 3 }

local function durationIndex(hours)
    local index = DURATION_INDEX[hours]
    if not index then
        error("duration must be 2, 8 or 24 hours", 0)
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

-- True when the client takes a throttled message now (doc 809-816). Blizzard's sell frame gates its post the same way.
function Backend.CanSendPost()
    return not has("IsThrottledMessageSystemReady") or call("IsThrottledMessageSystemReady") == true
end

-- The events after which the gate can change. The sell frame of Blizzard reads the first two; the other two end a
-- message too.
function Backend.ThrottleEvents()
    return { "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT",
        "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED", "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" }
end

local FAILURE_EVENT = "Flipside.ForeverPostFailure"
local FAILURE_OWNER = "Flipside.ForeverBackend.post"
local failureSubscribed = false

-- The text of an AuctionHouseError value (doc AuctionHouseEnumsDocumentation DatabaseError = 10).
local function errorText(code)
    local enum = type(_G.Enum) == "table" and _G.Enum.AuctionHouseError or nil
    if enum and code == enum.DatabaseError and type(_G.ERR_AUCTION_DATABASE_ERROR) == "string" then
        return _G.ERR_AUCTION_DATABASE_ERROR
    end
    return "the Auction House refused the post (error " .. tostring(code) .. ")"
end

local function onShowError(_, code)
    ns.bus:Emit(FAILURE_EVENT, "failure", 0, 1, errorText(code))
end

local function onPostError()
    ns.bus:Emit(FAILURE_EVENT, "failure", 0, 1, "the Auction House refused the post")
end

-- The event of a post error. It carries "failure", 0, 1 and a text, as the legacy multisell event does. The sender
-- of the post ignores it when no post waits. It comes from AUCTION_HOUSE_SHOW_ERROR (error: AuctionHouseError,
-- doc 1236-1244) and AUCTION_HOUSE_POST_ERROR (doc 1186-1195).
function Backend.MultisellEvent()
    if not failureSubscribed and ns.bus then
        failureSubscribed = true
        ns.bus:Subscribe("AUCTION_HOUSE_SHOW_ERROR", FAILURE_OWNER, onShowError)
        ns.bus:Subscribe("AUCTION_HOUSE_POST_ERROR", FAILURE_OWNER, onPostError)
    end
    return FAILURE_EVENT
end

ns.AuctionClient.Use(Backend)
