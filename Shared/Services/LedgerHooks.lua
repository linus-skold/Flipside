local _, ns = ...

-- The read-only post-hooks of the ledger (SPEC 5.8, decided 2026-10-17 by the user). This is the complete list:
-- SendMail, BuyMerchantItem, C_AuctionHouse.PlaceBid (Forever) and PlaceAuctionBid (TBC).
-- Each hook runs after the client call. It only reads data, runs inside a pcall, and calls no protected function.
-- A hook that fails does nothing and never changes the client call.
local LedgerHooks = {}
ns.LedgerHooks = LedgerHooks

-- The names of the hooked functions. A test checks that no other function is hooked.
LedgerHooks.HOOKED = { "SendMail", "BuyMerchantItem", "C_AuctionHouse.PlaceBid", "PlaceAuctionBid" }

-- Wrap a handler so that an error in it stays inside the hook.
local function safe(handler)
    return function(...)
        pcall(handler, ...)
    end
end

-- deps: hook (hooksecurefunc), globals (_G), report(message) (optional), and the handlers:
-- onSendMail(recipient), onBuyMerchantItem(index, quantity), onBid(auctionID, bidAmount, isLegacy).
-- A hook is installed only if its function exists. Returns the list of installed hook names.
function LedgerHooks.Install(deps)
    local installed = {}
    local globals = deps.globals

    local function install(label, target, name, handler)
        if type(deps.hook) ~= "function" or type(target) ~= "table" or type(target[name]) ~= "function"
            or type(handler) ~= "function" then
            return
        end
        local ok, err = pcall(deps.hook, target, name, safe(handler))
        if ok then
            installed[#installed + 1] = label
        elseif deps.report then
            deps.report("ledger hook " .. label .. " failed: " .. tostring(err))
        end
    end

    install("SendMail", globals, "SendMail", deps.onSendMail)
    install("BuyMerchantItem", globals, "BuyMerchantItem", deps.onBuyMerchantItem)
    install("C_AuctionHouse.PlaceBid", globals.C_AuctionHouse, "PlaceBid", deps.onBid and function(auctionID, bid)
        deps.onBid(auctionID, bid, false)
    end or nil)
    install("PlaceAuctionBid", globals, "PlaceAuctionBid", deps.onBid and function(listType, index, bid)
        if listType == "list" then
            deps.onBid(index, bid, true)
        end
    end or nil)
    return installed
end
