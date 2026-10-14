local _, ns = ...

-- WoW: Forever host of the Flipside tab. It owns Blizzard's AuctionHouseFrame, the tab button and the pane switch.
-- It only reads Blizzard's frame fields and never writes to them (taint).
local Host = {}
ns.AuctionTabHost = Host

local OWNER = "Flipside.AuctionTabHost"
local ADDON = "Blizzard_AuctionHouseUI"
local TAB_TEMPLATES = { "AuctionHouseFrameTabTemplate", "PanelTabButtonTemplate" }
local INSETS = { top = 60, bottom = 30 }

-- Start page scan bar: the bottom strip right of the gold display (Blizzard_AuctionHouseFrame.xml:11-16 and 17-21).
-- The strip is 27 px high above the frame edge: the category list ends 27 px above the bottom
-- (Blizzard_AuctionHouseFrame.xml:76-80, height 438 in Blizzard_AuctionHouseCategoriesList.xml:61).
local START_BAR = { left = 174, right = 8, bottom = 4, buttonWidth = 90, stopWidth = 60 }

local function indexOf(list, item)
    for index, value in ipairs(list) do
        if value == item then
            return index
        end
    end
    return nil
end

local function createTabButton(frame)
    local button
    for _, template in ipairs(TAB_TEMPLATES) do
        local ok, result = pcall(CreateFrame, "Button", nil, frame, template)
        if ok then
            button = result
            break
        end
    end
    return button or CreateFrame("Button", nil, frame, "PanelTabButtonTemplate")
end

-- Show or hide the panes that the current display mode lists. Blizzard's state is only read.
local function setPanes(frame, shown)
    local mode = frame:GetDisplayMode()
    if type(mode) == "table" then
        for _, name in ipairs(mode) do
            if frame[name] then
                frame[name]:SetShown(shown)
            end
        end
    end
    return mode
end

-- Create the tab button after the Blizzard tabs. The tab template can add the button to frame.Tabs itself.
local function buildTab(state, core, frame)
    local tabs = frame.Tabs
    local blizzardTabs = {}
    for index, existing in ipairs(tabs) do
        blizzardTabs[index] = existing
    end
    local last = blizzardTabs[#blizzardTabs]
    local button = createTabButton(frame)
    state.tab = button
    if not indexOf(tabs, button) then
        table.insert(tabs, button)
    end
    state.index = indexOf(tabs, button)
    button:SetID(state.index)
    button:SetText("Flipside")
    if last then
        button:SetPoint("TOPLEFT", last, "TOPRIGHT", 3, 0)
    end
    button:SetScript("OnClick", function()
        core:Select()
    end)
    PanelTemplates_SetNumTabs(frame, #tabs)
    return blizzardTabs
end

-- Give the place of the scan bar on the browse page. The browse results frame is shown only on the Buy start page.
-- Blizzard frames are only read.
function Host.StartPage(frame)
    local page = frame.BrowseResultsFrame
    if not page then
        return nil
    end
    return {
        parent = frame,
        page = page,
        buttonWidth = START_BAR.buttonWidth,
        stopWidth = START_BAR.stopWidth,
        anchor = function(bar)
            bar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", START_BAR.left, START_BAR.bottom)
            bar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -START_BAR.right, START_BAR.bottom)
        end,
    }
end

local function buildFrame(state, core, frame)
    state.frame = frame
    local blizzardTabs = buildTab(state, core, frame)
    local api = {
        insets = INSETS,
        startPage = Host.StartPage(frame),
        -- Core shows the panel: remember the Blizzard tab, hide the panes and mark the Flipside tab.
        Enter = function(wasActive)
            if not wasActive then
                state.previousTab = frame.selectedTab
            end
            state.selectedMode = setPanes(frame, false)
            PanelTemplates_SetTab(frame, state.index)
        end,
        -- Core left the panel: show the panes again and mark the given or the previous Blizzard tab.
        Leave = function(tabIndex)
            setPanes(frame, true)
            local index = tabIndex or state.previousTab
            if index then
                PanelTemplates_SetTab(frame, index)
            end
        end,
    }
    core:Mount(frame, api)
    for blizzardIndex, blizzardTab in ipairs(blizzardTabs) do
        blizzardTab:HookScript("OnClick", function()
            if core:IsActive() then
                core:Leave(blizzardIndex)
            end
        end)
    end
    hooksecurefunc(frame, "SetDisplayMode", function()
        -- Same mode again: Blizzard did nothing, so the tab click hook restores the panes.
        if core:IsActive() and frame:GetDisplayMode() ~= state.selectedMode then
            core:Deselect()
        end
    end)
end

-- Undo a failed build: hide the tab, remove it from the frame and keep no half-built state.
local function abandon(state, core, frame)
    local tab = state.tab
    if tab then
        tab:Hide()
        local index = indexOf(frame.Tabs, tab)
        if index then
            table.remove(frame.Tabs, index)
            PanelTemplates_SetNumTabs(frame, #frame.Tabs)
        end
    end
    core:Unmount()
    state.frame, state.tab, state.index = nil, nil, nil
end

local function build(state, core)
    local frame = AuctionHouseFrame
    if state.frame or not frame then
        return
    end
    local ok, err = pcall(buildFrame, state, core, frame)
    if not ok then
        abandon(state, core, frame)
        ns.ReportError("the Auction House tab is not available: " .. tostring(err))
    end
end

-- Attach the core panel to the Auction House frame, now or when its addon loads.
-- core needs Mount(parent, api), Unmount(), Select(), Leave(tabIndex), Deselect(), IsActive() and core.deps.bus.
-- Returns a state table with frame, tab and index.
function Host.Attach(core)
    local state = {}
    if AuctionHouseFrame then
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
