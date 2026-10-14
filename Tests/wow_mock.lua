-- Small mocked WoW API for busted specs. Call mock.reset() before each test.

local M = {}

local GLOBAL_NAMES = {
    "ACCEPT", "CANCEL", "C_AuctionHouse", "C_Item", "C_Timer", "CreateFrame", "DEFAULT_CHAT_FRAME",
    "C_GameRules", "FlipsideDB", "FlipsideScanDB", "GetBuildInfo", "GetCurrentRegionName", "GetNormalizedRealmName",
    "GetServerTime", "GetTime", "GetCurrentRegion", "IsTestBuild", "IsBetaBuild", "IsPublicTestClient",
    "SLASH_FLIPSIDE1", "SLASH_FLIPSIDE2",
    "SLASH_SCANTEST1", "ScanTestDB", "SlashCmdList",
    "StaticPopupDialogs", "StaticPopup_Show", "UnitName", "WOW_PROJECT_ID", "date", "debugprofilestop", "time",
}

local frameMethods = {}
frameMethods.__index = frameMethods

function frameMethods:RegisterEvent(event)
    if M.invalidEvents[event] then
        error("unknown event: " .. tostring(event), 2)
    end
    self.events[event] = true
end

function frameMethods:UnregisterEvent(event)
    self.events[event] = nil
end

function frameMethods:Show()
    self.shown = true
end

function frameMethods:Hide()
    self.shown = false
end

function frameMethods:IsShown()
    return self.shown
end

function frameMethods:SetScript(name, fn)
    self.scripts[name] = fn
end

function frameMethods:GetScript(name)
    return self.scripts[name]
end

