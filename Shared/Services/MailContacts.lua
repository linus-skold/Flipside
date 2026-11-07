local _, ns = ...

-- The contacts of the Send page (SPEC 5.5, "Contact list"). The pure part merges the sources, removes the
-- duplicates, sorts and keeps the manual list. It uses no frame. The read functions at the end call the client
-- through _G, each one in a pcall, so a missing or slow API gives an empty list and never an error.
local MailContacts = {}
ns.MailContacts = MailContacts

-- The account setting that holds the manual contacts: a list of names.
MailContacts.KEY = "mail.contacts"
-- The groups in the order of the list. A name that two sources hold stays in the first group.
MailContacts.GROUPS = {
    { key = "own", title = "Own characters" },
    { key = "friends", title = "Friends" },
    { key = "guild", title = "Guild" },
    { key = "manual", title = "Saved" },
}
-- The longest recipient name: letters="77" of SendMailNameEditBox in Blizzard_MailFrame/MailFrame.xml (Forever).
MailContacts.MAX_NAME = 77
-- Seconds between two requests to the client for a new friend list and guild roster.
MailContacts.REQUEST_WAIT = 15

local function trim(text)
    return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

-- The text that two spellings of one character share, so the merge and the checks match them. Case does not
-- matter. A realm suffix "-Realm" of the home realm (realm, optional) goes away: "Anna-Home" is "Anna". Any other
-- "-" counts as a space: "Anna-Surname" is "Anna Surname". Spaces and "-" in the realm do not matter.
function MailContacts.Key(name, realm)
    name = trim(name):lower()
    local base, suffix = name:match("^(.-)%-(.+)$")
    if base and base ~= "" then
        local home = realm and (tostring(realm):lower():gsub("[%s%-]", "")) or ""
        if home ~= "" and (suffix:gsub("[%s%-]", "")) == home then
            return base
        end
        return base .. " " .. suffix
    end
    return name
end

local function before(a, b)
    local la, lb = a:lower(), b:lower()
    if la ~= lb then
        return la < lb
    end
    return a < b
end

