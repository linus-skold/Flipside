local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function load()
    local ns = {}
    for _, name in ipairs({ "Theme", "MinimapButton" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

describe("Kit minimap button", function()
    local ns, minimap

    before_each(function()
        mock.reset()
        local methods = getmetatable(CreateFrame("Frame")).__index
        methods.SetTexCoord = function() end
        ns = load()
        minimap = CreateFrame("Frame", "Minimap", UIParent)
        minimap.GetWidth = function()
            return 198
        end
        minimap.GetCenter = function()
            return 1000, 500
        end
    end)

    after_each(function()
        mock.teardown()
    end)

    local function create(options)
        options = options or {}
        options.parent = minimap
        options.icon = "Interface\\Icons\\INV_Misc_Coin_02"
        options.title = options.title or "Test"
        return ns.Kit.CreateMinimapButton("TestMinimapButton", options)
    end

    describe("angle maths", function()
        it("gives the angle of the cursor around the centre", function()
            assert.are.equal(0, ns.Kit.MinimapAngle(110, 50, 50, 50))
            assert.are.equal(90, ns.Kit.MinimapAngle(50, 90, 50, 50))
            assert.are.equal(180, ns.Kit.MinimapAngle(0, 50, 50, 50))
            assert.are.equal(270, ns.Kit.MinimapAngle(50, 0, 50, 50))
            assert.are.near(45, ns.Kit.MinimapAngle(60, 60, 50, 50), 1e-9)
        end)

        it("gives an offset on the circle", function()
            local x, y = ns.Kit.MinimapOffset(0, 100)
            assert.are.near(100, x, 1e-9)
            assert.are.near(0, y, 1e-9)
            x, y = ns.Kit.MinimapOffset(90, 100)
            assert.are.near(0, x, 1e-9)
            assert.are.near(100, y, 1e-9)
        end)

        it("round-trips an angle through the offset", function()
            local x, y = ns.Kit.MinimapOffset(225, 104)
            assert.are.near(225, ns.Kit.MinimapAngle(x, y, 0, 0), 1e-9)
        end)
    end)

    describe("create", function()
        it("makes a button on the minimap with the client icon", function()
            local button = create()
            assert.are.equal("Button", button.kind)
            assert.are.equal(minimap, button:GetParent())
            assert.are.equal(31, button.width)
            assert.are.equal("Interface\\Icons\\INV_Misc_Coin_02", button.icon.texture)
            assert.is_true(button:IsShown())
        end)

        it("places the button on the circle with the default angle", function()
            local button = create()
            local point = button.points[#button.points]
            local x, y = ns.Kit.MinimapOffset(225, 99 + 5)
            assert.are.same({ "CENTER", minimap, "CENTER", x, y }, point)
            assert.are.equal(225, button:GetAngle())
        end)

        it("uses the angle option and wraps the angle", function()
            local button = create({ angle = 90 })
            assert.are.equal(90, button:GetAngle())
            button:SetAngle(-90)
            assert.are.equal(270, button:GetAngle())
        end)

        it("starts hidden on request and shows again", function()
            local button = create({ hidden = true })
            assert.is_false(button:IsShown())
            button:SetHidden(false)
            assert.is_true(button:IsShown())
        end)
    end)

    describe("click", function()
        it("calls onClick with the button and the mouse button", function()
            local got
            local button = create({
                onClick = function(b, mouseButton)
                    got = { b, mouseButton }
                end,
            })
            button.scripts.OnClick(button, "LeftButton")
            assert.are.same({ button, "LeftButton" }, got)
        end)

        it("does nothing without onClick", function()
            local button = create()
            assert.has_no.errors(function()
                button.scripts.OnClick(button, "LeftButton")
            end)
        end)
    end)

    describe("drag", function()
        it("follows the cursor and reports the angle when the drag stops", function()
            local reported = {}
            local button = create({
                onAngleChanged = function(angle)
                    table.insert(reported, angle)
                end,
            })
            button.scripts.OnDragStart(button)
            assert.is_function(button.scripts.OnUpdate)
            mock.cursor = { 1000, 600 }
            button.scripts.OnUpdate(button)
            assert.are.equal(90, button:GetAngle())
            mock.cursor = { 900, 500 }
            button.scripts.OnUpdate(button)
            assert.are.equal(180, button:GetAngle())
            assert.are.same({}, reported)
            button.scripts.OnDragStop(button)
            assert.is_nil(button.scripts.OnUpdate)
            assert.are.same({ 180 }, reported)
        end)

        it("divides the cursor by the minimap scale", function()
            minimap.scale = 2
            local button = create()
            button.scripts.OnDragStart(button)
            mock.cursor = { 2000, 1200 }
            button.scripts.OnUpdate(button)
            assert.are.equal(90, button:GetAngle())
        end)
    end)

    describe("tooltip", function()
        it("shows the title and the lines on enter and hides on leave", function()
            local button = create({ title = "Flipside", lines = { "Left click: open the ledger", "Drag: move" } })
            button.scripts.OnEnter(button)
            assert.are.equal("Flipside", mock.tooltip.title)
            assert.are.same({ "Left click: open the ledger", "Drag: move" }, mock.tooltip.lines)
            assert.is_true(mock.tooltip.shown)
            button.scripts.OnLeave(button)
            assert.is_false(mock.tooltip.shown)
        end)

        it("shows no tooltip while the button is dragged", function()
            local button = create()
            button.scripts.OnDragStart(button)
            mock.tooltip.shown = false
            button.scripts.OnEnter(button)
            assert.is_false(mock.tooltip.shown)
        end)
    end)
end)
