local _, ns = ...

-- Price source values for formulas: scan sources, vendor sell price and later sources.

local FormulaSources = {}
ns.FormulaSources = FormulaSources

local LATER = {
    "vendorbuy", "avgbuy", "avgsell", "smartavgbuy", "minbuy", "maxbuy", "minsell",
    "maxsell", "crafting", "matprice", "destroy", "salerate", "importmarket",
}

local Sources = {}
Sources.__index = Sources

function FormulaSources.New(options)
    options = options or {}
    local self = setmetatable({}, Sources)
    self.itemCache = options.itemCache
    self.requested = {} -- itemID -> true
    self.kind = { vendorsell = "vendor" }
    self.field = {}
    for _, name in ipairs(ns.ScanSources.NAMES) do
        local key = name:lower()
        self.kind[key] = "scan"
        self.field[key] = ns.ScanSources.FIELD[name]
    end
    for _, name in ipairs(LATER) do
        self.kind[name] = "later"
    end
    return self
end

local function lowerName(name)
    return type(name) == "string" and name:lower() or nil
end

function Sources:Status(name)
    local kind = self.kind[lowerName(name)]
    if kind == "later" then
        return "later"
    end
    return kind and "available" or "unknown"
end

function Sources:_vendorSell(itemID)
    local cache = self.itemCache
    if not cache or type(itemID) ~= "number" then
        return nil
    end
    local info = cache:Get(itemID)
    if not info then
        if not self.requested[itemID] then
            self.requested[itemID] = true
            cache:Request(itemID)
        end
        return nil
    end
    local price = info.sellPrice
    if type(price) ~= "number" or price <= 0 then
        return nil
    end
    return price
end

function Sources:Read(name, ctx)
    local key = lowerName(name)
    local kind = self.kind[key]
    ctx = ctx or {}
    if kind == "scan" then
        if not ctx.record then
            return nil
        end
        if not ctx._scan then
            ctx._scan = ns.ScanSources.Compute(ctx.record, ctx.now)
        end
        return ctx._scan[self.field[key]]
    elseif kind == "vendor" then
        return self:_vendorSell(ctx.itemID)
    end
    return nil
end

function Sources:List()
    local list = {}
    for name, _ in pairs(self.kind) do
        list[#list + 1] = { name = name, status = self:Status(name) }
    end
    table.sort(list, function(a, b)
        return a.name < b.name
    end)
    return list
end
