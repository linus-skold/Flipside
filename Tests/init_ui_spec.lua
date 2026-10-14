local mock = require("Tests.wow_mock")

local ns

-- Load the files in the order of the TOC, as the client does.
local function tocFiles()
    local files = {}
    for line in io.lines("Flipside.toc") do
        local path = line:match("^([%w\\]+%.lua)%s*$")
        if path then
            table.insert(files, (path:gsub("\\", "/")))
        end
    end
    return files
end

local function slash(text)
    mock.messages = {}
    _G.SlashCmdList.FLIPSIDE(text)
end

local function login()
    mock.fire("ADDON_LOADED", "Flipside")
    mock.fire("PLAYER_LOGIN")
end

local function windowFrames()
    local list = {}
    for _, f in ipairs(mock.frames) do
        if f.name == "FlipsideMainWindow" then
            table.insert(list, f)
        end
    end
    return list
end

-- A fake Auction House frame with two Blizzard tabs.
local function makeAH()
    local frame = CreateFrame("Frame", "AuctionHouseFrame", UIParent)
    local modes = { Buy = { "PaneA" }, Auctions = { "PaneB" } }
    for _, name in ipairs({ "PaneA", "PaneB" }) do
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
        self.displayMode = mode
    end
    _G.AuctionHouseFrame = frame
    return frame
end

describe("Init UI", function()
    before_each(function()
        mock.reset()
        local methods = getmetatable(CreateFrame("Frame")).__index
        methods.SetJustifyH = function() end
        methods.HasFocus = function(self)
            return self.focused
        end
        _G.ScrollUtil = nil
        _G.hooksecurefunc = function(target, name, hook)
            local original = target[name]
            target[name] = function(...)
                original(...)
                hook(...)
            end
        end
        _G.C_Timer.NewTicker = function()
            return { Cancel = function() end }
        end
        mock.playerName = "Tester"
        mock.realmName = "TestRealm"
        ns = {}
        for _, path in ipairs(tocFiles()) do
            assert(loadfile(path))("Flipside", ns)
        end
    end)

    after_each(function()
        _G.AuctionHouseFrame = nil
        _G.hooksecurefunc = nil
        mock.teardown()
    end)

    it("loads the UI files in order before Init", function()
        local position = {}
        for i, path in ipairs(tocFiles()) do
            position[path] = i
        end
        assert.is_true(position["UI/Kit/Combat.lua"] < position["UI/Pages/FormulaPage.lua"])
        assert.is_true(position["UI/Pages/FormulaPage.lua"] < position["UI/MainWindow.lua"])
        assert.is_true(position["UI/MainWindow.lua"] < position["Features/AuctionTab/AuctionTab.lua"])
        assert.is_true(position["Features/AuctionTab/AuctionTab.lua"] < position["Core/Init.lua"])
        assert.is_table(ns.MainWindow)
        assert.is_table(ns.AuctionTab)
    end)

    describe("window", function()
        before_each(login)

        it("creates no window at login", function()
            assert.are.equal(0, #windowFrames())
        end)

        it("opens with /flip and hides with a second /flip", function()
            slash("")
            local frames = windowFrames()
            assert.are.equal(1, #frames)
            assert.is_true(frames[1]:IsShown())
            assert.are.same({}, mock.messages)
            slash("")
            assert.is_false(frames[1]:IsShown())
            slash("")
            assert.is_true(frames[1]:IsShown())
        end)

        it("creates the window once", function()
            slash("")
            _G.SlashCmdList.FLIPSIDE("")
            ns.OpenMainWindow()
            assert.are.equal(1, #windowFrames())
        end)

        it("prints the help for /flip help", function()
            slash("help")
            assert.are.equal("Flipside: /flip opens the Flipside window", mock.messages[1])
            assert.are.equal(0, #windowFrames())
        end)

        it("prints the help for an unknown argument", function()
            slash("nonsense")
            assert.are.equal("Flipside: /flip opens the Flipside window", mock.messages[1])
            assert.are.equal(0, #windowFrames())
        end)
    end)

    describe("Auction House tab", function()
        it("attaches at once when the Auction House frame exists", function()
            local ah = makeAH()
            login()
            assert.are.equal(3, #ah.Tabs)
            assert.are.equal("Flipside", ns.auctionTab.tab:GetText())
        end)

        it("attaches when the Auction House addon loads after login", function()
            login()
            assert.is_table(ns.auctionTab)
            assert.is_nil(ns.auctionTab.tab)
            local ah = makeAH()
            mock.fire("ADDON_LOADED", "Blizzard_SomethingElse")
            assert.are.equal(2, #ah.Tabs)
            mock.fire("ADDON_LOADED", "Blizzard_AuctionHouseUI")
            assert.are.equal(3, #ah.Tabs)
            assert.are.equal(ah.Tabs[3], ns.auctionTab.tab)
        end)

        it("attaches without a scan engine and says so", function()
            ns.ScanEngine = nil
            local ah = makeAH()
            login()
            assert.is_nil(ns.scanEngine)
            assert.are.equal(3, #ah.Tabs)
            assert.are.equal("scan is not available this session", ns.auctionTab.ui.cooldown:GetText())
        end)

        it("opens the Flipside window from the tab", function()
            makeAH()
            login()
            local button = ns.auctionTab.ui.openMain
            button:GetScript("OnClick")(button)
            local frames = windowFrames()
            assert.are.equal(1, #frames)
            assert.is_true(frames[1]:IsShown())
        end)

        it("starts a scan from the tab after the popup is accepted", function()
            makeAH()
            login()
            mock.fire("AUCTION_HOUSE_SHOW")
            local button = ns.auctionTab.ui.scan
            button:GetScript("OnClick")(button)
            assert.are.equal("FLIPSIDE_FULL_SCAN", mock.popup.which)
            assert.is_false(ns.scanEngine:IsRunning())
            mock.acceptPopup()
            assert.is_true(ns.scanEngine:IsRunning())
        end)

        it("does not start a scan when the popup is not accepted", function()
            makeAH()
            login()
            mock.fire("AUCTION_HOUSE_SHOW")
            local button = ns.auctionTab.ui.scan
            button:GetScript("OnClick")(button)
            assert.is_false(ns.scanEngine:IsRunning())
        end)

        it("uses the same popup for /flip scan", function()
            makeAH()
            login()
            mock.fire("AUCTION_HOUSE_SHOW")
            local button = ns.auctionTab.ui.scan
            button:GetScript("OnClick")(button)
            mock.popup = nil
            slash("scan")
            assert.are.equal("FLIPSIDE_FULL_SCAN", mock.popup.which)
            mock.acceptPopup()
            assert.is_true(ns.scanEngine:IsRunning())
        end)
    end)
end)
