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
    scanCooldownSeconds = 900,
    ruleset = "standard",
    scopeIncludesRealm = false,
    captureEnabled = true,
    hasCommodityMarket = true, -- stackables trade as commodities (D15)
    savedVariables = { main = "FlipsideDB", scan = "FlipsideScanDB" },
    -- Bag and bank container ids; each call returns a new list.
    bagIDs = function()
        return range(0, 5)
    end,
    bankIDs = function()
        return range(6, 14)
    end,
}
