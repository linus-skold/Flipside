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
    self.parsed = {} -- text -> tree or false
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

function Sources:SetCustom(custom)
    self.custom = custom
end

function Sources:Status(name)
    local key = lowerName(name)
    local kind = self.kind[key]
    if not kind and key and self.custom and self.custom:Get(key) then
        return "custom"
    end
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

local MAX_NESTING = 8

-- Evaluates a custom source in the same ctx; a loop or deep nesting gives nil.
function Sources:_readCustom(key, ctx)
    local text = self.custom:Get(key)
    if not text then
        return nil
    end
    local stack = ctx._custom
    if not stack then
        stack = { depth = 0, active = {} }
        ctx._custom = stack
    end
    if stack.active[key] or stack.depth >= MAX_NESTING then
        return nil
    end
    local tree = self.parsed[text]
    if tree == nil then
        tree = ns.FormulaParse.Parse(text) or false
        self.parsed[text] = tree
    end
    if not tree then
        return nil
    end
    stack.active[key] = true
    stack.depth = stack.depth + 1
    local value = ns.FormulaEval.Evaluate(tree, function(inner)
        if inner == "invalid" then
            return nil
        end
        return self:Read(inner, ctx)
    end)
    stack.depth = stack.depth - 1
    stack.active[key] = nil
    return value
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
    elseif kind == nil and key and self.custom then
        return self:_readCustom(key, ctx)
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
