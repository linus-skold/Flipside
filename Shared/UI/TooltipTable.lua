local _, ns = ...

-- Draws a price table model (see TooltipLines) with own font strings. It has no Flipside logic.
-- On a tooltip it sits over blank tooltip lines and never writes a Blizzard frame field.

local TooltipTable = {}
ns.TooltipTable = TooltipTable

local FONTS = { header = "GameFontNormal", label = "GameFontDisable", value = "GameFontHighlight" }
local GAP = 12
local TOOLTIP_PADDING = 20

local views = setmetatable({}, { __mode = "k" })

local function newText(frame, font, justify)
    local fs = frame:CreateFontString(nil, "OVERLAY", font)
    fs:SetJustifyH(justify)
    return fs
end

-- Returns a view that draws in a child frame of parent. Rows need 1 + #model.rows places.
function TooltipTable.New(parent)
    local view = { frame = CreateFrame("Frame", nil, parent), rows = {}, width = 0 }
    view.frame:SetSize(1, 1)
    view.frame:Hide()

    local function rowAt(index)
        local row = view.rows[index]
        if not row then
            row = { label = newText(view.frame, FONTS.label, "LEFT"), cells = {} }
            view.rows[index] = row
        end
        return row
    end

    -- Sets the texts and the column widths. Returns the total width of the table.
    function view:Set(model)
        local columns, data = model.columns, model.rows
        self.count = #data + 1
        local labelWidth, widths = 0, {}
        for index = 1, self.count do
            local row = rowAt(index)
            local source = data[index - 1]
            local label = source and source.label or ""
            row.label:SetFontObject(FONTS.label)
            row.label:SetText(label)
            labelWidth = math.max(labelWidth, row.label:GetStringWidth())
            for j = 1, #columns do
                local cell = row.cells[j]
                if not cell then
                    cell = newText(self.frame, FONTS.value, "RIGHT")
                    row.cells[j] = cell
                end
                cell:SetFontObject(index == 1 and FONTS.header or FONTS.value)
                cell:SetText(index == 1 and columns[j] or source.cells[j])
                widths[j] = math.max(widths[j] or 0, cell:GetStringWidth())
            end
        end
        for index = self.count + 1, #self.rows do
            self.rows[index].label:Hide()
            for _, cell in ipairs(self.rows[index].cells) do
                cell:Hide()
            end
        end
        self.columns, self.labelWidth, self.widths = #columns, labelWidth, widths
        local total = labelWidth
        for j = 1, #columns do
            total = total + GAP + widths[j]
        end
        self.width = total
        return total
    end

    -- Anchors each row. place(index) gives a region and a vertical offset; the row starts at its left edge.
    function view:Place(place)
        for index = 1, self.count do
            local row = self.rows[index]
            local region, offset = place(index)
            row.label:ClearAllPoints()
            row.label:SetPoint("TOPLEFT", region, "TOPLEFT", 0, offset or 0)
            row.label:Show()
            local right = self.labelWidth
            for j = 1, self.columns do
                right = right + GAP + self.widths[j]
                local cell = row.cells[j]
                cell:ClearAllPoints()
                cell:SetPoint("TOPRIGHT", region, "TOPLEFT", right, offset or 0)
                cell:Show()
            end
        end
        self.frame:Show()
    end

    function view:Clear()
        self.frame:Hide()
    end

    return view
end

-- Returns the width that a tooltip needs for a table of the given width.
function TooltipTable.TooltipWidth(width)
    return width + TOOLTIP_PADDING
end

local function release(tooltip)
    local state = views[tooltip]
    if state then
        state.view:Clear()
        if state.minWidth and tooltip.SetMinimumWidth then
            tooltip:SetMinimumWidth(0, false)
        end
        state.minWidth = false
    end
end

-- Returns the state of a tooltip: { view, minWidth }. The first call creates the frame and the hooks.
function TooltipTable.For(tooltip)
    local state = views[tooltip]
    if state then
        return state
    end
    if type(tooltip.HookScript) ~= "function" then
        return nil
    end
    state = { view = TooltipTable.New(tooltip), minWidth = false }
    views[tooltip] = state
    tooltip:HookScript("OnTooltipCleared", function()
        release(tooltip)
    end)
    tooltip:HookScript("OnHide", function()
        release(tooltip)
    end)
    return state
end

-- Hides the table of a tooltip, if it has one.
function TooltipTable.Release(tooltip)
    release(tooltip)
end
