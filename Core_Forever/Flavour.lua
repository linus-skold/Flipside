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
    savedVariables = { main = "FlipsideDB", scan = "FlipsideScanDB", ledger = "FlipsideLedgerDB" },
    -- Bag and bank container ids; each call returns a new list.
    bagIDs = function()
        return range(0, 5)
    end,
    bankIDs = function()
        return range(6, 14)
    end,
}
