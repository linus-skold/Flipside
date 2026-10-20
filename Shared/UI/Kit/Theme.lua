local _, ns = ...
ns.Kit = ns.Kit or {}
local Kit = ns.Kit

-- One theme table: client font objects, spacing and client textures. No tint.
Kit.Theme = {
    fonts = {
        title = "GameFontNormalLarge",
        normal = "GameFontNormal",
        highlight = "GameFontHighlight",
        small = "GameFontNormalSmall",
        disabled = "GameFontDisable",
        good = "GameFontGreen",
        bad = "GameFontRed",
        number = "NumberFontNormal",
    },
    padding = 12,
    rowHeight = 20,
    gap = 6,
    insetPadding = 4,
    rowHighlight = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
    divider = "Options_HorizontalDivider",
}

-- Return the font object name for a role. An unknown role gives the normal font.
function Kit.Font(role)
    local fonts = Kit.Theme.fonts
    return fonts[role] or fonts.normal
end

-- Return r, g, b and the hex string (no |c prefix) of an item quality. Missing data gives white.
function Kit.QualityColor(quality)
    if C_Item and C_Item.GetItemQualityColor and quality then
        local r, g, b, hex = C_Item.GetItemQualityColor(quality)
        if r then
            return r, g, b, hex
        end
    end
    return 1, 1, 1, "ffffffff"
end

-- Return the text wrapped in the colour of an item quality.
function Kit.QualityText(quality, text)
    local _, _, _, hex = Kit.QualityColor(quality)
    return "|c" .. hex .. text .. "|r"
end

-- Client sound kit names for each kind of Kit sound. The names are the ones the client uses for its own frames.
Kit.SOUNDS = {
    tab = "IG_CHARACTER_INFO_TAB",
    open = "IG_CHARACTER_INFO_OPEN",
    close = "IG_CHARACTER_INFO_CLOSE",
}

local soundGate

-- Set a function that tells if Kit sounds are on. With no gate, sounds are on.
function Kit.SetSoundGate(fn)
    soundGate = fn
end

-- Play a Kit sound (tab, open or close) on the default sound channel. A missing API or key does nothing.
function Kit.PlaySound(kind)
    if soundGate and not soundGate() then
        return false
    end
    local kit = SOUNDKIT
    local key = kit and Kit.SOUNDS[kind] and kit[Kit.SOUNDS[kind]]
    if not key or not PlaySound then
        return false
    end
    PlaySound(key)
    return true
end
