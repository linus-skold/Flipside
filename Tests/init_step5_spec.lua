local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local ns, deps

local function tocFiles()
    return manifest.files()
end

local function loadAddon()
    local space = {}
    for _, path in ipairs(tocFiles()) do
        assert(loadfile(path))("Flipside", space)
    end
    local create = space.MainWindow.Create
    space.MainWindow.Create = function(given)
        deps = given
        return create(given)
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

local LINEN = "|cff1eff00|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r"

local function newTooltip()
    local t = { lines = {} }
    function t:AddLine(text) self.lines[#self.lines + 1] = { text = text } end
    function t:AddDoubleLine(l, r) self.lines[#self.lines + 1] = { left = l, right = r } end
    return t
end

describe("Init step 5", function()
    before_each(function()
        mock.reset()
        local methods = getmetatable(CreateFrame("Frame")).__index
        methods.SetJustifyH = function() end
        methods.HasFocus = function(self)
            return self.focused
        end
        _G.ScrollUtil = nil
        _G.ChatEdit_InsertLink = function()
            return true
        end
        _G.hooksecurefunc = function() end
        _G.C_Timer.NewTicker = function()
            return { Cancel = function() end }
        end
        mock.playerName = "Tester"
        mock.realmName = "TestRealm"
        mock.stackSizes[2589] = 200
        mock.bags[0] = { { itemID = 2589, hyperlink = LINEN, stackCount = 5, itemName = "Linen Cloth" } }
        deps = nil
        ns = loadAddon()
        login()
    end)

    after_each(function()
        _G.hooksecurefunc = nil
        _G.ChatEdit_InsertLink = nil
        mock.teardown()
    end)

    it("creates the holdings and the tooltip settings at login", function()
        assert.is_table(ns.holdings)
        assert.is_table(ns.tooltipConfig)
        assert.are.equal(1, #mock.postCalls)
        assert.are.equal(Enum.TooltipDataType.Item, mock.postCalls[1].type)
    end)

    it("saves the class of the character at login", function()
        mock.advance(0.5)
        assert.are.equal("MAGE", ns.holdings:Count("2589").characters[1].class)
    end)

    it("shows the tooltip again when Alt changes over an item", function()
        assert.is_true(ns.bus:HasSubscribers("MODIFIER_STATE_CHANGED"))
    end)

    it("writes the bags after the login delay and after a bag update", function()
        assert.are.equal(0, ns.holdings:Count("2589").total)
        mock.advance(0.5)
        assert.are.equal(5, ns.holdings:Count("2589").total)
        mock.bags[0][1].stackCount = 8
        mock.fire("BAG_UPDATE_DELAYED")
        mock.fire("BAG_UPDATE_DELAYED")
        mock.advance(0.4)
        assert.are.equal(5, ns.holdings:Count("2589").total)
        mock.advance(0.2)
        assert.are.equal(8, ns.holdings:Count("2589").total)
    end)

    it("reads the bank only while it is open", function()
        mock.advance(0.5)
        mock.bags[6] = { { itemID = 2589, hyperlink = LINEN, stackCount = 3, itemName = "Linen Cloth" } }
        mock.fire("PLAYERBANKSLOTS_CHANGED")
        mock.advance(0.5)
        assert.are.equal(0, ns.holdings:Count("2589").characters[1].bank)
        mock.fire("BANKFRAME_OPENED")
        assert.are.equal(3, ns.holdings:Count("2589").characters[1].bank)
        mock.fire("BANKFRAME_CLOSED")
    end)

    it("reads mail and own auctions", function()
        mock.mail = { { attachments = { { link = LINEN, count = 2 } } } }
        mock.ownedAuctions = { { itemLink = LINEN, quantity = 4, status = 0 } }
        mock.fire("MAIL_INBOX_UPDATE")
        mock.fire("OWNED_AUCTIONS_UPDATED")
        mock.advance(0.5)
        local entry = ns.holdings:Count("2589").characters[1]
        assert.are.equal(2, entry.mail)
        assert.are.equal(4, entry.auctions)
    end)

    describe("tooltip", function()
        before_each(function()
            mock.advance(0.5)
        end)

        it("adds one invalid price row and no header for an item without scan data", function()
            local tip = newTooltip()
            mock.postCalls[1].fn(tip, { hyperlink = LINEN })
            assert.are.equal(" ", tip.lines[1].text)
            assert.are.equal("Prices", tip.lines[2].left)
            assert.are.equal("invalid price", tip.lines[2].right)
            for _, line in ipairs(tip.lines) do
                assert.is_nil(tostring(line.text):find("Flipside", 1, true))
            end
            local found
            for _, line in ipairs(tip.lines) do
                if line.left == "Total: 5" then found = true end
            end
            assert.is_true(found)
        end)

        it("shows the stack count in the price label while Alt is held", function()
            assert.is_true(ns.tooltipConfig:AddLine("Mine", "123"))
            local owner = { GetBagID = function() return 0 end, GetID = function() return 1 end }
            local function run()
                local tip = newTooltip()
                tip.GetOwner = function() return owner end
                mock.postCalls[1].fn(tip, { hyperlink = LINEN })
                return tip
            end
            local function hasStack(tip)
                for _, line in ipairs(tip.lines) do
                    if line.left == "Mine x5" then return true end
                end
                return false
            end
            assert.is_false(hasStack(run()))
            mock.altDown = true
            assert.is_true(hasStack(run()))
        end)

        it("does not break the tooltip when the build fails", function()
            ns.TooltipLines.Build = function() error("boom") end
            local tip = newTooltip()
            assert.has_no.errors(function()
                mock.postCalls[1].fn(tip, { hyperlink = LINEN })
            end)
            assert.are.equal(0, #tip.lines)
            assert.is_truthy(mock.messages[#mock.messages]:find("tooltip lines failed", 1, true))
        end)

        it("prints the build time", function()
            slash("tooltipstats")
            assert.are.same({ "Flipside: no tooltip lines were built yet" }, mock.messages)
            mock.postCalls[1].fn(newTooltip(), { hyperlink = LINEN })
            slash("tooltipstats")
            assert.is_truthy(mock.messages[1]:find("1 builds, max", 1, true))
        end)
    end)

    describe("forget", function()
        it("removes the inventory of a saved character", function()
            mock.advance(0.5)
            slash("forget Tester-TestRealm")
            assert.are.same({ "Flipside: forgot the inventory of Tester-TestRealm" }, mock.messages)
            assert.are.equal(0, ns.holdings:Count("2589").total)
            slash("forget Nobody-Nowhere")
            assert.are.same({ "Flipside: no saved character Nobody-Nowhere" }, mock.messages)
            slash("forget")
            assert.is_truthy(mock.messages[1]:find("usage", 1, true))
        end)
    end)

    describe("window", function()
        it("has the Ledger tab first, then Tooltip after Operations, and passes the deps", function()
            slash("")
            local tabs = windowFrame().Tabs
            assert.are.equal("Ledger", tabs[1]:GetText())
            assert.are.equal("Operations", tabs[3]:GetText())
            assert.are.equal("Tooltip", tabs[4]:GetText())
            assert.are.equal(ns.tooltipConfig, deps.tooltipConfig)
            assert.are.equal(ns.holdings, deps.holdings)
            assert.is_function(deps.buildPreview)
            assert.is_function(deps.getRecord)
        end)

        it("builds the Tooltip page and refreshes it when the tab is clicked", function()
            mock.advance(0.5)
            slash("")
            local tabs = windowFrame().Tabs
            tabs[4].scripts.OnClick(tabs[4])
            assert.are.same({}, mock.messages)
            local rows = deps.buildPreview(LINEN, { lines = {}, showGroup = false, showOperation = false,
                showCounts = true })
            assert.are.equal("Total: 5", rows[1].left)
        end)
    end)
end)
