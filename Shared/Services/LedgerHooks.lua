local _, ns = ...

-- The read-only post-hooks of the ledger (SPEC 5.8, decided 2026-10-17 by the user). This is the complete list:
-- SendMail, BuyMerchantItem, and the bid call of the Auction House (the flavour backend installs that one, D23).
-- Each hook runs after the client call. It only reads data, runs inside a pcall, and calls no protected function.
-- A hook that fails does nothing and never changes the client call.
local LedgerHooks = {}
ns.LedgerHooks = LedgerHooks

-- Wrap a handler so that an error in it stays inside the hook.
local function safe(handler)
    return function(...)
        pcall(handler, ...)
    end
end

-- deps: hook (hooksecurefunc), globals (_G), report(message) (optional), hookBid(hook, handler) (the backend hook of
-- the bid call) and the handlers: onSendMail(recipient), onBuyMerchantItem(index, quantity), onBid(auctionID).
-- A hook is installed only if its function exists. Returns the list of installed hook names.
function LedgerHooks.Install(deps)
    local installed = {}
    local globals = deps.globals

    local function install(name, handler)
        if type(deps.hook) ~= "function" or type(globals[name]) ~= "function" or type(handler) ~= "function" then
            return
        end
        local ok, err = pcall(deps.hook, globals, name, safe(handler))
        if ok then
            installed[#installed + 1] = name
        elseif deps.report then
            deps.report("ledger hook " .. name .. " failed: " .. tostring(err))
        end
    end

    install("SendMail", deps.onSendMail)
    install("BuyMerchantItem", deps.onBuyMerchantItem)
    -- The bid hook belongs to the flavour backend, because it names the auction API. hookBid(hook, handler) gives
    -- the hooked name or nil.
    if type(deps.hookBid) == "function" and type(deps.onBid) == "function" and type(deps.hook) == "function" then
        local ok, name = pcall(deps.hookBid, deps.hook, safe(deps.onBid))
        if ok and name then
            installed[#installed + 1] = name
        elseif not ok and deps.report then
            deps.report("ledger bid hook failed: " .. tostring(name))
        end
    end
    return installed
end
