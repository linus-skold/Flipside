local _, ns = ...

-- TBC Anniversary legacy auction backend: a stub for now.
-- The legacy scan, name search and owned auctions come in later pull requests.
-- Without them, CanScan is false, capture is off, and name search and owned reads are not available.
local Backend = {}

function Backend.OpenEvent()
    return "AUCTION_HOUSE_SHOW"
end

function Backend.CloseEvent()
    return "AUCTION_HOUSE_CLOSED"
end

ns.AuctionClient.Use(Backend)
