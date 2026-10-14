local _, ns = ...

-- TBC Anniversary host of the Flipside tab. It owns the legacy AuctionFrame, the tab button and the pane switch.
-- It never writes to a Blizzard frame field (taint). It never changes AuctionFrame.numTabs or selectedTab.
-- The Flipside tab is not one of the Blizzard tabs: Blizzard's tab code (numTabs = 3) never sees it.
local Host = {}
ns.AuctionTabHost = Host

local OWNER = "Flipside.AuctionTabHost"
local ADDON = "Blizzard_AuctionUI"
local TAB_NAME = "FlipsideAuctionFrameTab"
local TAB_TEMPLATE = "AuctionTabTemplate"
local BLIZZARD_TAB_COUNT = 3
-- The legacy frame is 832 x 447. Space for the portrait and title above, the money frame below.
local INSETS = { top = 75, bottom = 40 }

local function blizzardTab(index)
    return _G["AuctionFrameTab" .. index]
end

-- Hide the three Blizzard panes. Blizzard's own tab click does the same hide.
local function hidePanes()
    AuctionFrameBrowse:Hide()
    AuctionFrameBid:Hide()
    AuctionFrameAuctions:Hide()
end

local function buildTab(state, core)
    local frame = AuctionFrame
    local button = CreateFrame("Button", TAB_NAME, frame, TAB_TEMPLATE)
    state.tab = button
    button:SetText("Flipside")
    button:SetPoint("TOPLEFT", blizzardTab(BLIZZARD_TAB_COUNT), "TOPRIGHT", -8, 0)
    button:SetScript("OnClick", function()
        core:Select()
    end)
end

local function buildFrame(state, core)
    local frame = AuctionFrame
    state.frame = frame
    buildTab(state, core)
    local api = {
        insets = INSETS,
        -- Core shows the panel: remember the Blizzard tab, hide the panes and mark the Flipside tab.
        Enter = function(wasActive)
            if not wasActive then
                state.previousTab = PanelTemplates_GetSelectedTab(frame) or 1
            end
            hidePanes()
            local previous = blizzardTab(state.previousTab)
            if previous then
                PanelTemplates_DeselectTab(previous)
            end
            PanelTemplates_SelectTab(state.tab)
        end,
        -- Core left the panel: unmark the tab, then let Blizzard's tab click show the pane again.
        Leave = function(tabIndex)
            PanelTemplates_DeselectTab(state.tab)
            local tab = blizzardTab(tabIndex or state.previousTab or 1)
            -- A hidden frame needs no click: AuctionFrame_OnShow clicks the first tab.
            if tab and frame:IsShown() then
                AuctionFrameTab_OnClick(tab)
            end
        end,
    }
    core:Mount(frame, api)
    -- A Blizzard tab click already showed its pane. Only hide the panel and unmark the Flipside tab.
    hooksecurefunc("AuctionFrameTab_OnClick", function()
        if core:IsActive() then
            core:Deselect()
            PanelTemplates_DeselectTab(state.tab)
        end
    end)
end

-- Undo a failed build: hide the tab and keep no half-built state.
local function abandon(state, core)
    if state.tab then
        state.tab:Hide()
    end
    core:Unmount()
    state.frame, state.tab = nil, nil
end

local function build(state, core)
    if state.frame or not AuctionFrame then
        return
    end
    local ok, err = pcall(buildFrame, state, core)
    if not ok then
        abandon(state, core)
        ns.ReportError("the Auction House tab is not available: " .. tostring(err))
    end
end

-- Attach the core panel to the legacy Auction House frame, now or when its addon loads.
-- core needs Mount(parent, api), Unmount(), Select(), Leave(tabIndex), Deselect(), IsActive() and core.deps.bus.
-- Returns a state table with frame and tab.
function Host.Attach(core)
    local state = {}
    if AuctionFrame then
        build(state, core)
    else
        local bus = core.deps.bus
        bus:Subscribe("ADDON_LOADED", OWNER, function(_, name)
            if name == ADDON then
                bus:Unsubscribe("ADDON_LOADED", OWNER)
                build(state, core)
            end
        end)
    end
    return state
end
