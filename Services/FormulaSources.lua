local _, ns = ...

-- Price source values for formulas: scan sources, vendor sell price and later sources.

local FormulaSources = {}
ns.FormulaSources = FormulaSources

FormulaSources.DOCS = {
    scanmin = { text = "Lowest buyout in the most recent scan." },
    scanrecent = { text = "Market value of the most recent scan only." },
    scanmarket = {
        text = "Average market value of the last 14 days. Newer days count more.",
    },
    scanhistorical = { text = "Average market value of the last 60 days. Every day counts the same." },
    scanqty = { text = "Number of units listed in the most recent scan." },
    scanage = { text = "Hours since the item was last seen in a scan." },
    scansamples = { text = "Number of days with scan data in the last 14 days." },
    vendorsell = { text = "Price that a vendor pays you for the item. Invalid if no vendor buys it." },
    vendorbuy = { text = "Price that a vendor charges for the item. Not available yet. It comes with vendoring." },
    avgbuy = { text = "Your average buy price from the ledger. Not available yet. It comes with the ledger." },
    avgsell = { text = "Your average sell price from the ledger. Not available yet. It comes with the ledger." },
    smartavgbuy = {
        text = "Your average buy price, weighted by recent buys. Not available yet. It comes with the ledger.",
    },
    minbuy = { text = "Your lowest buy price from the ledger. Not available yet. It comes with the ledger." },
    maxbuy = { text = "Your highest buy price from the ledger. Not available yet. It comes with the ledger." },
    minsell = { text = "Your lowest sell price from the ledger. Not available yet. It comes with the ledger." },
    maxsell = { text = "Your highest sell price from the ledger. Not available yet. It comes with the ledger." },
    crafting = { text = "Cost to craft the item. Not available yet. It comes with crafting in Phase 2." },
    matprice = { text = "Price of a crafting material. Not available yet. It comes with crafting in Phase 2." },
    destroy = { text = "Value of what you get when you destroy the item. Not available yet. It comes in Phase 3." },
    salerate = {
        text = "Share of your listings that sold. Not available yet. It comes with the ledger.",
    },
    importmarket = {
        text = "Market value from an optional imported file. Not available yet. It comes with the import feature.",
    },
    invalid = {
        text = "A value that means no price. A formula with a missing price is invalid. Missing never counts as 0.",
    },
    ["10g 5s 2c"] = {
        text = "Money. g is gold, s is silver, c is copper. A number with no unit is copper. Example: 12s70c.",
    },
    ["150%"] = {
        text = "Percent. 150% means 1.5 times. Example: scanmarket * 90%.",
    },
}
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
