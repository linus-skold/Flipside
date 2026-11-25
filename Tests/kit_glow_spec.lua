local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end }
    for _, name in ipairs({ "Theme", "Widgets", "List", "Tabs", "Columns" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns.Kit
end

describe("Kit.AddHoverGlow", function()
    local Kit

    before_each(function()
        mock.reset()
        _G.ScrollUtil = nil
        Kit = loadModules()
    end)

    after_each(function()
        mock.teardown()
    end)

    it("adds a yellow ADD texture on the HIGHLIGHT layer that covers the frame", function()
        local button = CreateFrame("Button")
        local texture = Kit.AddHoverGlow(button)
        local glow = Kit.Theme.glow
        assert.are.equal("HIGHLIGHT", texture.layer)
        assert.are.equal(Kit.Theme.rowHighlight, texture.texture)
        assert.are.equal("ADD", texture.blendMode)
        assert.are.same({ glow.r, glow.g, glow.b, glow.alpha }, texture.vertexColor)
        assert.is_true(glow.r > 0.9 and glow.g > 0.7 and glow.b < 0.2)
        assert.is_true(glow.alpha <= 0.5)
        assert.are.equal(button, texture.allPoints)
        assert.are.equal(texture, button.kitGlow)
    end)

    it("returns the same texture on a second call", function()
        local button = CreateFrame("Button")
        assert.are.equal(Kit.AddHoverGlow(button), Kit.AddHoverGlow(button))
    end)

    it("covers a target with a pad", function()
        local button = CreateFrame("Button")
        local label = button:CreateFontString()
        local texture = Kit.AddHoverGlow(button, { target = label, pad = 2, alpha = 0.2 })
        assert.are.same({ "TOPLEFT", label, "TOPLEFT", -2, 2 }, texture.points[1])
        assert.are.same({ "BOTTOMRIGHT", label, "BOTTOMRIGHT", 2, -2 }, texture.points[2])
        assert.are.equal(0.2, texture.vertexColor[4])
    end)

    it("shows on enter and hides on leave in script mode, and keeps an earlier OnEnter", function()
        local frame = CreateFrame("Frame")
        local entered = 0
        frame:SetScript("OnEnter", function()
            entered = entered + 1
        end)
        local texture = Kit.AddHoverGlow(frame, { scripts = true })
        assert.are.equal("BACKGROUND", texture.layer)
        assert.is_false(texture:IsShown())
        frame.scripts.OnEnter(frame)
        assert.is_true(texture:IsShown())
        assert.are.equal(1, entered)
        frame.scripts.OnLeave(frame)
        assert.is_false(texture:IsShown())
    end)

    it("gives the glow to the rows of a list, with and without a skin", function()
        local plain = Kit.CreateList(CreateFrame("Frame"), { initRow = function() end })
        plain:SetData({ { 1 }, { 2 } })
        assert.is_not_nil(plain.rows[1].kitGlow)
        assert.are.equal("HIGHLIGHT", plain.rows[2].kitGlow.layer)
        local skinned = Kit.CreateList(CreateFrame("Frame"), { initRow = function() end,
            skin = { stripeAtlases = { "s1", "s2" }, highlightAtlas = "hover" } })
        skinned:SetData({ { 1 } })
        assert.is_not_nil(skinned.rows[1].kitGlow)
        assert.are.equal("hover", skinned.rows[1].kitHover.atlas)
    end)

    it("gives the glow to sortable column headers only", function()
        local cols = { { key = "a", title = "A", width = { share = 1 }, sortable = true },
            { key = "b", title = "B", width = { share = 1 } } }
        local header = Kit.CreateColumnHeader(CreateFrame("Frame"), cols, { gap = 6 })
        Kit.MakeHeaderSortable(header, cols, function() end)
        assert.is_not_nil(header.buttons.a.kitGlow)
        assert.is_nil(header.buttons.b)
    end)

    it("gives the glow to the top tabs", function()
        local tabs = Kit.CreateTopTabs(CreateFrame("Frame"), { { "a", "A" }, { "b", "B" } }, {})
        assert.is_not_nil(tabs.buttons[1].kitGlow)
        assert.is_not_nil(tabs.buttons[2].kitGlow)
    end)
end)
