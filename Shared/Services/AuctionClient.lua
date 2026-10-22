local _, ns = ...

-- The one door to the auction API. A flavour file registers a backend with Use(); shared code calls only this module.
-- Backend functions: StartScan, ScanDoneEvent, RowCount, ReadRow, RowLink, RowIsPet, ItemIsCommodity,
-- HasCommodityCheck, NameSearch, TargetedSearch, NameResultEvent, NameResults, NameItemKeyInfo, Capture, OwnedAuctions,
-- CanReadOwned, OwnedEvent, OpenEvent, CloseEvent, CanScan, CanLiveSearch, LiveSearch, LiveResultEvents, LiveRows,
-- LivePageCount, SortedPaging, LiveOwnersPending, IsReady,
-- ReadyEvent, RefreshOwned, CanBuy, StartCommodityPurchase, ConfirmCommodityPurchase,
-- CancelCommodityPurchase, QuoteSecondsLeft, BuyItemAuction, BuyEvents, CanPost, PostItem, PostCommodity,
-- ConfirmPostItem, ConfirmPostCommodity, Deposit, AvailablePostCount, IsSellItemValid, PostedEvent,
-- MultisellEvent, CanSendPost, ThrottleEvents, AuctionInfo,
-- HookBid. A backend leaves out what its client
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
query("NameAddedEvent")
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
-- LiveSearch(itemID, page) takes an optional 0-based page (the legacy client only; Forever ignores it).
-- LivePageCount() gives the number of result pages of the last search, or nil if the client has no pages. LiveRows
-- then reads the page that the last search asked for.
query("LiveSearch", false)
query("LivePageCount")
-- SortedPaging() is true if the last search gave the pages cheapest first, so page 1 holds the cheapest auctions.
-- LiveOwnersPending() is true if a row of the last result has no seller name yet (the client gives it late).
query("SortedPaging", false)
query("LiveOwnersPending", false)
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
-- HookBid(hook, handler) installs the read-only bid post-hook of the ledger and gives the hooked name, or nil.
query("HookBid")
action("StartCommodityPurchase")
action("ConfirmCommodityPurchase")
action("CancelCommodityPurchase")
action("BuyItemAuction")

-- Posting (optional). The item is a bag slot. duration is in hours of the flavour (2, 8 or 24; TBC 12, 24 or 48).
-- PostItem(bag, slot, duration, quantity, bid, buyout, itemID, guard, numStacks) (numStacks is the number of stacks
-- of quantity items, legacy client only, default 1; the bid and the buyout are for one stack; itemID is the planned
-- item; the legacy backend refuses a slot with another item, Forever ignores it. guard(deposit) is optional: the
-- legacy backend calls it with
-- the real deposit before it posts, and if it gives false the backend posts nothing and gives "held", deposit.
-- Forever ignores guard) and PostCommodity(bag, slot, duration, quantity, unitPrice)
-- are protected: call them only inside a click handler. They give needsConfirmation (true or false); if it is true,
-- the confirm call with the same arguments finishes the post. Deposit(bag, slot, duration, quantity, isCommodity)
-- gives the deposit in copper or nil. AvailablePostCount(bag, slot) gives the number of posts of this item that the
-- client allows. IsSellItemValid(bag, slot) tells if the slot item can be posted. PostedEvent() gives the event name
-- that follows a post.
query("CanPost", false)
query("Deposit")
-- HoldSlot(bag, slot, quantity, itemID, numStacks) is optional (legacy client). It puts the item in the sale slot and
-- keeps it there: Deposit then gives the real deposit with no new fill. It gives true, or false and a text.
-- ReleaseSlot() puts the sale slot item back in its bag slot and gives true if the slot is empty after the call.
-- Both are protected: call them from a click.
query("HoldSlot")
query("ReleaseSlot")
query("AvailablePostCount")
query("IsSellItemValid")
query("PostedEvent")
-- MultisellEvent() gives the event name of a multi-stack post (legacy client only). The event carries "start",
-- "update" or "failure", the number of stacks created, the total, and for a failure a text.
query("MultisellEvent")
-- CanSendPost() tells if the client takes a post now (the throttle gate); it is true without a backend function.
-- ThrottleEvents() gives the list of events after which the gate can change; nil means the client has none, so the
-- caller polls CanSendPost.
query("CanSendPost", true)
query("ThrottleEvents")

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
