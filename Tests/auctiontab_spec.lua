local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local LINK = "|cff0070dd|Hitem:123::::::::80:::::::::|h[Thing]|h|r"

local function loadModules()
    local ns = {}
    for _, name in ipairs({ "EventBus", "ItemString", "ScanClock", "ScanCooldown",
        "ScanSources", "FormulaLookup", "ItemNameIndex", "Theme", "Widgets",
        "ScanBar", "AuctionTab", "AuctionTabHost" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

local function record(min)
    return { latest = { time = 1000000 - 7200, min = min, market = 5200, qty = 40, partial = true }, days = {} }
end

describe("AuctionTab", function()
    local ns, deps, ah, ticker, hooks, confirmed, opened, engine, cooldown, records, tickers

    local function makeAH()
        local frame = CreateFrame("Frame", "AuctionHouseFrame", UIParent)
        local modes = { Buy = { "PaneA", "PaneB" }, Auctions = { "PaneC" } }
        frame.modes = modes
        for _, name in ipairs({ "PaneA", "PaneB", "PaneC" }) do
            frame[name] = CreateFrame("Frame", nil, frame)
            frame[name]:Hide()
        end
        frame.Tabs = {}
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
        _G.AuctionHouseFrame = frame
        return frame
    end

    local function fakeStore()
        return {
            Get = function(_, key)
                return records[key]
            end,
            GetRegion = function()
                return "EU"
            end,
            CountItems = function()
                return 42
            end,
        }
    end

    before_each(function()
        mock.reset()
        local frameMethods = getmetatable(CreateFrame("Frame")).__index
        frameMethods.SetJustifyH = function() end
        hooks, tickers, confirmed, opened, records = {}, {}, nil, 0, {}
        _G.hooksecurefunc = function(target, name, hook)
            local original = target[name]
            target[name] = function(...)
                original(...)
                hook(...)
            end
            table.insert(hooks, name)
        end
        _G.C_Timer = {
            After = function() end,
            NewTicker = function(seconds, fn)
                ticker = { seconds = seconds, fn = fn, cancelled = false }
                ticker.Cancel = function(self)
                    self.cancelled = true
                end
                table.insert(tickers, ticker)
                return ticker
            end,
        }
        ns = loadModules()
        engine = {
            running = false, starts = 0, cancels = 0, canStart = { true },
            IsRunning = function(self)
                return self.running
            end,
            CanStart = function(self)
                return unpack(self.canStart)
            end,
            Start = function(self)
                self.starts = self.starts + 1
            end,
            Cancel = function(self)
                self.cancels = self.cancels + 1
            end,
        }
        cooldown = {
            left = 0, resets = 0, resetResult = true,
            Remaining = function(self)
                return self.left
            end,
            Reset = function(self)
                self.resets = self.resets + 1
                return self.resetResult
            end,
            GetLastSuccess = function()
                return 1000000 - 7200
            end,
        }
        deps = {
            bus = ns.EventBus.New({}),
            scanEngine = engine,
            scanCooldown = cooldown,
            scanStore = fakeStore(),
            formulaLookup = ns.FormulaLookup,
            scanSources = ns.ScanSources,
            serverTime = GetServerTime,
            confirmScan = function(onAccept)
                confirmed = onAccept
            end,
            openMainWindow = function()
                opened = opened + 1
            end,
        }
        ah = makeAH()
    end)

    after_each(function()
        _G.AuctionHouseFrame = nil
        _G.hooksecurefunc = nil
        mock.teardown()
    end)

    local function attach()
        local tab = ns.AuctionTab.Attach(deps)
        return tab, tab.ui
    end

    local function click(button)
        button:GetScript("OnClick")(button)
    end

    describe("tab", function()
        it("appends one tab after Blizzard's tabs and sets the tab count", function()
            local tab = attach()
            assert.are.equal(3, #ah.Tabs)
            assert.are.equal(ah.Tabs[3], tab.hostState.tab)
            assert.are.equal("Flipside", tab.hostState.tab:GetText())
            assert.are.equal(3, tab.hostState.tab:GetID())
            assert.are.equal("AuctionHouseFrameTabTemplate", tab.hostState.tab.template)
            local last = mock.tabCalls[#mock.tabCalls]
            assert.are.same({ "num", ah, 3 }, last)
            assert.is_false(tab.content:IsShown())
        end)

        it("falls back to the panel tab template", function()
            mock.missingTemplates.AuctionHouseFrameTabTemplate = true
            local tab = attach()
            assert.are.equal("PanelTabButtonTemplate", tab.hostState.tab.template)
        end)

        it("shows the content and hides Blizzard's panes on click", function()
            local tab = attach()
            click(ah.Tabs[1])
            assert.is_true(ah.PaneA:IsShown())
            click(tab.hostState.tab)
            assert.is_true(tab.content:IsShown())
            assert.is_false(ah.PaneA:IsShown())
            assert.is_false(ah.PaneB:IsShown())
            assert.are.same({ "tab", ah, 3 }, mock.tabCalls[#mock.tabCalls])
            assert.is_false(ticker.cancelled)
            assert.are.equal(1, ticker.seconds)
        end)

        it("does not change the display mode of Blizzard's frame", function()
            local tab = attach()
            click(ah.Tabs[1])
            local mode = ah.displayMode
            click(tab.hostState.tab)
            assert.are.equal(ah.modes.Buy, mode)
            assert.are.equal(mode, ah.displayMode)
        end)

        it("restores the panes when the same Blizzard tab is clicked again", function()
            local tab = attach()
            click(ah.Tabs[1])
            click(tab.hostState.tab)
            click(ah.Tabs[1])
            assert.is_false(tab.content:IsShown())
            assert.is_true(ah.PaneA:IsShown())
            assert.is_true(ah.PaneB:IsShown())
            assert.is_true(ticker.cancelled)
            assert.are.same({ "tab", ah, 1 }, mock.tabCalls[#mock.tabCalls])
            click(ah.Tabs[1])
            assert.is_true(ah.PaneA:IsShown())
        end)

        it("switches to a different Blizzard tab", function()
            local tab = attach()
            click(ah.Tabs[1])
            click(tab.hostState.tab)
            click(ah.Tabs[2])
            assert.is_false(tab.content:IsShown())
            assert.is_true(ah.PaneC:IsShown())
            assert.is_false(ah.PaneA:IsShown())
            assert.is_false(ah.PaneB:IsShown())
            assert.is_true(ticker.cancelled)
        end)

        it("hides the content when Blizzard changes the mode by itself", function()
            local tab = attach()
            click(ah.Tabs[1])
            click(tab.hostState.tab)
            ah:SetDisplayMode(ah.modes.Auctions)
            assert.is_false(tab.content:IsShown())
            assert.is_true(ah.PaneC:IsShown())
            assert.is_false(ah.PaneA:IsShown())
        end)

        it("keeps the content when Blizzard sets the same mode", function()
            local tab = attach()
            click(ah.Tabs[1])
            click(tab.hostState.tab)
            ah:SetDisplayMode(ah.modes.Buy)
            assert.is_true(tab.content:IsShown())
        end)

        it("restores the panes and the tab when the frame hides", function()
            local tab = attach()
            click(ah.Tabs[1])
            ah.selectedTab = 1
            click(tab.hostState.tab)
            tab.content:Hide()
            tab.content:GetScript("OnHide")(tab.content)
            assert.is_true(ticker.cancelled)
            assert.is_true(ah.PaneA:IsShown())
            assert.are.same({ "tab", ah, 1 }, mock.tabCalls[#mock.tabCalls])
            ah:SetDisplayMode(ah.modes.Buy)
            assert.is_true(ah.PaneA:IsShown())
        end)
        it("restarts the ticker when the content shows again", function()
            local tab = attach()
            click(ah.Tabs[1])
            click(tab.hostState.tab)
            ah:SetDisplayMode(ah.modes.Auctions)
            click(tab.hostState.tab)
            assert.are.equal(2, #tickers)
            assert.is_false(tickers[2].cancelled)
        end)

        it("hooks SetDisplayMode once", function()
            attach()
            assert.are.same({ "SetDisplayMode" }, hooks)
        end)
    end)

    describe("tab template", function()
        local function useTemplate(addsItself)
            local create = _G.CreateFrame
            _G.CreateFrame = function(kind, name, parent, template)
                local f = create(kind, name, parent, template)
                if template == "AuctionHouseFrameTabTemplate" and parent == ah and addsItself then
                    table.insert(parent.Tabs, f)
                end
                return f
            end
        end

        local function countHooks()
            local hooked = {}
            local function spy(tab)
                tab.HookScript = function(self)
                    table.insert(hooked, self)
                end
            end
            for _, tab in ipairs(ah.Tabs) do
                spy(tab)
            end
            local create = _G.CreateFrame
            _G.CreateFrame = function(...)
                local f = create(...)
                spy(f)
                return f
            end
            return hooked
        end

        for _, addsItself in ipairs({ true, false }) do
            it("builds the tab once when the template " .. (addsItself and "adds" or "does not add")
                .. " it to Tabs", function()
                local blizzardOne, blizzardTwo = ah.Tabs[1], ah.Tabs[2]
                local hooked = countHooks()
                useTemplate(addsItself)
                local tab = attach()
                assert.are.equal(3, #ah.Tabs)
                assert.are.equal(blizzardOne, ah.Tabs[1])
                assert.are.equal(blizzardTwo, ah.Tabs[2])
                assert.are.equal(tab.hostState.tab, ah.Tabs[3])
                assert.are.equal(3, tab.hostState.index)
                assert.are.equal(3, tab.hostState.tab:GetID())
                assert.are.same({ "TOPLEFT", blizzardTwo, "TOPRIGHT", 3, 0 }, tab.hostState.tab.points[1])
                assert.are.same({ "num", ah, 3 }, mock.tabCalls[#mock.tabCalls])
                assert.are.same({ blizzardOne, blizzardTwo }, hooked)
                click(tab.hostState.tab)
                assert.is_true(tab.content:IsShown())
            end)
        end

        it("leaves nothing behind and reports when the build fails", function()
            local reports = {}
            ns.ReportError = function(message)
                table.insert(reports, message)
            end
            local create = _G.CreateFrame
            local button
            _G.CreateFrame = function(kind, name, parent, template)
                local f = create(kind, name, parent, template)
                if template == "AuctionHouseFrameTabTemplate" then
                    button = f
                    f.SetPoint = function()
                        error("Cannot anchor to itself")
                    end
                end
                return f
            end
            local tab = attach()
            assert.are.equal(1, #reports)
            assert.is_truthy(reports[1]:find("Cannot anchor to itself", 1, true))
            assert.are.equal(2, #ah.Tabs)
            assert.is_false(button:IsShown())
            assert.is_nil(tab.hostState.tab)
            assert.is_nil(tab.hostState.frame)
            assert.are.same({ "num", ah, 2 }, mock.tabCalls[#mock.tabCalls])
            assert.are.same({}, hooks)
        end)
    end)
    describe("attach", function()
        it("attaches at once when the frame exists", function()
            local tab = attach()
            assert.is_not_nil(tab.hostState.tab)
        end)

        it("waits for the Auction House addon", function()
            _G.AuctionHouseFrame = nil
            local tab = attach()
            assert.is_nil(tab.hostState.tab)
            assert.is_nil(tab:Refresh())
            deps.bus:Emit("ADDON_LOADED", "Other")
            assert.is_nil(tab.hostState.tab)
            ah = makeAH()
            deps.bus:Emit("ADDON_LOADED", "Blizzard_AuctionHouseUI")
            assert.is_not_nil(tab.hostState.tab)
            assert.are.equal(3, #ah.Tabs)
            deps.bus:Emit("ADDON_LOADED", "Blizzard_AuctionHouseUI")
            assert.are.equal(3, #ah.Tabs)
        end)

        it("checks the deps", function()
            assert.has_error(function()
                ns.AuctionTab.Attach(nil)
            end)
            deps.confirmScan = nil
            assert.has_error(function()
                ns.AuctionTab.Attach(deps)
            end)
        end)
    end)

    describe("scan block", function()
        it("is ready when no cooldown runs", function()
            local _, ui = attach()
            assert.is_true(ui.scan.enabled)
            assert.is_false(ui.stop:IsShown())
            assert.are.equal("Cooldown: ready", ui.cooldown:GetText())
        end)

        it("is disabled during the cooldown and counts down", function()
            cooldown.left = 845
            local tab, ui = attach()
            assert.is_false(ui.scan.enabled)
            assert.are.equal("Cooldown: 14 min 05 s", ui.cooldown:GetText())
            cooldown.left = 0
            click(ah.Tabs[1])
            click(tab.hostState.tab)
            ticker.fn()
            assert.is_true(ui.scan.enabled)
            assert.are.equal("Cooldown: ready", ui.cooldown:GetText())
        end)

        it("shows Stop and disables the scan while a scan runs", function()
            engine.running = true
            local _, ui = attach()
            assert.is_false(ui.scan.enabled)
            assert.is_true(ui.stop:IsShown())
            assert.are.equal("Scan running", ui.cooldown:GetText())
        end)

        it("asks first, then starts the scan on accept", function()
            local _, ui = attach()
            click(ui.scan)
            assert.are.equal(0, engine.starts)
            assert.is_function(confirmed)
            confirmed()
            assert.are.equal(1, engine.starts)
        end)

        it("does not ask when the scan cannot start", function()
            engine.canStart = { false, "ah-closed" }
            local _, ui = attach()
            click(ui.scan)
            assert.is_nil(confirmed)
            assert.are.equal("full scan not started: open the Auction House first", ui.message:GetText())
        end)

        it("says why when the scan cannot start after accept", function()
            local _, ui = attach()
            click(ui.scan)
            engine.canStart = { false, "cooldown", 65 }
            confirmed()
            assert.are.equal(0, engine.starts)
            assert.are.equal("full scan not started: scan on cooldown, 1 min 05 s left", ui.message:GetText())
        end)

        it("stops the scan", function()
            engine.running = true
            local _, ui = attach()
            click(ui.stop)
            assert.are.equal(1, engine.cancels)
        end)

        it("resets the cooldown", function()
            local _, ui = attach()
            click(ui.reset)
            assert.are.equal(1, cooldown.resets)
            assert.is_truthy(ui.message:GetText():find("scan cooldown cleared", 1, true))
        end)

        it("does not reset while a scan runs", function()
            engine.running = true
            local _, ui = attach()
            click(ui.reset)
            assert.are.equal(0, cooldown.resets)
            assert.is_truthy(ui.message:GetText():find("stop it first", 1, true))
        end)

        it("says so when settings are read-only", function()
            cooldown.resetResult = false
            local _, ui = attach()
            click(ui.reset)
            assert.are.equal("settings are read-only; the cooldown was not cleared", ui.message:GetText())
        end)

        it("opens the Flipside window", function()
            local _, ui = attach()
            click(ui.openMain)
            assert.are.equal(1, opened)
        end)

        it("disables the scan when the engine is missing", function()
            deps.scanEngine, deps.scanCooldown = nil, nil
            local _, ui = attach()
            assert.is_false(ui.scan.enabled)
            assert.are.equal("scan is not available this session", ui.cooldown:GetText())
        end)
    end)

    describe("start page scan bar", function()
        local enabled, saves, page

        -- Writes of new keys to a fake Blizzard frame fail: the host must not add fields.
        local function guard(frame)
            local meta = getmetatable(frame)
            setmetatable(frame, {
                __index = meta.__index,
                __newindex = function(_, key)
                    error("write to a Blizzard frame: " .. tostring(key), 2)
                end,
            })
        end

        before_each(function()
            enabled, saves = true, {}
            page = CreateFrame("Frame", nil, ah)
            page:Hide()
            ah.BrowseResultsFrame = page
            guard(ah)
            guard(page)
            deps.startPageEnabled = function()
                return enabled
            end
            deps.setStartPageEnabled = function(on)
                table.insert(saves, on)
                enabled = on
                return true
            end
        end)

        local function showPage()
            page:Show()
            page:GetScript("OnShow")(page)
        end

        it("sits in the bottom strip right of the gold display", function()
            local tab = attach()
            local frame = tab.startPage.frame
            assert.are.equal(ah, frame:GetParent())
            assert.are.same({ "BOTTOMLEFT", ah, "BOTTOMLEFT", 174, 4 }, frame.points[1])
            assert.are.same({ "BOTTOMRIGHT", ah, "BOTTOMRIGHT", -8, 4 }, frame.points[2])
        end)

        it("shows only while the browse page is shown", function()
            local tab = attach()
            local frame = tab.startPage.frame
            assert.is_false(frame:IsShown())
            showPage()
            assert.is_true(frame:IsShown())
            page:Hide()
            assert.is_false(frame:IsShown())
        end)

        it("starts a scan with the shared rules", function()
            local tab = attach()
            showPage()
            click(tab.startPage.bar.scan)
            assert.is_function(confirmed)
            confirmed()
            assert.are.equal(1, engine.starts)
        end)

        it("stays hidden when the setting is off", function()
            enabled = false
            local tab = attach()
            showPage()
            assert.is_false(tab.startPage.frame:IsShown())
        end)

        it("is not built without the browse results frame", function()
            ah.BrowseResultsFrame = nil
            local tab = attach()
            assert.is_nil(tab.startPage)
        end)

        it("is not built without a scan engine", function()
            deps.scanEngine = nil
            local tab = attach()
            assert.is_nil(tab.startPage)
        end)

        it("has a check box that saves the setting and hides the bar", function()
            local tab, ui = attach()
            showPage()
            assert.is_true(ui.startCheck.checked)
            ui.startCheck.checked = false
            click(ui.startCheck)
            assert.are.same({ false }, saves)
            assert.is_false(tab.startPage.frame:IsShown())
            ui.startCheck.checked = true
            click(ui.startCheck)
            assert.are.same({ false, true }, saves)
            assert.is_true(tab.startPage.frame:IsShown())
        end)

        it("says so when the setting cannot be saved", function()
            deps.setStartPageEnabled = function()
                return false
            end
            local _, ui = attach()
            ui.startCheck.checked = false
            click(ui.startCheck)
            assert.is_truthy(ui.message:GetText():find("not saved", 1, true))
        end)

        it("removes the bar when the build fails", function()
            local tab = attach()
            tab:Unmount()
            assert.is_nil(tab.startPage)
        end)
    end)

    describe("status block", function()
        it("shows the region, the item count and the last scan age", function()
            local _, ui = attach()
            assert.are.equal("Region EU, 42 items stored\nLast scan: 2.0 h ago", ui.status:GetText())
        end)

        it("adds the summary lines after a scan", function()
            local _, ui = attach()
            deps.bus:Emit("Flipside.ScanFinished", {
                result = "ok", rows = 10, kept = 9, items = 8, keys = 7, newItems = 2, changed = 1,
                cpuMs = 12.4, wallMs = 3000, itemsKeyed = 8, itemsPendingMissing = 0, itemsNoLink = 0,
                itemsLinkMismatch = 0, itemsUnknown = 0, itemsLinkFallback = 0, noKey = 0,
                commodityStats = { client = 1, stack = 2, unknown = 3, mismatch = 4, linkFallback = 5 },
            })
            local text = ui.status:GetText()
            assert.is_truthy(text:find("full scan ok: 10 rows, 8 items, 7 keys, 2 new, 1 changed >30%, cpu 12 ms, "
                .. "wall 3.0 s", 1, true))
            assert.is_truthy(text:find("commodity check: client 1, stack 2, unknown 3, mismatch 4, link fallback 5",
                1, true))
            assert.is_truthy(text:find("items 8: keyed 8, link fallback 0, pending 0, no link 0, link mismatch 0, "
                .. "unknown 0", 1, true))
        end)
    end)

    describe("DescribeSummary", function()
        local function summary(extra)
            local s = {
                result = "partial", rows = 1, kept = 1, items = 1, keys = 1, newItems = 0, changed = 0,
                cpuMs = 1, wallMs = 1000, itemsKeyed = 0, itemsPendingMissing = 3, itemsNoLink = 1,
                itemsLinkMismatch = 1, itemsUnknown = 2, itemsLinkFallback = 0, noKey = 4,
            }
            for k, v in pairs(extra or {}) do
                s[k] = v
            end
            return s
        end

        it("lists the reasons of a partial scan", function()
            local lines = ns.AuctionTab.DescribeSummary(summary())
            assert.are.equal(2, #lines)
            assert.are.equal("partial scan, latest values only: 3 items without data, 2 items with unknown "
                .. "stack size, 2 items with a bad link, 4 rows without a key", lines[2])
        end)

        it("reports an error and a cancel", function()
            assert.are.same({ "full scan failed: boom" },
                ns.AuctionTab.DescribeSummary(summary({ result = "error", error = "boom" })))
            assert.are.same({ "full scan cancelled" },
                ns.AuctionTab.DescribeSummary(summary({ result = "cancelled" })))
        end)
    end)

    describe("DescribePrice", function()
        it("describes all values", function()
            local rows = ns.AuctionTab.DescribePrice({
                scanMin = 100, scanRecent = 200, scanMarket = 300, scanHistorical = 400, scanQty = 50,
                scanAge = 1.25, scanSamples = 3, scanPartial = true,
            }, "123")
            assert.are.same({
                { label = "Key", text = "123" },
                { label = "ScanMin", money = true, copper = 100 },
                { label = "ScanRecent", money = true, copper = 200 },
                { label = "ScanMarket", money = true, copper = 300 },
                { label = "ScanHistorical", money = true, copper = 400 },
                { label = "ScanQty", text = "50" },
                { label = "ScanAge", text = "1.2 h" },
                { label = "ScanSamples", text = "3" },
                { label = "Partial", text = "yes" },
            }, rows)
        end)

        it("shows a dash for missing values and no partial row", function()
            local rows = ns.AuctionTab.DescribePrice({ scanSamples = 0 }, "9")
            assert.are.equal(8, #rows)
            assert.is_nil(rows[2].copper)
            assert.are.equal("-", rows[6].text)
            assert.are.equal("-", rows[7].text)
            assert.are.equal("0", rows[8].text)
        end)
    end)

    describe("price lookup", function()
        local function shownRows(ui)
            local out = {}
            for _, slot in ipairs(ui.slots) do
                if slot.name:IsShown() then
                    table.insert(out, slot)
                end
            end
            return out
        end

        it("looks up an item link", function()
            records["123"] = record(1000)
            local tab, ui = attach()
            ui.input:SetText(LINK)
            click(ui.lookup)
            local rows = shownRows(ui)
            assert.are.equal(9, #rows)
            assert.are.equal("Key", rows[1].name:GetText())
            assert.are.equal("123", rows[1].value:GetText())
            assert.are.equal("ScanMin", rows[2].name:GetText())
            assert.is_true(rows[2].money:IsShown())
            assert.are.equal("1000c", rows[2].money:GetText())
            assert.are.equal("ScanQty", rows[6].name:GetText())
            assert.are.equal("40", rows[6].value:GetText())
            assert.are.equal("2.0 h", rows[7].value:GetText())
            assert.are.equal("", ui.priceMessage:GetText())
            assert.is_not_nil(tab)
        end)

        it("looks up an item id with the Enter key", function()
            records["123"] = record(1000)
            local _, ui = attach()
            ui.input:GetScript("OnEnterPressed")(ui.input)
            assert.are.equal("enter an item link or item id", ui.priceMessage:GetText())
            ui.input:SetText("123")
            ui.input:GetScript("OnEnterPressed")(ui.input)
            assert.are.equal(9, #shownRows(ui))
        end)

        it("says when no data exists", function()
            local _, ui = attach()
            ui.input:SetText("77")
            click(ui.lookup)
            assert.are.equal("no scan data for 77", ui.priceMessage:GetText())
            assert.are.equal(0, #shownRows(ui))
        end)

        it("says when the input is not an item", function()
            local _, ui = attach()
            ui.input:SetText("hello")
            click(ui.lookup)
            assert.are.equal("not an item: hello", ui.priceMessage:GetText())
        end)

        it("looks up a Flipside key", function()
            records["25320#s-44"] = record(1000)
            local _, ui = attach()
            ui.input:SetText("25320#s-44")
            click(ui.lookup)
            assert.are.equal(9, #shownRows(ui))
            assert.are.equal("25320#s-44", shownRows(ui)[1].value:GetText())
            ui.input:SetText("25321#s-44")
            click(ui.lookup)
            assert.are.equal("no scan data for 25321#s-44", ui.priceMessage:GetText())
        end)

        describe("refresh from the Auction House", function()
            local requests, answer

            local function withRefresh()
                requests, answer = {}, { true }
                deps.requestPriceRefresh = function(itemID, name)
                    requests[#requests + 1] = { itemID = itemID, name = name }
                    return unpack(answer)
                end
            end

            it("asks for a fresh price of an id, a link and a key", function()
                withRefresh()
                records["123"] = record(1000)
                records["123#s-5"] = record(900)
                local _, ui = attach()
                for _, text in ipairs({ "123", LINK, "123#s-5" }) do
                    ui.input:SetText(text)
                    click(ui.lookup)
                end
                assert.are.equal(3, #requests)
                for _, request in ipairs(requests) do
                    assert.are.equal(123, request.itemID)
                end
                assert.are.equal("refreshing the price", ui.pendingMessage:GetText())
            end)

            it("passes the name of a name match", function()
                withRefresh()
                records["123"] = record(1000)
                deps.itemNameIndex = {
                    Resolve = function()
                        return { kind = "name", matches = { { itemID = 123, name = "Thing", key = "123" } },
                            pendingCount = 0 }
                    end,
                }
                local _, ui = attach()
                ui.input:SetText("thing")
                click(ui.lookup)
                assert.are.same({ { itemID = 123, name = "Thing" } }, requests)
            end)

            it("shows the stored price and the hint when the Auction House is closed", function()
                withRefresh()
                answer = { false, "open the Auction House to refresh this price" }
                records["123"] = record(1000)
                local _, ui = attach()
                ui.input:SetText("123")
                click(ui.lookup)
                assert.are.equal(9, #shownRows(ui))
                assert.are.equal("open the Auction House to refresh this price", ui.pendingMessage:GetText())
            end)

            it("shows the rows again when the fresh price is stored", function()
                withRefresh()
                local _, ui = attach()
                ui.input:SetText("123")
                click(ui.lookup)
                assert.are.equal(0, #shownRows(ui))
                records["123"] = record(777)
                deps.bus:Emit("Flipside.PriceCaptured", "124")
                assert.are.equal(0, #shownRows(ui))
                deps.bus:Emit("Flipside.PriceCaptured", "123")
                assert.are.equal(9, #shownRows(ui))
                assert.are.equal("777c", shownRows(ui)[2].money:GetText())
                assert.are.equal("price refreshed", ui.pendingMessage:GetText())
                assert.are.equal(1, #requests)
            end)
        end)

        describe("by name", function()
            local pending

            local function useIndex(matches)
                pending = 0
                deps.itemNameIndex = {
                    Resolve = function(_, text)
                        if text:match("^%d+$") then
                            return { kind = "item", input = text }
                        end
                        if #text < 2 then
                            return { kind = "error", message = "type at least 2 characters of the name" }
                        end
                        return { kind = "name", matches = matches, pendingCount = pending }
                    end,
                }
            end

            local function shownChoices(ui)
                local out = {}
                for _, button in ipairs(ui.choices) do
                    if button:IsShown() then
                        table.insert(out, button)
                    end
                end
                return out
            end

            it("shows the price of a single match", function()
                records["123"] = record(1000)
                useIndex({ { itemID = 123, name = "Thing", key = "123" } })
                local _, ui = attach()
                ui.input:SetText("thing")
                click(ui.lookup)
                assert.are.equal(9, #shownRows(ui))
                assert.are.equal("123", shownRows(ui)[1].value:GetText())
                assert.are.equal(0, #shownChoices(ui))
            end)

            it("still accepts an id", function()
                records["123"] = record(1000)
                useIndex({})
                local _, ui = attach()
                ui.input:SetText("123")
                click(ui.lookup)
                assert.are.equal(9, #shownRows(ui))
            end)

            it("says when no item has the name", function()
                useIndex({})
                local _, ui = attach()
                ui.input:SetText("nothing")
                click(ui.lookup)
                assert.are.equal('no item named "nothing" in the scan data', ui.priceMessage:GetText())
            end)

            it("says when the name is too short", function()
                useIndex({})
                local _, ui = attach()
                ui.input:SetText("x")
                click(ui.lookup)
                assert.are.equal("type at least 2 characters of the name", ui.priceMessage:GetText())
            end)

            it("lists several matches and shows the price of the clicked one", function()
                records["123"] = record(1000)
                records["124#s-3"] = record(2000)
                useIndex({
                    { itemID = 123, name = "Thing", key = "123" },
                    { itemID = 124, name = "Thing Two", key = "124#s-3" },
                })
                local _, ui = attach()
                ui.input:SetText("thing")
                click(ui.lookup)
                assert.are.equal(0, #shownRows(ui))
                local choices = shownChoices(ui)
                assert.are.equal(2, #choices)
                assert.are.equal("Thing (123)", choices[1]:GetText())
                assert.are.equal("Thing Two (variant 124#s-3)", choices[2]:GetText())
                click(choices[2])
                assert.are.equal("124#s-3", shownRows(ui)[1].value:GetText())
                assert.are.equal("2000c", shownRows(ui)[2].money:GetText())
                assert.are.equal(0, #shownChoices(ui))
            end)

            it("shows the pending names line", function()
                records["123"] = record(1000)
                useIndex({ { itemID = 123, name = "Thing", key = "123" } })
                local _, ui = attach()
                pending = 4
                ui.input:SetText("thing")
                click(ui.lookup)
                assert.are.equal("4 item names are still loading", ui.pendingMessage:GetText())
                pending = 0
                click(ui.lookup)
                assert.are.equal("", ui.pendingMessage:GetText())
            end)
        end)

        it("clears old rows on a new lookup", function()
            records["123"] = record(1000)
            local _, ui = attach()
            ui.input:SetText("123")
            click(ui.lookup)
            ui.input:SetText("77")
            click(ui.lookup)
            assert.are.equal(0, #shownRows(ui))
        end)
    end)

    describe("host interface", function()
        local host, parent, api, state

        before_each(function()
            _G.AuctionHouseFrame = nil
            parent = CreateFrame("Frame", nil, UIParent)
            state = { marker = true }
            host = {
                Attach = function(core)
                    host.core = core
                    return state
                end,
            }
            deps.host = host
        end)

        local function mount(tab)
            api = { insets = { top = 10, bottom = 5 }, enters = {}, leaves = {} }
            api.Enter = function(wasActive) table.insert(api.enters, wasActive) end
            api.Leave = function(index) table.insert(api.leaves, index or "previous") end
            tab:Mount(parent, api)
        end

        it("calls host.Attach with the core and keeps the state", function()
            local tab = ns.AuctionTab.Attach(deps)
            assert.are.equal(tab, host.core)
            assert.are.equal(state, tab.hostState)
            assert.is_false(tab:IsActive())
        end)

        it("works without a host", function()
            deps.host = nil
            assert.has_no.errors(function() ns.AuctionTab.Attach(deps) end)
        end)

        it("builds the panel in the parent with the host insets", function()
            local tab = ns.AuctionTab.Attach(deps)
            mount(tab)
            assert.are.equal(parent, tab.content:GetParent())
            assert.is_false(tab.content:IsShown())
            assert.are.equal(-10, tab.content.points[1][5])
            assert.are.equal(5, tab.content.points[2][5])
        end)

        it("tells the host on select and leave", function()
            local tab = ns.AuctionTab.Attach(deps)
            mount(tab)
            tab:Select()
            assert.is_true(tab:IsActive())
            assert.is_true(tab.content:IsShown())
            tab:Select()
            assert.are.same({ false, true }, api.enters)
            tab:Leave(2)
            assert.is_false(tab:IsActive())
            assert.is_false(tab.content:IsShown())
            assert.is_true(ticker.cancelled)
            assert.are.same({ 2 }, api.leaves)
        end)

        it("leaves through the host when the content hides", function()
            local tab = ns.AuctionTab.Attach(deps)
            mount(tab)
            tab:Select()
            tab.content:GetScript("OnHide")(tab.content)
            assert.are.same({ "previous" }, api.leaves)
        end)

        it("deselects without the host", function()
            local tab = ns.AuctionTab.Attach(deps)
            mount(tab)
            tab:Select()
            tab:Deselect()
            assert.is_false(tab:IsActive())
            assert.are.same({}, api.leaves)
        end)

        it("unmounts and keeps no state", function()
            local tab = ns.AuctionTab.Attach(deps)
            mount(tab)
            tab:Unmount()
            assert.is_nil(tab.content)
            assert.is_nil(tab.ui)
            assert.is_nil(tab:Refresh())
        end)
    end)end)
