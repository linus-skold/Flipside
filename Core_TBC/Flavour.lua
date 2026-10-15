local _, ns = ...

-- TBC Anniversary flavour config. Shared code reads these values from ns.Flavour and never tests the id.
local function range(first, last)
    local list = {}
    for id = first, last do
        list[#list + 1] = id
    end
    return list
end

-- Client constants, with safe fallbacks if the client does not define them.
local function bagCount()
    return type(NUM_BAG_SLOTS) == "number" and NUM_BAG_SLOTS or 4
end

local function bankBagCount()
    return type(NUM_BANKBAGSLOTS) == "number" and NUM_BANKBAGSLOTS or 7
end

ns.Flavour = {
    id = "tbc",
    -- Placeholder: the real cooldown is not known until the TBC spike has run.
    scanCooldownSeconds = 900,
    ruleset = "tbc-anniversary",
    scopeIncludesRealm = true, -- D24
    captureEnabled = true,
    hasCommodityMarket = false, -- every listing is a stack with a stack buyout
    hasMailInvoices = false, -- the TBC invoice fields are not checked yet; only the mail headers are read
    -- Tab templates from the TBC client. Bottom tabs look like the Character and Auction House frame tabs.
    pageTabTemplate = "CharacterFrameTabButtonTemplate",
    topTabTemplate = "PanelTopTabButtonTemplate",
    -- TabButtonTemplate does not size to text on its own. The Kit sizes it: text + padding + 32 for the sides.
    topTabMinWidth = 40,
    savedVariables = { main = "FlipsideDB_TBC", scan = "FlipsideScanDB_TBC", ledger = "FlipsideLedgerDB_TBC" },
    -- Backpack and bag slots 0..NUM_BAG_SLOTS.
    bagIDs = function()
        return range(0, bagCount())
    end,
    -- The bank container, then the bank bag slots after the character bags.
    bankIDs = function()
        local list = { type(BANK_CONTAINER) == "number" and BANK_CONTAINER or -1 }
        for _, id in ipairs(range(bagCount() + 1, bagCount() + bankBagCount())) do
            list[#list + 1] = id
        end
        return list
    end,
}
