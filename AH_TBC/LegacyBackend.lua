local _, ns = ...

-- TBC Anniversary legacy auction backend: name search and owned auctions.
-- The full scan is a getAll query. Its first run is the spike, so it records diagnostics (ScanDiagnostics).
-- Each call reads the legacy globals at call time, as the client can change them.
local Backend = {}

-- Legacy GetAuctionItemInfo return positions.
local INFO_NAME, INFO_COUNT, INFO_SALE_STATUS, INFO_ITEM_ID = 1, 3, 16, 17

local SCAN_SETTLE_SECONDS = 2
local DIAG_KEEP = 5
-- Time that a scan refreshes missing links after the read, by mode.
local REFRESH_SECONDS = { full = 90, fast = 8, page = 2 }

-- Counters of the last scan, filled while the engine reads rows.
local scan = {}

local function newScan()
    return { batch = 0, total = 0, nilName = 0, zeroBuyout = 0, nilLink = 0, linkSeen = {}, page = 0 }
end

local function now()
    return type(GetTime) == "function" and GetTime() or 0
end

-- Item names of the last name search, by item ID. NameItemKeyInfo reads them.
local names = {}


local function has(name)
    return type(_G[name]) == "function"
end

-- Call a legacy global by name; a missing function gives a clear error.
local function call(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then
        error(name .. " is not available", 0)
    end
    return fn(...)
end

function Backend.CanScan()
    return has("QueryAuctionItems") and has("GetNumAuctionItems") and has("GetAuctionItemInfo")
end

-- Returns true, or false and a text. The second CanSendAuctionQuery value is the get-all permission.
-- The page mode needs only the first value.
function Backend.ScanCanStart(mode)
    if not has("CanSendAuctionQuery") then
        return true
    end
    local canQuery, canMass = _G.CanSendAuctionQuery("list")
    if not canQuery then
        return false, "the Auction House is busy, try again in a moment"
    end
    if mode ~= "page" and not canMass then
        return false, "get all is on cooldown; the server allows it about every 15 minutes"
    end
    return true
end

-- The scan modes of this client. Full and fast use the get all query and differ in the refresh time.
-- Page reads the list page by page and needs no get all permission.
function Backend.ScanModes()
    return { "full", "fast", "page" }
end

function Backend.ScanRefreshSeconds(mode)
    return REFRESH_SECONDS[mode] or 0
end

-- Kind of the last list query: "scan", "name", "lookup", "browse" (any other query) or "getall" (not ours).
-- The capture reads a page only for "browse" and "lookup". The hook sees each QueryAuctionItems call.
local query = { kind = nil, id = 0, processed = 0, own = false, hooked = false }

local function startQuery(kind)
    query.kind = kind
    query.id = query.id + 1
end

-- Mark the next hooked call as ours, then call the client.
local function ownQuery(kind, ...)
    startQuery(kind)
    query.own = true
    local results = { pcall(call, "QueryAuctionItems", ...) }
    query.own = false
    if not results[1] then
        error(results[2], 0)
    end
    return unpack(results, 2)
end

local function onQueryCall(_, _, _, _, _, _, getAll)
    if query.own then
        return
    end
    startQuery(getAll and "getall" or "browse")
end

local function hookQueries()
    if query.hooked or type(hooksecurefunc) ~= "function" or not has("QueryAuctionItems") then
        return
    end
    query.hooked = true
    hooksecurefunc("QueryAuctionItems", onQueryCall)
end

function Backend.StartScan()
    scan = newScan()
    scan.startedAt = now()
    return ownQuery("scan", "", nil, nil, 0, false, 0, true, false, nil)
end

-- Page mode: true if the client takes a query now.
function Backend.CanQueryPage()
    return not has("CanSendAuctionQuery") or _G.CanSendAuctionQuery("list") == true
end

-- Page mode: a browse query of one page (0-based) without a name, with the get all flag off.
function Backend.ScanPageQuery(page)
    if page == 0 then
        scan = newScan()
        scan.startedAt = now()
    end
    scan.page = page
    return ownQuery("scan", "", nil, nil, page, false, 0, false, false, nil)
end

-- The number of auctions in the list, from the second GetNumAuctionItems value.
function Backend.ScanTotal()
    local _, total = call("GetNumAuctionItems", "list")
    return total
end

function Backend.ScanDoneEvent()
    return "AUCTION_ITEM_LIST_UPDATE"
end

-- The engine reads after the first event, once the batch equals the total or no event came for this long.
function Backend.ScanSettleSeconds()
    return SCAN_SETTLE_SECONDS
end

function Backend.ScanComplete()
    local batch, total = call("GetNumAuctionItems", "list")
    return type(batch) == "number" and batch > 0 and batch == total
end

function Backend.RowCount()
    local batch, total = call("GetNumAuctionItems", "list")
    scan.batch, scan.total = batch or 0, total or 0
    scan.readStart = scan.readStart or now()
    return batch
end

-- Returns count, buyout, itemID, hasAllInfo of row i (0-based). The buyout is for the whole stack.
function Backend.ReadRow(i)
    local info = { call("GetAuctionItemInfo", "list", i + 1) }
    scan.lastRead = now()
    if info[1] == nil or info[1] == "" then
        scan.nilName = (scan.nilName or 0) + 1
    end
    if info[10] == 0 then
        scan.zeroBuyout = (scan.zeroBuyout or 0) + 1
    end
    return info[3], info[10], info[17], info[18]
end

function Backend.RowLink(i)
    local link = call("GetAuctionItemLink", "list", i + 1)
    scan.lastRead = now()
    local seenKey = (scan.page or 0) * 100000 + i
    if scan.linkSeen and not scan.linkSeen[seenKey] then
        scan.linkSeen[seenKey] = true
        if link == nil then
            scan.nilLink = scan.nilLink + 1
        end
    end
    return link
end

-- There are no battle pets in the legacy list.
function Backend.RowIsPet()
    return false
end

-- Builds the diagnostics line of the finished scan and keeps the last 5 runs in the scan DB.
function Backend.ScanDiagnostics(summary)
    summary = summary or {}
    local readSeconds = (scan.readStart and scan.lastRead) and (scan.lastRead - scan.readStart) or 0
    local entry = {
        time = type(GetServerTime) == "function" and GetServerTime() or 0,
        result = summary.result,
        rows = summary.rows, items = summary.items, keys = summary.keys,
        batch = scan.batch, total = scan.total,
        firstEventMs = summary.firstEventMs, events = summary.events,
        readSeconds = readSeconds,
        nilLink = scan.nilLink, nilName = scan.nilName, zeroBuyout = scan.zeroBuyout,
        mode = summary.mode, pending = summary.pendingMissing, failed = summary.failed,
        keyedWithoutLink = summary.keyedWithoutLink, refreshSeconds = summary.refreshSeconds,
        pages = summary.pages,
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
    return string.format(
        "legacy scan: mode %s, rows %s, batch %s of %s, first event %s ms, events %s, read %.1f s, nil link %d, "
            .. "nil name %d, zero buyout %d, items %s, keys %s, pending %s, failed %s, keyed without link %s, "
            .. "refresh %.1f s, pages %s",
        tostring(entry.mode), tostring(entry.rows), tostring(entry.batch), tostring(entry.total),
        entry.firstEventMs and string.format("%d", entry.firstEventMs) or "-", tostring(entry.events),
        readSeconds, entry.nilLink or 0, entry.nilName or 0, entry.zeroBuyout or 0, tostring(entry.items),
        tostring(entry.keys), tostring(entry.pending), tostring(entry.failed), tostring(entry.keyedWithoutLink),
        entry.refreshSeconds or 0, tostring(entry.pages))
end

function Backend.OpenEvent()
    return "AUCTION_HOUSE_SHOW"
end

function Backend.CloseEvent()
    return "AUCTION_HOUSE_CLOSED"
end

-- Name search: a legacy browse query for page 0. The client allows one query at a time.
function Backend.NameSearch(text)
    if not call("CanSendAuctionQuery", "list") then
        error("the Auction House is busy, try again in a moment", 0)
    end
    names = {}
    return ownQuery("name", tostring(text or ""), nil, nil, 0, false, 0, false, false, nil)
end

function Backend.CanTargetSearch()
    return has("QueryAuctionItems") and has("CanSendAuctionQuery")
end

-- Exact-name browse query for one item; the list event and the capture handle the result.
function Backend.TargetedSearch(_, name)
    if type(name) ~= "string" or name == "" then
        error("the item name is not loaded yet, try again in a moment", 0)
    end
    if not call("CanSendAuctionQuery", "list") then
        error("the Auction House is busy, try again in a moment", 0)
    end
    return ownQuery("lookup", name, nil, nil, 0, false, 0, false, true, nil)
end

function Backend.NameResultEvent()
    return "AUCTION_ITEM_LIST_UPDATE"
end

-- Returns one row { itemKey = { itemID } } for each item ID of the list; it keeps the names.
function Backend.NameResults()
    local rows, seen = {}, {}
    local count = call("GetNumAuctionItems", "list")
    for i = 1, tonumber(count) or 0 do
        local info = { call("GetAuctionItemInfo", "list", i) }
        local itemID = info[INFO_ITEM_ID]
        local name = info[INFO_NAME]
        if type(itemID) == "number" and type(name) == "string" and name ~= "" and not seen[itemID] then
            seen[itemID] = true
            names[itemID] = name
            rows[#rows + 1] = { itemKey = { itemID = itemID } }
        end
    end
    return rows
end

function Backend.NameItemKeyInfo(itemKey)
    local itemID = type(itemKey) == "table" and itemKey.itemID or nil
    return { itemName = names[itemID] }
end

-- A legacy browse page holds at most this many rows. A longer list is a get-all result.
local PAGE_ROWS = 50
local PAGE_DEBOUNCE_SECONDS = 0.3

-- Search capture of the legacy list. readPage() gives rows { itemID, count, buyout, link } and a full flag,
-- or nil if the page is not for the capture (a Flipside scan or name search, a get-all, or a page read before).
function Backend.Capture()
    if not (has("GetNumAuctionItems") and has("GetAuctionItemInfo")) then
        return nil
    end
    hookQueries()
    return {
        api = {},
        pageEvent = "AUCTION_ITEM_LIST_UPDATE",
        debounceSeconds = PAGE_DEBOUNCE_SECONDS,
        readPage = function()
            if (query.kind ~= "browse" and query.kind ~= "lookup") or query.processed == query.id then
                return nil
            end
            local batch, total = call("GetNumAuctionItems", "list")
            if type(batch) ~= "number" or batch < 1 or batch > PAGE_ROWS then
                return nil
            end
            query.processed = query.id
            local rows = {}
            for i = 1, batch do
                local info = { call("GetAuctionItemInfo", "list", i) }
                rows[#rows + 1] = {
                    itemID = info[INFO_ITEM_ID],
                    count = info[INFO_COUNT],
                    buyout = info[10],
                    link = has("GetAuctionItemLink") and _G.GetAuctionItemLink("list", i) or nil,
                }
            end
            return rows, batch == total
        end,
    }
end

function Backend.CanReadOwned()
    return has("GetNumAuctionItems") and has("GetAuctionItemInfo")
end

-- Returns rows { itemLink, itemKey, quantity, status } of the own auctions. status 1 means sold.
-- The client fills the owner list when the Auction House opens; this code never queries it.
function Backend.OwnedAuctions()
    local rows = {}
    local count = call("GetNumAuctionItems", "owner")
    for i = 1, tonumber(count) or 0 do
        local info = { call("GetAuctionItemInfo", "owner", i) }
        local itemID = info[INFO_ITEM_ID]
        if type(itemID) == "number" then
            rows[#rows + 1] = {
                itemLink = has("GetAuctionItemLink") and GetAuctionItemLink("owner", i) or nil,
                itemKey = { itemID = itemID },
                quantity = info[INFO_COUNT],
                status = info[INFO_SALE_STATUS],
            }
        end
    end
    return rows
end

function Backend.OwnedEvent()
    return "AUCTION_OWNED_LIST_UPDATE"
end

-- Live search and buy (Buying tab). The legacy list has no auction ID and no quote. A row is its index in the list of
-- the last query. LiveRows keeps a fingerprint of each row; the buy reads the row again and refuses a changed row.
local BUY_OWNER = "Flipside.LegacyBackend"
local READY_POLL_SECONDS = 0.25
local READY_POLL_MAX = 40
local BUY_WINDOW_SECONDS = 20
-- Events that the legacy client does not have. They are never emitted, so the Buying tab listens to nothing.
local NO_EVENT = {
    commodity = "Flipside.LegacyNoCommodityResult", priceUpdated = "Flipside.LegacyNoQuote",
    priceUnavailable = "Flipside.LegacyNoQuoteUnavailable", commoditySucceeded = "Flipside.LegacyNoCommodityBought",
    commodityFailed = "Flipside.LegacyNoCommodityFailed",
}
local READY_EVENT = "Flipside.LegacyQueryReady"
local BOUGHT_EVENT = "Flipside.LegacyBuyCompleted"
local BUY_ERROR_EVENT = "Flipside.LegacyBuyError"

local live = { rows = {}, buy = nil, subscribed = false }

local function itemName(itemID)
    local getInfo = has("GetItemInfo") and _G.GetItemInfo or (type(C_Item) == "table" and C_Item.GetItemInfo)
    if type(getInfo) ~= "function" then
        return nil
    end
    return (getInfo(itemID))
end

function Backend.CanLiveSearch()
    return has("QueryAuctionItems") and has("CanSendAuctionQuery") and has("GetNumAuctionItems")
        and has("GetAuctionItemInfo")
end

-- True when the client takes a query now.
function Backend.IsReady()
    return has("CanSendAuctionQuery") and _G.CanSendAuctionQuery("list") == true
end

-- The client has no ready event. After a query, a timer polls CanSendAuctionQuery and emits this event.
function Backend.ReadyEvent()
    return READY_EVENT
end

local function pollReady(tries)
    if type(C_Timer) ~= "table" or not ns.bus then
        return
    end
    C_Timer.After(READY_POLL_SECONDS, function()
        if Backend.IsReady() then
            ns.bus:Emit(READY_EVENT)
        elseif tries < READY_POLL_MAX then
            pollReady(tries + 1)
        end
    end)
end

-- One exact-name query for an item, page 0. Gives true, or false and a text.
function Backend.LiveSearch(itemID)
    if not Backend.IsReady() then
        return false, "the Auction House is busy, try again in a moment"
    end
    local name = itemName(itemID)
    if type(name) ~= "string" or name == "" then
        return false, "the item name is not loaded yet, try again in a moment"
    end
    live.rows = {}
    ownQuery("lookup", name, nil, nil, 0, false, 0, false, true, nil)
    pollReady(1)
    return true
end

-- The legacy list has no commodity result. The item result is the list update.
function Backend.LiveResultEvents()
    return NO_EVENT.commodity, "AUCTION_ITEM_LIST_UPDATE"
end

local function byPrice(a, b)
    if a.unitPrice ~= b.unitPrice then
        return a.unitPrice < b.unitPrice
    end
    return a.auctionID < b.auctionID
end

-- Rows of the item in the list, cheapest unit price first. auctionID is the list index. A row with no buyout is
-- skipped. Each row is an item auction: the unit price is the buyout of the stack divided by the count.
function Backend.LiveRows(itemID)
    local rows, prints = {}, {}
    local me = type(UnitName) == "function" and UnitName("player") or nil
    for i = 1, tonumber((call("GetNumAuctionItems", "list"))) or 0 do
        local info = { call("GetAuctionItemInfo", "list", i) }
        local count, buyout, owner = info[INFO_COUNT], info[10], info[14]
        if info[INFO_ITEM_ID] == itemID and type(buyout) == "number" and buyout > 0 and (count or 0) > 0 then
            prints[i] = { itemID = itemID, count = count, buyout = buyout, owner = owner }
            rows[#rows + 1] = {
                auctionID = i, unitPrice = buyout / count, quantity = count, buyout = buyout, isCommodity = false,
                ownerItem = me ~= nil and owner == me, itemLink = has("GetAuctionItemLink")
                    and _G.GetAuctionItemLink("list", i) or nil,
            }
        end
    end
    table.sort(rows, byPrice)
    live.rows = prints
    return rows
end

function Backend.CanBuy()
    return has("PlaceAuctionBid") and has("GetAuctionItemInfo")
end

-- Pattern of the system text that follows a won buyout (ERR_AUCTION_WON_S, "You won an auction for %s").
local function wonPattern()
    local text = _G.ERR_AUCTION_WON_S
    if type(text) ~= "string" then
        return nil
    end
    local escaped = text:gsub("%p", "%%%0"):gsub("%%%%s", "(.+)")
    return "^" .. escaped .. "$"
end

local function buyOpen()
    local buy = live.buy
    if buy and now() - buy.at > BUY_WINDOW_SECONDS then
        live.buy = nil
        return nil
    end
    return buy
end

local function onSystemText(_, text)
    local buy = buyOpen()
    local pattern = wonPattern()
    local shown = buy and pattern and type(text) == "string" and text:match(pattern) or nil
    if shown and buy.name and shown:find(buy.name, 1, true) then
        live.buy = nil
        ns.bus:Emit(BOUGHT_EVENT, buy.auctionID)
    end
end

local function onUiError(_, first, second)
    local buy = buyOpen()
    if buy then
        live.buy = nil
        ns.bus:Emit(BUY_ERROR_EVENT, second or first)
    end
end

-- The legacy client sends no purchase event with an ID. This code reads the won text and the error text instead,
-- and emits its own events.
function Backend.BuyEvents()
    if not live.subscribed and ns.bus then
        live.subscribed = true
        ns.bus:Subscribe("CHAT_MSG_SYSTEM", BUY_OWNER, onSystemText)
        ns.bus:Subscribe("UI_ERROR_MESSAGE", BUY_OWNER, onUiError)
    end
    return {
        priceUpdated = NO_EVENT.priceUpdated, priceUnavailable = NO_EVENT.priceUnavailable,
        commoditySucceeded = NO_EVENT.commoditySucceeded, commodityFailed = NO_EVENT.commodityFailed,
        itemCompleted = BOUGHT_EVENT, itemError = BUY_ERROR_EVENT,
    }
end

-- Buy the listing at its buyout. Protected: call it from a click only. auctionID is the list index of LiveRows.
-- The row must still be the same item, count, buyout and owner as when LiveRows read it; if not, this raises an error.
function Backend.BuyItemAuction(auctionID, buyout)
    local seen = live.rows[auctionID]
    if not seen then
        error("the listing is not from the last search, search again", 0)
    end
    local info = { call("GetAuctionItemInfo", "list", auctionID) }
    if info[INFO_ITEM_ID] ~= seen.itemID or info[INFO_COUNT] ~= seen.count or info[10] ~= seen.buyout
        or buyout ~= seen.buyout or (seen.owner ~= nil and info[14] ~= seen.owner) then
        live.rows = {}
        error("the listing changed, search again", 0)
    end
    live.buy = { auctionID = auctionID, name = info[INFO_NAME], at = now() }
    local ok, err = pcall(call, "PlaceAuctionBid", "list", auctionID, buyout)
    if not ok then
        live.buy = nil
        error(err, 0)
    end
    live.rows = {}
end

-- Info of one list row by index, for the ledger: itemLink, quantity, buyoutAmount. The ledger reads it before the
-- buy call, while the row is still in the list. Gives nil if the row has no item.
function Backend.AuctionInfo(auctionID)
    if not has("GetAuctionItemInfo") or type(auctionID) ~= "number" then
        return nil
    end
    local ok, info = pcall(function()
        return { call("GetAuctionItemInfo", "list", auctionID) }
    end)
    if not ok or info[INFO_ITEM_ID] == nil then
        return nil
    end
    local link = has("GetAuctionItemLink") and _G.GetAuctionItemLink("list", auctionID) or nil
    if link == nil then
        link = "item:" .. info[INFO_ITEM_ID]
    end
    return { itemLink = link, quantity = info[INFO_COUNT], buyoutAmount = info[10] }
end

-- Posting (Selling tab). The legacy client posts the item in the sale slot: the code puts the bag item there, checks
-- it, and calls PostAuction(start, buyout, duration, stackSize, numStacks). The prices are for one stack. A call with
-- numStacks above 1 makes the client post the stacks one after the other (multisell).
-- PostItem and ConfirmPostItem are protected: call them only inside a click handler.
-- This code starts no timer for them.
local POST_OWNER = "Flipside.LegacyBackend.Post"
local POSTED_EVENT = "Flipside.LegacyPosted"
local POST_WINDOW_SECONDS = 20
local CONFIRM_WINDOW_SECONDS = 120
local post = { subscribed = false, pending = nil, at = nil, refused = nil }

-- Duration in hours to the legacy index: 1 = 12 h, 2 = 24 h, 3 = 48 h. A value with no exact match gives the nearest
-- longer index that exists, and 3 above 48 h.
function Backend.DurationIndex(hours)
    if type(hours) ~= "number" or hours <= 0 then
        error("duration must be a number of hours", 0)
    end
    if hours <= 12 then
        return 1
    elseif hours <= 24 then
        return 2
    end
    return 3
end

local function containerCall(name)
    local fn = type(C_Container) == "table" and C_Container[name] or nil
    return type(fn) == "function" and fn or nil
end

function Backend.CanPost()
    return containerCall("PickupContainerItem") ~= nil and containerCall("GetContainerItemInfo") ~= nil
        and has("PostAuction") and has("ClickAuctionSellItemButton") and has("GetAuctionSellItemInfo")
        and has("GetAuctionDeposit") and has("ClearCursor") and has("CursorHasItem")
end

-- The table of a bag slot (itemID, stackCount, isBound), or nil.
local function slotInfo(bag, slot)
    local read = containerCall("GetContainerItemInfo")
    local info = read and read(bag, slot)
    return type(info) == "table" and info.itemID and info or nil
end

-- The item in the sale slot: { itemID, stack (maximum stack), total (items in the slot) }, or nil.
local function sellInfo()
    local name, _, _, _, _, _, _, stack, total, itemID = call("GetAuctionSellItemInfo")
    if name == nil or name == "" then
        return nil
    end
    return { itemID = itemID, stack = stack, total = total }
end

local MULTISELL_EVENT = "Flipside.LegacyMultisell"
local MULTISELL_WINDOW_SECONDS = 30

-- Tell the listeners about a multisell step: kind is "start", "update" or "failure".
local function emitMultisell(kind, created, total, text)
    ns.bus:Emit(MULTISELL_EVENT, kind, created, total, text)
end

local function endMultisell(text)
    local multi = post.multi
    post.multi = nil
    emitMultisell("failure", multi and multi.created or 0, multi and multi.total, text)
end

-- True if a multisell runs or just ended its last step, so that a late error belongs to it.
local function multisellOpen()
    local multi = post.multi
    return multi ~= nil and now() - multi.at <= MULTISELL_WINDOW_SECONDS
end

local function onPostError()
    if multisellOpen() and not post.calling then
        endMultisell("the Auction House refused the post")
        return
    end
    post.refused = "the Auction House refused the post"
end

-- True if text is the text of one of the client ERR_AUCTION_* messages (for example ERR_AUCTION_DATABASE_ERROR).
local function isAuctionError(text)
    if type(text) ~= "string" then
        return false
    end
    for name, value in pairs(_G) do
        if type(name) == "string" and name:sub(1, 12) == "ERR_AUCTION_" and value == text then
            return true
        end
    end
    return false
end

local function onPostUiError(_, first, second)
    local text = second or first
    if post.calling then
        post.refused = tostring(text or "the Auction House refused the post")
    elseif multisellOpen() and isAuctionError(text) then
        endMultisell(text)
    end
end

local function onMultisellStart(_, total)
    post.multi = { created = 0, total = total, at = now() }
    emitMultisell("start", 0, total)
end

local function onMultisellUpdate(_, created, total)
    local multi = post.multi or {}
    multi.created, multi.total, multi.at = created, total, now()
    post.multi = multi
    if type(created) == "number" and type(total) == "number" and created >= total then
        post.multi = nil
    end
    emitMultisell("update", created, total)
end

local function onMultisellFailure()
    endMultisell("the Auction House stopped the multi-stack post")
end

local function onPostText(_, text)
    if post.at and now() - post.at <= POST_WINDOW_SECONDS and type(text) == "string"
        and text == _G.ERR_AUCTION_STARTED then
        ns.bus:Emit(POSTED_EVENT)
    end
end

local function subscribePost()
    if not post.subscribed and ns.bus then
        post.subscribed = true
        ns.bus:Subscribe("CHAT_MSG_SYSTEM", POST_OWNER, onPostText)
        ns.bus:Subscribe("AUCTION_HOUSE_POST_ERROR", POST_OWNER, onPostError)
        ns.bus:Subscribe("UI_ERROR_MESSAGE", POST_OWNER, onPostUiError)
        ns.bus:Subscribe("AUCTION_MULTISELL_START", POST_OWNER, onMultisellStart)
        ns.bus:Subscribe("AUCTION_MULTISELL_UPDATE", POST_OWNER, onMultisellUpdate)
        ns.bus:Subscribe("AUCTION_MULTISELL_FAILURE", POST_OWNER, onMultisellFailure)
    end
end

-- The event of a multi-stack post (PostItem with numStacks above 1). It carries "start", "update" or "failure",
-- the stacks created, the total of stacks and, for a failure, a text. A failure comes from AUCTION_MULTISELL_FAILURE,
-- from AUCTION_HOUSE_POST_ERROR, or from a UI error text that is one of the ERR_AUCTION_* texts of the client.
function Backend.MultisellEvent()
    subscribePost()
    return MULTISELL_EVENT
end

-- The legacy client sends no event with an ID for a post. This code reads the "Auction created." system text for 20
-- seconds after the call and emits its own event.
function Backend.PostedEvent()
    subscribePost()
    return POSTED_EVENT
end

-- Number of items in the bag slot (the most that one post can use), 0 for an empty slot.
function Backend.AvailablePostCount(bag, slot)
    local info = slotInfo(bag, slot)
    return info and info.stackCount or 0
end

-- False for an empty slot and for a bound item. The client refuses other items when they go to the sale slot.
function Backend.IsSellItemValid(bag, slot)
    local info = slotInfo(bag, slot)
    return info ~= nil and info.isBound ~= true
end

-- Ask for a fresh owned list. The call is not protected.
function Backend.RefreshOwned()
    if has("GetOwnerAuctionItems") then
        _G.GetOwnerAuctionItems()
    end
end

-- Put the sale slot item back in the bags. A failed step must not leave the item on the cursor.
local function releaseSellSlot()
    if sellInfo() then
        call("ClickAuctionSellItemButton")
    end
    call("ClearCursor")
end

-- The bag slot must still hold the planned item (when itemID is given) and at least the quantity.
local function checkSlot(bag, slot, quantity, itemID)
    local info = slotInfo(bag, slot)
    if not info then
        error("the bag slot is empty now, read the bags again", 0)
    end
    if itemID ~= nil and info.itemID ~= itemID then
        error("the bag slot holds another item now, read the bags again", 0)
    end
    if (info.stackCount or 0) < quantity then
        error("the bag slot holds fewer items now, read the bags again", 0)
    end
    return info
end

-- Empty the sale slot, check the bag slot, then put the bag item in the sale slot and read it back.
local function fillSellSlot(bag, slot, quantity, itemID, stacks)
    if call("CursorHasItem") then
        error("the cursor holds an item, put it down first", 0)
    end
    if sellInfo() then
        releaseSellSlot()
    end
    -- Several stacks may come from several bag slots: the sale slot reports the total in all bags.
    local info = checkSlot(bag, slot, stacks > 1 and 1 or quantity, itemID)
    containerCall("PickupContainerItem")(bag, slot)
    call("ClickAuctionSellItemButton")
    local sell = sellInfo()
    if not sell or sell.itemID ~= info.itemID or (sell.total or 0) < quantity * stacks
        or (sell.stack or 0) < quantity then
        releaseSellSlot()
        error("the item did not go into the sale slot, check the item and the quantity", 0)
    end
    return info.itemID
end

local function hidePostDialogs()
    local hide = _G.StaticPopup_Hide
    if type(hide) == "function" then
        pcall(hide, "AUCTION_HOUSE_POST_WARNING")
        pcall(hide, "AUCTION_HOUSE_POST_ERROR")
    end
end

local function checkPostNumbers(quantity, buyout, stacks)
    if type(quantity) ~= "number" or quantity < 1 or quantity ~= math.floor(quantity) then
        error("the quantity must be a whole number of 1 or more", 0)
    end
    if type(buyout) ~= "number" or buyout < 1 then
        error("the buyout must be 1 copper or more", 0)
    end
    if type(stacks) ~= "number" or stacks < 1 or stacks ~= math.floor(stacks) then
        error("the number of stacks must be a whole number of 1 or more", 0)
    end
end

-- The real deposit of the stacks with the item in the sale slot: GetAuctionDeposit(duration index, start price,
-- buyout, stack size, number of stacks). The prices are for one stack. Gives copper for all stacks, or nil.
local function readDeposit(index, start, buyout, quantity, stacks)
    local ok, deposit = pcall(call, "GetAuctionDeposit", index, start, buyout, quantity, stacks)
    return ok and type(deposit) == "number" and deposit or nil
end

-- Post numStacks stacks (default 1) of quantity items at the buyout (the price of one stack). With numStacks above 1
-- the client posts the stacks one after the other (multisell) and sends the multisell events: see MultisellEvent.
-- bid is the start price of one stack; nil means the buyout. itemID is the planned item; if the bag slot holds
-- another item, nothing is posted. Gives true if the
-- client asks to confirm (ConfirmPostItem finishes the post), false if the post is done.
-- guard is optional. After the item is in the sale slot, guard(deposit) runs with the real deposit. If it gives
-- false, the code puts the item back in the bag, calls no PostAuction, and gives "held" and the deposit. A new
-- PostItem call without guard then posts it.
-- Protected: call it from a click.
function Backend.PostItem(bag, slot, duration, quantity, bid, buyout, itemID, guard, numStacks)
    local index = Backend.DurationIndex(duration)
    local stacks = numStacks == nil and 1 or numStacks
    checkPostNumbers(quantity, buyout, stacks)
    local start = (type(bid) == "number" and bid > 0) and bid or buyout
    if start > buyout then
        error("the start price is above the buyout", 0)
    end
    subscribePost()
    post.pending, post.refused = nil, nil
    local placed = fillSellSlot(bag, slot, quantity, itemID, stacks)
    if guard then
        local deposit = readDeposit(index, start, buyout, quantity, stacks)
        local okGuard, proceed = pcall(guard, deposit)
        if not okGuard then
            releaseSellSlot()
            error(proceed, 0)
        end
        if proceed == false then
            releaseSellSlot()
            return "held", deposit
        end
    end
    post.at, post.calling = now(), true
    post.multi = stacks > 1 and { created = 0, total = stacks, at = now() } or nil
    local ok, result = pcall(call, "PostAuction", start, buyout, index, quantity, stacks)
    post.calling = false
    if not ok then
        post.multi = nil
        releaseSellSlot()
        error(result, 0)
    end
    if result then
        return false
    end
    post.multi = nil
    hidePostDialogs()
    if post.refused then
        local text = post.refused
        post.refused, post.at = nil, nil
        releaseSellSlot()
        error(text, 0)
    end
    post.pending = { bag = bag, slot = slot, quantity = quantity, buyout = buyout, start = start, index = index,
        itemID = placed, at = now(), stacks = stacks }
    return true
end

-- Finish a post that the client asked to confirm. The call must match the PostItem call, and the sale slot must still
-- hold the item. A confirm works once. Protected: call it from a click.
function Backend.ConfirmPostItem(bag, slot, duration, quantity, _bid, buyout, _itemID, _guard, numStacks)
    local pending = post.pending
    post.pending = nil
    local index = Backend.DurationIndex(duration)
    local stacks = numStacks == nil and 1 or numStacks
    if not pending or now() - pending.at > CONFIRM_WINDOW_SECONDS or pending.bag ~= bag or pending.slot ~= slot
        or pending.quantity ~= quantity or pending.buyout ~= buyout or pending.index ~= index
        or pending.stacks ~= stacks then
        error("no post waits for a confirm, post again", 0)
    end
    if post.refused then
        local text = post.refused
        post.refused = nil
        releaseSellSlot()
        error(text, 0)
    end
    local sell = sellInfo()
    if not sell or sell.itemID ~= pending.itemID or (sell.total or 0) < pending.quantity * stacks then
        error("the sale slot changed, post again", 0)
    end
    post.at, post.calling = now(), true
    post.multi = stacks > 1 and { created = 0, total = stacks, at = now() } or nil
    local ok, err = pcall(call, "PostAuction", pending.start, pending.buyout, pending.index, pending.quantity, stacks,
        true)
    post.calling = false
    if not ok then
        post.multi = nil
        error(err, 0)
    end
    return false
end

-- The deposit in copper of numStacks stacks (default 1), or nil. The client computes it only for the item in the sale
-- slot, and this code
-- puts no item there outside a post click. So the value is nil unless the sale slot holds the item already.
-- start and buyout are the prices of the post. If they are nil, the values of the post that waits for a confirm
-- are used (when it matches); if there are none, the value is nil.
function Backend.Deposit(bag, slot, duration, quantity, _, start, buyout, numStacks)
    local index = Backend.DurationIndex(duration)
    local stacks = numStacks == nil and 1 or numStacks
    local sell, info = sellInfo(), slotInfo(bag, slot)
    if not (sell and info and sell.itemID == info.itemID and (sell.total or 0) >= quantity * stacks) then
        return nil
    end
    local pending = post.pending
    if (type(start) ~= "number" or type(buyout) ~= "number") and pending and pending.bag == bag
        and pending.slot == slot and pending.index == index and pending.quantity == quantity
        and pending.stacks == stacks then
        start, buyout = pending.start, pending.buyout
    end
    if type(start) ~= "number" or type(buyout) ~= "number" then
        return nil
    end
    return readDeposit(index, start, buyout, quantity, stacks)
end

ns.AuctionClient.Use(Backend)

