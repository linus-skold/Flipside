local _, ns = ...

-- Display names and alias matching of the own characters (SPEC 5.5, "Character names on Forever").
-- A character key stays "Name-Realm" in all saved data. On Forever the client has no real server name: the second
-- name is the surname of the character. The surname is saved per character key. It is used to show a name, as an
-- alias when a typed name is matched, and to build the full name for the mail call.
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

-- Returns the name part of a "Name-Realm" key. A key with no realm is returned as it is.
function CharacterName.Plain(key)
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
    if type(key) ~= "string" or key == "" or not CharacterName.Enabled() then
        return key
    end
    local name = CharacterName.Plain(key)
    local surname = CharacterName.Surname(key)
    if surname then
        return name .. CharacterName.Separator() .. surname
    end
    return name
end

-- Returns the first key of the list that the typed text names, or nil. Case does not matter. The text can be:
--  "Name-Realm": the key itself (a key with no realm also matches "Name-Realm" of the same name);
--  "Name": the name part of the key (the text has no realm);
--  "Name Surname": the name and the saved surname of the key (flavours with a surname only).
-- A text with a realm never matches a key of another realm.
function CharacterName.Resolve(text, keys)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local wanted = text:lower()
    local wantedName, wantedRealm = wanted:match("^([^%-]+)%-(.+)$")
    for _, key in ipairs(keys or {}) do
        if type(key) == "string" and key ~= "" then
            local lower = key:lower()
            local name, realm = lower:match("^([^%-]+)%-(.+)$")
            if lower == wanted then
                return key
            end
            if not wantedRealm and (name or lower) == wanted then
                return key
            end
            if wantedRealm and not realm and lower == wantedName then
                return key
            end
            local surname = CharacterName.Surname(key)
            if surname and wanted == ((name or lower) .. CharacterName.Separator() .. surname):lower() then
                return key
            end
        end
    end
    return nil
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
    local key = CharacterName.Resolve(text, keys)
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
