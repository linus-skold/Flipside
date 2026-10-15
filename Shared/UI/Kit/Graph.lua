local _, ns = ...
ns.Kit = ns.Kit or {}
local Kit = ns.Kit

-- A line graph. It takes all input as arguments and knows no addon name (D19).

local LINE_COLOR = { 1, 0.82, 0, 1 }
local GRID_COLOR = { 1, 1, 1, 0.12 }
local MARKER_SIZE = 7

-- Returns the view of a point list: xMin, xMax, yMin, yMax. A field in view stays. The y range starts at 0.
-- yMax is larger than yMin, so a flat line still has a height.
function Kit.GraphView(points, view)
    view = view or {}
    local result = { yTicks = view.yTicks }
    local xMin, xMax, yMax
    for _, point in ipairs(points) do
        xMin = (xMin == nil or point.x < xMin) and point.x or xMin
        xMax = (xMax == nil or point.x > xMax) and point.x or xMax
        yMax = (yMax == nil or point.y > yMax) and point.y or yMax
    end
    result.xMin = view.xMin or xMin or 0
    result.xMax = view.xMax or xMax or 0
    result.yMin = view.yMin or 0
    result.yMax = view.yMax or yMax or 0
    if result.yMax <= result.yMin then
        result.yMax = result.yMin + 1
    end
    return result
end

-- Returns the pixel position of each point: a list of { x, y } from the bottom left corner of the plot.
-- A point that is outside the view is moved to the edge. If all x values are equal, the points are in the middle.
function Kit.GraphLayout(points, view, width, height)
    local spanX, spanY = view.xMax - view.xMin, view.yMax - view.yMin
    local layout = {}
    for index, point in ipairs(points) do
        local x = spanX > 0 and (point.x - view.xMin) / spanX * width or width / 2
        local y = spanY > 0 and (point.y - view.yMin) / spanY * height or 0
        layout[index] = { x = math.min(math.max(x, 0), width), y = math.min(math.max(y, 0), height) }
    end
    return layout
end

-- Returns the index of the laid out point that is nearest to the pixel x. On a tie the first point wins.
-- Returns nil for an empty layout.
function Kit.GraphNearest(layout, pixelX)
    local best, bestDistance
    for index, point in ipairs(layout) do
        local distance = math.abs(point.x - pixelX)
        if bestDistance == nil or distance < bestDistance then
            best, bestDistance = index, distance
        end
    end
    return best
end

-- Returns the item at index of a pool, made by make(). Items after count are hidden by hidePool.
local function take(pool, index, make)
    local item = pool[index]
    if not item then
        item = make()
        pool[index] = item
    end
    item:Show()
    return item
end

local function hidePool(pool, count)
    for index = count + 1, #pool do
        pool[index]:Hide()
    end
end

