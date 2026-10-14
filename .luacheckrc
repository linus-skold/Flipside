std = "lua51"
max_line_length = 120
exclude_files = { "Libs/", "lua51/", ".claude/", ".lua/", ".luarocks/" }

-- WoW API that the code reads.
read_globals = {
    "ACCEPT",
    "AuctionHouseFrame",
    "hooksecurefunc",
    "CANCEL",
    "C_AuctionHouse",
    "C_Container",
    "C_GameRules",
    "C_Item",
    "C_Timer",
    "CreateDataProvider",
    "CreateFrame",
    "CreateScrollBoxListLinearView",
    "CreateScrollBoxListTreeListView",
    "CreateTreeDataProvider",
    "DEFAULT_CHAT_FRAME",
    "GameTooltip",
    "GetBuildInfo",
    "GetCurrentRegion",
    "GetCurrentRegionName",
    "GetNormalizedRealmName",
    "GetMoneyString",
    "GetServerTime",
    "GetTime",
    "InCombatLockdown",
    "IsBetaBuild",
    "IsPublicTestClient",
    "IsTestBuild",
    "GetTimePreciseSec",
    "PanelTemplates_SetNumTabs",
    "PanelTemplates_SetTab",
    "ScrollUtil",
    "StaticPopup_Show",
    "UIParent",
    "UnitName",
    "WOW_PROJECT_ID",
    "date",
    "debugprofilestop",
    "time",
}

-- Names that the code writes.
globals = {
    "FlipsideDB",
    "FlipsideScanDB",
    "ScanTestDB",
    "SlashCmdList",
    "SLASH_FLIPSIDE1",
    "SLASH_FLIPSIDE2",
    "SLASH_SCANTEST1",
    "StaticPopupDialogs",
    "UISpecialFrames",
}

files["Tests/"] = { std = "+busted" }
