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
    rowHighlight = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
    divider = "Options_HorizontalDivider",
}

-- Return the font object name for a role. An unknown role gives the normal font.
function Kit.Font(role)
    local fonts = Kit.Theme.fonts
    return fonts[role] or fonts.normal
end
