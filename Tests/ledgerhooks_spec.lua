local manifest = require("Tests.manifest")

describe("LedgerHooks", function()
    local ns, hooked, globals, seen, reports

    -- hooksecurefunc(table, name, fn): the post-hook wraps the function and calls fn after it.
    local function hook(target, name, fn)
        hooked[#hooked + 1] = { target = target, name = name }
        local original = target[name]
        target[name] = function(...)
            local results = { original(...) }
            fn(...)
            return unpack(results)
        end
    end

    local function install(overrides)
        local deps = {
            hook = hook,
            globals = globals,
            report = function(message)
                reports[#reports + 1] = message
            end,
            onSendMail = function(...)
                seen[#seen + 1] = { "mail", ... }
            end,
            onBuyMerchantItem = function(...)
                seen[#seen + 1] = { "buy", ... }
            end,
            onBid = function(...)
                seen[#seen + 1] = { "bid", ... }
            end,
            -- The backend names the bid function; this fake hooks PlaceBid on the table that it owns.
            hookBid = function(hookFn, handler)
                hookFn(globals.C_Bid, "PlaceBid", function(auctionID)
                    handler(auctionID)
                end)
                return "bid"
            end,
        }
        for name, value in pairs(overrides or {}) do
            deps[name] = value
        end
        return ns.LedgerHooks.Install(deps)
    end

    before_each(function()
        ns = {}
        assert(loadfile(manifest.path("LedgerHooks")))("Flipside", ns)
        hooked, seen, reports = {}, {}, {}
        globals = {
            SendMail = function() end,
            BuyMerchantItem = function() end,
            C_Bid = { PlaceBid = function() end },
        }
    end)

    it("installs exactly the three global hooks and the bid hook of the backend", function()
        local installed = install()
        assert.are.same({ "SendMail", "BuyMerchantItem", "bid" }, installed)
        assert.are.equal(3, #hooked)
    end)

    it("installs only the hooks whose function exists", function()
        globals.BuyMerchantItem = nil
        assert.are.same({ "SendMail", "bid" }, install())
    end)

    it("calls the handler after the client call with the same arguments", function()
        install()
        globals.SendMail("Bank", "Subject", "Body")
        globals.BuyMerchantItem(3, 20)
        globals.C_Bid.PlaceBid(77, 500)
        assert.are.same({ "mail", "Bank", "Subject", "Body" }, seen[1])
        assert.are.same({ "buy", 3, 20 }, seen[2])
        assert.are.same({ "bid", 77 }, seen[3])
    end)

    it("keeps an error of the bid handler inside the hook", function()
        install({
            onBid = function()
                error("boom")
            end,
        })
        assert.has_no.errors(function()
            globals.C_Bid.PlaceBid(77, 500)
        end)
    end)

    it("installs no bid hook without a backend hook function", function()
        assert.are.same({ "SendMail", "BuyMerchantItem" }, install({ hookBid = false }))
    end)

    it("keeps an error of a handler inside the hook", function()
        install({
            onSendMail = function()
                error("boom")
            end,
        })
        assert.has_no.errors(function()
            globals.SendMail("Bank")
        end)
    end)

    it("keeps the result of the client call", function()
        globals.BuyMerchantItem = function()
            return "result"
        end
        install()
        assert.are.equal("result", globals.BuyMerchantItem(1))
    end)

    it("reports a hook that cannot be installed and goes on", function()
        local installed = install({
            hook = function(_, name)
                error("no " .. name)
            end,
        })
        assert.are.same({}, installed)
        assert.are.equal(3, #reports)
    end)

    it("installs nothing without a hook function or without a handler", function()
        assert.are.same({}, install({ hook = false }))
        assert.are.same({ "SendMail" }, install({ onBuyMerchantItem = false, onBid = false }))
    end)
end)
