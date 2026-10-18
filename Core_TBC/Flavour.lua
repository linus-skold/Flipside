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
    -- Auction durations in hours for the index 1, 2 and 3 (Blizzard_AuctionUI Classic: 12, 24 and 48 hours).
    durations = { 12, 24, 48 },
    -- The default post duration in hours (an operation, the manual post).
    defaultDuration = 24,
    -- The hours that older versions saved for the same indexes. The settings migration maps them to durations.
    legacyDurations = { 2, 8, 24 },
    -- Placeholder: the real cooldown is not known until the TBC spike has run.
    scanCooldownSeconds = 900,
    ruleset = "tbc-anniversary",
    scopeIncludesRealm = true, -- D24
    captureEnabled = true,
    hasCommodityMarket = false, -- every listing is a stack with a stack buyout
    multisell = true, -- PostAuction posts several stacks in one click; the operation has the Max stacks field
    hasMailInvoices = true, -- GetInboxInvoiceInfo has the Forever field order (classic_anniversary MailFrame.lua 514)
    ledgerRealmFilter = true, -- the Ledger page has a server and character filter (mail does not cross servers)
    -- Tab templates from the TBC client. Bottom tabs look like the Character and Auction House frame tabs.
    pageTabTemplate = "CharacterFrameTabButtonTemplate",
    topTabTemplate = "PanelTopTabButtonTemplate",
    -- TabButtonTemplate does not size to text on its own. The Kit sizes it: text + padding + 32 for the sides.
    topTabMinWidth = 40,
    -- Selling: Post stays off until the post result came and this many seconds passed. The client refuses fast posts.
    postDelay = 1.0,
    -- Seconds after which Post comes back even with no result.
    postTimeout = 5,
    -- Mailing send run (SPEC 5.5). SendMail takes three arguments in the TBC UI.
    sendMailArgs = 3,
    -- Seconds to wait after BAG_UPDATE_DELAYED before the next mail (confirmed in game: 0.5 works).
    mailDelay = 0.5,
    -- Seconds to wait for BAG_UPDATE_DELAYED after a mail before the run goes on.
    mailBagWait = 5,
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
