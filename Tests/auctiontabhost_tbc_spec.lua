local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local TOC = "Flipside_TBC.toc"
local ART = { "TopLeft", "Top", "TopRight", "BotLeft", "Bot", "BotRight" }

local function loadModules()
    local ns = {}
    for _, name in ipairs({ "EventBus", "AuctionTabHost" }) do
        assert(loadfile(manifest.path(name, TOC)))("Flipside", ns)
    end
    return ns
end

describe("AuctionTabHost (TBC)", function()
    local ns, ah, panes, tabs, visual, clicks, core, reports, calls, textures, realCreate

    -- Writes of new keys to a fake Blizzard frame fail: the host must not add fields.
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

    -- Blizzard or another addon adds a tab: the button, the global name and the tab count.
    local function addTab(index)
        local tab = _G.CreateFrame("Button", "AuctionFrameTab" .. index, ah, "AuctionTabTemplate")
        tab:SetID(index)
        tabs[index] = tab
        _G["AuctionFrameTab" .. index] = tab
        ah.numTabs = index
        return tab
    end

    -- existing is the number of tabs before Flipside: 3 for Blizzard alone, 7 with other tab addons.
    local function makeBlizzard(existing)
        ah = realCreate("Frame", "AuctionFrame", UIParent)
        ah.selectedTab, ah.numTabs, ah.type = 0, 0, "list"
        panes, tabs = {}, {}
        for _, name in ipairs({ "AuctionFrameBrowse", "AuctionFrameBid", "AuctionFrameAuctions" }) do
            local pane = realCreate("Frame", name, ah)
            pane:Hide()
            _G[name] = pane
            table.insert(panes, pane)
        end
        for index = 1, existing do
            addTab(index)
        end
        for _, name in ipairs(ART) do
            local texture = { name = name }
            texture.SetTexture = function(_, path)
                textures[name] = path
            end
            _G["AuctionFrame" .. name] = texture
        end
        -- Mirror of AuctionFrameTab_OnClick (Blizzard_AuctionUI.lua): PanelTemplates_SetTab, then the panes.
        _G.AuctionFrameTab_OnClick = function(self)
            local index = self:GetID()
            ah.selectedTab = index
            for number = 1, ah.numTabs do
                visual[tabs[number]] = number == index and "selected" or "deselected"
            end
            for _, pane in ipairs(panes) do
                pane:Hide()
            end
            if index <= 3 then
                panes[index]:Show()
            end
            clicks[#clicks + 1] = index
        end
        _G.PanelTemplates_SetNumTabs = function(frame, number)
            calls[#calls + 1] = { "num", number }
            frame.numTabs = number
        end
        _G.PanelTemplates_EnableTab = function(_, index)
            calls[#calls + 1] = { "enable", index }
        end
        _G.PanelTemplates_TabResize = function(tab)
            calls[#calls + 1] = { "resize", tab }
        end
        _G.AuctionFrame = ah
        guard(ah)
        for _, pane in ipairs(panes) do
            guard(pane)
        end
        for index = 1, existing do
            guard(tabs[index])
        end
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

    local function click(tab)
        tab:GetScript("OnClick")(tab)
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

    before_each(function()
        mock.reset({ flavour = "tbc" })
        realCreate = _G.CreateFrame
        -- The client gives each button of AuctionTabTemplate the OnClick that calls AuctionFrameTab_OnClick.
        _G.CreateFrame = function(kind, name, parent, template)
            local frame = realCreate(kind, name, parent, template)
            if template == "AuctionTabTemplate" then
                frame:SetScript("OnClick", function(self)
                    _G.AuctionFrameTab_OnClick(self)
                end)
            end
            if name then
                _G[name] = frame
                local number = tonumber(name:match("^AuctionFrameTab(%d+)$"))
                if number and tabs then
                    tabs[number] = frame
                end
            end
            return frame
        end
        ns = loadModules()
        visual, clicks, reports, calls, textures = {}, {}, {}, {}, {}
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
        for _, name in ipairs({ "AuctionFrame", "AuctionFrameBrowse", "AuctionFrameBid", "AuctionFrameAuctions",
            "AuctionFrameTab_OnClick", "hooksecurefunc", "PanelTemplates_EnableTab", "PanelTemplates_TabResize" }) do
            _G[name] = nil
        end
        for index = 1, 12 do
            _G["AuctionFrameTab" .. index] = nil
        end
        for _, name in ipairs(ART) do
            _G["AuctionFrame" .. name] = nil
        end
        mock.teardown()
    end)

    for _, existing in ipairs({ 3, 7 }) do
        describe("with " .. existing .. " existing tabs", function()
            local ours, index

            before_each(function()
                index = existing + 1
                makeBlizzard(existing)
            end)

            it("adds a real tab that follows the last one", function()
                local state = ns.AuctionTabHost.Attach(core)
                ours = state.tab
                assert.are.equal(index, state.index)
                assert.are.equal("AuctionFrameTab" .. index, ours.name)
                assert.are.equal("AuctionTabTemplate", ours.template)
                assert.are.equal(index, ours:GetID())
                assert.are.equal("Flipside", ours:GetText())
                assert.are.same({ "LEFT", tabs[existing], "RIGHT", -8, 0 }, ours.points[1])
                assert.are.equal(index, ah.numTabs)
                assert.are.same({ "num", index }, calls[1])
                assert.are.same({ "enable", index }, calls[2])
                assert.are.equal("resize", calls[3][1])
            end)

            it("shows our panel when our tab is clicked", function()
                local state = ns.AuctionTabHost.Attach(core)
                openFrame()
                click(state.tab)
                assert.is_true(core:IsActive())
                assert.is_true(core.content:IsShown())
                assert.are.equal(index, ah.selectedTab)
                for _, pane in ipairs(panes) do
                    assert.is_false(pane:IsShown())
                end
                assert.are.equal("selected", visual[state.tab])
                assert.are.equal("deselected", visual[tabs[1]])
                assert.are.equal(0, core.unmounts)
            end)

            it("sets the plain Auctions art", function()
                local state = ns.AuctionTabHost.Attach(core)
                openFrame()
                click(state.tab)
                assert.are.equal("Interface\\AuctionFrame\\UI-AuctionFrame-Auction-TopLeft", textures.TopLeft)
                assert.are.equal("Interface\\AuctionFrame\\UI-AuctionFrame-Auction-Bot", textures.Bot)
            end)

            it("hides our panel when another tab is clicked", function()
                local state = ns.AuctionTabHost.Attach(core)
                openFrame()
                for _, number in ipairs({ 1, 2, 3, existing }) do
                    click(state.tab)
                    clicks = {}
                    click(tabs[number])
                    assert.is_false(core:IsActive())
                    assert.is_false(core.content:IsShown())
                    assert.are.same({ number }, clicks)
                    assert.are.equal("deselected", visual[state.tab])
                end
                assert.is_true(panes[3]:IsShown() or existing > 3)
            end)

            it("does nothing to our panel when it is not active", function()
                ns.AuctionTabHost.Attach(core)
                openFrame()
                click(tabs[2])
                assert.is_false(core.content:IsShown())
                assert.is_true(panes[2]:IsShown())
            end)

            it("leaves on its own and asks Blizzard to show a tab", function()
                local state = ns.AuctionTabHost.Attach(core)
                openFrame()
                click(state.tab)
                clicks = {}
                core:Leave(2)
                assert.are.same({ 2 }, clicks)
                assert.is_true(panes[2]:IsShown())
                assert.is_false(core:IsActive())
            end)

            it("closes and reopens", function()
                local state = ns.AuctionTabHost.Attach(core)
                openFrame()
                click(state.tab)
                clicks = {}
                closeFrame()
                assert.is_false(core:IsActive())
                assert.are.same({}, clicks)
                openFrame()
                assert.are.same({ 1 }, clicks)
                assert.is_true(panes[1]:IsShown())
                assert.is_false(core.content:IsShown())
                click(state.tab)
                assert.is_true(core:IsActive())
                assert.is_false(panes[1]:IsShown())
            end)

            it("adds no field to a Blizzard frame in a full cycle", function()
                local state = ns.AuctionTabHost.Attach(core)
                openFrame()
                for _ = 1, 2 do
                    click(state.tab)
                    click(tabs[3])
                    click(state.tab)
                    closeFrame()
                    openFrame()
                end
                assert.are.equal(index, ah.numTabs)
                assert.are.equal("list", ah.type)
            end)
        end)
    end

    describe("attach", function()
        it("builds at once when the frame exists", function()
            makeBlizzard(3)
            local state = ns.AuctionTabHost.Attach(core)
            assert.are.equal(ah, state.frame)
            assert.are.equal(1, core.mounts)
            assert.are.equal(ah, core.parent)
        end)

        it("waits for ADDON_LOADED of Blizzard_AuctionUI", function()
            local state = ns.AuctionTabHost.Attach(core)
            assert.is_nil(state.frame)
            core.deps.bus:Emit("ADDON_LOADED", "Other")
            assert.are.equal(0, core.mounts)
            makeBlizzard(3)
            core.deps.bus:Emit("ADDON_LOADED", "Blizzard_AuctionUI")
            assert.are.equal(ah, state.frame)
            assert.are.equal(1, core.mounts)
            core.deps.bus:Emit("ADDON_LOADED", "Blizzard_AuctionUI")
            assert.are.equal(1, core.mounts)
        end)

        it("gives the core the insets and the compact layout", function()
            makeBlizzard(3)
            ns.AuctionTabHost.Attach(core)
            assert.are.same({ left = 14, right = 40, top = 60, bottom = 40 }, core.api.insets)
            assert.are.equal("compact", core.api.layout)
        end)

        it("does not break a tab that another addon adds after ours", function()
            makeBlizzard(3)
            local state = ns.AuctionTabHost.Attach(core)
            local later = addTab(ah.numTabs + 1)
            assert.are.equal("AuctionFrameTab5", later.name)
            assert.are.equal(5, ah.numTabs)
            openFrame()
            click(state.tab)
            click(later)
            assert.is_false(core:IsActive())
            click(state.tab)
            assert.is_true(core:IsActive())
        end)

        it("skips an index that another addon already used without a tab count", function()
            makeBlizzard(3)
            realCreate("Button", "AuctionFrameTab4", ah)
            _G.AuctionFrameTab4 = realCreate("Button", "AuctionFrameTab4", ah)
            local state = ns.AuctionTabHost.Attach(core)
            assert.are.equal(5, state.index)
            assert.are.equal(5, ah.numTabs)
            assert.are.same({ "LEFT", _G.AuctionFrameTab4, "RIGHT", -8, 0 }, state.tab.points[1])
        end)

        it("reports and leaves nothing behind when the build fails", function()
            makeBlizzard(3)
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
end)
