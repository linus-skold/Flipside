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

describe("AuctionTab layout option", function()
    local ns, deps, parent, api, labels

    local function mount(fields)
        api = { enters = {}, leaves = {} }
        api.Enter = function() end
        api.Leave = function() end
        for key, value in pairs(fields) do
            api[key] = value
        end
        local tab = ns.AuctionTab.Attach(deps)
        local label = ns.Kit.Label
        labels = {}
        ns.Kit.Label = function(frame, text, role)
            table.insert(labels, { text = text, role = role })
            return label(frame, text, role)
        end
        tab:Mount(parent, api)
        ns.Kit.Label = label
        return tab
    end

    local function roles()
        local set = {}
        for _, entry in ipairs(labels) do
            set[entry.role] = true
        end
        return set
    end

    before_each(function()
        mock.reset()
        getmetatable(CreateFrame("Frame")).__index.SetJustifyH = function() end
        _G.C_Timer = { After = function() end, NewTicker = function() return { Cancel = function() end } end }
        ns = loadModules()
        deps = {
            bus = ns.EventBus.New({}),
            serverTime = GetServerTime,
            confirmScan = function() end,
            openMainWindow = function() end,
        }
        parent = CreateFrame("Frame", nil, UIParent)
    end)

    after_each(function()
        mock.teardown()
    end)

    it("uses the old layout and the Kit padding when the host sets no new field", function()
        local tab = mount({ insets = { top = 10, bottom = 5 } })
        local padding = ns.Kit.Theme.padding
        assert.are.equal(padding, tab.content.points[1][4])
        assert.are.equal(-10, tab.content.points[1][5])
        assert.are.equal(-padding, tab.content.points[2][4])
        assert.are.equal(5, tab.content.points[2][5])
        assert.is_true(roles().title)
        assert.are.equal("Full scan", labels[1].text)
    end)

    it("uses the left and right insets of the host", function()
        local tab = mount({ insets = { left = 14, right = 40, top = 60, bottom = 40 } })
        assert.are.equal(14, tab.content.points[1][4])
        assert.are.equal(-60, tab.content.points[1][5])
        assert.are.equal(-40, tab.content.points[2][4])
        assert.are.equal(40, tab.content.points[2][5])
    end)

    it("builds the compact panel without large headings", function()
        local tab = mount({ layout = "compact", insets = { left = 14, right = 40, top = 60, bottom = 40 } })
        assert.is_nil(roles().title)
        assert.is_true(roles().normal)
        local ui = tab.ui
        for _, name in ipairs({ "scan", "stop", "reset", "cooldown", "openMain", "message", "status", "input",
            "lookup", "priceMessage", "pendingMessage" }) do
            assert.is_truthy(ui[name], name)
        end
        assert.are.equal(8, #ui.choices)
        assert.are.equal(9, #ui.slots)
    end)

    it("keeps the scan controls in a slim bar at the top", function()
        local tab = mount({ layout = "compact" })
        local ui = tab.ui
        assert.are.equal(0, ui.scan.points[1][5])
        assert.are.equal(0, ui.stop.points[1][5])
        assert.are.equal(0, ui.reset.points[1][5])
        assert.are.equal(0, ui.openMain.points[1][5])
    end)

    it("fits every widget in the content area of the legacy frame", function()
        local tab = mount({ layout = "compact", insets = { left = 14, right = 40, top = 60, bottom = 40 } })
        local contentHeight = 447 - 60 - 40
        local ui = tab.ui
        local lowest = 0
        for _, widget in ipairs({ ui.status, ui.input, ui.priceMessage, ui.choices[8], ui.slots[9].name }) do
            local y = widget.points[1][5]
            lowest = math.min(lowest, y - (widget.height or 20))
        end
        assert.is_true(-lowest <= contentHeight)
    end)

    it("works with the main behaviour in the compact layout", function()
        local tab = mount({ layout = "compact" })
        tab:Select()
        assert.is_true(tab.content:IsShown())
        tab.ui.input:SetText("")
        tab:Lookup("")
        assert.is_truthy(tab.ui.priceMessage:GetText())
        tab:Deselect()
        assert.is_false(tab.content:IsShown())
    end)
end)
