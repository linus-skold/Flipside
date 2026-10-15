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
--   width    a number (fixed width), nil / "fill" for the one column that takes the rest, or { share = n }
--            for a column that takes n parts of the room that the fixed columns leave. Share columns split the
--            whole width in equal parts for equal n. A list cannot mix a fill column and share columns.
--   justify  "LEFT" (default), "RIGHT" or "CENTER"
--   number   true for money and numbers: the default justify is then "RIGHT"
--   format   optional function(value, data) that returns the cell text (default tostring)
--   owned    true if the caller draws the cell itself (the header still shows)
--   hidden   true to leave the column out: it takes no space and its label and cell are hidden.
--            Change the flag, then call Kit.LayoutColumnLabels to place the labels again.
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
--   Kit.LayoutColumnLabels(header.labels, header.frame, columns)  -- after a hidden flag changes

local DEFAULT_GAP = 6
local DEFAULT_MIN_FILL = 20

local function isFill(column)
    return column.width == nil or column.width == "fill"
end

local function isShare(column)
    return type(column.width) == "table" and column.width.share ~= nil
end

-- The justify of a column: its own value, else RIGHT for a number column, else LEFT.
function Kit.ColumnJustify(column)
    return column.justify or (column.number and "RIGHT" or "LEFT")
end

-- The columns that are not hidden, in order.
local function visibleColumns(columns)
    local list = {}
    for _, column in ipairs(columns) do
        if not column.hidden then
            list[#list + 1] = column
        end
    end
    return list
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
    columns = visibleColumns(columns)
    options = options or {}
    local gap = options.gap or DEFAULT_GAP
    local left, right = options.left or 0, options.right or 0
    local fill = fillIndex(columns)
    local used = left + right + gap * math.max(0, #columns - 1)
    local shareTotal = 0
    for index, column in ipairs(columns) do
        if isShare(column) then
            if fill then
                error("a fill column and share columns cannot mix", 2)
            end
            shareTotal = shareTotal + column.width.share
        elseif index ~= fill then
            used = used + column.width
        end
    end
    local fillWidth = math.max(options.minFill or DEFAULT_MIN_FILL, (totalWidth or 0) - used)
    local shareRoom = math.max(0, (totalWidth or 0) - used)
    local layout, x = {}, left
    for index, column in ipairs(columns) do
        local width
        if isShare(column) then
            width = shareRoom * column.width.share / shareTotal
        else
            width = index == fill and fillWidth or column.width
        end
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
    columns = visibleColumns(columns)
    options = options or {}
    local gap = options.gap or DEFAULT_GAP
    for _, column in ipairs(columns) do
        if isShare(column) then
            error("share columns need the row width: use Kit.ColumnLayout", 2)
        end
    end
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

-- Place the labels with the widths of Kit.ColumnLayout for the parent width. The parent places them again
-- when its size changes.
local function placeShared(state, parent)
    local width = parent.GetWidth and parent:GetWidth() or 0
    for _, entry in ipairs(Kit.ColumnLayout(state.columns, width, state.options)) do
        local label = state.labels[entry.key]
        if label then
            placeText(label, parent, { side = "LEFT", x = entry.x, width = entry.width, justify = entry.justify })
            label:Show()
        end
    end
end

local function layoutShared(labels, parent, columns, options)
    parent.kitColumnStates = parent.kitColumnStates or {}
    local states = parent.kitColumnStates
    local state
    for _, known in ipairs(states) do
        if known.labels == labels then
            state = known
        end
    end
    if not state then
        state = { labels = labels }
        states[#states + 1] = state
        if not parent.kitColumnHooked then
            parent.kitColumnHooked = true
            parent:HookScript("OnSizeChanged", function(self)
                for _, each in ipairs(self.kitColumnStates) do
                    placeShared(each, self)
                end
            end)
        end
    end
    state.columns, state.options = columns, options
    placeShared(state, parent)
end

-- Place the labels (a table of fontStrings by key) in the parent with the anchors of the visible columns.
-- A label of a hidden column is hidden. Call it again after a hidden flag changes.
function Kit.LayoutColumnLabels(labels, parent, columns, options)
    for _, column in ipairs(columns) do
        local label = labels[column.key]
        if label and column.hidden then
            label:Hide()
        end
    end
    for _, column in ipairs(columns) do
        if not column.hidden and isShare(column) then
            return layoutShared(labels, parent, columns, options)
        end
    end
    for _, anchor in ipairs(Kit.ColumnAnchors(columns, options)) do
        local label = labels[anchor.key]
        if label then
            placeText(label, parent, anchor)
            label:Show()
        end
    end
end

-- Create the header row: a frame (place it yourself) with one label for each column.
-- Returns { frame, labels = { [key] = fontString } }.
function Kit.CreateColumnHeader(parent, columns, options)
    options = options or {}
    local header = { frame = CreateFrame("Frame", nil, parent), labels = {} }
    for _, column in ipairs(columns) do
        header.labels[column.key] = Kit.Label(header.frame, column.title or "", options.role or "highlight")
    end
    Kit.LayoutColumnLabels(header.labels, header.frame, columns, options)
    return header
end

-- Create the cell labels of one row, with the same anchors as the header.
-- Returns { [key] = fontString }. A column with owned = true gets no cell.
function Kit.CreateColumnCells(row, columns, options)
    options = options or {}
    local cells = {}
    for _, column in ipairs(columns) do
        if not column.owned then
            cells[column.key] = Kit.Label(row, "", options.role or "small")
        end
    end
    Kit.LayoutColumnLabels(cells, row, columns, options)
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
