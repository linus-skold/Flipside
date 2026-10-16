local _, ns = ...

-- TBC Anniversary host of the Flipside tabs. It owns the legacy AuctionFrame tab buttons and the panel show and hide.
-- Each tab is a real tab of the frame: the button is AuctionFrameTab<N+1> and PanelTemplates_SetNumTabs adds it.
-- Blizzard's click code then marks the tab. It has no branch for our index, so a hook shows or hides our panel.
-- The host writes no frame field itself. numTabs is written by PanelTemplates_SetNumTabs, as other tab addons do.
local Host = {}
ns.AuctionTabHost = Host
Host.multiTab = true

-- The attached tabs, in order. shared holds the one click hook of the Blizzard frame.
local entries = {}
local shared = {}
local waiting = false

local OWNER = "Flipside.AuctionTabHost"
local ADDON = "Blizzard_AuctionUI"
local TAB_TEMPLATE = "AuctionTabTemplate"
-- Same overlap as the Blizzard tab anchors.
local TAB_GAP = -8
-- The legacy frame is 832 x 447. The panel covers the header strip, the list panel and the bottom bar of the Bids art
-- (sort buttons at y 52, list panel y 74 to 409 and x 23 to 798, Blizzard buttons at 14 above the bottom edge).
local INSETS = { left = 22, right = 34, top = 52, bottom = 14 }
-- The Buying and Selling panels fill the whole content area, so they stay clear of the gold display. It is
-- AuctionFrameMoneyFrame: BOTTOMRIGHT at BOTTOMLEFT of the frame, offset x 181 y 18 (Blizzard_AuctionUI.xml:87-95).
-- The small money template is 13 px high, so the top edge is at 31 px. The inset adds a gap of 4 px: 35.
local MONEY_INSETS = { left = 22, right = 34, top = 52, bottom = 35 }
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

local function buildTab(entry)
    local state = entry.state
    local index = nextIndex()
    local button = CreateFrame("Button", "AuctionFrameTab" .. index, AuctionFrame, TAB_TEMPLATE)
    state.tab, state.index = button, index
    button:SetID(index)
    button:SetText(entry.label)
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

-- Hook the Blizzard tab click once. The template click calls AuctionFrameTab_OnClick for every tab, ours too.
-- It runs before this hook, so Blizzard has already marked the tab and hidden its panes.
local function hookClick()
    if shared.clickHook then
        return
    end
    shared.clickHook = true
    hooksecurefunc("AuctionFrameTab_OnClick", function(tab)
        local clicked
        for _, entry in ipairs(entries) do
            if entry.state.tab == tab then
                clicked = entry
            end
        end
        for _, entry in ipairs(entries) do
            if entry ~= clicked and entry.state.frame and entry.core:IsActive() then
                entry.core:Deselect()
            end
        end
        if clicked and clicked.state.frame then
            clicked.core:Select()
        end
    end)
end

local function buildFrame(entry)
    local state, core = entry.state, entry.core
    local frame = AuctionFrame
    state.frame = frame
    buildTab(entry)
    local api = {
        insets = entry.id and MONEY_INSETS or INSETS,
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
    hookClick()
end

-- Undo a failed build: hide the tab and keep no half-built state.
local function abandon(entry)
    local state = entry.state
    if state.tab then
        state.tab:Hide()
    end
    entry.core:Unmount()
    state.frame, state.tab, state.index = nil, nil, nil
end

local function build(entry)
    if entry.state.frame or not AuctionFrame then
        return
    end
    local ok, err = pcall(buildFrame, entry)
    if not ok then
        abandon(entry)
        ns.ReportError("the Auction House tab " .. entry.label .. " is not available: " .. tostring(err))
    end
end

local function buildAll()
    for _, entry in ipairs({ unpack(entries) }) do
        build(entry)
    end
end

-- Attach a core panel to the legacy Auction House frame, now or when its addon loads. Tabs follow in call order.
-- core needs Mount(parent, api), Unmount(), Select(), Leave(tabIndex), Deselect(), IsActive() and core.deps.bus.
-- opts.label is the tab text (default "Flipside"). opts.id marks a list tab (Buying, Selling).
-- A list tab gets the insets above the gold display. Call Attach again for more tabs.
-- Returns a state table with frame, tab and index.
function Host.Attach(core, opts)
    local entry = { core = core, label = opts and opts.label or "Flipside", id = opts and opts.id, state = {} }
    entries[#entries + 1] = entry
    if AuctionFrame then
        build(entry)
    elseif not waiting then
        waiting = true
        local bus = core.deps.bus
        bus:Subscribe("ADDON_LOADED", OWNER, function(_, name)
            if name == ADDON then
                bus:Unsubscribe("ADDON_LOADED", OWNER)
                waiting = false
                buildAll()
            end
        end)
    end
    return entry.state
end
