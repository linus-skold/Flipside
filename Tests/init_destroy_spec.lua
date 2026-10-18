local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local PLATE = "|cffa335ee|Hitem:100::::::::60:::::|h[Plate One]|h|r"
local POTION = "|cffffffff|Hitem:200::::::::60:::::|h[Potion]|h|r"
local SWORD = "|cff0070dd|Hitem:300::::::::60:::::|h[Fine Sword]|h|r"

local ns

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
        if f.name == "FlipsideDestroyWindow" then
            return f
        end
    end
end

-- Item info as C_Item.GetItemInfo gives it: name, link, quality, item level, required level, type, subtype,
-- stack size, slot, icon, sell price, class id, subclass id.
local function gear(name, link, quality, minLevel, classID, subclassID)
    return { name, link, quality, 30, minLevel, "", "", 1, "INVTYPE_CHEST", "icon-" .. name, 0, classID, subclassID }
end

describe("Init Destroy window", function()
    before_each(function()
        mock.reset()
        local methods = getmetatable(CreateFrame("Frame")).__index
        methods.SetJustifyH = function() end
        methods.HasFocus = function(self)
            return self.focused
        end
        _G.ScrollUtil = nil
        _G.hooksecurefunc = function() end
        _G.C_Timer.NewTicker = function()
            return { Cancel = function() end }
        end
        _G.UnitLevel = function()
            return 60
        end
        _G.UnitClass = function()
            return "Mage", "MAGE"
        end
        _G.C_Spell = {
            GetSpellName = function()
                return "Disenchant"
            end,
        }
        _G.IsPlayerSpell = function()
            return true
        end
        mock.playerName = "Tester"
        mock.realmName = "TestRealm"
        mock.itemInfo[100] = gear("Plate One", PLATE, 4, 10, 4, 4)
        mock.itemInfo[200] = gear("Potion", POTION, 1, 1, 0, 0)
        mock.itemInfo[300] = gear("Fine Sword", SWORD, 3, 12, 2, 7)
        mock.bags[0] = {
            { itemID = 200, hyperlink = POTION, stackCount = 1, itemName = "Potion", isBound = false },
            { itemID = 100, hyperlink = PLATE, stackCount = 1, itemName = "Plate One", isBound = true },
            { itemID = 300, hyperlink = SWORD, stackCount = 1, itemName = "Fine Sword", isBound = true },
        }
        ns = loadAddon()
        login()
        mock.messages = {}
    end)

    after_each(function()
        _G.hooksecurefunc = nil
        _G.UnitLevel, _G.UnitClass, _G.C_Spell, _G.IsPlayerSpell = nil, nil, nil, nil
        mock.teardown()
    end)

    describe("slash command", function()
        it("opens the window with /flip destroy and closes it with the next one", function()
            assert.is_nil(windowFrame())
            slash("destroy")
            local frame = windowFrame()
            assert.is_truthy(frame)
            assert.is_true(frame:IsShown())
            slash("destroy")
            assert.is_false(frame:IsShown())
            slash("  DESTROY ")
            assert.is_true(frame:IsShown())
        end)

        it("makes the window only once", function()
            slash("destroy")
            slash("destroy")
            slash("destroy")
            local count = 0
            for _, f in ipairs(mock.frames) do
                if f.name == "FlipsideDestroyWindow" then
                    count = count + 1
                end
            end
            assert.are.equal(1, count)
        end)

        it("is in the help text", function()
            slash("help")
            local found = false
            for _, line in ipairs(mock.messages) do
                found = found or line == "Flipside: /flip destroy opens the Destroy window"
            end
            assert.is_true(found)
        end)

        it("does not open the window for the first time in combat", function()
            mock.inCombat = true
            slash("destroy")
            assert.is_nil(windowFrame())
            assert.are.same({ "Flipside: the Destroy window cannot open for the first time in combat" },
                mock.messages)
        end)

        it("does not open the window without the settings DB", function()
            ns.db = nil
            slash("destroy")
            assert.is_nil(windowFrame())
            assert.are.same({ "Flipside: the Destroy window is not available this session" }, mock.messages)
        end)
    end)

    describe("window", function()
        local view

        before_each(function()
            slash("destroy")
            view = ns.DestroyWindow.Get()
            -- The mock does not run OnShow when a frame shows.
            view.frame.scripts.OnShow(view.frame)
        end)

        it("lists the matching bag items, bound items too, by bag and slot", function()
            assert.are.equal(2, #view.rows)
            assert.are.equal("Plate One", view.rows[1].name)
            assert.are.equal(2, view.rows[1].slot)
            assert.are.equal("Fine Sword", view.rows[2].name)
            assert.are.equal("icon-Plate One", view.rows[1].icon)
        end)

        it("sets the Destroy button for the first row", function()
            assert.are.equal("macro", view.destroyButton:GetAttribute("type"))
            assert.are.equal("/cast Disenchant\n/use 0 2", view.destroyButton:GetAttribute("macrotext"))
            assert.is_true(view.destroyButton.enabled)
        end)

        it("registers the Destroy button for the up and the down click", function()
            assert.are.same({ "AnyUp", "AnyDown" }, view.destroyButton.clickButtons)
            assert.is_truthy(view.destroyButton.template:find("SecureActionButtonTemplate", 1, true))
        end)

        it("writes the macro to the log before a click", function()
            ns.Log.SetDebug(true)
            view.destroyButton.scripts.PreClick(view.destroyButton)
            local found = false
            for _, entry in ipairs(ns.Log.Query({ category = "destroy" })) do
                found = found or (entry.text:find("/cast Disenchant\n/use 0 2", 1, true) ~= nil)
            end
            assert.is_true(found)
        end)

        it("keeps the secure click handler", function()
            assert.is_nil(view.destroyButton.scripts.OnClick)
        end)

        it("sets the Destroy button for the selected row", function()
            local row = view.list.rows[2]
            row.scripts.OnClick(row)
            assert.are.equal("/cast Disenchant\n/use 0 3", view.destroyButton:GetAttribute("macrotext"))
        end)

        it("disables Destroy and says so if the player does not know Disenchant", function()
            _G.IsPlayerSpell = function()
                return false
            end
            view:Refresh()
            assert.is_false(view.destroyButton.enabled)
            assert.are.equal("You do not know Disenchant.", view.status:GetText())
        end)

        it("does not change the button in combat", function()
            mock.inCombat = true
            mock.fire("PLAYER_REGEN_DISABLED")
            assert.is_false(view.destroyButton.enabled)
            assert.are.equal("Destroy is not possible in combat.", view.status:GetText())
            assert.are.equal("/cast Disenchant\n/use 0 2", view.destroyButton:GetAttribute("macrotext"))
            mock.inCombat = false
            mock.fire("PLAYER_REGEN_ENABLED")
            assert.is_true(view.destroyButton.enabled)
        end)

        it("ignores the current item for good", function()
            assert.is_true(view:Ignore())
            assert.are.equal(1, #view.rows)
            assert.are.equal("Fine Sword", view.rows[1].name)
            assert.are.same({ [100] = true }, ns.db:Get("account", "destroy.ignored"))
            assert.are.equal(1, #view.ignoredRows)
        end)

        it("removes an item from the ignore list", function()
            view:Ignore()
            view:RemoveIgnored(100)
            assert.are.equal(2, #view.rows)
            assert.are.equal(0, #view.ignoredRows)
        end)

        it("skips the current item until the next /reload", function()
            assert.is_true(view:Skip())
            assert.are.equal(1, #view.rows)
            assert.is_nil(ns.db:Get("account", "destroy.ignored"))
            slash("destroy")
            slash("destroy")
            assert.are.equal(1, #view.rows)
        end)

        it("disables the actions if no item matches", function()
            view:Skip()
            view:Skip()
            assert.are.equal(0, #view.rows)
            assert.is_false(view.destroyButton.enabled)
            assert.is_false(view.ignoreButton.enabled)
            assert.is_false(view.skipButton.enabled)
            assert.is_false(view:Ignore())
        end)

        it("saves a rule change and applies it", function()
            view:ChangeRules(function(config)
                config.minQuality = 4
            end)
            assert.are.equal(1, #view.rows)
            assert.are.equal(4, ns.db:Get("account", "destroy.rules").minQuality)
        end)

        it("refreshes once after the bags change, at most once for each wait", function()
            table.remove(mock.bags[0], 3)
            mock.fire("BAG_UPDATE_DELAYED")
            mock.fire("BAG_UPDATE_DELAYED")
            assert.are.equal(2, #view.rows)
            mock.advance(1)
            assert.are.equal(1, #view.rows)
        end)

        it("does not refresh while the window is hidden", function()
            view.frame:Hide()
            table.remove(mock.bags[0], 3)
            mock.fire("BAG_UPDATE_DELAYED")
            mock.advance(1)
            assert.are.equal(2, #view.rows)
        end)
    end)
end)
