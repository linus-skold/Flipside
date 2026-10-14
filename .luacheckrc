std = "lua51"
max_line_length = 120
exclude_files = { "Libs/", "lua51/", ".claude/" }

-- WoW API that the code reads.
read_globals = {
    "ACCEPT",
    "CANCEL",
    "C_AuctionHouse",
    "C_Item",
    "C_Timer",
    "CreateFrame",
    "DEFAULT_CHAT_FRAME",
    "GetBuildInfo",
    "GetNormalizedRealmName",
    "GetServerTime",
    "GetTimePreciseSec",
    "StaticPopup_Show",
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
}

files["Tests/"] = { std = "+busted" }
