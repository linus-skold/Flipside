local _, ns = ...

local ScanKey = {}
ns.ScanKey = ScanKey

local Resolver = {}
Resolver.__index = Resolver

-- Calls a lookup in pcall and returns its first result, or nil on error.
local function SafeCall(fn, itemID)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, value = pcall(fn, itemID)
    if not ok then
        return nil
    end
    return value
end

-- Returns a key resolver. lookups.clientIsCommodity and lookups.maxStack are optional.
function ScanKey.New(lookups)
    lookups = lookups or {}
    return setmetatable({
        clientIsCommodity = lookups.clientIsCommodity,
        maxStack = lookups.maxStack,
        cache = {},
        stats = { client = 0, stack = 0, unknown = 0, mismatch = 0, linkFallback = 0 },
        unknownSeen = {},
        fallbackSeen = {},
    }, Resolver)
end

-- Returns isCommodity (true, false or nil) and the source: "client", "stack" or "unknown".
function Resolver:IsCommodity(itemID)
    local cached = self.cache[itemID]
    if cached then
        return cached.isCommodity, cached.source
    end

    local client = SafeCall(self.clientIsCommodity, itemID)
    if type(client) ~= "boolean" then
        client = nil
    end
    local stack = SafeCall(self.maxStack, itemID)
    local fromStack
    if type(stack) == "number" then
        fromStack = stack > 1
    end

    local isCommodity, source
    if client ~= nil then
        isCommodity, source = client, "client"
        if fromStack ~= nil and fromStack ~= client then
            self.stats.mismatch = self.stats.mismatch + 1
        end
    elseif fromStack ~= nil then
        isCommodity, source = fromStack, "stack"
    else
        if not self.unknownSeen[itemID] then
            self.unknownSeen[itemID] = true
            self.stats.unknown = self.stats.unknown + 1
        end
        return nil, "unknown"
    end

    if self.unknownSeen[itemID] then
        self.unknownSeen[itemID] = nil
        self.stats.unknown = self.stats.unknown - 1
    end
    self.stats[source] = self.stats[source] + 1
    self.cache[itemID] = { isCommodity = isCommodity, source = source }
    return isCommodity, source
end

-- Returns key, isCommodity or nil and a reason: "unknown", "no-link" or "link-mismatch".
-- If the commodity status is unknown, the exact key of the link is used and isCommodity is nil.
function Resolver:KeyFor(itemID, link)
    local ItemString = ns.ItemString
    local isCommodity = self:IsCommodity(itemID)
    if isCommodity == nil then
        local key = link ~= nil and ItemString.ToExactKey(link) or nil
        if not key then
            return nil, "unknown"
        end
        local parsed = ItemString.ParseLink(link)
        if not parsed or parsed.itemID ~= itemID then
            return nil, "link-mismatch"
        end
        if not self.fallbackSeen[itemID] then
            self.fallbackSeen[itemID] = true
            self.stats.linkFallback = self.stats.linkFallback + 1
        end
        return key, nil
    end
    if isCommodity then
        local key = ItemString.ToBaseKey(itemID)
        if not key then
            return nil, "no-link"
        end
        return key, true
    end
    local key = link ~= nil and ItemString.ToExactKey(link) or nil
    if not key then
        return nil, "no-link"
    end
    local parsed = ItemString.ParseLink(link)
    if not parsed or parsed.itemID ~= itemID then
        return nil, "link-mismatch"
    end
    return key, false
end

-- Returns a new table with the decision counts.
function Resolver:GetStats()
    local stats = self.stats
    return {
        client = stats.client, stack = stats.stack, unknown = stats.unknown, mismatch = stats.mismatch,
        linkFallback = stats.linkFallback,
    }
end

-- Returns true if the text holds a battle pet link.
function ScanKey.IsBattlePet(link)
    return type(link) == "string" and link:find("|Hbattlepet:", 1, true) ~= nil
end
