local _, ns = ...

-- TBC Anniversary legacy auction backend: name search and owned auctions.
-- The full scan is a getAll query. Its first run is the spike, so it records diagnostics (ScanDiagnostics).
-- Each call reads the legacy globals at call time, as the client can change them.
local Backend = {}

-- Legacy GetAuctionItemInfo return positions.
local INFO_NAME, INFO_COUNT, INFO_SALE_STATUS, INFO_ITEM_ID = 1, 3, 16, 17

local SCAN_SETTLE_SECONDS = 2
local DIAG_KEEP = 5

-- Counters of the last scan, filled while the engine reads rows.
local scan = {}

local function newScan()
    return { batch = 0, total = 0, nilName = 0, zeroBuyout = 0, nilLink = 0, linkSeen = {} }
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
function Backend.ScanCanStart()
    if not has("CanSendAuctionQuery") then
        return true
    end
    local canQuery, canMass = _G.CanSendAuctionQuery()
    if not canQuery then
        return false, "the Auction House is busy, try again in a moment"
    end
    if not canMass then
        return false, "get all is on cooldown; the server allows it about every 15 minutes"
    end
    return true
end

function Backend.StartScan()
    scan = newScan()
    scan.startedAt = now()
    return call("QueryAuctionItems", "", nil, nil, 0, false, 0, true, false, nil)
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
    if scan.linkSeen and not scan.linkSeen[i] then
        scan.linkSeen[i] = true
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
        "legacy scan: rows %s, batch %s of %s, first event %s ms, events %s, read %.1f s, nil link %d, "
            .. "nil name %d, zero buyout %d, items %s",
        tostring(entry.rows), tostring(entry.batch), tostring(entry.total),
        entry.firstEventMs and string.format("%d", entry.firstEventMs) or "-", tostring(entry.events),
        readSeconds, entry.nilLink or 0, entry.nilName or 0, entry.zeroBuyout or 0, tostring(entry.items))
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
    return call("QueryAuctionItems", tostring(text or ""), nil, nil, 0, false, 0, false, false, nil)
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
