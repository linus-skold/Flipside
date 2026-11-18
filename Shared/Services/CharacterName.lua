local _, ns = ...

-- Display names and alias matching of the own characters (SPEC 5.5, "Character names on Forever").
-- On Forever the character key is the player GUID (CharacterKey) and the client has no real server name: the second
-- name is the surname of the character. The surname is saved per character key. It is used to show a name, as an
-- alias when a typed name is matched, and to build the full name for the mail call.
-- A key can also be a legacy "Name-Realm" key. CharacterKey gives the name and the realm of both kinds.
-- A flavour sets ns.Flavour.usesSurname for this. TBC shows the key as it is.
local CharacterName = {}
ns.CharacterName = CharacterName

local SETTING_KEY = "surname"
local DEFAULT_SEPARATOR = " "

-- The name of the character setting that keeps the surname.
CharacterName.SETTING_KEY = SETTING_KEY

local deps = {}

-- deps.db: a settings DB (GetFor, SetFor) that keeps the surname of each character key.
-- deps.separator: optional function that gives the text between a name and a surname. The default is a space.
function CharacterName.Setup(options)
    deps = options or {}
end

-- True if the flavour shows and matches the surname.
function CharacterName.Enabled()
    return type(ns.Flavour) == "table" and ns.Flavour.usesSurname == true
end

function CharacterName.Separator()
    local text = deps.separator and deps.separator()
    return type(text) == "string" and text ~= "" and text or DEFAULT_SEPARATOR
end

-- Returns the name part of a key (a GUID key: its saved name; a "Name-Realm" key: the part before the realm).
-- A key with no realm is returned as it is.
function CharacterName.Plain(key)
    if ns.CharacterKey then
        return ns.CharacterKey.Name(key)
    end
    if type(key) ~= "string" then
        return tostring(key)
    end
    return key:match("^([^%-]+)%-") or key
end

-- Returns the saved surname of a character key, or nil.
function CharacterName.Surname(key)
    if not (CharacterName.Enabled() and deps.db and type(key) == "string" and key ~= "") then
        return nil
    end
    local surname = deps.db:GetFor(key, SETTING_KEY)
    return type(surname) == "string" and surname ~= "" and surname or nil
end

-- Saves the surname of a character key. An empty or missing surname keeps the saved value. Returns false if
-- nothing was saved. This does nothing on a flavour with no surname.
function CharacterName.SaveSurname(key, surname)
    if not (CharacterName.Enabled() and deps.db and type(key) == "string" and key ~= "") then
        return false
    end
    if type(surname) ~= "string" or surname == "" then
        return false
    end
    if deps.db:GetFor(key, SETTING_KEY) == surname then
        return true
    end
    return deps.db:SetFor(key, SETTING_KEY, surname)
end

-- Returns the name to show for a character key. Forever: "Name Surname", or "Name" with no known surname.
-- TBC: the key as it is.
function CharacterName.Display(key)
    if type(key) ~= "string" or key == "" then
        return key
    end
    if not CharacterName.Enabled() then
        -- A GUID is never shown, also if a flavour has no surname.
        return ns.CharacterKey and ns.CharacterKey.FullName(key) or key
    end
    local name = CharacterName.Plain(key)
    local surname = CharacterName.Surname(key)
    if surname then
        return name .. CharacterName.Separator() .. surname
    end
    return name
end

-- Returns the key of the list that the typed text names, or nil. Case does not matter. The text can be:
--  "Name-Realm": the key itself (a key with no realm also matches "Name-Realm" of the same name);
--  "Name": the name part of the key (the text has no realm);
--  "Name Surname": the name and the saved surname of the key (flavours with a surname only).
-- A text with a realm never matches a key of another realm.
-- A key is a GUID on Forever: the name and the realm come from the saved metadata (CharacterKey).
-- Two characters can have the same name and realm there. "Name Surname" names one character. A text with a name
-- only ("Name" or "Name-Realm") that more than one key matches gives no key: the result is nil, "ambiguous" and the
-- name that the keys share.
function CharacterName.Resolve(text, keys)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local wanted = text:lower()
    local wantedName, wantedRealm = wanted:match("^([^%-]+)%-(.+)$")
    local byName, seen, alias = {}, {}, nil
    for _, key in ipairs(keys or {}) do
        if type(key) == "string" and key ~= "" and not seen[key] then
            seen[key] = true
            local name = CharacterName.Plain(key):lower()
            local realm
            if ns.CharacterKey then
                realm = ns.CharacterKey.Realm(key)
            else
                realm = key:match("^[^%-]+%-(.+)$")
            end
            realm = type(realm) == "string" and realm:lower() or nil
            local surname = CharacterName.Surname(key)
            if surname and wanted == (name .. CharacterName.Separator() .. surname):lower() then
                alias = alias or key
            elseif (realm and name .. "-" .. realm or name) == wanted
                or (wantedRealm and not realm and name == wantedName)
                or (not wantedRealm and name == wanted) then
                byName[#byName + 1] = key
            end
        end
    end
    if alias then
        return alias
    end
    if #byName > 1 then
        return nil, "ambiguous", CharacterName.Plain(byName[1])
    end
    return byName[1]
end

-- Returns the name to send to the mail call. Forever has regional unique names: the server needs the full name
-- "Name<separator>Surname".
--  An own character that the text names: its full name. With no saved surname the result is nil and a reason.
--  Other text with two parts ("Name Surname" or "Name-Surname"): the parts with the separator between them.
--  Any other text, and every text on TBC: the text as it is.
function CharacterName.MailName(text, keys)
    if not CharacterName.Enabled() then
        return text
    end
    local key, problem, shared = CharacterName.Resolve(text, keys)
    if problem == "ambiguous" then
        return nil, "Flipside: more than one of your characters is named " .. shared .. "; type Name Surname"
    end
    if key then
        local surname = CharacterName.Surname(key)
        if surname then
            return CharacterName.Plain(key) .. CharacterName.Separator() .. surname
        end
        return nil, "Flipside: log in to " .. CharacterName.Plain(key) .. " once so Flipside knows the surname"
    end
    if type(text) == "string" then
        local separator = CharacterName.Separator()
        local name, surname = text:match("^([^%-%s]+)%-([^%-%s]+)$")
        if not name then
            name, surname = text:match("^(%S+)%s+(%S+)$")
        end
        if name then
            return name .. separator .. surname
        end
    end
    return text
end