-- Returns a new list of the valid names of a list: trimmed texts, no empty text, no duplicate (case does not
-- matter). The order stays.
function MailContacts.Clean(list)
    local result, seen = {}, {}
    for _, name in ipairs(type(list) == "table" and list or {}) do
        if type(name) == "string" then
            name = trim(name)
            local key = name:lower()
            if name ~= "" and not seen[key] then
                seen[key] = true
                result[#result + 1] = name
            end
        end
    end
    return result
end

-- Returns true if the name is in the list (MailContacts.Key spelling; realm is optional).
function MailContacts.Has(list, name, realm)
    if trim(name) == "" then
        return false
    end
    local wanted = MailContacts.Key(name, realm)
    for _, entry in ipairs(list or {}) do
        if type(entry) == "string" and MailContacts.Key(entry, realm) == wanted then
            return true
        end
    end
    return false
end

-- Merges the sources into groups. sources has a list of names for each group key (own, friends, guild, manual).
-- exclude is a list of names that must not show (the current character). realm (optional) is the home realm
-- for MailContacts.Key: "Anna", "anna" and "Anna-Realm" are one name. Returns a list of
-- { key, title, names } in the order of MailContacts.GROUPS. A group with no name is not in the list. Each name
-- shows once, in the first group that holds it. The names of a group are sorted, case does not matter.
function MailContacts.Merge(sources, exclude, realm)
    local seen = {}
    for _, name in ipairs(exclude or {}) do
        if type(name) == "string" and trim(name) ~= "" then
            seen[MailContacts.Key(name, realm)] = true
        end
    end
    local groups = {}
    for _, group in ipairs(MailContacts.GROUPS) do
        local names = {}
        for _, name in ipairs(MailContacts.Clean((sources or {})[group.key])) do
            local key = MailContacts.Key(name, realm)
            if not seen[key] then
                seen[key] = true
                names[#names + 1] = name
            end
        end
        if #names > 0 then
            table.sort(names, before)
            groups[#groups + 1] = { key = group.key, title = group.title, names = names }
        end
    end
    return groups
end

-- Returns the names of the groups as one list, in the order of the groups. The autocomplete reads this list.
function MailContacts.Flat(groups)
    local names = {}
    for _, group in ipairs(groups or {}) do
        for _, name in ipairs(group.names) do
            names[#names + 1] = name
        end
    end
    return names
end

-- Returns the items of the contact drop-down: the placeholder (value "") and, for each group, a header and its names.
function MailContacts.MenuItems(groups, placeholder)
    local items = { { value = "", text = placeholder } }
    for _, group in ipairs(groups or {}) do
        items[#items + 1] = { value = "", text = group.title, header = true }
        for _, name in ipairs(group.names) do
            items[#items + 1] = { value = name, text = name }
        end
    end
    return items
end

-- Adds a name to the manual list. Returns the new list (the old list does not change), true, or the old list copy,
-- false and a reason. Refused: an empty name, a name over MAX_NAME letters, the current character and a name that
-- the list holds already. rules (optional): exclude (names of the current character), listed (names that the groups show already, an own
-- character, a friend or a guild member) and realm (MailContacts.Key).
function MailContacts.Add(list, name, rules)
    rules = rules or {}
    local current = MailContacts.Clean(list)
    name = trim(name)
    if name == "" then
        return current, false, "Enter a name first"
    end
    if #name > MailContacts.MAX_NAME then
        return current, false, "The name is too long"
    end
    if MailContacts.Has(rules.exclude, name, rules.realm) then
        return current, false, "That is the current character"
    end
    if MailContacts.Has(current, name, rules.realm) then
        return current, false, name .. " is already saved"
    end
    if MailContacts.Has(rules.listed, name, rules.realm) then
        return current, false, name .. " is in the list already"
    end
    current[#current + 1] = name
    return current, true
end

-- Removes a name from the manual list. Returns the new list and true, or the list copy and false if the name is
-- not in the list.
function MailContacts.Remove(list, name, realm)
    local current = MailContacts.Clean(list)
    if trim(name) == "" then
        return current, false
    end
    local wanted = MailContacts.Key(name, realm)
    for index, entry in ipairs(current) do
        if MailContacts.Key(entry, realm) == wanted then
            table.remove(current, index)
            return current, true
        end
    end
    return current, false
end

-- Returns the manual list of the settings DB (account scope). A DB that is nil gives an empty list.
function MailContacts.Load(db)
    return MailContacts.Clean(db and db:Get("account", MailContacts.KEY))
end

-- Writes the manual list. Returns false if the DB cannot write now.
function MailContacts.Save(db, list)
    if not db then
        return false
    end
    return db:Set("account", MailContacts.KEY, MailContacts.Clean(list)) and true or false
end

-- Returns the names of the character friends (online and offline). C_FriendList.GetNumFriends and
-- GetFriendInfoByIndex (the info has a name) are in the Forever client.
function MailContacts.Friends()
    local names, api = {}, _G.C_FriendList
    if type(api) ~= "table" or not api.GetNumFriends or not api.GetFriendInfoByIndex then
        return names
    end
    local ok, count = pcall(api.GetNumFriends)
    if not ok then
        return names
    end
    for index = 1, tonumber(count) or 0 do
        local read, info = pcall(api.GetFriendInfoByIndex, index)
        if read and type(info) == "table" and type(info.name) == "string" then
            names[#names + 1] = info.name
        end
    end
    return names
end

-- Returns the names of the guild members of this character. In the Forever client the guild is a club:
-- C_Club.GetGuildClubId (nil with no guild), C_Club.GetClubMembers and C_Club.GetMemberInfo (the info has a name).
function MailContacts.GuildMembers()
    local names, api = {}, _G.C_Club
    if type(api) ~= "table" or not (api.GetGuildClubId and api.GetClubMembers and api.GetMemberInfo) then
        return names
    end
    local ok, clubId = pcall(api.GetGuildClubId)
    if not ok or clubId == nil then
        return names
    end
    local listed, members = pcall(api.GetClubMembers, clubId)
    if not listed or type(members) ~= "table" then
        return names
    end
    for _, memberId in ipairs(members) do
        local read, info = pcall(api.GetMemberInfo, clubId, memberId)
        if read and type(info) == "table" and type(info.name) == "string" then
            names[#names + 1] = info.name
        end
    end
    return names
end

local lastRequest

-- Asks the client for a new friend list and guild roster (the answers come as events). now is a time in seconds.
-- It asks at most once in MailContacts.REQUEST_WAIT seconds. Returns true if it asked.
function MailContacts.Request(now)
    if lastRequest and now - lastRequest < MailContacts.REQUEST_WAIT then
        return false
    end
    lastRequest = now
    local friends, guild = _G.C_FriendList, _G.C_GuildInfo
    if type(friends) == "table" and friends.ShowFriends then
        pcall(friends.ShowFriends)
    end
    if type(guild) == "table" and guild.GuildRoster then
        pcall(guild.GuildRoster)
    end
    return true
end
