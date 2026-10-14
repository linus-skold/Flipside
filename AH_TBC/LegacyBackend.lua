local _, ns = ...

-- TBC Anniversary legacy auction backend: name search and owned auctions.
-- The full scan stays off (CanScan is false) until the getAll spike has results.
-- Each call reads the legacy globals at call time, as the client can change them.
local Backend = {}

-- Legacy GetAuctionItemInfo return positions.
local INFO_NAME, INFO_COUNT, INFO_SALE_STATUS, INFO_ITEM_ID = 1, 3, 16, 17

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
