local _, ns = ...

local OperationSchema = {}
ns.OperationSchema = OperationSchema

local DEFAULT_MIN = "check(first(crafting, scanmarket), "
    .. "max(0.25 * avg(crafting, scanmarket, scanhistorical), 1.5 * vendorsell))"

-- The post durations in hours: 2, 8 and 24 on WoW: Forever, 12, 24 and 48 on TBC (ns.Flavour.durations).
local DURATIONS = ns.Flavour and ns.Flavour.durations or { 2, 8, 24 }
local DEFAULT_DURATION = ns.Flavour and ns.Flavour.defaultDuration or 24

-- TBC posts several stacks per click (ns.Flavour.multisell): the selling operation has a stack size and a stack count.
local MULTISELL = ns.Flavour ~= nil and ns.Flavour.multisell == true

OperationSchema.TYPES = { "selling", "buying", "vendoring", "mailing" }

-- The built-in selling operation: price 1c under the lowest auction, vendor price as the floor, no scan data needed.
OperationSchema.DEFAULT_SELLING_NAME = "Default"
OperationSchema.VENDOR_FLOOR = "first(vendorsell, 1)"
OperationSchema.DEFAULT_BUYING_NAME = "Default"

local LABELS = { selling = "Selling", buying = "Buying", vendoring = "Vendoring", mailing = "Mailing" }

-- The item rarities (quality 0 to 5) of both clients.
local QUALITIES = {
    { value = 0, label = "Poor" },
    { value = 1, label = "Common" },
    { value = 2, label = "Uncommon" },
    { value = 3, label = "Rare" },
    { value = 4, label = "Epic" },
    { value = 5, label = "Legendary" },
}

-- Epic is the highest rarity of a mailing operation: Legendary items never go by mail.
local MAIL_MAX_QUALITY = 4
local MAIL_QUALITIES = {}
for index = 1, MAIL_MAX_QUALITY + 1 do
    MAIL_QUALITIES[index] = QUALITIES[index]
end

