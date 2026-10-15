local _, ns = ...
ns.Kit = ns.Kit or {}
local Kit = ns.Kit

-- Real columns for lists and trees: one column definition gives the header and every row cell
-- the same x offset and width, so the text lines up at any panel width.
--
-- A column is a table:
--   key      name of the column; the default value is data[key]
--   get      optional function(data) that returns the value (replaces data[key])
--   title    header text
--   width    a number (fixed width), or nil / "fill" for the one column that takes the rest
--   justify  "LEFT" (default), "RIGHT" or "CENTER"
--   number   true for money and numbers: the default justify is then "RIGHT"
--   format   optional function(value, data) that returns the cell text (default tostring)
--   owned    true if the caller draws the cell itself (the header still shows)
--
-- Options (all optional): gap (space between columns, default 6), left and right (space at the row edges,
-- default 0), minFill (smallest width of the fill column, default 20), role (header font role).
--
-- Example:
--   local columns = {
--       { key = "name", title = "Item", width = 160 },
--       { key = "price", title = "Price", width = 80, number = true, format = formatMoney },
--       { key = "info", title = "Info" },  -- fills the rest
--   }
--   local header = Kit.CreateColumnHeader(parent, columns)  -- place header.frame
--   local cells = Kit.CreateColumnCells(row, columns)       -- once for each row
--   Kit.SetColumnCells(cells, columns, data)                -- every time the row shows data

local DEFAULT_GAP = 6
local DEFAULT_MIN_FILL = 20

local function isFill(column)
    return column.width == nil or column.width == "fill"
end

-- The justify of a column: its own value, else RIGHT for a number column, else LEFT.
function Kit.ColumnJustify(column)
    return column.justify or (column.number and "RIGHT" or "LEFT")
end

local function fillIndex(columns)
    local found
    for index, column in ipairs(columns) do
        if isFill(column) then
            if found then
                error("only one column can fill the rest", 3)
            end
            found = index
        end
    end
    return found
end

-- Compute the x offset and width of each column for a total row width.
-- Returns an array of { key, x, width, justify }. x counts from the left edge of the row.
function Kit.ColumnLayout(columns, totalWidth, options)
    options = options or {}
    local gap = options.gap or DEFAULT_GAP
    local left, right = options.left or 0, options.right or 0
    local fill = fillIndex(columns)
    local used = left + right + gap * math.max(0, #columns - 1)
    for index, column in ipairs(columns) do
        if index ~= fill then
            used = used + column.width
        end
    end
    local fillWidth = math.max(options.minFill or DEFAULT_MIN_FILL, (totalWidth or 0) - used)
    local layout, x = {}, left
    for index, column in ipairs(columns) do
        local width = index == fill and fillWidth or column.width
        layout[index] = { key = column.key, x = x, width = width, justify = Kit.ColumnJustify(column) }
        x = x + width + gap
    end
    return layout
end

-- Compute how to anchor each column so it needs no row width. A column before the fill column
-- anchors to the left edge (x, width). The fill column anchors to both edges (x, rightOffset).
-- A column after the fill column anchors to the right edge (rightOffset, width).
-- Returns an array of { key, justify, side = "LEFT" | "RIGHT" | "BOTH", x, right, width }.
function Kit.ColumnAnchors(columns, options)
    options = options or {}
    local gap = options.gap or DEFAULT_GAP
    local fill = fillIndex(columns)
    local anchors, x = {}, options.left or 0
    for index = 1, fill and fill - 1 or #columns do
        local column = columns[index]
        anchors[index] = { key = column.key, justify = Kit.ColumnJustify(column), side = "LEFT", x = x,
            width = column.width }
        x = x + column.width + gap
    end
    if not fill then
        return anchors
    end
    local right = options.right or 0
    for index = #columns, fill + 1, -1 do
        local column = columns[index]
        anchors[index] = { key = column.key, justify = Kit.ColumnJustify(column), side = "RIGHT", right = right,
            width = column.width }
        right = right + column.width + gap
    end
    anchors[fill] = { key = columns[fill].key, justify = Kit.ColumnJustify(columns[fill]), side = "BOTH", x = x,
        right = right }
    return anchors
end

local function placeText(label, parent, anchor)
    label:ClearAllPoints()
    if anchor.side == "LEFT" then
        label:SetPoint("LEFT", parent, "LEFT", anchor.x, 0)
        label:SetWidth(anchor.width)
    elseif anchor.side == "RIGHT" then
        label:SetPoint("RIGHT", parent, "RIGHT", -anchor.right, 0)
        label:SetWidth(anchor.width)
    else
        label:SetPoint("LEFT", parent, "LEFT", anchor.x, 0)
        label:SetPoint("RIGHT", parent, "RIGHT", -anchor.right, 0)
    end
    label:SetJustifyH(anchor.justify)
    if label.SetWordWrap then
        label:SetWordWrap(false)
    end
    if label.SetMaxLines then
        label:SetMaxLines(1)
    end
end

-- Create the header row: a frame (place it yourself) with one label for each column.
-- Returns { frame, labels = { [key] = fontString } }.
function Kit.CreateColumnHeader(parent, columns, options)
    options = options or {}
    local header = { frame = CreateFrame("Frame", nil, parent), labels = {} }
    for index, anchor in ipairs(Kit.ColumnAnchors(columns, options)) do
        local label = Kit.Label(header.frame, columns[index].title or "", options.role or "highlight")
        placeText(label, header.frame, anchor)
        header.labels[anchor.key] = label
    end
    return header
end

-- Create the cell labels of one row, with the same anchors as the header.
-- Returns { [key] = fontString }. A column with owned = true gets no cell.
function Kit.CreateColumnCells(row, columns, options)
    options = options or {}
    local cells = {}
    for index, anchor in ipairs(Kit.ColumnAnchors(columns, options)) do
        if not columns[index].owned then
            local label = Kit.Label(row, "", options.role or "small")
            placeText(label, row, anchor)
            cells[anchor.key] = label
        end
    end
    return cells
end

-- The text of one cell: the value of the column formatted, or an empty text for nil.
function Kit.ColumnText(column, data)
    local value
    if column.get then
        value = column.get(data)
    else
        value = data[column.key]
    end
    if column.format then
        return tostring(column.format(value, data))
    end
    if value == nil then
        return ""
    end
    return tostring(value)
end

-- Fill the cells of one row from data.
function Kit.SetColumnCells(cells, columns, data)
    for _, column in ipairs(columns) do
        local cell = cells[column.key]
        if cell then
            cell:SetText(Kit.ColumnText(column, data))
        end
    end
end
