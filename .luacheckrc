std = "lua51"
max_line_length = 120
exclude_files = { "Shared/Libs/", "lua51/", ".claude/", ".lua/", ".luarocks/" }

-- WoW API that the code reads.
read_globals = {
    "ACCEPT",
    "CLOSE",
    "SAVE",
    "GetCursorPosition",
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
    "Enum",
    "GetInboxItem",
    "GetInboxItemLink",
    "GetInboxNumItems",
    "IsAltKeyDown",
    "TooltipDataProcessor",
    "GameTooltip",
    "GetBuildInfo",
    "GetCurrentRegion",
    "GetCurrentRegionName",
    "GetNormalizedRealmName",
    "GetMoneyString",
    "GetServerTime",
    "GetTime",
    "InCombatLockdown",
    "MenuUtil",
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

files["ScanTest/ScanTest_TBC.lua"] = {
    read_globals = { "AuctionFrame", "QueryAuctionItems", "CanSendAuctionQuery", "GetNumAuctionItems",
        "GetAuctionItemInfo", "GetAuctionItemLink" },
}

files["Tests/"] = { std = "+busted" }
files["Core_TBC/"] = { read_globals = { "NUM_BAG_SLOTS", "NUM_BANKBAGSLOTS", "BANK_CONTAINER" } }
files["AH_TBC/"] = {
    read_globals = {
        "NUM_BAG_SLOTS", "NUM_BANKBAGSLOTS", "BANK_CONTAINER",
        "AuctionFrame", "AuctionFrameBrowse", "AuctionFrameBid", "AuctionFrameAuctions",
        "AuctionFrameTab_OnClick", "PanelTemplates_GetSelectedTab", "PanelTemplates_SelectTab",
        "PanelTemplates_DeselectTab", "GetAuctionItemLink",
    },
}
