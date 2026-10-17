local _, ns = ...

-- Forever flavour config. Shared code reads these values from ns.Flavour and never tests the id.
local function range(first, last)
    local list = {}
    for id = first, last do
        list[#list + 1] = id
    end
    return list
end

ns.Flavour = {
    id = "forever",
    -- Auction durations in hours for the index 1, 2 and 3.
    durations = { 2, 8, 24 },
    -- The default post duration in hours (an operation, the manual post).
    defaultDuration = 24,
    scanCooldownSeconds = 900,
    ruleset = "standard",
    scopeIncludesRealm = false,
    captureEnabled = true,
    hasCommodityMarket = true, -- stackables trade as commodities (D15)
    hasMailInvoices = true, -- GetInboxInvoiceInfo is read-only; the field order is checked in the Forever source
    -- Tab templates. The Forever tab templates size to text on their own.
    pageTabTemplate = "PanelTabButtonTemplate",
    topTabTemplate = "PanelTopTabButtonTemplate",
    -- Selling: Post stays off until the post result came and this many seconds passed. Not tested in game: tune it.
    postDelay = 0.5,
    -- Seconds after which Post comes back even with no result.
    postTimeout = 5,
    -- Mailing send run (SPEC 5.5). SendMail takes four arguments in the Forever UI (the last is the reply mail id).
    sendMailArgs = 4,
    -- Seconds to wait after BAG_UPDATE_DELAYED before the next mail. Not tested in game on Forever: tune it here.
    mailDelay = 0.5,
    -- Seconds to wait for BAG_UPDATE_DELAYED after a mail before the run goes on.
    mailBagWait = 5,
    savedVariables = { main = "FlipsideDB", scan = "FlipsideScanDB", ledger = "FlipsideLedgerDB" },
    -- Bag and bank container ids; each call returns a new list.
    bagIDs = function()
        return range(0, 5)
    end,
    bankIDs = function()
        return range(6, 14)
    end,
}
