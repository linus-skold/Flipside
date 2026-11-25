local _, ns = ...

-- Optional price source: reads the AuctionDB values of the TSM addon at run time, if TSM is loaded.
-- Only the public TSM_API global is called (with a dot, each call in pcall). TSM sends no load event,
-- so each read tests for TSM_API again. A missing TSM, an error or a nil result gives nil (no data).

local TsmPrices = {}
ns.TsmPrices = TsmPrices

-- Source name in formulas (lower case) -> TSM price key. The scheme: "tsm" + the TSM key without "DB".
-- One short form: tsmRegionMarket is DBRegionMarketAvg.
TsmPrices.KEYS = {
    tsmmarket = "DBMarket",
    tsmminbuyout = "DBMinBuyout",
    tsmrecent = "DBRecent",
    tsmhistorical = "DBHistorical",
    tsmregionmarket = "DBRegionMarketAvg",
    tsmregionhistorical = "DBRegionHistorical",
    tsmregionsaleavg = "DBRegionSaleAvg",
    tsmregionsalerate = "DBRegionSaleRate",
    tsmregionsoldperday = "DBRegionSoldPerDay",
    tsmnumauctions = "DBNumAuctions",
}

-- Display order of the names (help text and lists).
TsmPrices.NAMES = {
    "tsmMarket", "tsmMinBuyout", "tsmRecent", "tsmHistorical", "tsmRegionMarket", "tsmRegionHistorical",
    "tsmRegionSaleAvg", "tsmRegionSaleRate", "tsmRegionSoldPerDay", "tsmNumAuctions",
}

-- Sources that are not money: a rate (0 to 1) or a count. Tooltips and the formula page show them as plain numbers.
TsmPrices.NUMBER = { tsmregionsalerate = true, tsmregionsoldperday = true, tsmnumauctions = true }

function TsmPrices.IsNumber(name)
    return type(name) == "string" and TsmPrices.NUMBER[name:lower()] == true
end

local function api()
    local tsm = _G.TSM_API
    if type(tsm) == "table" and type(tsm.GetCustomPriceValue) == "function" then
        return tsm
    end
    return nil
end

function TsmPrices.IsLoaded()
    return api() ~= nil
end

-- Returns the TSM item string of an item link, or nil.
function TsmPrices.ItemString(link)
    local tsm = api()
    if not tsm or type(tsm.ToItemString) ~= "function" or type(link) ~= "string" then
        return nil
    end
    local ok, value = pcall(tsm.ToItemString, link)
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

-- Item string of an item ID or a Flipside item key (D20). A variant key "<id>#..." and a bare ID both map to the
-- base item "i:<id>": TSM data of a base item is the only data that all items have.
function TsmPrices.ItemStringFromKey(key)
    local base = ns.ItemString and ns.ItemString.ToBaseKey and ns.ItemString.ToBaseKey(key)
    local id = tonumber(base or (type(key) == "string" and key:match("^(%d+)")) or key)
    if not id or id <= 0 then
        return nil
    end
    return "i:" .. id
end

-- Returns the copper value (or count or rate) of a source name for an item ID or key. nil means no data.
function TsmPrices.Get(name, itemKey)
    local tsmKey = type(name) == "string" and TsmPrices.KEYS[name:lower()]
    if not tsmKey then
        return nil
    end
    local tsm = api()
    if not tsm then
        return nil
    end
    local itemString = TsmPrices.ItemStringFromKey(itemKey)
    if not itemString then
        return nil
    end
    local ok, value = pcall(tsm.GetCustomPriceValue, tsmKey, itemString)
    if ok and type(value) == "number" and value == value then
        return value
    end
    return nil
end
