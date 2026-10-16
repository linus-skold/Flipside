local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = {}
    for _, name in ipairs({ "EventBus", "ScanCooldown", "Theme", "Widgets", "ScanBar" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

describe("ScanBar", function()
    local ns, engine, cooldown, deps, confirmed, said, tickers

    local function click(button)
        button:GetScript("OnClick")(button)
    end

    before_each(function()
        mock.reset()
        _G.C_Timer = {
            After = function() end,
            NewTicker = function(seconds, fn)
                local ticker = { seconds = seconds, fn = fn, cancelled = false }
                ticker.Cancel = function(self)
                    self.cancelled = true
                end
                table.insert(tickers, ticker)
                return ticker
            end,
        }
        tickers, confirmed, said = {}, nil, {}
        ns = loadModules()
        engine = {
            running = false, starts = {}, cancels = 0, canStart = { true }, progress = {},
            IsRunning = function(self)
                return self.running
            end,
            CanStart = function(self)
                return unpack(self.canStart)
            end,
            Start = function(self, mode)
                table.insert(self.starts, mode or "none")
            end,
            Cancel = function(self)
                self.cancels = self.cancels + 1
            end,
            GetProgress = function(self)
                return unpack(self.progress)
            end,
        }
        cooldown = {
            left = 0,
            Remaining = function(self)
                return self.left
            end,
        }
        deps = {
            bus = ns.EventBus.New({}),
            scanEngine = engine,
            scanCooldown = cooldown,
            scanModes = { "full", "fast", "page" },
            confirmScan = function(onAccept)
                confirmed = onAccept
            end,
        }
    end)

    after_each(function()
        _G.C_Timer = nil
        mock.teardown()
    end)

    describe("widget", function()
        local function build(extra)
            local parent = CreateFrame("Frame", nil, UIParent)
            local opts = { say = function(text) table.insert(said, text) end }
            for key, value in pairs(extra or {}) do
                opts[key] = value
            end
            local bar = ns.ScanBar.New(parent, deps, opts)
            bar:Refresh()
            return bar, parent
        end

        it("builds one button for each scan mode", function()
            local bar = build()
            assert.are.equal("Full scan", bar.buttons.full:GetText())
            assert.are.equal("Fast scan", bar.buttons.fast:GetText())
            assert.are.equal("Page scan", bar.buttons.page:GetText())
            assert.are.equal(bar.buttons.full, bar.scan)
        end)

        it("builds one Full scan button without scan modes", function()
            deps.scanModes = nil
            local bar = build()
            assert.is_nil(bar.buttons)
            assert.are.equal("Full scan", bar.scan:GetText())
            click(bar.scan)
            confirmed()
            assert.are.same({ "none" }, engine.starts)
        end)

        it("is ready when no cooldown runs", function()
            local bar = build()
            for _, button in pairs(bar.buttons) do
                assert.is_true(button.enabled)
            end
            assert.is_false(bar.stop:IsShown())
            assert.are.equal("Cooldown: ready", bar.status:GetText())
        end)

        it("disables get all but not the page scan during the cooldown", function()
            cooldown.left = 845
            local bar = build()
            assert.is_false(bar.buttons.full.enabled)
            assert.is_false(bar.buttons.fast.enabled)
            assert.is_true(bar.buttons.page.enabled)
            assert.are.equal("Cooldown: 14 min 05 s", bar.status:GetText())
        end)

        it("disables get all when the client refuses it", function()
            engine.canStart = { false, "client" }
            local bar = build()
            assert.is_false(bar.buttons.full.enabled)
            assert.are.equal("Get all not ready", bar.status:GetText())
        end)

        it("shows Stop and disables the buttons while a scan runs", function()
            engine.running = true
            local bar = build()
            for _, button in pairs(bar.buttons) do
                assert.is_false(button.enabled)
            end
            assert.is_true(bar.stop:IsShown())
            assert.are.equal("Scan running", bar.status:GetText())
        end)

        it("shows the page progress", function()
            engine.running = true
            engine.progress = { "page", 3, 120 }
            local bar = build()
            assert.are.equal("Page scan: page 3 of 120", bar.status:GetText())
            engine.progress = { "page" }
            bar:Refresh()
            assert.are.equal("Page scan: starting", bar.status:GetText())
        end)

        it("asks first for get all, then starts the scan on accept", function()
            local bar = build()
            click(bar.buttons.fast)
            assert.is_function(confirmed)
            assert.are.same({}, engine.starts)
            confirmed()
            assert.are.same({ "fast" }, engine.starts)
        end)

        it("starts the page scan at once", function()
            local bar = build()
            click(bar.buttons.page)
            assert.is_nil(confirmed)
            assert.are.same({ "page" }, engine.starts)
        end)

        it("says why a scan cannot start and does not ask", function()
            engine.canStart = { false, "ah-closed" }
            local bar = build()
            click(bar.buttons.full)
            assert.is_nil(confirmed)
            assert.are.same({ "full scan not started: open the Auction House first" }, said)
        end)

        it("says the cooldown left", function()
            engine.canStart = { false, "cooldown", 65 }
            local bar = build()
            click(bar.buttons.full)
            assert.are.same({ "full scan not started: scan on cooldown, 1 min 05 s left" }, said)
        end)

        it("stops the scan", function()
            engine.running = true
            local bar = build()
            click(bar.stop)
            assert.are.equal(1, engine.cancels)
        end)

        it("disables everything when the engine is missing", function()
            deps.scanEngine = nil
            local bar = build()
            for _, button in pairs(bar.buttons) do
                assert.is_false(button.enabled)
            end
            assert.is_false(bar.stop:IsShown())
            assert.are.equal("scan is not available this session", bar.status:GetText())
        end)

        it("shows a refusal and the last result in the short status", function()
            engine.canStart = { false, "ah-closed" }
            local bar = build({ say = false, short = true })
            assert.are.equal("Ready", bar.status:GetText())
            click(bar.buttons.full)
            assert.are.equal("full scan not started: open the Auction House first", bar.status:GetText())
            bar:SetResult({ label = "full scan", result = "ok", items = 3200 })
            bar:Refresh()
            assert.are.equal("Last: full scan ok, 3200 items", bar.status:GetText())
        end)

        it("shows pending items in the last result", function()
            assert.are.equal("Last: full scan complete, 7 pending",
                ns.ScanBar.ResultText({ label = "full scan", result = "ok", items = 9, pending = 7 }))
        end)

        it("shows the text and the fraction of a progress event", function()
            engine.running = true
            local bar = build()
            deps.bus:Emit("Flipside.ScanProgress", { phase = "waiting" })
            assert.are.equal("Waiting for server", bar.status:GetText())
            deps.bus:Emit("Flipside.ScanProgress", { phase = "reading", done = 1234, total = 5678 })
            assert.are.equal("Scanning 1234 / 5678 (21%)", bar.status:GetText())
            assert.are.equal(1234 / 5678, ns.ScanBar.ProgressFraction(bar.progress))
            deps.bus:Emit("Flipside.ScanProgress", { phase = "loading", done = 5, total = 10 })
            assert.are.equal("Loading items 5 / 10 (50%)", bar.status:GetText())
            deps.bus:Emit("Flipside.ScanProgress", { phase = "saving" })
            assert.are.equal("Saving", bar.status:GetText())
        end)

        it("shows page and row counts of the page scan", function()
            local text = ns.ScanBar.ProgressText({ phase = "pages", done = 3, total = 40, rows = 150 })
            assert.are.equal("Page scan: page 3 of 40, 150 rows", text)
            assert.are.equal("page 3 of 40", ns.ScanBar.ProgressText({ phase = "pages", done = 3, total = 40 }, true))
            assert.is_nil(ns.ScanBar.ProgressFraction({ phase = "waiting" }))
        end)

        it("clears the progress when the scan finishes", function()
            engine.running = true
            local bar = build()
            deps.bus:Emit("Flipside.ScanProgress", { phase = "reading", done = 1, total = 2 })
            assert.is_not_nil(bar.progress)
            engine.running = false
            deps.bus:Emit("Flipside.ScanFinished", { label = "full scan", result = "ok", items = 1 })
            assert.is_nil(bar.progress)
            bar:Refresh()
            assert.are.equal("Cooldown: ready", bar.status:GetText())
        end)
        it("shows short progress", function()
            engine.running = true
            engine.progress = { "page", 5, 40 }
            local bar = build({ short = true })
            assert.are.equal("page 5 of 40", bar.status:GetText())
        end)
    end)

    describe("start page", function()
        local blizzard, page, enabled, placement, mount

        before_each(function()
            blizzard = CreateFrame("Frame", "BlizzardFrame", UIParent)
            page = CreateFrame("Frame", "BlizzardPage", blizzard)
            page:Hide()
            enabled = true
            deps.startPageEnabled = function()
                return enabled
            end
            placement = {
                parent = blizzard,
                page = page,
                width = 300,
                buttonWidth = 62,
                stopWidth = 52,
                anchor = function(frame)
                    frame:SetPoint("TOPRIGHT", blizzard, "TOPRIGHT", -36, -9)
                end,
            }
            mount = ns.ScanBar.MountStartPage(deps, placement)
        end)

        it("is a child of the Blizzard frame at the placement anchor", function()
            assert.are.equal(blizzard, mount.frame:GetParent())
            assert.are.same({ "TOPRIGHT", blizzard, "TOPRIGHT", -36, -9 }, mount.frame.points[1])
            assert.are.equal(22, mount.frame.height)
        end)

        it("is hidden while the Blizzard page is hidden", function()
            assert.is_false(mount.frame:IsShown())
        end)

        it("shows with the page and hides with it", function()
            page:Show()
            page:GetScript("OnShow")(page)
            assert.is_true(mount.frame:IsShown())
            assert.are.equal("Ready", mount.bar.status:GetText())
            assert.are.equal(1, #tickers)
            page:Hide()
            assert.is_false(mount.frame:IsShown())
            assert.is_true(tickers[1].cancelled)
        end)

        it("stays hidden when the setting is off", function()
            enabled = false
            page:Show()
            page:GetScript("OnShow")(page)
            assert.is_false(mount.frame:IsShown())
            assert.are.equal(0, #tickers)
        end)

        it("follows the setting at once", function()
            page:Show()
            page:GetScript("OnShow")(page)
            enabled = false
            mount:Update()
            assert.is_false(mount.frame:IsShown())
            enabled = true
            mount:Update()
            assert.is_true(mount.frame:IsShown())
        end)

        it("refreshes on the ticker and shows the last result", function()
            page:Show()
            page:GetScript("OnShow")(page)
            cooldown.left = 90
            tickers[1].fn()
            assert.are.equal("Cooldown: 1 min 30 s", mount.bar.status:GetText())
            cooldown.left = 0
            deps.bus:Emit("Flipside.ScanFinished", { label = "full scan", result = "ok", items = 12 })
            assert.are.equal("Last: full scan ok, 12 items", mount.bar.status:GetText())
        end)

        it("stops the ticker when the Blizzard frame hides the bar", function()
            page:Show()
            page:GetScript("OnShow")(page)
            mount.frame:Hide()
            assert.is_true(tickers[1].cancelled)
        end)

        it("stays hidden after Destroy", function()
            mount:Destroy()
            page:Show()
            page:GetScript("OnShow")(page)
            assert.is_false(mount.frame:IsShown())
        end)

        it("places the status text after the Stop button while a scan runs", function()
            page:Show()
            page:GetScript("OnShow")(page)
            assert.are.equal(mount.bar.lastButton, mount.bar.status.points[1][2])
            engine.running = true
            mount.bar:Refresh()
            assert.are.equal(mount.bar.stop, mount.bar.status.points[1][2])
        end)
    end)
end)
