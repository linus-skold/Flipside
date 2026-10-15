local _, ns = ...

-- The one door to the auction API. A flavour file registers a backend with Use(); shared code calls only this module.
-- Backend functions: StartScan, ScanDoneEvent, RowCount, ReadRow, RowLink, RowIsPet, ItemIsCommodity,
-- HasCommodityCheck, NameSearch, TargetedSearch, NameResultEvent, NameResults, NameItemKeyInfo, Capture, OwnedAuctions,
-- CanReadOwned, OwnedEvent, OpenEvent, CloseEvent, CanScan, CanLiveSearch, LiveSearch, LiveResultEvents, LiveRows,
-- IsReady, ReadyEvent, RefreshOwned, CanBuy, StartCommodityPurchase, ConfirmCommodityPurchase, CancelCommodityPurchase,
-- QuoteSecondsLeft, BuyItemAuction, BuyEvents, CanPost, PostItem, PostCommodity, ConfirmPostItem, ConfirmPostCommodity,
-- Deposit, AvailablePostCount, IsSellItemValid, PostedEvent, AuctionInfo. A backend leaves out what its client
-- cannot do.
local AuctionClient = {}
ns.AuctionClient = AuctionClient

local backend

-- Register the backend table; a second call replaces the first.
function AuctionClient.Use(newBackend)
    if type(newBackend) ~= "table" then
        error("backend must be a table", 2)
    end
    backend = newBackend
end

-- The registered backend, or nil.
function AuctionClient.Backend()
    return backend
end

local function missing(name)
    error("auction backend has no " .. name, 0)
end

-- Forward to a backend function that gives a value; return the default if there is no backend function.
local function query(name, default)
    AuctionClient[name] = function(...)
        local fn = backend and backend[name]
        if type(fn) ~= "function" then
            return default
        end
        return fn(...)
    end
end

-- Forward to a backend function; raise an error if there is none.
local function action(name)
    AuctionClient[name] = function(...)
        local fn = backend and backend[name]
        if type(fn) ~= "function" then
            missing(name)
        end
        return fn(...)
    end
end

-- Capabilities: false without a backend function.
query("CanScan", false)
query("HasCommodityCheck", false)
query("CanReadOwned", false)
query("CanTargetSearch", false)
query("CanLiveSearch", false)

-- Event names: nil without a backend function.
query("ScanDoneEvent")
query("NameResultEvent")
query("OwnedEvent")
query("OpenEvent")
query("CloseEvent")
query("ReadyEvent")

-- Optional scan helpers: ScanCanStart() gives true, or false and a text; ScanSettleSeconds() and ScanComplete()
-- tell the engine when a multi-event scan is done; ScanDiagnostics(summary) gives a text line.
query("ScanDiagnostics")
query("ScanSettleSeconds")
query("ScanComplete")
query("ScanCanStart", true)

-- Scan modes: ScanModes() gives a list of names (nil means one scan, the default). ScanRefreshSeconds(mode) gives the
-- time that the engine refreshes missing links after the read.
query("ScanModes")
query("ScanRefreshSeconds")
-- Page scan: ScanPageQuery(page) sends one page query, CanQueryPage() tells if the client takes it, ScanTotal() gives
-- the number of auctions in the list.
query("ScanPageQuery")
query("CanQueryPage", false)
query("ScanTotal")

-- Live search (optional; absent on the legacy client). LiveSearch(itemID) gives true, or false and a text.
-- LiveResultEvents() gives the commodity and the item result event names. LiveRows(itemID) gives rows
-- { auctionID, unitPrice, quantity, isCommodity, ownerItem, timeLeft, itemLink } with the cheapest first.
-- IsReady() tells if a throttled call is allowed. RefreshOwned() asks for a fresh owned list.
query("LiveSearch", false)
query("LiveResultEvents")
query("LiveRows", {})
query("IsReady", true)
query("RefreshOwned")

-- Buy block. CanBuy() tells if the client can buy.
-- StartCommodityPurchase, ConfirmCommodityPurchase and BuyItemAuction are protected: call them only from a click.
-- CancelCommodityPurchase is not protected.
-- StartCommodityPurchase(itemID, quantity) asks for a quote; the quote event follows.
-- ConfirmCommodityPurchase(itemID, quantity) buys at the quote.
-- CancelCommodityPurchase() drops the quote. QuoteSecondsLeft() gives the time left of the quote.
-- BuyItemAuction(auctionID, buyout) buys one item auction at its buyout price.
-- BuyEvents() gives { priceUpdated, priceUnavailable, commoditySucceeded, commodityFailed,
-- itemCompleted, itemError }.
query("CanBuy", false)
query("QuoteSecondsLeft")
query("BuyEvents")
action("StartCommodityPurchase")
action("ConfirmCommodityPurchase")
action("CancelCommodityPurchase")
action("BuyItemAuction")

-- Posting (optional). The item is a bag slot. duration is in hours: 2, 8 or 24.
-- PostItem(bag, slot, duration, quantity, bid, buyout, itemID) (itemID is the planned item; the legacy backend refuses
-- a slot with another item, Forever ignores it) and PostCommodity(bag, slot, duration, quantity, unitPrice)
-- are protected: call them only inside a click handler. They give needsConfirmation (true or false); if it is true,
-- the confirm call with the same arguments finishes the post. Deposit(bag, slot, duration, quantity, isCommodity)
-- gives the deposit in copper or nil. AvailablePostCount(bag, slot) gives the number of posts of this item that the
-- client allows. IsSellItemValid(bag, slot) tells if the slot item can be posted. PostedEvent() gives the event name
-- that follows a post.
query("CanPost", false)
query("Deposit")
query("AvailablePostCount")
query("IsSellItemValid")
query("PostedEvent")

-- Search capture: nil means capture is off.
-- AuctionInfo(auctionID) gives a table with itemLink, buyoutAmount and maybe quantity, or nil.
query("AuctionInfo")

query("Capture")

-- Commodity flag of an item id: true, false, or nil if unknown.
query("ItemIsCommodity")

-- Calls that need a backend.
action("StartScan")
action("RowCount")
action("ReadRow")
action("RowLink")
action("RowIsPet")
action("NameSearch")
-- TargetedSearch(itemID, name): search the listings of one item. The capture stores the result.
action("TargetedSearch")
action("NameResults")
action("NameItemKeyInfo")
action("OwnedAuctions")
-- Protected post calls (see the posting block above).
action("PostItem")
action("PostCommodity")
action("ConfirmPostItem")
action("ConfirmPostCommodity")

-- Call listeners (the ledger). OnCall(fn) adds fn. The buy and post calls below tell each listener their name and
-- arguments before the backend call. A listener error never stops the call. This is a plain Lua wrap: no hook.
local listeners = {}

function AuctionClient.OnCall(fn)
    if type(fn) ~= "function" then
        error("listener must be a function", 2)
    end
    listeners[#listeners + 1] = fn
end

for _, name in ipairs({ "ConfirmCommodityPurchase", "BuyItemAuction", "PostItem", "PostCommodity",
    "ConfirmPostItem", "ConfirmPostCommodity" }) do
    local inner = AuctionClient[name]
    AuctionClient[name] = function(...)
        for _, fn in ipairs(listeners) do
            pcall(fn, name, ...)
        end
        return inner(...)
    end
end
