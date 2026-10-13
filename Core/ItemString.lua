local _, ns = ...

local ItemString = {}
ns.ItemString = ItemString

-- Names of the leading fields, in link order. Field 1 is the item id.
local FIELD_NAMES = {
    "itemID", "enchantID", "gemID1", "gemID2", "gemID3", "gemID4", "suffixID",
    "uniqueID", "linkLevel", "specializationID", "upgradeTypeID", "instanceDifficultyID",
}
local SUFFIX_INDEX = 7
local COUNT_INDEX = #FIELD_NAMES + 1

-- Splits text on colons and keeps empty fields.
local function Split(text)
    local parts = {}
    local pos = 1
    while true do
        local stop = text:find(":", pos, true)
        if not stop then
            parts[#parts + 1] = text:sub(pos)
            return parts
        end
        parts[#parts + 1] = text:sub(pos, stop - 1)
        pos = stop + 1
    end
end

-- Converts a field to a number. Empty is 0. Returns nil if the field is invalid.
local function ToNumber(field, allowNegative)
    if field == "" then
        return 0
    end
    if field:match("^%d+$") or (allowNegative and field:match("^%-%d+$")) then
        return tonumber(field)
    end
    return nil
end

-- Returns the field text of the first item link in a string, or nil.
local function GetBody(text)
    local start
    if text:sub(1, 5) == "item:" then
        start = 6
    else
        local at = text:find("|Hitem:", 1, true)
        if not at then
            return nil
        end
        start = at + 7
    end
    return text:match("^[^|]*", start)
end

local function ParseBody(body)
    local fields = Split(body)
    local result = {}
    for i, name in ipairs(FIELD_NAMES) do
        local value = ToNumber(fields[i] or "", i == SUFFIX_INDEX)
        if not value then
            return nil
        end
        result[name] = value
    end
    if result.itemID < 1 then
        return nil
    end

    local count = ToNumber(fields[COUNT_INDEX] or "")
    if not count then
        return nil
    end
    local bonusIDs = {}
    local last = math.min(COUNT_INDEX + count, #fields)
    for i = COUNT_INDEX + 1, last do
        local value = ToNumber(fields[i])
        if not value then
            return nil
        end
        bonusIDs[#bonusIDs + 1] = value
    end
    result.bonusIDs = bonusIDs

    local extra = {}
    for i = last + 1, #fields do
        extra[#extra + 1] = fields[i]
    end
    while #extra > 0 and extra[#extra] == "" do
        extra[#extra] = nil
    end
    result.extra = extra
    return result
end

-- Returns a table of item fields, or nil if the input is not an item.
function ItemString.ParseLink(input)
    local kind = type(input)
    if kind == "number" then
        if input >= 1 and input % 1 == 0 and input ~= math.huge then
            return ParseBody(string.format("%d", input))
        end
        return nil
    end
    if kind ~= "string" then
        return nil
    end
    if input:match("^%d+$") then
        return ParseBody(input)
    end
    local body = GetBody(input)
    if not body then
        return nil
    end
    return ParseBody(body)
end

-- Returns true if the string holds an item link or starts with "item:".
function ItemString.IsItemLink(input)
    if type(input) ~= "string" or input:match("^%d+$") then
        return false
    end
    return ItemString.ParseLink(input) ~= nil
end
