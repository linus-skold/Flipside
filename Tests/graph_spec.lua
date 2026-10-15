local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadKit()
    local ns = {}
    for _, name in ipairs({ "Theme", "Widgets", "Graph" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns.Kit
end

describe("Kit.LineGraph", function()
    local Kit

    before_each(function()
        mock.reset()
        Kit = loadKit()
    end)

    after_each(function()
        mock.teardown()
    end)

    local points = { { x = 0, y = 0 }, { x = 10, y = 50 }, { x = 20, y = 100 } }

    describe("view and layout", function()
        it("takes the range from the points and starts y at 0", function()
            local view = Kit.GraphView({ { x = 5, y = 30 }, { x = 15, y = 80 } })
            assert.are.same({ 5, 15, 0, 80 }, { view.xMin, view.xMax, view.yMin, view.yMax })
        end)

        it("keeps the fields that the caller gives", function()
            local view = Kit.GraphView(points, { yMax = 200, yTicks = { 0, 200 } })
            assert.are.equal(200, view.yMax)
            assert.are.same({ 0, 200 }, view.yTicks)
            assert.are.equal(20, view.xMax)
        end)

        it("gives a flat or empty graph a height", function()
            assert.are.equal(1, Kit.GraphView({ { x = 1, y = 0 } }).yMax)
            assert.are.equal(1, Kit.GraphView({}).yMax)
        end)

        it("lays the points out in pixels from the bottom left", function()
            local layout = Kit.GraphLayout(points, Kit.GraphView(points), 200, 100)
            assert.are.same({ x = 0, y = 0 }, layout[1])
            assert.are.same({ x = 100, y = 50 }, layout[2])
            assert.are.same({ x = 200, y = 100 }, layout[3])
        end)

        it("scales y by the range of the view", function()
            local layout = Kit.GraphLayout(points, Kit.GraphView(points, { yMax = 200 }), 200, 100)
            assert.are.equal(25, layout[2].y)
            assert.are.equal(50, layout[3].y)
        end)

        it("puts one point, or points of equal x, in the middle", function()
            local layout = Kit.GraphLayout({ { x = 7, y = 5 } }, Kit.GraphView({ { x = 7, y = 5 } }), 200, 100)
            assert.are.equal(100, layout[1].x)
        end)

        it("moves a point outside the view to the edge", function()
            local view = { xMin = 0, xMax = 10, yMin = 0, yMax = 100 }
            local layout = Kit.GraphLayout({ { x = -5, y = 500 } }, view, 100, 50)
            assert.are.same({ x = 0, y = 50 }, layout[1])
        end)
    end)

    describe("nearest point", function()
        local layout = { { x = 0, y = 0 }, { x = 100, y = 0 }, { x = 200, y = 0 } }

        it("finds the point with the nearest x", function()
            assert.are.equal(1, Kit.GraphNearest(layout, -50))
            assert.are.equal(1, Kit.GraphNearest(layout, 49))
            assert.are.equal(2, Kit.GraphNearest(layout, 51))
            assert.are.equal(3, Kit.GraphNearest(layout, 190))
            assert.are.equal(3, Kit.GraphNearest(layout, 900))
        end)

        it("takes the first point on a tie", function()
            assert.are.equal(1, Kit.GraphNearest(layout, 50))
        end)

        it("gives nil for no points", function()
            assert.is_nil(Kit.GraphNearest({}, 10))
        end)
    end)

    describe("widget", function()
        local function build(options)
            local graph = Kit.LineGraph(CreateFrame("Frame", nil, UIParent), options)
            graph:SetWidth(280)
            graph:SetHeight(130)
            return graph
        end

        local function shown(pool)
            local count = 0
            for _, item in ipairs(pool) do
                if item.shown then
                    count = count + 1
                end
            end
            return count
        end

        local function childrenOf(frame, kind)
            local out = {}
            for _, f in ipairs(mock.objects) do
                if f.parent == frame and f.kind == kind then
                    out[#out + 1] = f
                end
            end
            return out
        end

        it("lays the points out in the plot area", function()
            local graph = build()
            graph:SetPoints(points, { yMax = 100, yTicks = { 0, 50, 100 } })
            local layout = graph:GetLayout()
            assert.are.equal(3, #layout)
            -- The plot is 280 - 70 - 10 = 200 wide and 130 - 8 - 18 = 104 high.
            assert.are.equal(200, layout[3].x)
            assert.are.equal(104, layout[3].y)
        end)

        it("makes a texture line for each segment and reuses them", function()
            local created = 0
            local graph = build()
            local plot = graph.plot
            local make = plot.CreateLine
            plot.CreateLine = function(...)
                created = created + 1
                return make(...)
            end
            graph:SetPoints(points)
            assert.are.equal(2, created)
            graph:SetPoints({ points[1], points[2] })
            assert.are.equal(2, created)
            graph:SetPoints(points)
            assert.are.equal(2, created)
        end)

        it("sets the end points of a line from the layout", function()
            local graph = build()
            local lines = {}
            local make = graph.plot.CreateLine
            graph.plot.CreateLine = function(...)
                local line = make(...)
                lines[#lines + 1] = line
                return line
            end
            graph:SetPoints(points)
            local layout = graph:GetLayout()
            assert.are.same({ "BOTTOMLEFT", graph.plot, layout[1].x, layout[1].y }, lines[1].startPoint)
            assert.are.same({ "BOTTOMLEFT", graph.plot, layout[2].x, layout[2].y }, lines[1].endPoint)
            assert.are.same({ "BOTTOMLEFT", graph.plot, layout[3].x, layout[3].y }, lines[2].endPoint)
        end)

        it("draws thin bars if the client has no CreateLine", function()
            mock.noLines = true
            local graph = build()
            assert.is_nil(graph.plot.CreateLine)
            graph:SetPoints(points)
            local bars = {}
            for _, texture in ipairs(childrenOf(graph.plot, "Texture")) do
                if texture.layer == "ARTWORK" then
                    bars[#bars + 1] = texture
                end
            end
            assert.are.equal(3, #bars)
            assert.are.equal(104, bars[3].height)
            assert.are.equal(0, #childrenOf(graph.plot, "Line"))
        end)

        it("labels the y ticks and the start, middle and end of the x axis", function()
            local graph = build({
                formatY = function(v)
                    return "y" .. v
                end,
                formatX = function(v)
                    return "x" .. v
                end,
            })
            graph:SetPoints(points, { yMax = 100, yTicks = { 0, 50, 100 } })
            local labels = {}
            for _, f in ipairs(childrenOf(graph, "FontString")) do
                labels[#labels + 1] = f.text
            end
            table.sort(labels)
            assert.are.same({ "", "x0", "x10", "x20", "y0", "y100", "y50" }, labels)
        end)

        it("shows the empty text for an empty list and hides it again", function()
            local graph = build({ emptyText = "Nothing" })
            graph:SetPoints({})
            local texts = {}
            for _, f in ipairs(childrenOf(graph, "FontString")) do
                if f.shown and f.text == "Nothing" then
                    texts[#texts + 1] = f
                end
            end
            assert.are.equal(1, #texts)
            graph:SetPoints(points)
            assert.are.equal(0, shown(texts))
        end)

        it("shows the tooltip of the nearest point on hover", function()
            local seen
            local graph = build({
                onHover = function(point, index)
                    seen = { point = point, index = index }
                    return { "Title", "Line" }
                end,
            })
            graph:SetPoints(points)
            assert.are.equal(2, graph:HoverAt(95))
            assert.are.equal(2, seen.index)
            assert.are.equal(50, seen.point.y)
            assert.are.equal("Title", mock.tooltip.title)
            assert.are.same({ "Line" }, mock.tooltip.lines)
            assert.is_true(mock.tooltip.shown)
            assert.are.equal(graph, mock.tooltip.owner)
        end)

        it("does not build the tooltip again for the same point", function()
            local calls = 0
            local graph = build({
                onHover = function()
                    calls = calls + 1
                    return { "T" }
                end,
            })
            graph:SetPoints(points)
            graph:HoverAt(90)
            graph:HoverAt(110)
            assert.are.equal(1, calls)
            graph:HoverAt(190)
            assert.are.equal(2, calls)
        end)

        it("follows the cursor while the mouse is over the graph and hides the tooltip on leave", function()
            local graph = build({
                onHover = function(point)
                    return { "y" .. point.y }
                end,
            })
            graph:SetPoints(points)
            graph.plot.left = 100
            mock.cursor = { 300, 0 }
            graph.scripts.OnUpdate(graph)
            assert.is_nil(mock.tooltip.title)
            graph.scripts.OnEnter(graph)
            graph.scripts.OnUpdate(graph)
            assert.are.equal("y100", mock.tooltip.title)
            graph.scripts.OnLeave(graph)
            assert.is_false(mock.tooltip.shown)
        end)

        it("gives nil for a hover when there are no points", function()
            local graph = build()
            graph:SetPoints({})
            assert.is_nil(graph:HoverAt(10))
        end)

        it("draws again when the size changes", function()
            local graph = build()
            graph:SetPoints(points)
            graph:SetWidth(480)
            graph.scripts.OnSizeChanged(graph)
            assert.are.equal(400, graph:GetLayout()[3].x)
        end)
    end)
end)