function M.reset()
    M.clock = 0 -- seconds since reset
    M.serverBase = 1000000
    M.timers = {}
    M.frames = {}
    M.invalidEvents = {} -- event names that RegisterEvent rejects
    M.messages = {}
    M.popup = nil -- last popup: { which, text, dialog }
    M.replicateCalls = 0
    M.rows = {} -- each row: itemID, count, buyout, hasAll, link
    M.region = "EU" -- result of GetCurrentRegionName()
    M.regionId = nil -- result of GetCurrentRegion(); nil removes the function
    M.testBuild = false -- result of IsTestBuild()
    M.standard = true -- result of C_GameRules.IsStandard()
    M.commodity = {} -- itemID -> isCommodity from GetItemKeyInfo; a missing id gives no info
    M.stackSizes = {} -- itemID -> max stack size
    M.playerName = nil -- result of UnitName("player")
    M.realmName = nil -- result of GetNormalizedRealmName()
    M.itemInfo = {} -- itemID -> array of GetItemInfo return values
    M.loadRequests = {} -- itemIDs passed to RequestLoadItemDataByID

    _G.ACCEPT = "Accept"
    _G.CANCEL = "Cancel"
    _G.WOW_PROJECT_ID = 99
    _G.date = os.date
    _G.time = os.time
    _G.ScanTestDB = nil
    _G.FlipsideDB = nil
    _G.FlipsideScanDB = nil
    _G.SLASH_FLIPSIDE1 = nil
    _G.SLASH_FLIPSIDE2 = nil
    _G.SLASH_SCANTEST1 = nil
    _G.SlashCmdList = {}
    _G.StaticPopupDialogs = {}

    _G.CreateFrame = function()
        local f = setmetatable({ events = {}, scripts = {}, shown = true }, frameMethods)
        table.insert(M.frames, f)
        return f
    end

    _G.DEFAULT_CHAT_FRAME = {
        AddMessage = function(_, msg)
            table.insert(M.messages, msg)
        end,
    }

    _G.GetBuildInfo = function()
        return "1.60.1", "70009", "Oct 1 2026", 16001, "1.60.1", {}
    end
    _G.GetServerTime = function()
        return M.serverBase + math.floor(M.clock)
    end
    _G.GetTime = function()
        return M.clock
    end
    _G.GetCurrentRegionName = function()
        return M.region
    end
    _G.IsTestBuild = function()
        return M.testBuild
    end
    _G.IsBetaBuild = function()
        return false
    end
    _G.IsPublicTestClient = function()
        return false
    end
    _G.GetCurrentRegion = function()
        return M.regionId
    end
    _G.C_GameRules = {
        IsStandard = function()
            return M.standard
        end,
    }
    _G.debugprofilestop = function()
        return M.clock * 1000
    end

    _G.C_Timer = {
        After = function(seconds, fn)
            table.insert(M.timers, { at = M.clock + seconds, fn = fn })
        end,
    }

    _G.UnitName = function()
        return M.playerName, nil
    end
    _G.GetNormalizedRealmName = function()
        return M.realmName
    end

    _G.C_Item = {
        GetItemInfo = function(itemID)
            local values = M.itemInfo[itemID]
            if values then
                return unpack(values, 1, 17)
            end
        end,
        RequestLoadItemDataByID = function(itemID)
            table.insert(M.loadRequests, itemID)
        end,
        GetItemMaxStackSizeByID = function(itemID)
            return M.stackSizes[itemID]
        end,
    }

    _G.C_AuctionHouse = {
        ReplicateItems = function()
            M.replicateCalls = M.replicateCalls + 1
        end,
        GetNumReplicateItems = function()
            return #M.rows
        end,
        -- Index base is 0 to n-1, like the addon assumes.
        GetReplicateItemInfo = function(index)
            local r = M.rows[index + 1]
            if not r then
                return
            end
            return "name", 0, r.count, 1, true, 1, 0, 0, 0, r.buyout, 0, false, "", "", "", 0,
                r.itemID, r.hasAll
        end,
    }

    _G.C_AuctionHouse.MakeItemKey = function(itemID)
        return { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
    end
    _G.C_AuctionHouse.GetItemKeyInfo = function(itemKey)
        local isCommodity = M.commodity[itemKey.itemID]
        if isCommodity ~= nil then
            return { isCommodity = isCommodity }
        end
    end
    _G.C_AuctionHouse.GetReplicateItemLink = function(index)
        local r = M.rows[index + 1]
        return r and r.link
    end
    _G.C_AuctionHouse.GetReplicateItemBattlePetInfo = function() end

    _G.StaticPopup_Show = function(which, arg1, arg2)
        local d = _G.StaticPopupDialogs[which]
        M.popup = { which = which, dialog = d, text = string.format(d.text, arg1 or "", arg2 or "") }
    end
end

-- Remove the globals that the mock sets.
function M.teardown()
    for _, name in ipairs(GLOBAL_NAMES) do
        _G[name] = nil
    end
end

-- Send an event to each frame that registered for it.
function M.fire(event, ...)
    local list = {}
    for _, f in ipairs(M.frames) do
        if f.events[event] and f.scripts.OnEvent then
            table.insert(list, f)
        end
    end
    for _, f in ipairs(list) do
        f.scripts.OnEvent(f, event, ...)
    end
end

function M.isRegistered(event)
    for _, f in ipairs(M.frames) do
        if f.events[event] then
            return true
        end
    end
    return false
end

-- Run one frame: call the OnUpdate script of each shown frame once.
function M.update()
    local list = {}
    for _, f in ipairs(M.frames) do
        if f.scripts.OnUpdate and f.shown then
            table.insert(list, f)
        end
    end
    for _, f in ipairs(list) do
        if f.scripts.OnUpdate and f.shown then
            f.scripts.OnUpdate(f, 0.016)
        end
    end
end

-- Move the clock forward and run the timers that are due.
function M.advance(seconds)
    M.clock = M.clock + seconds
    local due, rest = {}, {}
    for _, t in ipairs(M.timers) do
        if t.at <= M.clock then
            table.insert(due, t)
        else
            table.insert(rest, t)
        end
    end
    M.timers = rest
    table.sort(due, function(a, b)
        return a.at < b.at
    end)
    for _, t in ipairs(due) do
        t.fn()
    end
end

function M.runSlash(args)
    _G.SlashCmdList["SCANTEST"](args or "")
end

-- Run the logout event as the client does.
function M.logout()
    M.fire("PLAYER_LOGOUT")
end

function M.acceptPopup()
    local p = M.popup
    M.popup = nil
    p.dialog.OnAccept()
end

return M
