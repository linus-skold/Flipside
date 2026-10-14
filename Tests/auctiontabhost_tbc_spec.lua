local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local TOC = "Flipside_TBC.toc"
local FAKE_GLOBALS = { "AuctionFrame", "AuctionFrameBrowse", "AuctionFrameBid", "AuctionFrameAuctions",
    "AuctionFrameTab1", "AuctionFrameTab2", "AuctionFrameTab3", "AuctionFrameTab_OnClick", "hooksecurefunc",
    "PanelTemplates_GetSelectedTab", "PanelTemplates_SelectTab", "PanelTemplates_DeselectTab" }

local function loadModules()
    local ns = {}
    for _, name in ipairs({ "EventBus", "AuctionTabHost" }) do
        assert(loadfile(manifest.path(name, TOC)))("Flipside", ns)
    end
    return ns
end

describe("AuctionTabHost (TBC)", function()
    local ns, ah, panes, tabs, visual, clicks, core, reports

    -- Writes of new keys to a fake Blizzard frame fail: Blizzard fields are read only for the addon.
    local function guard(frame)
        local meta = getmetatable(frame)
        setmetatable(frame, {
            __index = meta.__index,
            __newindex = function(_, key)
                error("write to a Blizzard frame: " .. tostring(key), 2)
            end,
        })
        return frame
    end

    local function makeBlizzard()
        ah = CreateFrame("Frame", "AuctionFrame", UIParent)
        ah.selectedTab, ah.numTabs, ah.type = 0, 3, "list"
        guard(ah)
        ah:Hide()
        panes, tabs = {}, {}
        for _, name in ipairs({ "AuctionFrameBrowse", "AuctionFrameBid", "AuctionFrameAuctions" }) do
            local pane = guard(CreateFrame("Frame", name, ah))
            pane:Hide()
            _G[name] = pane
            table.insert(panes, pane)
        end
        for index = 1, 3 do
            local tab = CreateFrame("Button", "AuctionFrameTab" .. index, ah, "AuctionTabTemplate")
            tab:SetID(index)
            guard(tab)
            tab:SetScript("OnClick", function(self)
                _G.AuctionFrameTab_OnClick(self)
            end)
            _G["AuctionFrameTab" .. index] = tab
            tabs[index] = tab
        end
        -- Mirror of Blizzard_AuctionUI.lua:396. Blizzard's own code may write its fields.
        _G.AuctionFrameTab_OnClick = function(self)
            local index = self:GetID()
            ah.selectedTab = index
            for _, pane in ipairs(panes) do
                pane:Hide()
            end
            panes[index]:Show()
            clicks[#clicks + 1] = index
        end
        _G.PanelTemplates_GetSelectedTab = function(frame)
            return frame.selectedTab
        end
        _G.PanelTemplates_SelectTab = function(tab)
            visual[tab] = "selected"
        end
        _G.PanelTemplates_DeselectTab = function(tab)
            visual[tab] = "deselected"
        end
        _G.AuctionFrame = ah
    end

    -- A core with the real shape: Leave deselects first, then calls the host.
    local function makeCore()
        local fake = { deps = { bus = ns.EventBus.New({}) }, active = false, mounts = 0, unmounts = 0 }
        function fake:Mount(parent, api)
            self.mounts = self.mounts + 1
            self.parent, self.api = parent, api
            self.content = CreateFrame("Frame", nil, parent)
            self.content:Hide()
            self.content:SetScript("OnHide", function()
                if self.active then
                    self:Leave()
                end
            end)
        end
        function fake:Unmount()
            self.unmounts = self.unmounts + 1
        end
        function fake:IsActive()
            return self.active
        end
        function fake:Select()
            self.api.Enter(self.active)
            self.active = true
            self.content:Show()
        end
        function fake:Deselect()
            self.active = false
            self.content:Hide()
        end
        function fake:Leave(index)
            self:Deselect()
            self.api.Leave(index)
        end
        return fake
    end

    local function openFrame()
        ah:Show()
        -- Mirror of AuctionFrame_OnShow: it clicks the first tab.
        _G.AuctionFrameTab_OnClick(tabs[1])
    end

    -- The client hides the children of a hidden frame.
    local function closeFrame()
        ah:Hide()
        core.content:Hide()
    end

    local function ourTab(state)
        return state.tab
    end

    before_each(function()
        mock.reset({ flavour = "tbc" })
        ns = loadModules()
        visual, clicks, reports = {}, {}, {}
        ns.ReportError = function(message)
            table.insert(reports, message)
        end
        _G.hooksecurefunc = function(name, hook)
            local original = _G[name]
            _G[name] = function(...)
                original(...)
                hook(...)
            end
        end
        core = makeCore()
    end)

    after_each(function()
        for _, name in ipairs(FAKE_GLOBALS) do
            _G[name] = nil
        end
        mock.teardown()
    end)

    describe("attach", function()
        it("builds at once when the frame exists", function()
            makeBlizzard()
            local state = ns.AuctionTabHost.Attach(core)
            assert.are.equal(ah, state.frame)
            assert.are.equal(1, core.mounts)
            assert.are.equal(ah, core.parent)
            assert.are.equal("FlipsideAuctionFrameTab", ourTab(state).name)
            assert.are.equal("AuctionTabTemplate", ourTab(state).template)
            assert.are.equal("Flipside", ourTab(state):GetText())
        end)

        it("waits for ADDON_LOADED of Blizzard_AuctionUI", function()
            local state = ns.AuctionTabHost.Attach(core)
            assert.is_nil(state.frame)
            core.deps.bus:Emit("ADDON_LOADED", "Other")
            assert.are.equal(0, core.mounts)
            makeBlizzard()
            core.deps.bus:Emit("ADDON_LOADED", "Blizzard_AuctionUI")
            assert.are.equal(ah, state.frame)
            assert.are.equal(1, core.mounts)
            core.deps.bus:Emit("ADDON_LOADED", "Blizzard_AuctionUI")
            assert.are.equal(1, core.mounts)
        end)

        it("anchors the tab to the right of the last Blizzard tab", function()
            makeBlizzard()
            local state = ns.AuctionTabHost.Attach(core)
            assert.are.same({ "TOPLEFT", tabs[3], "TOPRIGHT", -8, 0 }, ourTab(state).points[1])
        end)

        it("gives the core insets for the legacy frame", function()
            makeBlizzard()
            ns.AuctionTabHost.Attach(core)
            assert.are.same({ top = 75, bottom = 40 }, core.api.insets)
        end)

        it("does not change the tab count of Blizzard's frame", function()
            makeBlizzard()
            ns.AuctionTabHost.Attach(core)
            assert.are.equal(3, ah.numTabs)
            assert.are.same({}, mock.tabCalls)
        end)

        it("reports and leaves nothing behind when the build fails", function()
            makeBlizzard()
            core.Mount = function()
                error("boom")
            end
            local state = ns.AuctionTabHost.Attach(core)
            assert.are.equal(1, #reports)
            assert.is_truthy(reports[1]:find("boom", 1, true))
            assert.are.equal(1, core.unmounts)
            assert.is_nil(state.frame)
            assert.is_nil(state.tab)
        end)
    end)

    describe("select", function()
        local state

        before_each(function()
            makeBlizzard()
            state = ns.AuctionTabHost.Attach(core)
            openFrame()
        end)

        it("hides the three panes and marks only our tab", function()
            assert.is_true(panes[1]:IsShown())
            ourTab(state):GetScript("OnClick")(ourTab(state))
            assert.is_true(core.content:IsShown())
            for _, pane in ipairs(panes) do
                assert.is_false(pane:IsShown())
            end
            assert.are.equal("selected", visual[ourTab(state)])
            assert.are.equal("deselected", visual[tabs[1]])
        end)

        it("keeps the Blizzard selected tab field", function()
            ourTab(state):GetScript("OnClick")(ourTab(state))
            assert.are.equal(1, ah.selectedTab)
            assert.are.equal(3, ah.numTabs)
        end)

        it("restores the Blizzard tab that was selected before", function()
            tabs[3]:GetScript("OnClick")(tabs[3])
            clicks = {}
            ourTab(state):GetScript("OnClick")(ourTab(state))
            assert.is_false(panes[3]:IsShown())
            core:Leave()
            assert.are.same({ 3 }, clicks)
            assert.is_true(panes[3]:IsShown())
            assert.are.equal("deselected", visual[ourTab(state)])
        end)

        it("restores the given tab on Leave(i)", function()
            ourTab(state):GetScript("OnClick")(ourTab(state))
            clicks = {}
            core:Leave(2)
            assert.are.same({ 2 }, clicks)
            assert.is_true(panes[2]:IsShown())
            assert.is_false(core.content:IsShown())
        end)

        it("keeps the saved tab when selected twice", function()
            tabs[2]:GetScript("OnClick")(tabs[2])
            ourTab(state):GetScript("OnClick")(ourTab(state))
            ourTab(state):GetScript("OnClick")(ourTab(state))
            clicks = {}
            core:Leave()
            assert.are.same({ 2 }, clicks)
        end)
    end)

    describe("Blizzard tab click", function()
        local state

        before_each(function()
            makeBlizzard()
            state = ns.AuctionTabHost.Attach(core)
            openFrame()
            ourTab(state):GetScript("OnClick")(ourTab(state))
            clicks = {}
        end)

        it("hides our panel and shows the clicked pane", function()
            tabs[2]:GetScript("OnClick")(tabs[2])
            assert.is_false(core:IsActive())
            assert.is_false(core.content:IsShown())
            assert.is_true(panes[2]:IsShown())
            assert.is_false(panes[1]:IsShown())
            assert.are.equal("deselected", visual[ourTab(state)])
            assert.are.equal(2, ah.selectedTab)
        end)

        it("clicks the Blizzard tab once only", function()
            tabs[1]:GetScript("OnClick")(tabs[1])
            assert.are.same({ 1 }, clicks)
        end)

        it("does nothing to our panel when it is not active", function()
            tabs[1]:GetScript("OnClick")(tabs[1])
            tabs[3]:GetScript("OnClick")(tabs[3])
            assert.is_false(core.content:IsShown())
            assert.is_true(panes[3]:IsShown())
        end)

        it("handles a click from Blizzard code, not from a tab button", function()
            _G.AuctionFrameTab_OnClick(tabs[3])
            assert.is_false(core:IsActive())
            assert.is_true(panes[3]:IsShown())
        end)
    end)

    describe("close and reopen", function()
        local state

        before_each(function()
            makeBlizzard()
            state = ns.AuctionTabHost.Attach(core)
            openFrame()
        end)

        it("leaves the panel when the frame closes and shows Browse on reopen", function()
            ourTab(state):GetScript("OnClick")(ourTab(state))
            clicks = {}
            closeFrame()
            assert.is_false(core:IsActive())
            assert.are.same({}, clicks)
            assert.are.equal("deselected", visual[ourTab(state)])
            openFrame()
            assert.are.same({ 1 }, clicks)
            assert.is_true(panes[1]:IsShown())
            assert.is_false(core.content:IsShown())
        end)

        it("can select the tab again after a reopen", function()
            ourTab(state):GetScript("OnClick")(ourTab(state))
            closeFrame()
            openFrame()
            ourTab(state):GetScript("OnClick")(ourTab(state))
            assert.is_true(core:IsActive())
            assert.is_false(panes[1]:IsShown())
            assert.are.equal("selected", visual[ourTab(state)])
        end)
    end)

    describe("taint rule", function()
        it("writes no field of a Blizzard frame in a full cycle", function()
            makeBlizzard()
            ah.selectedTab = 1 -- Blizzard's own code sets it; the guard allows existing keys
            local state = ns.AuctionTabHost.Attach(core)
            openFrame()
            local before = { numTabs = ah.numTabs, selectedTab = ah.selectedTab, type = ah.type }
            for _ = 1, 2 do
                ourTab(state):GetScript("OnClick")(ourTab(state))
                tabs[3]:GetScript("OnClick")(tabs[3])
                ourTab(state):GetScript("OnClick")(ourTab(state))
                closeFrame()
                openFrame()
            end
            assert.are.equal(before.numTabs, ah.numTabs)
            assert.are.equal(before.type, ah.type)
            for _, frame in ipairs({ ah, tabs[1], tabs[2], tabs[3], panes[1], panes[2], panes[3] }) do
                assert.is_nil(rawget(frame, "flipside"))
            end
        end)

        it("fails the guard when a new field is written", function()
            makeBlizzard()
            assert.has_error(function()
                ah.flipside = true
            end)
        end)
    end)
end)
