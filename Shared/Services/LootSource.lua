local _, ns = ...

-- Names the source of looted money (SPEC 5.8 point 4). It has no client calls of its own: Init gives it the reads.
-- It does not use GetLootSourceInfo (not on Forever) and not the combat log (restricted).
local LootSource = {}
ns.LootSource = LootSource

-- A spell cast and an item lock count for this long (seconds) before the loot window opens.
LootSource.CAST_SECONDS = 6
LootSource.LOCK_SECONDS = 5
LootSource.FISHING = "Fishing"
-- The kinds of the record field `src`.
LootSource.KINDS = { "mob", "object", "item", "fishing", "player" }

-- The unit tokens that can name the thing that the player looted, in this order.
local UNITS = { "softinteract", "mouseover" }

local Source = {}
Source.__index = Source

-- deps: now() in seconds. Optional: isSecret(value), isFishing() (true for a fishing loot window),
-- unit(token) (name and kind, "mob" or "object", or nil), tooltipName() (the title of the world tooltip),
-- bagItemName(bag, slot), formats ({ split, gold, silver, copper }: the client money texts).
function LootSource.New(deps)
    return setmetatable({ _deps = deps }, Source)
end

function Source:_Secret(value)
    local isSecret = self._deps.isSecret
    return isSecret ~= nil and isSecret(value) == true
end

-- Call a read of the deps. A missing, failing or secret read gives nil.
function Source:_Read(name, ...)
    local read = self._deps[name]
    if type(read) ~= "function" then
        return nil
    end
    local ok, first, second = pcall(read, ...)
    if not ok or self:_Secret(first) or self:_Secret(second) then
        return nil
    end
    return first, second
end

local function text(value)
    return type(value) == "string" and value ~= "" and value or nil
end

-- UNIT_SPELLCAST_SENT: the target name of an own cast. A gather or open spell names its node or chest.
function Source:OnCast(unit, target)
    -- A comparison on a secret value raises an error: check for a secret value first.
    if self:_Secret(unit) or self:_Secret(target) then
        self._cast = nil
        return
    end
    if unit ~= "player" then
        return
    end
    -- A cast on the player (a self buff) names no loot source.
    if type(target) == "string" and target ~= "" and target ~= self:_Read("playerName") then
        self._cast = { name = target, time = self._deps.now() }
    else
        self._cast = nil
    end
end

-- ITEM_LOCK_CHANGED: the bag slot that the player used last.
function Source:OnLock(bag, slot)
    if type(bag) == "number" and type(slot) == "number" and not self:_Secret(bag) and not self:_Secret(slot) then
        self._lock = { bag = bag, slot = slot, time = self._deps.now() }
    end
end

-- Returns the name and the kind ("mob", "object", "item" or "fishing") of the source of the loot window that
-- opens now, or nil. The kind is nil when only a name is known. isFromItem is the second LOOT_OPENED value.
function Source:Resolve(isFromItem)
    local now = self._deps.now()
    local cast, lock = self._cast, self._lock
    self._cast, self._lock = nil, nil
    local castName = cast and now - cast.time <= LootSource.CAST_SECONDS and cast.name or nil
    if isFromItem == true then
        local name
        if lock and now - lock.time <= LootSource.LOCK_SECONDS then
            name = text(self:_Read("bagItemName", lock.bag, lock.slot))
        end
        if name then
            return name, "item"
        end
        -- A cast name is a weak guess: no kind.
        return castName, nil
    end
    if self:_Read("isFishing") == true then
        return LootSource.FISHING, "fishing"
    end
    for _, token in ipairs(UNITS) do
        local name, kind = self:_Read("unit", token)
        if text(name) and (kind == "mob" or kind == "object") then
            return name, kind
        end
    end
    local tooltip = text(self:_Read("tooltipName"))
    if tooltip then
        return tooltip, nil
    end
    local name, kind = self:_Read("unit", "target")
    if text(name) and (kind == "mob" or kind == "object") then
        return name, kind
    end
    return castName, nil
end

-- Turn a client format text ("%s", "%d") into a Lua pattern with captures.
local function toPattern(format)
    local escaped = format:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    escaped = escaped:gsub("%%%%s", "(.-)"):gsub("%%%%d", "(%%d+)")
    return escaped
end

local PARTS = { { "gold", 10000 }, { "silver", 100 }, { "copper", 1 } }

-- Returns the copper amount of a CHAT_MSG_MONEY text that tells a share of group loot, or nil for any other text.
function Source:ShareAmount(message)
    local formats = self._deps.formats
    if type(message) ~= "string" or self:_Secret(message) or type(formats) ~= "table"
        or type(formats.split) ~= "string" then
        return nil
    end
    -- A format that ends in "%s" needs an end anchor, or the lazy capture is empty. The guild variant of the text
    -- ("... %s. (%s deposited ...)") has other text after the capture, so it has no anchor.
    local pattern = "^" .. toPattern(formats.split)
    if formats.split:sub(-2) == "%s" then
        pattern = pattern .. "$"
    end
    local amounts = message:match(pattern)
    if not amounts then
        return nil
    end
    local total, found = 0, false
    for _, part in ipairs(PARTS) do
        local format = formats[part[1]]
        local count = type(format) == "string" and amounts:match(toPattern(format)) or nil
        if count then
            total, found = total + tonumber(count) * part[2], true
        end
    end
    return found and total > 0 and total or nil
end
