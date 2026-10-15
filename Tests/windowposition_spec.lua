local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function load()
    local ns = {}
    for _, name in ipairs({ "Theme", "Window" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

describe("Kit window position", function()
    local ns, stored, sets

    local function save()
        return {
            get = function()
                return stored
            end,
            set = function(position)
                stored = position
                sets = sets + 1
            end,
        }
    end

    local function lastPoint(window)
        return window.points[#window.points]
    end

    before_each(function()
        mock.reset()
        ns = load()
        stored, sets = nil, 0
    end)

    after_each(function()
        mock.teardown()
    end)

    it("centres a window with no saved position", function()
        local window = ns.Kit.CreateWindow("TestWindowA", { savePosition = save() })
        assert.are.same({ "CENTER" }, lastPoint(window))
    end)

    it("works without the option", function()
        local window = ns.Kit.CreateWindow("TestWindowB")
        assert.are.same({ "CENTER" }, lastPoint(window))
        assert.has_no.errors(function()
            window.TitleContainer.scripts.OnDragStop()
        end)
    end)

    it("restores a saved position on create", function()
        stored = { point = "TOPLEFT", relativePoint = "BOTTOMLEFT", x = 120, y = 640 }
        local window = ns.Kit.CreateWindow("TestWindowC", { savePosition = save() })
        assert.are.same({ "TOPLEFT", UIParent, "BOTTOMLEFT", 120, 640 }, lastPoint(window))
    end)

    it("restores the same position in a second window that is created later", function()
        local first = ns.Kit.CreateWindow("TestWindowD", { savePosition = save() })
        first.GetPoint = function()
            return "TOPLEFT", UIParent, "BOTTOMLEFT", 30, 700
        end
        first.TitleContainer.scripts.OnDragStop()
        local second = ns.Kit.CreateWindow("TestWindowE", { savePosition = save() })
        assert.are.same({ "TOPLEFT", UIParent, "BOTTOMLEFT", 30, 700 }, lastPoint(second))
    end)

    it("clamps the window to the screen", function()
        local window = ns.Kit.CreateWindow("TestWindowF", { savePosition = save() })
        assert.is_true(window.clamped)
    end)

    it("saves the anchor and the offsets when a drag stops", function()
        local window = ns.Kit.CreateWindow("TestWindowG", { savePosition = save() })
        window.GetPoint = function()
            return "BOTTOMLEFT", UIParent, "BOTTOMLEFT", 55.5, 210
        end
        window.TitleContainer.scripts.OnDragStart()
        assert.is_true(window.moving)
        assert.are.equal(0, sets)
        window.TitleContainer.scripts.OnDragStop()
        assert.is_false(window.moving)
        assert.are.equal(1, sets)
        assert.are.same({ point = "BOTTOMLEFT", relativePoint = "BOTTOMLEFT", x = 55.5, y = 210 }, stored)
    end)

    it("ignores a saved position that is not valid", function()
        local bad = {
            "text",
            { point = "NOWHERE", relativePoint = "CENTER", x = 0, y = 0 },
            { point = "CENTER", relativePoint = "CENTER", x = "a", y = 0 },
            { point = "CENTER", relativePoint = "CENTER", x = 0 },
            { point = "CENTER", relativePoint = "CENTER", x = 0 / 0, y = 0 },
        }
        for i, value in ipairs(bad) do
            stored = value
            local window = ns.Kit.CreateWindow("TestWindowH" .. i, { savePosition = save() })
            assert.are.same({ "CENTER" }, lastPoint(window))
        end
    end)

    it("ignores a saved position that is off the screen", function()
        local screen = UIParent
        rawset(screen, "GetWidth", function()
            return 1920
        end)
        rawset(screen, "GetHeight", function()
            return 1080
        end)
        stored = { point = "CENTER", relativePoint = "CENTER", x = 5000, y = 0 }
        local window = ns.Kit.CreateWindow("TestWindowI", { savePosition = save() })
        assert.are.same({ "CENTER" }, lastPoint(window))
        stored = { point = "CENTER", relativePoint = "CENTER", x = -100, y = 300 }
        window = ns.Kit.CreateWindow("TestWindowJ", { savePosition = save() })
        assert.are.same({ "CENTER", UIParent, "CENTER", -100, 300 }, lastPoint(window))
        rawset(screen, "GetWidth", nil)
        rawset(screen, "GetHeight", nil)
    end)

    it("resets the window to the centre and clears the saved position", function()
        stored = { point = "TOPLEFT", relativePoint = "BOTTOMLEFT", x = 120, y = 640 }
        local window = ns.Kit.CreateWindow("TestWindowK", { savePosition = save() })
        window:ResetPosition()
        assert.are.same({ { "CENTER" } }, window.points)
        assert.is_nil(stored)
    end)
end)
