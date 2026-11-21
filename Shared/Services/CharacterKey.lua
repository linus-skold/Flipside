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
-- The key is nil if the client gives no name, or no realm and no usable GUID. The legacy key is nil if the key is the
-- legacy key itself: this is TBC, or Forever with no usable GUID. Then the session uses "Name-Realm" and no data moves.
-- Forever with a usable GUID and no realm: the key is the GUID and the legacy key is nil (no realm is known).
-- isSecret (optional) is issecretvalue. UnitGUID gives a secret value when the unit identity is restricted.
function CharacterKey.Compute(name, realm, guid, isSecret)
    if not isText(name) then
        return nil
    end
    local legacy = isText(realm) and (name .. "-" .. realm) or nil
    if CharacterKey.UsesGuid() and not (isSecret and isSecret(guid)) and CharacterKey.IsGuid(guid) then
        return guid, legacy
    end
    return legacy
end

-- The GUID of the player, or nil if the client gives none or a secret value.
local function playerGuid()
    local api = _G
    if type(api.UnitGUID) ~= "function" then
        return nil
    end
    local guid = api.UnitGUID("player")
    if type(api.issecretvalue) == "function" and api.issecretvalue(guid) then
        return nil
    end
    return CharacterKey.IsGuid(guid) and guid or nil
end

-- The realm that the client gives now: GetNormalizedRealmName, else GetRealmName with no spaces. Nil if none.
-- A client can give no realm at all (WoW: Forever, 2026-11-21).
function CharacterKey.ClientRealm()
    local api = _G
    if type(api.GetNormalizedRealmName) == "function" then
        local realm = api.GetNormalizedRealmName()
        if isText(realm) then
            return realm
        end
    end
    -- The GetRealmName fallback is for Forever only. TBC keeps the old rule (no realm gives no key).
    if CharacterKey.UsesGuid() and type(api.GetRealmName) == "function" then
        local realm = api.GetRealmName()
        if isText(realm) then
            realm = realm:gsub("%s", "")
            if realm ~= "" then
                return realm
            end
        end
    end
    return nil
end

-- The "Name-Realm" text of the current character, for a text only (never a key, never saved). Order: the realm
-- (CurrentRealm), then the surname on Forever (surname = the 2nd result of UnitName, else savedSurname), then the
-- name alone. An empty realm is normal on Forever (user, 2026-11-21).
function CharacterKey.FullSelfName(name, surname, savedSurname)
    name = tostring(name)
    local suffix = CharacterKey.CurrentRealm()
    if not suffix and CharacterKey.UsesGuid() then
        suffix = (isText(surname) and surname) or (isText(savedSurname) and savedSurname) or nil
    end
    return suffix and (name .. "-" .. suffix) or name
end

-- Other spellings of the own name, for a self check: the name alone, and on Forever "Name<separator>Surname" and
-- "Name-Surname" if a surname is known (surname, else savedSurname). The separator is optional (default a space).
function CharacterKey.SelfAliases(name, surname, savedSurname, separator)
    name = tostring(name)
    local list = { name }
    local last = isText(surname) and surname or (isText(savedSurname) and savedSurname) or nil
    if last and CharacterKey.UsesGuid() then
        list[#list + 1] = name .. (isText(separator) and separator or " ") .. last
        list[#list + 1] = name .. "-" .. last
    end
    return list
end

-- The realm of the current character: the client realm, else the realm saved in the metadata of the player GUID
-- (Forever, after the DB is open), else nil. Use this for each realm read. Never use "Name-" .. nil.
function CharacterKey.CurrentRealm()
    local realm = CharacterKey.ClientRealm()
    if realm then
        return realm
    end
    local guid = CharacterKey.UsesGuid() and playerGuid() or nil
    local meta = guid and CharacterKey.Meta(guid)
    return meta and isText(meta.realm) and meta.realm or nil
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
-- If the realm is not text, the saved realm stays (it is never replaced with nil).
function CharacterKey.SaveMeta(key, name, realm)
    if not (deps.db and CharacterKey.IsGuid(key) and isText(name)) then
        return false
    end
    local old = CharacterKey.Meta(key)
    if not isText(realm) then
        realm = old and old.realm or nil
    end
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
