local _, ns = ...

-- The key of a character in all saved data (SPEC 5.5, "Character names on Forever").
-- Forever: the key is the player GUID. A name is not enough there: two characters can share a first name and
-- differ in the surname. The name and the realm of each GUID key are saved as metadata (account scope), so that
-- all code can show a name and match a typed name. TBC: the key stays "Name-Realm" and has no metadata.
-- A legacy "Name-Realm" key (data of an older version, or of a session with no usable GUID) is read as before.
-- The first character that logs in with a name and a realm claims the legacy key of that name and realm. The
-- claim is saved, so that the stores that open later (the ledger addon) move the data to the same character.
local CharacterKey = {}
ns.CharacterKey = CharacterKey

local META_KEY = "characters.meta"
local CLAIM_KEY = "characters.claims"
local UNKNOWN_NAME = "Unknown"

-- Character-scope settings whose value is a character key. A move rewrites them (SettingsDB:MoveCharacter).
CharacterKey.VALUE_KEYS = { "ledger.view.char" }

local deps = {}

-- deps.db: the settings DB. It keeps the metadata and the claims. Without it all reads give no data.
function CharacterKey.Setup(options)
    deps = options or {}
end

-- True if the flavour uses the player GUID as the character key.
function CharacterKey.UsesGuid()
    return type(ns.Flavour) == "table" and ns.Flavour.characterGuidKey == true
end

-- True if the text has the form of a player GUID (Player-<realm id>-<hex>). "Name-Realm" never has this form.
function CharacterKey.IsGuid(key)
    return type(key) == "string" and key:match("^Player%-%d+%-%x+$") ~= nil
end

local function isText(value)
    return type(value) == "string" and value ~= ""
end

-- Returns the key of the current character, and its legacy key "Name-Realm".
-- The key is nil if the client gives no name or realm. The legacy key is nil if the key is the legacy key itself:
-- this is TBC, or Forever with no usable GUID. Then the session uses "Name-Realm" and no data moves.
-- isSecret (optional) is issecretvalue. UnitGUID gives a secret value when the unit identity is restricted.
function CharacterKey.Compute(name, realm, guid, isSecret)
    if not (isText(name) and isText(realm)) then
        return nil
    end
    local legacy = name .. "-" .. realm
    if not CharacterKey.UsesGuid() then
        return legacy
    end
    if isSecret and isSecret(guid) then
        return legacy
    end
    if CharacterKey.IsGuid(guid) then
        return guid, legacy
    end
    return legacy
end

-- The saved table of one section; nil if the DB is not set or has no table.
local function section(key)
    local value = deps.db and deps.db:Get("account", key)
    return type(value) == "table" and value or nil
end

-- Returns { name, realm } of a GUID key, or nil.
function CharacterKey.Meta(key)
    local all = section(META_KEY)
    local meta = all and type(key) == "string" and all[key]
    if type(meta) == "table" and isText(meta.name) then
        return meta
    end
    return nil
end

-- Saves the name and the realm of a GUID key. Returns false if nothing was saved.
function CharacterKey.SaveMeta(key, name, realm)
    if not (deps.db and CharacterKey.IsGuid(key) and isText(name) and isText(realm)) then
        return false
    end
    local old = CharacterKey.Meta(key)
    if old and old.name == name and old.realm == realm then
        return true
    end
    local copy = {}
    for k, v in pairs(section(META_KEY) or {}) do
        copy[k] = v
    end
    copy[key] = { name = name, realm = realm }
    return deps.db:Set("account", META_KEY, copy) ~= false
end

-- Removes the metadata of a key.
function CharacterKey.RemoveMeta(key)
    if not (deps.db and section(META_KEY) and section(META_KEY)[key]) then
        return false
    end
    local copy = {}
    for k, v in pairs(section(META_KEY)) do
        if k ~= key then
            copy[k] = v
        end
    end
    return deps.db:Set("account", META_KEY, copy) ~= false
end

-- Returns the name part of a key. A GUID key with no metadata gives "Unknown": a GUID is never shown.
function CharacterKey.Name(key)
    if type(key) ~= "string" then
        return tostring(key)
    end
    local meta = CharacterKey.Meta(key)
    if meta then
        return meta.name
    end
    if CharacterKey.IsGuid(key) then
        return UNKNOWN_NAME
    end
    return key:match("^([^%-]+)%-") or key
end

-- Returns the realm of a key, or nil if it has none (a key with no realm, or a GUID key with no metadata).
function CharacterKey.Realm(key)
    if type(key) ~= "string" then
        return nil
    end
    local meta = CharacterKey.Meta(key)
    if meta then
        return meta.realm
    end
    if CharacterKey.IsGuid(key) then
        return nil
    end
    return key:match("^[^%-]+%-(.+)$")
end

-- Returns "Name-Realm" for a key. A legacy key is returned as it is. A GUID key gives its metadata, or "Unknown".
function CharacterKey.FullName(key)
    if type(key) ~= "string" then
        return tostring(key)
    end
    if not CharacterKey.IsGuid(key) then
        return key
    end
    local realm = CharacterKey.Realm(key)
    return realm and (CharacterKey.Name(key) .. "-" .. realm) or CharacterKey.Name(key)
end

-- Claims the legacy key for a GUID key, if no other key has claimed it. Returns the key that owns the claim, or nil
-- if the DB is read-only or not set.
function CharacterKey.Claim(legacy, key)
    if not (deps.db and isText(legacy) and CharacterKey.IsGuid(key)) or deps.db:IsReadOnly() then
        return nil
    end
    local claims = section(CLAIM_KEY) or {}
    if claims[legacy] == nil then
        local copy = {}
        for k, v in pairs(claims) do
            copy[k] = v
        end
        copy[legacy] = key
        if deps.db:Set("account", CLAIM_KEY, copy) == false then
            return nil
        end
        return key
    end
    return claims[legacy]
end

-- Returns a copy of the claims: legacy key -> GUID key.
function CharacterKey.Claims()
    local copy = {}
    for legacy, key in pairs(section(CLAIM_KEY) or {}) do
        copy[legacy] = key
    end
    return copy
end
