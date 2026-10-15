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

ns.AuctionClient.Use(Backend)

