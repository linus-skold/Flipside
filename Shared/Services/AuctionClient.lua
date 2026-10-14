local _, ns = ...

-- The one door to the auction API. A flavour file registers a backend with Use(); shared code calls only this module.
-- Backend functions: StartScan, ScanDoneEvent, RowCount, ReadRow, RowLink, RowIsPet, ItemIsCommodity,
-- HasCommodityCheck, NameSearch, NameResultEvent, NameResults, NameItemKeyInfo, Capture, OwnedAuctions,
-- CanReadOwned, OwnedEvent, OpenEvent, CloseEvent, CanScan. A backend leaves out what its client cannot do.
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

-- Event names: nil without a backend function.
query("ScanDoneEvent")
query("NameResultEvent")
query("OwnedEvent")
query("OpenEvent")
query("CloseEvent")

-- Search capture: nil means capture is off.
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
action("NameResults")
action("NameItemKeyInfo")
action("OwnedAuctions")
