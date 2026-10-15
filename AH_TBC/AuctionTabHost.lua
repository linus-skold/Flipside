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
-- The legacy frame is 832 x 447. The panel covers the header strip, the list panel and the bottom bar of the Bids art
-- (sort buttons at y 52, list panel y 74 to 409 and x 23 to 798, Blizzard buttons at 14 above the bottom edge).
local INSETS = { left = 22, right = 34, top = 52, bottom = 14 }
-- The Bids art: a full-width list panel, with no filter column and no boxes. Blizzard sets these textures for the
-- Bids tab in AuctionFrameTab_OnClick. It sets all six again on the next tab click, so the art is restored.
local ART = {
    { "AuctionFrameTopLeft", "Bid-TopLeft" },
    { "AuctionFrameTop", "Auction-Top" },
    { "AuctionFrameTopRight", "Auction-TopRight" },
    { "AuctionFrameBotLeft", "Bid-BotLeft" },
    { "AuctionFrameBot", "Auction-Bot" },
    { "AuctionFrameBotRight", "Bid-BotRight" },
}

-- Start page scan bar: the top strip of the Browse page, right of the title and left of the close button.
-- The title is at the top centre (Blizzard_AuctionUI.xml:115-123). The close button is 3 px outside the
-- right edge (:96-104). The Browse labels start 38 px below the top (:126-134), the Search button 39 px (:1190-1200).
local START_BAR = { right = 36, top = 9, width = 350, buttonWidth = 62, stopWidth = 52 }

local function blizzardTab(index)
    return _G["AuctionFrameTab" .. index]
end

local function setArt()
    for _, pair in ipairs(ART) do
        local texture = _G[pair[1]]
        if texture then
            texture:SetTexture("Interface\\AuctionFrame\\UI-AuctionFrame-" .. pair[2])
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

-- Give the place of the scan bar on the Browse page. Blizzard frames are only read.
function Host.StartPage(frame)
    local page = _G.AuctionFrameBrowse
    if not page then
        return nil
    end
    return {
        parent = frame,
        page = page,
        width = START_BAR.width,
        buttonWidth = START_BAR.buttonWidth,
        stopWidth = START_BAR.stopWidth,
        anchor = function(bar)
            bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -START_BAR.right, -START_BAR.top)
        end,
    }
end

local function buildFrame(state, core)
    local frame = AuctionFrame
    state.frame = frame
    buildTab(state)
    local api = {
        insets = INSETS,
        layout = "compact",
        startPage = Host.StartPage(frame),
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