local SAFETY = {
    {
        key = "maxDataAgeHours", label = "Max data age (hours)", kind = "number",
        default = 72, min = 1, max = 720,
        help = "Skip items whose price data is older than this.",
    },
    {
        key = "minSamples", label = "Min samples", kind = "number",
        default = 3, min = 1, max = 60,
        help = "With fewer samples, the price comes from the cheapest listing, not from the market value.",
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
            key = "duration", label = "Post duration", kind = "choice", default = DEFAULT_DURATION,
            choices = {
                { value = DURATIONS[1], label = DURATIONS[1] .. " hours" },
                { value = DURATIONS[2], label = DURATIONS[2] .. " hours" },
                { value = DURATIONS[3], label = DURATIONS[3] .. " hours" },
            },
            help = "How long each auction runs. The Auction House offers these three values.",
        },
        {
            key = "postCap", label = "Post quantity", kind = "number", default = 0, min = 0, max = 5000,
            help = "The most to have on the AH for each item: auctions for an item, "
                .. "units for a commodity. 0 means no cap.",
        },
        {
            key = "stackSize", label = MULTISELL and "Stack size" or "Max stack size", kind = "number", default = 0,
            min = 0, max = 1000,
            help = MULTISELL and "The units in each stack. 0 means the item maximum (a full stack)."
                or "The most units in one item auction. 0 means a full stack. The client limit caps it. "
                .. "A commodity has no stack, so this does nothing for it.",
        },
        {
            key = "keepInBags", label = "Keep quantity", kind = "number", default = 0, min = 0, max = 10000,
            help = "This many of each item stay in your bags. They are never posted.",
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
            key = "vendorSkip", label = "Skip if vendor pays more", kind = "bool", default = true,
            help = "Skip an item when its vendor sell price is higher than the net of the auction "
                .. "(after cut and deposit).",
        },
        {
            key = "cancelUndercut", label = "Cancel undercut", kind = "bool", default = true,
            help = "Cancel your auctions when another seller undercuts them.",
        },
        {
            key = "needScanData", label = "Needs scan data", kind = "bool", default = true,
            help = "On: skip items with old or thin scan data. Off: skip no item for its data, "
                .. "and a missing normal or maximum price does not stop the post.",
        },
    },
    buying = {
        {
            key = "maxPrice", label = "Maximum price", kind = "formula", default = "scanmarket", optional = true,
            help = "Never buy above this price. Empty means no limit.",
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
    mailing = {
        {
            key = "recipient", label = "Recipient", kind = "text", default = "", maxLength = 64,
            help = "The character that gets the mail. Use Name or Name-Realm.",
        },
        {
            key = "keep", label = "Keep in bags", kind = "number", default = 0, min = 0, max = 10000,
            help = "This many of each item stay in your bags. 0 means send all.",
        },
        {
            key = "maxSend", label = "Send up to", kind = "number", default = 0, min = 0, max = 100000,
            help = "The most units of each item to send in one run. 0 means no limit.",
        },
        {
            key = "minQuality", label = "Lowest rarity", kind = "choice", default = 0,
            choices = MAIL_QUALITIES, quality = true,
            help = "Send only items of this rarity or better.",
        },
        {
            key = "maxQuality", label = "Highest rarity", kind = "choice", default = MAIL_MAX_QUALITY,
            choices = MAIL_QUALITIES, quality = true,
            help = "Send only items of this rarity or worse. Legendary items are never sent.",
        },
        {
            key = "itemClasses", label = "Item types", kind = "classes", default = "", maxLength = 200,
            help = "Send only items of the chosen types. None chosen means any type.",
        },
    },
}

-- Only the TBC selling operation has the Max stacks field: a commodity has no stacks.
if MULTISELL then
    for index, f in ipairs(FIELDS.selling) do
        if f.key == "stackSize" then
            table.insert(FIELDS.selling, index + 1, {
                key = "maxStacks", label = "Max stacks", kind = "number", default = 0, min = 0, max = 1000,
                help = "The most stacks to post for one item. 0 means all the full stacks in your bags. "
                    .. "The rest, less than a full stack, posts as one smaller stack (only when this is 0).",
            })
            break
        end
    end
end

local LISTS = {}
for type, own in pairs(FIELDS) do
    local list = {}
    for _, f in ipairs(own) do
        list[#list + 1] = f
    end
    -- A mailing operation reads no prices, so it has no safety fields.
    if type ~= "mailing" then
        for _, f in ipairs(SAFETY) do
            list[#list + 1] = f
        end
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

-- Returns the settings of the built-in selling operation.
function OperationSchema.DefaultSellingSettings()
    local settings = OperationSchema.Defaults("selling")
    settings.undercut = 1
    settings.minPrice = OperationSchema.VENDOR_FLOOR
    settings.needScanData = false
    return settings
end

-- Returns the settings of the built-in buying operation: no maximum price.
function OperationSchema.DefaultBuyingSettings()
    local settings = OperationSchema.Defaults("buying")
    settings.maxPrice = ""
    return settings
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
    -- An old mailing save can hold Legendary (5): clamp it to Epic.
    if type == "mailing" then
        for _, key in ipairs({ "minQuality", "maxQuality" }) do
            if tonumber(out[key]) and tonumber(out[key]) > MAIL_MAX_QUALITY then
                out[key] = MAIL_MAX_QUALITY
            end
        end
    end
    return out
end

local function checkField(f, value, compile)
    local kind = f.kind
    if kind == "formula" then
        if f.optional and type(value) == "string" and value:match("^%s*$") then
            return true
        end
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
    elseif kind == "text" then
        if type(value) ~= "string" or value:match("^%s*$") then
            return false, "Enter a character name."
        end
        if #value > f.maxLength then
            return false, "Enter at most " .. f.maxLength .. " characters."
        end
        return true
    elseif kind == "classes" then
        if type(value) ~= "string" or #value > f.maxLength or (value ~= "" and not value:match("^%d+[%d,]*$")) then
            return false, "Choose item types from the list."
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
