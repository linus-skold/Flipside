local _, ns = ...

-- Saves the price of an item when the player looks at its listings in the Auction House.
-- deps: store, serverTime, api, and the optional report, onCaptured, isScanRunning and keyFor(itemID, link).
-- api: commodityNum(itemID), commodityInfo(itemID, index), commodityFull(itemID),
--      itemNum(itemKey), itemInfo(itemKey, index), itemFull(itemKey). Result indexes start at 1.
local ScanCapture = {}
ns.ScanCapture = ScanCapture

local Capture = {}
Capture.__index = Capture

-- NOT verified in game: buyoutAmount is treated as the TOTAL for the auction.
-- If the client returns a price per unit, change this one function to return buyoutAmount.
local function UnitPriceFromBuyout(buyoutAmount, count)
    return buyoutAmount / count
end

local function IsPositiveInteger(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

function ScanCapture.New(deps)
    deps = deps or {}
    if type(deps.store) ~= "table" or type(deps.serverTime) ~= "function" or type(deps.api) ~= "table" then
        error("deps must have store, serverTime and api", 2)
    end
    return setmetatable({
        store = deps.store,
        serverTime = deps.serverTime,
        api = deps.api,
        report = deps.report,
        onCaptured = deps.onCaptured,
        isScanRunning = deps.isScanRunning,
        keyFor = deps.keyFor,
        failed = false,
    }, Capture)
end

-- Report the first failure of a session.
function Capture:_Fail(err)
    if self.failed then
        return
    end
    self.failed = true
    if self.report then
        self.report("search capture failed: " .. tostring(err))
    end
end

function Capture:_CanCapture()
    if self.store:IsReadOnly() then
        return false
    end
    if self.isScanRunning then
        local ok, running = pcall(self.isScanRunning)
        if not ok or running then
            return false
        end
    end
    return true
end

-- Returns a list of { unitPrice, count } rows, or nil after a failure.
function Capture:_ReadCommodity(itemID)
    local api = self.api
    local ok, n = pcall(api.commodityNum, itemID)
    if not ok or type(n) ~= "number" then
        self:_Fail(ok and "bad row count" or n)
        return nil
    end
    local auctions = {}
    for index = 1, n do
        local okRow, info = pcall(api.commodityInfo, itemID, index)
        if not okRow then
            self:_Fail(info)
            return nil
        end
        if type(info) == "table" and IsPositiveInteger(info.quantity) and type(info.unitPrice) == "number" then
            auctions[#auctions + 1] = { unitPrice = info.unitPrice, count = info.quantity }
        end
    end
    return auctions
end

-- Returns a map of exact key to auctions, or nil after a failure.
function Capture:_ReadItems(itemKey)
    local api = self.api
    local ok, n = pcall(api.itemNum, itemKey)
    if not ok or type(n) ~= "number" then
        self:_Fail(ok and "bad row count" or n)
        return nil
    end
    local byKey = {}
    for index = 1, n do
        local okRow, info = pcall(api.itemInfo, itemKey, index)
        if not okRow then
            self:_Fail(info)
            return nil
        end
        if type(info) == "table" and type(info.itemLink) == "string" and not ns.ScanKey.IsBattlePet(info.itemLink)
            and type(info.buyoutAmount) == "number" and info.buyoutAmount > 0
            and IsPositiveInteger(info.quantity) then
            local key = ns.ItemString.ToExactKey(info.itemLink)
            if key then
                local list = byKey[key]
                if not list then
                    list = {}
                    byKey[key] = list
                end
                list[#list + 1] = {
                    unitPrice = UnitPriceFromBuyout(info.buyoutAmount, info.quantity),
                    count = info.quantity,
                }
            end
        end
    end
    return byKey
end

-- Save one item. A partial result keeps the old market value, quantity and auction count.
function Capture:_Save(key, auctions, full)
    local snap = ns.ScanMarket.Reduce(auctions)
    if not snap then
        return
    end
    local record = self.store:Get(key) or ns.ScanRecord.New()
    local partial = not full
    if partial then
        local old = record.latest
        if old then
            snap.market, snap.qty, snap.auctions = old.market, old.qty, old.auctions
        else
            snap.market = snap.min
        end
    end
    local ok, err = pcall(function()
        ns.ScanBucket.Override(record, snap, self.serverTime(), partial)
    end)
    if not ok then
        self:_Fail(err)
        return
    end
    if self.store:Put(key, record) and self.onCaptured then
        self.onCaptured(key, snap, partial)
    end
end

-- Save the rows of one legacy list page. rows: { itemID, count, buyout, link }; buyout is for the whole stack.
-- full is true if the page holds all results of the query. A row that has no key or no buyout is skipped.
function Capture:OnPageResults(rows, full)
    if type(rows) ~= "table" or not self:_CanCapture() then
        return
    end
    local keyFor = self.keyFor
    local byKey = {}
    for _, row in ipairs(rows) do
        if type(row) == "table" and type(row.buyout) == "number" and row.buyout > 0
            and IsPositiveInteger(row.count) and not ns.ScanKey.IsBattlePet(row.link) then
            local key
            if keyFor then
                local ok, value = pcall(keyFor, row.itemID, row.link)
                key = ok and value or nil
            else
                key = row.link and ns.ItemString.ToExactKey(row.link) or nil
            end
            if key then
                local list = byKey[key]
                if not list then
                    list = {}
                    byKey[key] = list
                end
                list[#list + 1] = { unitPrice = UnitPriceFromBuyout(row.buyout, row.count), count = row.count }
            end
        end
    end
    for key, auctions in pairs(byKey) do
        self:_Save(key, auctions, full == true)
    end
end

function Capture:OnCommodityResults(itemID)
    if not self:_CanCapture() then
        return
    end
    local key = ns.ItemString.ToBaseKey(itemID)
    if not key then
        return
    end
    local auctions = self:_ReadCommodity(itemID)
    if not auctions then
        return
    end
    local ok, full = pcall(self.api.commodityFull, itemID)
    if not ok then
        self:_Fail(full)
        return
    end
    self:_Save(key, auctions, full == true)
end

function Capture:OnItemResults(itemKey)
    if not self:_CanCapture() then
        return
    end
    local byKey = self:_ReadItems(itemKey)
    if not byKey then
        return
    end
    local ok, full = pcall(self.api.itemFull, itemKey)
    if not ok then
        self:_Fail(full)
        return
    end
    for key, auctions in pairs(byKey) do
        self:_Save(key, auctions, full == true)
    end
end
