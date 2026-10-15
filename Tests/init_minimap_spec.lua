local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local ns
local SAVED = { point = "TOPLEFT", relativePoint = "BOTTOMLEFT", x = 40, y = 800 }

local function loadAddon()
    local space = {}
    for _, path in ipairs(manifest.files()) do
        assert(loadfile(path))("Flipside", space)
    end
    return space
end

local function login()
    mock.fire("ADDON_LOADED", "Flipside")
    mock.fire("PLAYER_LOGIN")
end

local function slash(text)
    mock.messages = {}
    _G.SlashCmdList.FLIPSIDE(text)
end

local function windowFrame()
    for _, f in ipairs(mock.frames) do
        if f.name == "FlipsideMainWindow" then
            return f
        end
    end
end

local function button()
    for _, f in ipairs(mock.frames) do
        if f.name == "FlipsideMinimapButton" then
            return f
        end
    end
end

local function click(b)
    b.scripts.OnClick(b, "LeftButton")
end

describe("Init minimap button and window position", function()
    before_each(function()
        mock.reset()
        local methods = getmetatable(CreateFrame("Frame")).__index
        methods.SetJustifyH = function() end
        methods.SetTexCoord = function() end
        methods.HasFocus = function(self)
            return self.focused
        end
        _G.ScrollUtil = nil
        _G.ChatEdit_InsertLink = function()
            return true
        end
        _G.hooksecurefunc = function(name, hook)
            local original = _G[name]
            _G[name] = function(...)
                local result = original(...)
                hook(...)
                return result
            end
        end
        _G.C_Timer.NewTicker = function()
            return { Cancel = function() end }
        end
        mock.playerName = "Tester"
        mock.realmName = "TestRealm"
        _G.Minimap = CreateFrame("Frame", "Minimap", UIParent)
        _G.Minimap.GetCenter = function()
            return 1000, 500
        end
        ns = loadAddon()
        login()
    end)

    after_each(function()
        _G.Minimap = nil
        _G.hooksecurefunc = nil
        _G.ChatEdit_InsertLink = nil
        mock.teardown()
    end)

    describe("minimap button", function()
        it("is created on the minimap with the tooltip lines", function()
            local b = button()
            assert.is_truthy(b)
            assert.are.equal(_G.Minimap, b:GetParent())
            assert.is_true(b:IsShown())
            b.scripts.OnEnter(b)
            assert.are.equal("Flipside", mock.tooltip.title)
            assert.are.equal("Left click: open the ledger", mock.tooltip.lines[1])
            assert.is_truthy(mock.tooltip.lines[2]:lower():find("drag", 1, true))
        end)

        it("is not created without a minimap", function()
            mock.teardown()
            mock.reset()
            _G.Minimap = nil
            mock.playerName = "Tester"
            mock.realmName = "TestRealm"
            getmetatable(CreateFrame("Frame")).__index.SetJustifyH = function() end
            ns = loadAddon()
            login()
            assert.is_nil(button())
            slash("minimap")
            assert.are.same({ "Flipside: the minimap button is not available this session" }, mock.messages)
        end)

        it("opens the window on the Ledger page with a left click and closes it with the next", function()
            local b = button()
            assert.is_nil(windowFrame())
            click(b)
            local window = windowFrame()
            assert.is_true(window:IsShown())
            assert.are.equal("ledger", ns.MainWindow.Get():GetSelectedPage())
            click(b)
            assert.is_false(window:IsShown())
        end)

        it("shows the Ledger page again if the window shows another page", function()
            slash("")
            local window = windowFrame()
            ns.MainWindow.Get():SelectPage("about")
            assert.is_true(window:IsShown())
            click(button())
            assert.is_true(window:IsShown())
            assert.are.equal("ledger", ns.MainWindow.Get():GetSelectedPage())
        end)

        it("saves the angle in the account settings when a drag stops", function()
            local b = button()
            b.scripts.OnDragStart(b)
            mock.cursor = { 1000, 600 }
            b.scripts.OnUpdate(b)
            b.scripts.OnDragStop(b)
            assert.are.equal(90, ns.db:Get("account", "ui.minimapAngle"))
        end)

        it("restores the saved angle after a reload", function()
            ns.db:Set("account", "ui.minimapAngle", 90)
            local saved = _G.FlipsideDB
            mock.reset()
            getmetatable(CreateFrame("Frame")).__index.SetJustifyH = function() end
            getmetatable(CreateFrame("Frame")).__index.SetTexCoord = function() end
            mock.playerName = "Tester"
            mock.realmName = "TestRealm"
            _G.FlipsideDB = saved
            _G.Minimap = CreateFrame("Frame", "Minimap", UIParent)
            ns = loadAddon()
            login()
            assert.are.equal(90, button():GetAngle())
        end)

        it("is hidden when the setting says so", function()
            ns.db:Set("account", "ui.minimapHidden", true)
            local saved = _G.FlipsideDB
            mock.reset()
            getmetatable(CreateFrame("Frame")).__index.SetJustifyH = function() end
            getmetatable(CreateFrame("Frame")).__index.SetTexCoord = function() end
            mock.playerName = "Tester"
            mock.realmName = "TestRealm"
            _G.FlipsideDB = saved
            _G.Minimap = CreateFrame("Frame", "Minimap", UIParent)
            ns = loadAddon()
            login()
            assert.is_false(button():IsShown())
        end)

        it("toggles with /flip minimap and saves the choice", function()
            slash("minimap")
            assert.is_false(button():IsShown())
            assert.is_true(ns.db:Get("account", "ui.minimapHidden"))
            assert.are.same({ "Flipside: minimap button hidden" }, mock.messages)
            slash("minimap")
            assert.is_true(button():IsShown())
            assert.is_false(ns.db:Get("account", "ui.minimapHidden"))
            assert.are.same({ "Flipside: minimap button shown" }, mock.messages)
        end)
    end)

    describe("window position", function()
        it("saves a new position when the window drag stops", function()
            slash("")
            local window = windowFrame()
            window.GetPoint = function()
                return "TOPLEFT", UIParent, "BOTTOMLEFT", 40, 800
            end
            window.TitleContainer.scripts.OnDragStop()
            assert.are.same({ point = "TOPLEFT", relativePoint = "BOTTOMLEFT", x = 40, y = 800 },
                ns.db:Get("account", "ui.windowPosition"))
        end)

        it("restores the position when the window is created", function()
            ns.db:Set("account", "ui.windowPosition", SAVED)
            slash("")
            local window = windowFrame()
            assert.are.same({ "TOPLEFT", UIParent, "BOTTOMLEFT", 40, 800 }, window.points[#window.points])
        end)

        it("resets the position with /flip resetpos", function()
            ns.db:Set("account", "ui.windowPosition", SAVED)
            slash("")
            local window = windowFrame()
            slash("resetpos")
            assert.is_nil(ns.db:Get("account", "ui.windowPosition"))
            assert.are.same({ { "CENTER" } }, window.points)
            assert.are.same({ "Flipside: window position reset" }, mock.messages)
        end)

        it("resets the saved position before the window exists", function()
            ns.db:Set("account", "ui.windowPosition", SAVED)
            slash("resetpos")
            assert.is_nil(ns.db:Get("account", "ui.windowPosition"))
        end)
    end)
end)
