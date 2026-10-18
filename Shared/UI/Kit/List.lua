local _, ns = ...
ns.Kit = ns.Kit or {}
local Kit = ns.Kit

-- Create a list. options: rowHeight, heightOf(data) (optional, gives the height of one row),
-- initRow(rowFrame, data), inset (true gives the client inset background),
-- skin (client atlas names for the inset background, the row stripes and the row hover; see Kit.Inset).
-- options.retainScroll = true keeps the scroll position when SetData runs again.
-- Use list.frame to place the list. Call list:SetData(array) to fill it.
-- list.contentInsets = { left, right } is the space between the list frame and the rows (for a header row).
-- Multi-select: options.multiSelect = true makes a click on a row toggle it, and a Shift-click add the range from
-- the last clicked row. Selected rows show the selection highlight. Extra options: keyOf(data) gives the identity
-- of a row (default: the data itself), onSelectionChange(list) runs after each change.
-- options.onDoubleClick(data, index) runs after a double-click on a row.
-- Methods: list:GetSelected() (array of data, in list order), list:IsSelected(data), list:ClearSelection(),
-- list:Click(index, shift) (the logic of a row click).
function Kit.CreateList(parent, options)
    options = options or {}
    local rowHeight = options.rowHeight or Kit.Theme.rowHeight
    local heightOf = options.heightOf
    local initRow = options.initRow or function() end
    local multi = options.multiSelect == true
    local keyOf = options.keyOf or function(data)
        return data
    end
    local list = { data = {}, selection = {} }
    local container = options.inset and Kit.Inset(parent, options.skin) or CreateFrame("Frame", nil, parent)
    local pad = options.inset and Kit.Theme.insetPadding or 0
    list.frame = container

    local function indexOfKey(key)
        for index, data in ipairs(list.data) do
            if keyOf(data) == key then
                return index
            end
        end
    end

    local function paintSelection(row)
        if row.kitSelect and row.kitData ~= nil then
            row.kitSelect:SetShown(list.selection[keyOf(row.kitData)] == true)
        end
    end

    local function prepareRow(row, alternate, data)
        Kit.SkinRow(row, options.skin, alternate)
        if options.onDoubleClick then
            row.kitData = data
            row:SetScript("OnDoubleClick", function(self)
                local index = indexOfKey(keyOf(self.kitData))
                if index then
                    options.onDoubleClick(self.kitData, index)
                end
            end)
        end
        if multi then
            if not row.kitSelect then
                row.kitSelect = Kit.SelectionTexture(row, options.skin)
                row:SetScript("OnClick", function(self)
                    local index = indexOfKey(keyOf(self.kitData))
                    if index then
                        local shift = _G.IsShiftKeyDown and _G.IsShiftKeyDown() or false
                        list:Click(index, shift)
                    end
                end)
            end
            row.kitData = data
            paintSelection(row)
        end
    end

    local function forEachRow(fn)
        if list.box then
            list.box:ForEachFrame(fn)
        else
            for _, row in ipairs(list.rows) do
                if row:IsShown() then
                    fn(row)
                end
            end
        end
    end

    local function selectionChanged()
        forEachRow(paintSelection)
        if options.onSelectionChange then
            options.onSelectionChange(list)
        end
    end

    -- Remove the selected keys that the new data no longer holds.
    local function pruneSelection()
        local present, changed = {}, false
        for _, data in ipairs(list.data) do
            present[keyOf(data)] = true
        end
        for key in pairs(list.selection) do
            if not present[key] then
                list.selection[key] = nil
                changed = true
            end
        end
        if list.anchorKey ~= nil and not present[list.anchorKey] then
            list.anchorKey = nil
        end
        return changed
    end

    local scrollApi = ScrollUtil and ScrollUtil.InitScrollBoxListWithScrollBar and CreateDataProvider
        and CreateScrollBoxListLinearView
    if scrollApi then
        local box = CreateFrame("Frame", nil, container, "WowScrollBoxList")
        local bar = CreateFrame("EventFrame", nil, container, "MinimalScrollBar")
        box:SetPoint("TOPLEFT", pad, -pad)
        box:SetPoint("BOTTOMRIGHT", -16 - pad, pad)
        bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
        bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
        local view = CreateScrollBoxListLinearView()
        view:SetElementExtent(rowHeight)
        if heightOf and view.SetElementExtentCalculator then
            view:SetElementExtentCalculator(function(_, data)
                return heightOf(data)
            end)
        end
        view:SetElementInitializer("Button", function(row, data)
            prepareRow(row, nil, data)
            initRow(row, data)
        end)
        ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
        Kit.AlternateStripes(box, options.skin)
        list.box = box
        list.contentInsets = { left = pad, right = 16 + pad }
        function list:SetData(array)
            self.data = array or {}
            local changed = pruneSelection()
            box:SetDataProvider(CreateDataProvider(self.data), options.retainScroll)
            if changed and options.onSelectionChange then
                options.onSelectionChange(self)
            end
        end
    else
        list.rows = {}
        list.contentInsets = { left = pad, right = pad }
        function list:SetData(array)
            self.data = array or {}
            local changed = pruneSelection()
            local y = pad
            for index, data in ipairs(self.data) do
                local row = self.rows[index]
                if not row then
                    row = CreateFrame("Button", nil, container)
                    self.rows[index] = row
                end
                local height = heightOf and heightOf(data) or rowHeight
                row:SetHeight(height)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", container, "TOPLEFT", pad, -y)
                row:SetPoint("TOPRIGHT", container, "TOPRIGHT", -pad, -y)
                y = y + height
                prepareRow(row, index % 2 == 1, data)
                row:Show()
                initRow(row, data)
            end
            for index = #self.data + 1, #self.rows do
                self.rows[index]:Hide()
            end
            if changed and options.onSelectionChange then
                options.onSelectionChange(self)
            end
        end
    end

    function list:GetData()
        return self.data
    end

    function list:IsSelected(data)
        return self.selection[keyOf(data)] == true
    end

    function list:GetSelected()
        local selected = {}
        for _, data in ipairs(self.data) do
            if self.selection[keyOf(data)] then
                selected[#selected + 1] = data
            end
        end
        return selected
    end

    function list:ClearSelection()
        if next(self.selection) == nil then
            return
        end
        self.selection, self.anchorKey = {}, nil
        selectionChanged()
    end

    -- A plain click toggles the row. A Shift-click adds all rows from the last clicked row to this row.
    function list:Click(index, shift)
        local data = self.data[index]
        if data == nil then
            return
        end
        local key = keyOf(data)
        local from = shift and self.anchorKey ~= nil and indexOfKey(self.anchorKey) or nil
        if from then
            for position = math.min(from, index), math.max(from, index) do
                self.selection[keyOf(self.data[position])] = true
            end
        else
            self.selection[key] = (not self.selection[key]) or nil
        end
        self.anchorKey = key
        selectionChanged()
    end
    return list
end
