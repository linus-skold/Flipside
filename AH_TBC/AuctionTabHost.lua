local _, ns = ...

-- TBC Anniversary host of the Flipside tab. It owns the legacy AuctionFrame tab button and the panel show and hide.
-- The tab is a real tab of the frame: the button is AuctionFrameTab<N+1> and PanelTemplates_SetNumTabs adds it.
-- Blizzard's click code then marks the tab. It has no branch for our index, so a hook shows or hides our panel.
-- The host writes no frame field itself. numTabs is written by PanelTemplates_SetNumTabs, as other tab addons do.
local Host = {}
ns.AuctionTabHost = Host

local OWNER = "Flipside.AuctionTabHost"
local ADDON = "Blizzard_AuctionUI"
local TAB_TEMPLATE = "AuctionTabTemplate"
-- Same overlap as the Blizzard tab anchors.
local TAB_GAP = -8
-- The legacy frame is 832 x 447. The panel sits below the title bar, above the tab row and the money frame.
local INSETS = { left = 14, right = 40, top = 60, bottom = 40 }
-- The plain Auctions art, without the search bar of the Browse art.
local ART = {
    { "AuctionFrameTopLeft", "TopLeft" },
    { "AuctionFrameTop", "Top" },
    { "AuctionFrameTopRight", "TopRight" },
    { "AuctionFrameBotLeft", "BotLeft" },
    { "AuctionFrameBot", "Bot" },
    { "AuctionFrameBotRight", "BotRight" },
}

local function blizzardTab(index)
    return _G["AuctionFrameTab" .. index]
end

local function setArt()
    for _, pair in ipairs(ART) do
        local texture = _G[pair[1]]
        if texture then
            texture:SetTexture("Interface\\AuctionFrame\\UI-AuctionFrame-Auction-" .. pair[2])
        end
    end
end

-- Find the first free tab index after the tabs that exist now.
local function nextIndex()
    local index = (AuctionFrame.numTabs or 0) + 1
    while blizzardTab(index) do
        index = index + 1
    end
    return index
end

local function buildTab(state)
    local index = nextIndex()
    local button = CreateFrame("Button", "AuctionFrameTab" .. index, AuctionFrame, TAB_TEMPLATE)
    state.tab, state.index = button, index
    button:SetID(index)
    button:SetText("Flipside")
    local last = blizzardTab(index - 1)
    if last then
        button:SetPoint("LEFT", last, "RIGHT", TAB_GAP, 0)
    end
    PanelTemplates_SetNumTabs(AuctionFrame, index)
    PanelTemplates_EnableTab(AuctionFrame, index)
    PanelTemplates_TabResize(button, 0, nil, 36)
end

local function buildFrame(state, core)
    local frame = AuctionFrame
    state.frame = frame
    buildTab(state)
    local api = {
        insets = INSETS,
        layout = "compact",
        -- Core shows the panel. Blizzard's click code already hid the panes and marked the tab.
        Enter = function()
            setArt()
            if SetAuctionsTabShowing then
                SetAuctionsTabShowing(false)
            end
        end,
        -- Core left the panel by itself (not by a tab click): let Blizzard show a tab again.
        Leave = function(tabIndex)
            local tab = blizzardTab(tabIndex or 1)
            -- A hidden frame needs no click: AuctionFrame_OnShow clicks the first tab.
            if tab and frame:IsShown() then
                AuctionFrameTab_OnClick(tab)
            end
        end,
    }
    core:Mount(frame, api)
    -- The template click calls AuctionFrameTab_OnClick for every tab, ours too. It runs before this hook.
    hooksecurefunc("AuctionFrameTab_OnClick", function(tab)
        if tab == state.tab then
            core:Select()
        elseif core:IsActive() then
            core:Deselect()
        end
    end)
end

-- Undo a failed build: hide the tab and keep no half-built state.
local function abandon(state, core)
    if state.tab then
        state.tab:Hide()
    end
    core:Unmount()
    state.frame, state.tab, state.index = nil, nil, nil
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
-- Returns a state table with frame, tab and index.
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
