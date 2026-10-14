local _, ns = ...

local OperationSchema = {}
ns.OperationSchema = OperationSchema

local DEFAULT_MIN = "check(first(crafting, scanmarket), "
    .. "max(0.25 * avg(crafting, scanmarket, scanhistorical), 1.5 * vendorsell))"

OperationSchema.TYPES = { "selling", "buying", "vendoring" }

local LABELS = { selling = "Selling", buying = "Buying", vendoring = "Vendoring" }

local SAFETY = {
    {
        key = "maxDataAgeHours", label = "Max data age (hours)", kind = "number",
        default = 72, min = 1, max = 720,
        help = "Skip items whose price data is older than this.",
    },
    {
        key = "minSamples", label = "Min samples", kind = "number",
        default = 3, min = 1, max = 60,
        help = "Skip items with fewer price samples than this.",
    },
}

local FIELDS = {
    selling = {
        {
            key = "minPrice", label = "Minimum price", kind = "formula", default = DEFAULT_MIN,
            help = "Never post below this price.",
        },
        {
            key = "normalPrice", label = "Normal price", kind = "formula", default = "scanmarket",
            help = "The price to post at when there is no competition.",
        },
        {
            key = "maxPrice", label = "Maximum price", kind = "formula", default = "2 * scanmarket",
            help = "Never post above this price.",
        },
        {
            key = "undercut", label = "Undercut", kind = "money", default = 1, min = 0, max = 1000000,
            help = "The amount in copper to go below the lowest auction.",
        },
        {
            key = "duration", label = "Duration", kind = "choice", default = 24,
            choices = {
                { value = 12, label = "12 hours" },
                { value = 24, label = "24 hours" },
                { value = 48, label = "48 hours" },
            },
            help = "How long each auction runs.",
        },
        {
            key = "postCap", label = "Post cap", kind = "number", default = 0, min = 0, max = 5000,
            help = "The most auctions to post for each item. 0 means no cap.",
        },
        {
            key = "stackSize", label = "Stack size", kind = "number", default = 0, min = 0, max = 1000,
            help = "Units in each auction. 0 means a full stack. The client limit caps it.",
        },
        {
            key = "keepInBags", label = "Keep in bags", kind = "number", default = 0, min = 0, max = 10000,
            help = "This many of each item stay in your bags; the rest can be sold.",
        },
        {
            key = "belowMin", label = "Below minimum", kind = "choice", default = "skip",
            choices = {
                { value = "skip", label = "Skip the item" },
                { value = "postAtMin", label = "Post at minimum" },
            },
            help = "What to do when the market is below the minimum price.",
        },
        {
            key = "aboveMax", label = "Above maximum", kind = "choice", default = "postAtMax",
            choices = {
                { value = "postAtMax", label = "Post at maximum" },
                { value = "postAtNormal", label = "Post at normal" },
            },
            help = "What to do when the market is above the maximum price.",
        },
        {
            key = "cancelUndercut", label = "Cancel undercut", kind = "bool", default = true,
            help = "Cancel your auctions when another seller undercuts them.",
        },
    },
    buying = {
        {
            key = "maxPrice", label = "Maximum price", kind = "formula", default = "scanmarket",
            help = "Never buy above this price.",
        },
        {
            key = "showAboveMax", label = "Show above maximum", kind = "bool", default = false,
            help = "Also list auctions that cost more than the maximum.",
        },
    },
    vendoring = {
        {
            key = "sellToVendor", label = "Sell to vendor", kind = "bool", default = false,
            help = "Sell matching items to a vendor.",
        },
        {
            key = "keepInBags", label = "Keep in bags", kind = "number", default = 0, min = 0, max = 10000,
            help = "This many of each item stay in your bags; the rest can be sold to a vendor.",
        },
        {
            key = "safetyMultiple", label = "Safety multiple", kind = "number", default = 2, min = 1, max = 100,
            help = "List for review items that sell for more than this multiple of the vendor price.",
        },
    },
}

local LISTS = {}
for type, own in pairs(FIELDS) do
    local list = {}
    for _, f in ipairs(own) do
        list[#list + 1] = f
    end
    for _, f in ipairs(SAFETY) do
        list[#list + 1] = f
    end
    LISTS[type] = list
end

function OperationSchema.TypeLabel(type)
    return LABELS[type]
end

function OperationSchema.Fields(type)
    local list = LISTS[type]
    if not list then
        error("unknown operation type: " .. tostring(type), 2)
    end
    return list
end

function OperationSchema.Defaults(type)
    local out = {}
    for _, f in ipairs(OperationSchema.Fields(type)) do
        out[f.key] = f.default
    end
    return out
end

function OperationSchema.Normalize(type, settings)
    local out = {}
    for k, v in pairs(settings or {}) do
        out[k] = v
    end
    for _, f in ipairs(OperationSchema.Fields(type)) do
        if out[f.key] == nil then
            out[f.key] = f.default
        end
    end
    return out
end

local function checkField(f, value, compile)
    local kind = f.kind
    if kind == "formula" then
        if type(value) ~= "string" or value:match("^%s*$") then
            return false, "Enter a formula."
        end
        local compiled, err = compile(value)
        if not compiled then
            local msg = (type(err) == "table" and err.message) or tostring(err)
            local pos = type(err) == "table" and err.pos
            if pos then
                msg = msg .. " (at position " .. tostring(pos) .. ")"
            end
            return false, msg
        end
        return true
    elseif kind == "money" or kind == "number" then
        if type(value) ~= "number" or value ~= math.floor(value) or value ~= value then
            return false, "Enter a whole number."
        end
        if value < f.min or value > f.max then
            return false, "Enter a number from " .. f.min .. " to " .. f.max .. "."
        end
        return true
    elseif kind == "choice" then
        for _, c in ipairs(f.choices) do
            if c.value == value then
                return true
            end
        end
        return false, "Choose one of the listed values."
    elseif kind == "bool" then
        if type(value) ~= "boolean" then
            return false, "Enter yes or no."
        end
        return true
    end
    return false, "Unknown field kind."
end

function OperationSchema.ValidateField(type, key, value, compile)
    for _, f in ipairs(OperationSchema.Fields(type)) do
        if f.key == key then
            return checkField(f, value, compile)
        end
    end
    return false, "Unknown field."
end

function OperationSchema.Validate(type, settings, compile)
    settings = settings or {}
    local errors, ok = {}, true
    for _, f in ipairs(OperationSchema.Fields(type)) do
        local good, msg = checkField(f, settings[f.key], compile)
        if not good then
            ok = false
            errors[f.key] = msg
        end
    end
    return ok, errors
end
