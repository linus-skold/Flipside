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
    local canQuery, canMass = _G.CanSendAuctionQuery()
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
    return not has("CanSendAuctionQuery") or _G.CanSendAuctionQuery() == true
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

ns.AuctionClient.Use(Backend)

