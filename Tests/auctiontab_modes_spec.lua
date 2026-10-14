local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = {}
    for _, name in ipairs({ "EventBus", "ItemString", "ScanClock", "ScanCooldown", "ScanSources", "FormulaLookup",
        "ItemNameIndex", "Theme", "Widgets", "ScanBar", "AuctionTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

describe("AuctionTab scan modes", function()
    local ns, deps, parent, engine, left, started, popups

    local function mount(modes)
        deps.scanModes = modes
        local tab = ns.AuctionTab.Attach(deps)
        tab:Mount(parent, { Enter = function() end, Leave = function() end, layout = "compact" })
        return tab
    end

    local function click(button)
        button:GetScript("OnClick")(button)
    end

    before_each(function()
        mock.reset()
        getmetatable(CreateFrame("Frame")).__index.SetJustifyH = function() end
        _G.C_Timer = { After = function() end, NewTicker = function() return { Cancel = function() end } end }
        ns = loadModules()
        left, started, popups = 0, {}, 0
        engine = {
            running = false,
            IsRunning = function(self) return self.running end,
            CanStart = function(_, mode)
                if mode ~= "page" and left > 0 then
                    return false, "cooldown", left
                end
                return true
            end,
            Start = function(_, mode) started[#started + 1] = mode or "none" return true end,
            Cancel = function() end,
            GetProgress = function() return "page", 3, 120 end,
        }
        deps = {
            bus = ns.EventBus.New({}),
            serverTime = GetServerTime,
            confirmScan = function(callback) popups = popups + 1 callback() end,
            openMainWindow = function() end,
            scanEngine = engine,
            scanCooldown = { Remaining = function() return left end, GetLastSuccess = function() return nil end,
                Reset = function() return true end },
            scanStore = { GetRegion = function() return "EU" end, CountItems = function() return 0 end },
        }
        parent = CreateFrame("Frame", nil, UIParent)
    end)

    after_each(function()
        mock.teardown()
    end)

    it("shows one button for each mode", function()
        local tab = mount({ "full", "fast", "page" })
        local buttons = tab.ui.modeButtons
        assert.is_truthy(buttons.full and buttons.fast and buttons.page)
        assert.are.equal("Fast scan", buttons.fast:GetText())
        assert.are.equal("Page scan", buttons.page:GetText())
        assert.are.equal(buttons.full, tab.ui.scan)
    end)

    it("disables the get all modes on cooldown and keeps the page mode", function()
        left = 125
        local tab = mount({ "full", "fast", "page" })
        local buttons = tab.ui.modeButtons
        assert.is_false(buttons.full.enabled)
        assert.is_false(buttons.fast.enabled)
        assert.is_true(buttons.page.enabled)
        assert.is_truthy(tab.ui.cooldown:GetText():find("2 min 05 s", 1, true))
    end)

    it("starts the clicked mode, and asks for confirmation except for the page mode", function()
        local tab = mount({ "full", "fast", "page" })
        click(tab.ui.modeButtons.fast)
        click(tab.ui.modeButtons.page)
        assert.are.same({ "fast", "page" }, started)
        assert.are.equal(1, popups)
    end)

    it("shows the page progress while a page scan runs", function()
        local tab = mount({ "full", "fast", "page" })
        engine.running = true
        tab:Refresh()
        assert.are.equal("Page scan: page 3 of 120", tab.ui.cooldown:GetText())
        assert.is_false(tab.ui.modeButtons.page.enabled)
    end)

    it("shows one button without modes", function()
        local tab = mount(nil)
        assert.is_nil(tab.ui.modeButtons)
        assert.is_truthy(tab.ui.scan)
        click(tab.ui.scan)
        assert.are.same({ "none" }, started)
    end)
end)
