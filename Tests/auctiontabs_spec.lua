local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local ADDON = "Blizzard_AuctionHouseUI"

local function loadModules(toc)
    local ns = { ReportError = function() end }
    for _, name in ipairs({ "EventBus", "AuctionTabs", "AuctionTabHost" }) do
        assert(loadfile(manifest.path(name, toc)))("Flipside", ns)
    end
    return ns
end

describe("AuctionTabs registry and Forever host", function()
    local ns, ah, modes, reports, bus

    -- A write of a new key to a fake Blizzard frame fails: the host must not add fields.
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

    local function makeAH()
        local frame = CreateFrame("Frame", "AuctionHouseFrame", UIParent)
        modes = { Buy = { "PaneA", "PaneB" }, Auctions = { "PaneC" } }
        for _, name in ipairs({ "PaneA", "PaneB", "PaneC" }) do
            frame[name] = CreateFrame("Frame", nil, frame)
            frame[name]:Hide()
        end
        frame.Tabs = {}
        frame.selectedTab = 1
        for _, mode in ipairs({ "Buy", "Auctions" }) do
            local tab = CreateFrame("Button", nil, frame, "AuctionHouseFrameTabTemplate")
            tab:SetScript("OnClick", function()
                frame:SetDisplayMode(modes[mode])
            end)
            table.insert(frame.Tabs, tab)
        end
        frame.GetDisplayMode = function(self)
            return self.displayMode
        end
        frame.SetDisplayMode = function(self, mode)
            if self.displayMode == mode then
                return
            end
            self.displayMode = mode
            for _, list in pairs(modes) do
                for _, name in ipairs(list) do
                    self[name]:Hide()
                end
            end
            for _, name in ipairs(mode) do
                self[name]:Show()
            end
        end
        frame:SetDisplayMode(modes.Buy)
        return frame
    end

    -- A core with the real shape: Leave deselects first, then calls the host.
    local function makeCore()
        local fake = { deps = { bus = bus }, active = false, unmounts = 0 }
        function fake:Mount(parent, api)
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

    local function paneShown(name)
        return ah[name]:IsShown()
    end

    local function lastTab()
        local calls = mock.tabCalls
        for index = #calls, 1, -1 do
            if calls[index][1] == "tab" then
                return calls[index][3]
            end
        end
    end

    before_each(function()
        mock.reset()
        _G.hooksecurefunc = function(target, name, hook)
            local original = target[name]
            target[name] = function(...)
                original(...)
                hook(...)
            end
        end
        reports = {}
        bus = nil
    end)

    after_each(function()
        _G.AuctionHouseFrame = nil
        _G.hooksecurefunc = nil
        mock.teardown()
    end)

    local function setup()
        ns = loadModules("Flipside.toc")
        ns.ReportError = function(text)
            reports[#reports + 1] = text
        end
        bus = ns.EventBus.New({})
    end

    describe("registry", function()
        before_each(setup)

        it("checks the spec", function()
            assert.has_error(function()
                ns.AuctionTabs.Register({ label = "x", create = function() end })
            end)
            assert.has_error(function()
                ns.AuctionTabs.Register({ id = "x", create = function() end })
            end)
        end)

        it("keeps the order and replaces the same id", function()
            local function create() end
            ns.AuctionTabs.Register({ id = "a", label = "A", create = create })
            ns.AuctionTabs.Register({ id = "b", label = "B", create = create })
            ns.AuctionTabs.Register({ id = "a", label = "A2", create = create })
            local list = ns.AuctionTabs.List()
            assert.are.equal(2, #list)
            assert.are.equal("A2", list[1].label)
            assert.are.equal("b", list[2].id)
        end)

        it("skips unavailable specs", function()
            local attached = {}
            ns.AuctionTabs.Register({ id = "a", label = "A", create = makeCore, available = function()
                return false
            end })
            ns.AuctionTabs.AttachAll({ host = { multiTab = true, Attach = function(core)
                attached[#attached + 1] = core
            end } })
            assert.are.same({}, attached)
        end)

        it("gives a host without many tabs no extra tab", function()
            local attached = 0
            ns.AuctionTabs.Register({ id = "a", label = "A", create = makeCore })
            local cores = ns.AuctionTabs.AttachAll({ host = { Attach = function()
                attached = attached + 1
            end } })
            assert.are.same({}, cores)
            assert.are.equal(0, attached)
        end)

        it("is a no-op on the TBC host", function()
            local tbc = loadModules("Flipside_TBC.toc")
            tbc.AuctionTabs.Register({ id = "a", label = "A", create = function()
                error("must not create")
            end })
            assert.is_nil(tbc.AuctionTabHost.multiTab)
            assert.are.same({}, tbc.AuctionTabs.AttachAll({ bus = bus }))
        end)

        it("reports a create error and goes on", function()
            local attached = {}
            ns.AuctionTabs.Register({ id = "bad", label = "Bad", create = function()
                error("boom")
            end })
            ns.AuctionTabs.Register({ id = "ok", label = "Ok", create = makeCore })
            local cores = ns.AuctionTabs.AttachAll({ host = { multiTab = true, Attach = function(core, opts)
                attached[#attached + 1] = opts.label
                return core
            end } })
            assert.are.same({ "Ok" }, attached)
            assert.is_not_nil(cores.ok)
            assert.are.equal(1, #reports)
        end)
    end)

    describe("host with two tabs", function()
        local flipside, buying, flipsideTab, buyingTab

        local function attachBoth()
            flipside = makeCore()
            ns.AuctionTabHost.Attach(flipside)
            ns.AuctionTabs.Register({ id = "buying", label = "Buying", create = function()
                buying = makeCore()
                return buying
            end })
            ns.AuctionTabs.AttachAll({ bus = bus })
            flipsideTab, buyingTab = ah.Tabs[3], ah.Tabs[4]
        end

        before_each(function()
            setup()
            ah = makeAH()
            _G.AuctionHouseFrame = ah
        end)

        it("adds both tab buttons after the Blizzard tabs", function()
            attachBoth()
            assert.are.equal(4, #ah.Tabs)
            assert.are.equal("Flipside", flipsideTab.text)
            assert.are.equal("Buying", buyingTab.text)
            assert.are.equal(3, flipsideTab:GetID())
            assert.are.equal(4, buyingTab:GetID())
            assert.are.equal(ah, flipside.parent)
            assert.are.equal(ah, buying.parent)
        end)

        it("switches between the tabs and keeps the first Blizzard tab", function()
            attachBoth()
            click(flipsideTab)
            assert.is_true(flipside.active)
            assert.is_false(paneShown("PaneA"))
            assert.are.equal(3, lastTab())
            click(buyingTab)
            assert.is_false(flipside.active)
            assert.is_true(buying.active)
            assert.is_false(flipside.content:IsShown())
            assert.is_true(buying.content:IsShown())
            assert.is_false(paneShown("PaneA"))
            assert.are.equal(4, lastTab())
            click(flipsideTab)
            assert.is_true(flipside.active)
            assert.is_false(buying.active)
        end)

        it("restores the Blizzard panes when a Blizzard tab is clicked", function()
            attachBoth()
            click(buyingTab)
            click(ah.Tabs[1])
            assert.is_false(buying.active)
            assert.is_true(paneShown("PaneA"))
            assert.is_true(paneShown("PaneB"))
            assert.are.equal(1, lastTab())
        end)

        it("restores the panes of another mode", function()
            attachBoth()
            click(flipsideTab)
            click(ah.Tabs[2])
            assert.is_false(flipside.active)
            assert.is_true(paneShown("PaneC"))
            assert.is_false(paneShown("PaneA"))
        end)

        it("restores the previous tab when the panel hides", function()
            attachBoth()
            click(flipsideTab)
            click(buyingTab)
            buying.content:Hide()
            assert.is_false(buying.active)
            assert.is_true(paneShown("PaneA"))
            assert.are.equal(1, lastTab())
        end)

        it("writes no Blizzard frame field", function()
            guard(ah)
            for _, name in ipairs({ "PaneA", "PaneB", "PaneC" }) do
                guard(ah[name])
            end
            for _, tab in ipairs(ah.Tabs) do
                guard(tab)
            end
            attachBoth()
            click(flipsideTab)
            click(buyingTab)
            click(ah.Tabs[2])
            click(buyingTab)
            click(ah.Tabs[1])
            assert.are.same({}, reports)
        end)

        it("builds both tabs when the Auction House addon loads", function()
            _G.AuctionHouseFrame = nil
            flipside = makeCore()
            ns.AuctionTabHost.Attach(flipside)
            ns.AuctionTabs.Register({ id = "buying", label = "Buying", create = function()
                buying = makeCore()
                return buying
            end })
            ns.AuctionTabs.AttachAll({ bus = bus })
            assert.are.equal(2, #ah.Tabs)
            _G.AuctionHouseFrame = ah
            bus:Emit("ADDON_LOADED", "Other")
            assert.are.equal(2, #ah.Tabs)
            bus:Emit("ADDON_LOADED", ADDON)
            assert.are.equal(4, #ah.Tabs)
            assert.are.equal("Buying", ah.Tabs[4].text)
        end)

        it("drops a tab that fails to mount and keeps the other", function()
            flipside = makeCore()
            ns.AuctionTabHost.Attach(flipside)
            local bad = makeCore()
            function bad.Mount()
                error("no mount")
            end
            ns.AuctionTabHost.Attach(bad, { label = "Bad" })
            assert.are.equal(3, #ah.Tabs)
            assert.are.equal(1, bad.unmounts)
            assert.are.equal(1, #reports)
            click(ah.Tabs[3])
            assert.is_true(flipside.active)
        end)
    end)
end)