-- Create a line graph. options:
--   height (default 130), margins { left = 70, right = 10, top = 8, bottom = 18 },
--   formatY(value) and formatX(value) give the axis label text,
--   onHover(point, index) gives an array of strings for the tooltip (the first is the title), or nil for none,
--   emptyText shows when there are no points.
-- Methods: SetPoints(points, view), HoverAt(pixelX), Redraw().
-- points is a list of { x, y } sorted by x. view is optional: xMin, xMax, yMin, yMax, yTicks (a list of y values
-- that get a grid line and a label). The graph draws the points as a line with a texture line (CreateLine) or,
-- if the client has none, as thin bars.
function Kit.LineGraph(parent, options)
    options = options or {}
    local margins = {}
    for name, value in pairs({ left = 70, right = 10, top = 8, bottom = 18 }) do
        margins[name] = options.margins and options.margins[name] or value
    end
    local graph = CreateFrame("Frame", nil, parent)
    graph:SetHeight(options.height or 130)
    graph:EnableMouse(true)
    local plot = CreateFrame("Frame", nil, graph)
    plot:SetPoint("TOPLEFT", graph, "TOPLEFT", margins.left, -margins.top)
    plot:SetPoint("BOTTOMRIGHT", graph, "BOTTOMRIGHT", -margins.right, margins.bottom)
    graph.plot = plot

    local state = { points = {}, view = Kit.GraphView({}), layout = {} }
    local pools = { grid = {}, line = {}, yLabel = {}, xLabel = {} }
    local useLines = type(plot.CreateLine) == "function"
    local hover = { active = false, index = nil }

    local empty = Kit.Label(graph, options.emptyText or "", "disabled")
    empty:SetPoint("CENTER", plot, "CENTER", 0, 0)
    empty:Hide()

    local marker = plot:CreateTexture(nil, "OVERLAY")
    marker:SetSize(MARKER_SIZE, MARKER_SIZE)
    marker:SetColorTexture(1, 1, 1, 1)
    marker:Hide()

    local function plotSize()
        local width = graph:GetWidth() - margins.left - margins.right
        local height = graph:GetHeight() - margins.top - margins.bottom
        return math.max(width, 1), math.max(height, 1)
    end

    local function text(pool, index, role)
        return take(pool, index, function()
            local label = Kit.Label(graph, "", role)
            return label
        end)
    end

    local function drawGrid(width, height)
        local view = state.view
        local ticks = view.yTicks or { view.yMin, view.yMax }
        local count = 0
        for _, value in ipairs(ticks) do
            count = count + 1
            local y = (value - view.yMin) / (view.yMax - view.yMin) * height
            local grid = take(pools.grid, count, function()
                local texture = plot:CreateTexture(nil, "BACKGROUND")
                texture:SetColorTexture(GRID_COLOR[1], GRID_COLOR[2], GRID_COLOR[3], GRID_COLOR[4])
                texture:SetHeight(1)
                return texture
            end)
            grid:ClearAllPoints()
            grid:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, y)
            grid:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, y)
            local label = text(pools.yLabel, count, "small")
            label:ClearAllPoints()
            label:SetPoint("RIGHT", plot, "BOTTOMLEFT", -4, y)
            label:SetJustifyH("RIGHT")
            label:SetText(options.formatY and options.formatY(value) or tostring(value))
        end
        hidePool(pools.grid, count)
        hidePool(pools.yLabel, count)
        -- The x labels: the start, the middle and the end.
        local anchors = {
            { value = view.xMin, point = "TOPLEFT", x = 0 },
            { value = (view.xMin + view.xMax) / 2, point = "TOP", x = width / 2 },
            { value = view.xMax, point = "TOPRIGHT", x = width },
        }
        for index, anchor in ipairs(anchors) do
            local label = text(pools.xLabel, index, "small")
            label:ClearAllPoints()
            label:SetPoint(anchor.point, plot, "BOTTOMLEFT", anchor.x, -3)
            label:SetText(options.formatX and options.formatX(anchor.value) or tostring(anchor.value))
        end
        hidePool(pools.xLabel, #anchors)
    end

    local function drawSeries()
        local layout = state.layout
        local used = 0
        if useLines then
            for index = 1, #layout - 1 do
                used = used + 1
                local line = take(pools.line, used, function()
                    local made = plot:CreateLine(nil, "ARTWORK")
                    made:SetThickness(1.5)
                    made:SetColorTexture(LINE_COLOR[1], LINE_COLOR[2], LINE_COLOR[3], LINE_COLOR[4])
                    return made
                end)
                line:SetStartPoint("BOTTOMLEFT", plot, layout[index].x, layout[index].y)
                line:SetEndPoint("BOTTOMLEFT", plot, layout[index + 1].x, layout[index + 1].y)
            end
        end
        if not useLines or #layout == 1 then
            -- Without CreateLine the graph draws one thin bar for each point.
            for _, point in ipairs(layout) do
                used = used + 1
                local bar = take(pools.line, used, function()
                    local made = plot:CreateTexture(nil, "ARTWORK")
                    made:SetColorTexture(LINE_COLOR[1], LINE_COLOR[2], LINE_COLOR[3], LINE_COLOR[4])
                    return made
                end)
                bar:ClearAllPoints()
                bar:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", point.x - 1, 0)
                bar:SetSize(2, math.max(point.y, 1))
            end
        end
        hidePool(pools.line, used)
    end

    function graph.Redraw()
        local width, height = plotSize()
        state.layout = Kit.GraphLayout(state.points, state.view, width, height)
        empty:SetShown(#state.points == 0)
        drawGrid(width, height)
        drawSeries()
        marker:Hide()
        hover.index = nil
    end

    -- Set the points and redraw. view is optional (see Kit.GraphView).
    function graph:SetPoints(points, view)
        state.points = points or {}
        state.view = Kit.GraphView(state.points, view)
        self:Redraw()
    end

    function graph.GetLayout()
        return state.layout
    end

    function graph.GetView()
        return state.view
    end

    -- Show the tooltip for the point that is nearest to the pixel x of the plot. Returns its index, or nil.
    function graph.HoverAt(_, pixelX)
        local index = Kit.GraphNearest(state.layout, pixelX)
        if index == nil then
            return nil
        end
        if index ~= hover.index then
            hover.index = index
            local point = state.layout[index]
            marker:ClearAllPoints()
            marker:SetPoint("CENTER", plot, "BOTTOMLEFT", point.x, point.y)
            marker:Show()
            local lines = options.onHover and options.onHover(state.points[index], index)
            if lines and #lines > 0 then
                GameTooltip:SetOwner(graph, "ANCHOR_CURSOR_RIGHT")
                GameTooltip:SetText(lines[1])
                for line = 2, #lines do
                    GameTooltip:AddLine(lines[line], 1, 1, 1, true)
                end
                GameTooltip:Show()
            else
                GameTooltip:Hide()
            end
        end
        return index
    end

    graph:SetScript("OnEnter", function()
        hover.active = true
    end)
    graph:SetScript("OnLeave", function()
        hover.active, hover.index = false, nil
        marker:Hide()
        GameTooltip:Hide()
    end)
    graph:SetScript("OnUpdate", function()
        if hover.active then
            local cursorX = GetCursorPosition()
            graph:HoverAt(cursorX / graph:GetEffectiveScale() - plot:GetLeft())
        end
    end)
    graph:SetScript("OnSizeChanged", function()
        graph:Redraw()
    end)
    return graph
end
