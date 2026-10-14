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

-- Returns item id, suffix id and a sorted copy of the bonus ids, or nil.
local function Resolve(input)
    local fields = input
    if type(input) ~= "table" then
        fields = ItemString.ParseLink(input)
    end
    if type(fields) ~= "table" then
        return nil
    end
    local itemID, suffixID, bonusIDs = fields.itemID, fields.suffixID or 0, fields.bonusIDs or {}
    if type(itemID) ~= "number" or itemID < 1 or itemID % 1 ~= 0 or itemID == math.huge then
        return nil
    end
    if type(suffixID) ~= "number" or suffixID % 1 ~= 0 or suffixID == math.huge or suffixID == -math.huge then
        return nil
    end
    if type(bonusIDs) ~= "table" then
        return nil
    end
    local sorted = {}
    for i, id in ipairs(bonusIDs) do
        if type(id) ~= "number" or id < 0 or id % 1 ~= 0 or id == math.huge then
            return nil
        end
        sorted[i] = id
    end
    table.sort(sorted)
    return itemID, suffixID, sorted
end

-- Returns the item id in decimal, or nil if the input is not an item.
function ItemString.ToBaseKey(input)
    local itemID = Resolve(input)
    if not itemID then
        return nil
    end
    return string.format("%d", itemID)
end

-- Returns the item id, suffix id and bonus ids as one key, or nil.
function ItemString.ToExactKey(input)
    local itemID, suffixID, bonusIDs = Resolve(input)
    if not itemID then
        return nil
    end
    local key = string.format("%d", itemID)
    if suffixID ~= 0 then
        key = key .. string.format("#s%d", suffixID)
    end
    if #bonusIDs > 0 then
        local parts = {}
        for i, id in ipairs(bonusIDs) do
            parts[i] = string.format("%d", id)
        end
        key = key .. "#b" .. table.concat(parts, ",")
    end
    return key
end

-- Returns the base key for a commodity, otherwise the exact key.
function ItemString.ToKey(input, isCommodity)
    if isCommodity then
        return ItemString.ToBaseKey(input)
    end
    return ItemString.ToExactKey(input)
end

-- Matches a decimal integer without leading zeros.
local function IsPlainInteger(text)
    return text == "0" or text:match("^[1-9]%d*$") ~= nil
end

-- Returns a table of item id, suffix id and bonus ids, or nil if the key is invalid.
function ItemString.ParseKey(key)
    if type(key) ~= "string" then
        return nil
    end
    if key:find(":", 1, true) then
        return nil
    end
    local parts = Split((key:gsub("#", ":")))
    local itemText = parts[1]
    if not itemText:match("^[1-9]%d*$") then
        return nil
    end
    local result = { itemID = tonumber(itemText), suffixID = 0, bonusIDs = {} }
    local seenSuffix, seenBonus = false, false
    for i = 2, #parts do
        local tag, value = parts[i]:sub(1, 1), parts[i]:sub(2)
        if tag == "s" and not seenSuffix and not seenBonus then
            local digits = value:gsub("^%-", "")
            if not digits:match("^[1-9]%d*$") then
                return nil
            end
            result.suffixID = tonumber(value)
            seenSuffix = true
        elseif tag == "b" and not seenBonus then
            local previous = 0
            for number in (value .. ","):gmatch("([^,]*),") do
                if not IsPlainInteger(number) then
                    return nil
                end
                local id = tonumber(number)
                if id < previous then
                    return nil
                end
                previous = id
                result.bonusIDs[#result.bonusIDs + 1] = id
            end
            seenBonus = true
        else
            return nil
        end
    end
    return result
end

-- Returns the base key of a valid key, or nil.
function ItemString.KeyToBaseKey(key)
    local parsed = ItemString.ParseKey(key)
    if not parsed then
        return nil
    end
    return string.format("%d", parsed.itemID)
end
