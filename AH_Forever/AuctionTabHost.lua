local _, ns = ...

-- WoW: Forever host of the Flipside tabs. It owns Blizzard's AuctionHouseFrame, the tab buttons and the pane switch.
-- It supports many tabs (Host.multiTab). Each tab has its own core. One tab at a time is active.
-- It only reads Blizzard's frame fields and never writes to them (taint).
local Host = {}
ns.AuctionTabHost = Host
Host.multiTab = true

local OWNER = "Flipside.AuctionTabHost"
local ADDON = "Blizzard_AuctionHouseUI"
local TAB_TEMPLATES = { "AuctionHouseFrameTabTemplate", "PanelTabButtonTemplate" }
local INSETS = { top = 60, bottom = 30 }

-- The attached tabs, in order. shared holds the state of the one Blizzard frame.
local entries = {}
local shared = {}
local waiting = false

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

-- Returns the built tab (other than skip) whose panel is active, or nil.
local function activeEntry(skip)
    for _, entry in ipairs(entries) do
        if entry ~= skip and entry.state.frame and entry.core:IsActive() then
            return entry
        end
    end
    return nil
end

-- Create the tab button after the last tab. The tab template can add the button to frame.Tabs itself.
local function buildTab(entry, frame)
    local state = entry.state
    local tabs = frame.Tabs
    local last = tabs[#tabs]
    local button = createTabButton(frame)
    state.tab = button
    if not indexOf(tabs, button) then
        table.insert(tabs, button)
    end
    state.index = indexOf(tabs, button)
    button:SetID(state.index)
    button:SetText(entry.label)
    if last then
        button:SetPoint("TOPLEFT", last, "TOPRIGHT", 3, 0)
    end
    button:SetScript("OnClick", function()
        entry.core:Select()
    end)
    PanelTemplates_SetNumTabs(frame, #tabs)
end

-- Hook the Blizzard tabs and the display mode once. The hooks work on the active tab.
local function hookFrame(frame)
    if not shared.tabHooks then
        for blizzardIndex, blizzardTab in ipairs(shared.blizzardTabs) do
            blizzardTab:HookScript("OnClick", function()
                local active = activeEntry()
                if active then
                    active.core:Leave(blizzardIndex)
                end
            end)
        end
        shared.tabHooks = true
    end
    if not shared.modeHook then
        hooksecurefunc(frame, "SetDisplayMode", function()
            -- Same mode again: Blizzard did nothing, so the tab click hook restores the panes.
            local active = activeEntry()
            if active and frame:GetDisplayMode() ~= shared.selectedMode then
                active.core:Deselect()
            end
        end)
        shared.modeHook = true
    end
end

local function buildFrame(entry, frame)
    local state, core = entry.state, entry.core
    if not shared.blizzardTabs then
        local blizzardTabs = {}
        for index, existing in ipairs(frame.Tabs) do
            blizzardTabs[index] = existing
        end
        shared.blizzardTabs = blizzardTabs
    end
    state.frame = frame
    buildTab(entry, frame)
    local api = {
        insets = INSETS,
        -- Core shows the panel: remember the Blizzard tab, hide the panes and mark this tab.
        -- If another Flipside tab is active, it hides and the remembered tab stays.
        Enter = function(wasActive)
            local other = activeEntry(entry)
            if other then
                other.core:Deselect()
            elseif not wasActive then
                shared.previousTab = frame.selectedTab
            end
            shared.selectedMode = setPanes(frame, false)
            PanelTemplates_SetTab(frame, state.index)
        end,
        -- Core left the panel: show the panes again and mark the given or the previous Blizzard tab.
        Leave = function(tabIndex)
            setPanes(frame, true)
            local index = tabIndex or shared.previousTab
            if index then
                PanelTemplates_SetTab(frame, index)
            end
        end,
    }
    core:Mount(frame, api)
    hookFrame(frame)
end

-- Undo a failed build: hide the tab, remove it from the frame and keep no half-built state.
local function abandon(entry, frame)
    local state = entry.state
    local tab = state.tab
    if tab then
        tab:Hide()
        local index = indexOf(frame.Tabs, tab)
        if index then
            table.remove(frame.Tabs, index)
            PanelTemplates_SetNumTabs(frame, #frame.Tabs)
        end
    end
    entry.core:Unmount()
    state.frame, state.tab, state.index = nil, nil, nil
end

local function build(entry)
    local frame = AuctionHouseFrame
    if entry.state.frame or not frame then
        return
    end
    local ok, err = pcall(buildFrame, entry, frame)
    if not ok then
        abandon(entry, frame)
        ns.ReportError("the Auction House tab " .. entry.label .. " is not available: " .. tostring(err))
    end
end

local function buildAll()
    for _, entry in ipairs({ unpack(entries) }) do
        build(entry)
    end
end

-- Attach a core panel to the Auction House frame, now or when its addon loads.
-- core needs Mount(parent, api), Unmount(), Select(), Leave(tabIndex), Deselect(), IsActive() and core.deps.bus.
-- opts.label is the tab text (default "Flipside"). Call Attach again for more tabs.
-- Returns a state table with frame, tab and index.
function Host.Attach(core, opts)
    local entry = { core = core, label = opts and opts.label or "Flipside", state = {} }
    entries[#entries + 1] = entry
    if AuctionHouseFrame then
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
