local _, ns = ...
ns.Kit = ns.Kit or {}
local Kit = ns.Kit

local function prepareRow(row)
    if not row.kitReady then
        row.kitReady = true
        row:SetHighlightTexture(Kit.Theme.rowHighlight, "ADD")
    end
end

-- Create a list. options: rowHeight, initRow(rowFrame, data), inset (true gives the client inset background).
-- Use list.frame to place the list. Call list:SetData(array) to fill it.
function Kit.CreateList(parent, options)
    options = options or {}
    local rowHeight = options.rowHeight or Kit.Theme.rowHeight
    local initRow = options.initRow or function() end
    local list = { data = {} }
    local container = options.inset and Kit.Inset(parent) or CreateFrame("Frame", nil, parent)
    local pad = options.inset and Kit.Theme.insetPadding or 0
    list.frame = container

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
        view:SetElementInitializer("Button", function(row, data)
            prepareRow(row)
            initRow(row, data)
        end)
        ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
        list.box = box
        function list:SetData(array)
            self.data = array or {}
            box:SetDataProvider(CreateDataProvider(self.data))
        end
    else
        list.rows = {}
        function list:SetData(array)
            self.data = array or {}
            for index, data in ipairs(self.data) do
                local row = self.rows[index]
                if not row then
                    row = CreateFrame("Button", nil, container)
                    row:SetHeight(rowHeight)
                    row:SetPoint("TOPLEFT", container, "TOPLEFT", pad, -pad - (index - 1) * rowHeight)
                    row:SetPoint("TOPRIGHT", container, "TOPRIGHT", -pad, -pad - (index - 1) * rowHeight)
                    self.rows[index] = row
                end
                prepareRow(row)
                row:Show()
                initRow(row, data)
            end
            for index = #self.data + 1, #self.rows do
                self.rows[index]:Hide()
            end
        end
    end

    function list:GetData()
        return self.data
    end
    return list
end
