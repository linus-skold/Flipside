local _, ns = ...

-- The ledger record: the fields, the source and type lists, and the validation (SPEC 5.8). Pure.
local LedgerRecord = {}
ns.LedgerRecord = LedgerRecord

-- The record types. The type sets the view.
LedgerRecord.TYPES = { "sale", "purchase", "post", "income", "expense", "loot", "expired", "cancelled", "log" }

-- The sources, with the types that each source can have.
local SOURCE_TYPES = {
    ahSale = { sale = true },
    ahPurchase = { purchase = true },
    ahPost = { post = true },
    ahDeposit = { expense = true },
    ahDepositRefund = { income = true },
    ahOutbidRefund = { income = true },
    ahExpired = { expired = true },
    ahCancelled = { cancelled = true },
    loot = { loot = true },
    vendorSale = { income = true },
    vendorPurchase = { expense = true },
    repair = { expense = true },
    mailMoney = { income = true },
    trade = { income = true, expense = true },
    quest = { income = true },
    unknown = { income = true, expense = true },
}
LedgerRecord.SOURCE_TYPES = SOURCE_TYPES

local SOURCES = {}
for source in pairs(SOURCE_TYPES) do
    SOURCES[#SOURCES + 1] = source
end
table.sort(SOURCES)
LedgerRecord.SOURCES = SOURCES

local TYPE_SET = {}
for _, name in ipairs(LedgerRecord.TYPES) do
    TYPE_SET[name] = true
end

-- Money comes in for these types and goes out for the next two. Other types hold no money flow.
local MONEY_IN = { sale = true, income = true, loot = true }
local MONEY_OUT = { purchase = true, expense = true }

-- Returns "in", "out" or nil for a record type.
function LedgerRecord.Direction(recordType)
    if MONEY_IN[recordType] then
        return "in"
    elseif MONEY_OUT[recordType] then
        return "out"
    end
    return nil
end

-- The setting defaults of the ledger (account scope).
local DEFAULTS = {
    ["ledger.bufferCap"] = 500,
    ["ledger.hardLimit"] = 2000,
    ["ledger.retentionDays"] = 180,
    ["ledger.mobWindow"] = 60,
    ["ledger.logDays"] = 30,
    ["ledger.debug"] = false,
}

-- Returns a new table with the setting defaults.
function LedgerRecord.Defaults()
    local copy = {}
    for key, value in pairs(DEFAULTS) do
        copy[key] = value
    end
    return copy
end

local function isCount(value)
    return type(value) == "number" and value >= 0 and value % 1 == 0 and value < math.huge
end

local function isText(value)
    return type(value) == "string"
end

-- Field name -> check function. All fields except time, char, type and source are optional.
local CHECKS = {
    time = isCount,
    char = function(v)
        return isText(v) and v ~= ""
    end,
    type = function(v)
        return TYPE_SET[v] == true
    end,
    source = function(v)
        return SOURCE_TYPES[v] ~= nil
    end,
    item = isText,
    itemName = isText,
    qty = isCount,
    money = isCount,
    mob = isText,
    ctx = isText,
    fp = isText,
    invoiceType = isText,
    counterparty = isText,
    bid = isCount,
    buyout = isCount,
    deposit = isCount,
    cut = isCount,
    value = isCount,
}

-- Returns true, or false and a message.
function LedgerRecord.Validate(record)
    if type(record) ~= "table" then
        return false, "record must be a table"
    end
    for name in pairs(record) do
        if not CHECKS[name] then
            return false, "unknown field " .. tostring(name)
        end
    end
    for _, name in ipairs({ "time", "char", "type" }) do
        if record[name] == nil then
            return false, "missing field " .. name
        end
    end
    for name, check in pairs(CHECKS) do
        if record[name] ~= nil and not check(record[name]) then
            return false, "invalid field " .. name
        end
    end
    -- A log record has no source; the other types need one that fits.
    if record.type == "log" then
        if record.source ~= nil then
            return false, "a log record has no source"
        end
    else
        if record.source == nil then
            return false, "missing field source"
        end
        if not SOURCE_TYPES[record.source][record.type] then
            return false, "source " .. record.source .. " cannot have type " .. record.type
        end
    end
    if (record.qty or 0) > 0 and (record.item or "") == "" and (record.itemName or "") == "" then
        return false, "qty needs an item"
    end
    return true
end

-- Returns a new record with defaults (item "", qty 0, money 0, mob "unknown" for loot), or nil and a message.
function LedgerRecord.New(fields)
    if type(fields) ~= "table" then
        return nil, "record must be a table"
    end
    local record = {}
    for name, value in pairs(fields) do
        record[name] = value
    end
    record.item = record.item or ""
    record.qty = record.qty or 0
    record.money = record.money or 0
    if record.type == "loot" and (record.mob == nil or record.mob == "") then
        record.mob = "unknown"
    end
    local ok, message = LedgerRecord.Validate(record)
    if not ok then
        return nil, message
    end
    return record
end
