local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local FILES = { "Theme", "Window", "Widgets", "Tabs" }

describe("Kit sounds", function()
    local Kit, window, tabs, enabled

    local function page(key)
        return { key = key, title = key, build = function() end }
    end

    before_each(function()
        mock.reset()
        local ns = {}
        for _, name in ipairs(FILES) do
            assert(loadfile(manifest.path(name)))("Flipside", ns)
        end
        Kit = ns.Kit
        enabled = true
        Kit.SetSoundGate(function()
            return enabled
        end)
        window = Kit.CreateWindow("SoundTestWindow", { width = 300, height = 200 })
        tabs = Kit.CreatePageTabs(window, { page("a"), page("b") })
        mock.sounds = {}
    end)

    after_each(function()
        mock.teardown()
    end)

    it("plays the tab sound once for a tab click", function()
        window.Tabs[2]:GetScript("OnClick")(window.Tabs[2])
        assert.are.same({ SOUNDKIT.IG_CHARACTER_INFO_TAB }, mock.sounds)
        assert.are.equal("b", tabs:GetSelected())
    end)

    it("plays no sound for a tab select from code", function()
        tabs:Select("b")
        assert.are.same({}, mock.sounds)
    end)

    it("plays the top tab sound for a click only", function()
        local top = Kit.CreateTopTabs(window, { { "x", "X" }, { "y", "Y" } }, {})
        top:Select("y")
        assert.are.same({}, mock.sounds)
        top.buttons[1]:GetScript("OnClick")(top.buttons[1])
        assert.are.same({ SOUNDKIT.IG_CHARACTER_INFO_TAB }, mock.sounds)
    end)

    it("plays the open and close sounds for a window", function()
        window:Show()
        window.scripts.OnShow(window)
        assert.are.same({ SOUNDKIT.IG_CHARACTER_INFO_OPEN }, mock.sounds)
        window:Hide()
        assert.are.same({ SOUNDKIT.IG_CHARACTER_INFO_OPEN, SOUNDKIT.IG_CHARACTER_INFO_CLOSE }, mock.sounds)
    end)

    it("plays nothing when sounds are off", function()
        enabled = false
        window.Tabs[2]:GetScript("OnClick")(window.Tabs[2])
        window:Show()
        window.scripts.OnShow(window)
        window:Hide()
        assert.are.same({}, mock.sounds)
    end)

    it("gives no error when SOUNDKIT, the key or PlaySound is missing", function()
        _G.SOUNDKIT = nil
        assert.is_false(Kit.PlaySound("tab"))
        _G.SOUNDKIT = {}
        assert.is_false(Kit.PlaySound("open"))
        _G.SOUNDKIT = { IG_CHARACTER_INFO_TAB = 1 }
        _G.PlaySound = nil
        assert.is_false(Kit.PlaySound("tab"))
        assert.is_false(Kit.PlaySound("unknown"))
    end)

    it("plays sounds when no gate is set", function()
        Kit.SetSoundGate(nil)
        assert.is_true(Kit.PlaySound("tab"))
    end)
end)
