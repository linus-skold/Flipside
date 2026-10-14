local _, ns = ...
ns.Kit = ns.Kit or {}
local Kit = ns.Kit

local INDENT = 14
local TOGGLE_SIZE = 16

local function buildIndex(nodes, index)
    for _, node in ipairs(nodes) do
        index[node.id] = node
        if node.children then
            buildIndex(node.children, index)
        end
    end
    return index
end

local function flatten(nodes, depth, collapsed, out)
    for _, node in ipairs(nodes) do
        table.insert(out, { data = node, depth = depth })
        if node.children and not collapsed[node.id] then
            flatten(node.children, depth + 1, collapsed, out)
        end
    end
    return out
end

local function prepareRow(row)
    if row.kitTree then
        return
    end
    row.kitTree = true
    row:SetHighlightTexture(Kit.Theme.rowHighlight, "ADD")
    row.selection = row:CreateTexture(nil, "BACKGROUND")
    row.selection:SetTexture(Kit.Theme.rowHighlight)
    row.selection:SetBlendMode("ADD")
    row.selection:SetAllPoints(row)
    row.toggle = CreateFrame("Button", nil, row)
    row.toggle:SetSize(TOGGLE_SIZE, TOGGLE_SIZE)
    row.toggle.glyph = Kit.Label(row.toggle, "-", "highlight")
    row.toggle.glyph:SetPoint("CENTER")
    row.label = Kit.Label(row, "", "normal")
    row.label:SetPoint("LEFT", row.toggle, "RIGHT", 2, 0)
end

-- Show an indented label and a collapse toggle. indentRow is true when the view does not indent.
local function defaultInit(tree, row, data, depth, isCollapsed, hasChildren, indentRow)
    prepareRow(row)
    row.toggle:ClearAllPoints()
    row.toggle:SetPoint("LEFT", row, "LEFT", indentRow and (depth - 1) * INDENT or 0, 0)
    row.toggle:SetShown(hasChildren)
    row.toggle.glyph:SetText(isCollapsed and "+" or "-")
    row.toggle:SetScript("OnClick", function()
        tree:SetCollapsed(data.id, not isCollapsed)
    end)
    row.label:SetText(data.text or "")
    row.selection:SetShown(tree.selected ~= nil and tree.selected == data.id)
end

local function renderRow(tree, row, data, depth, isCollapsed, hasChildren, indentRow)
    prepareRow(row)
    row:SetScript("OnClick", function()
        tree:Select(data.id)
    end)
    if tree.initRow then
        tree.initRow(row, data, depth, isCollapsed, hasChildren)
    else
        defaultInit(tree, row, data, depth, isCollapsed, hasChildren, indentRow)
    end
end

-- Create a tree. options: rowHeight, initRow(row, node, depth, isCollapsed, hasChildren), onSelect(node).
-- A node is { id, text, children }. Use tree.frame to place the tree.
function Kit.CreateTree(parent, options)
    options = options or {}
    local rowHeight = options.rowHeight or Kit.Theme.rowHeight
    local tree = {
        roots = {},
        byId = {},
        collapsed = {},
        initRow = options.initRow,
    }

    local scrollApi = ScrollUtil and ScrollUtil.InitScrollBoxListWithScrollBar and CreateTreeDataProvider
        and CreateScrollBoxListTreeListView
    if scrollApi then
        local container = CreateFrame("Frame", nil, parent)
        local box = CreateFrame("Frame", nil, container, "WowScrollBoxList")
        local bar = CreateFrame("EventFrame", nil, container, "MinimalScrollBar")
        box:SetPoint("TOPLEFT")
        box:SetPoint("BOTTOMRIGHT", -16, 0)
        bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
        bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
        local view = CreateScrollBoxListTreeListView(INDENT)
        view:SetElementExtent(rowHeight)
        view:SetElementInitializer("Button", function(row, treeNode)
            local data = treeNode:GetData()
            renderRow(tree, row, data, treeNode:GetDepth(), treeNode:IsCollapsed(), #treeNode:GetNodes() > 0, false)
        end)
        ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
        tree.frame = container
        tree.box = box
        function tree:Render()
            local provider = CreateTreeDataProvider()
            local function add(parentNode, nodes)
                for _, data in ipairs(nodes) do
                    local treeNode = parentNode:Insert(data)
                    if data.children then
                        add(treeNode, data.children)
                    end
                    if self.collapsed[data.id] then
                        treeNode:SetCollapsed(true)
                    end
                end
            end
            add(provider, self.roots)
            box:SetDataProvider(provider, true)
        end
    else
        tree.list = Kit.CreateList(parent, {
            rowHeight = rowHeight,
            initRow = function(row, entry)
                local data = entry.data
                local hasChildren = data.children ~= nil and #data.children > 0
                renderRow(tree, row, data, entry.depth, tree.collapsed[data.id] == true, hasChildren, true)
            end,
        })
        tree.frame = tree.list.frame
        function tree:Render()
            self.list:SetData(flatten(self.roots, 1, self.collapsed, {}))
        end
    end

    -- Set the root nodes and show them.
    function tree:SetNodes(rootNodes)
        self.roots = rootNodes or {}
        self:Refresh()
    end

    -- Show the nodes again. Selection and collapse state stay by id.
    function tree:Refresh()
        self.byId = buildIndex(self.roots, {})
        if self.selected ~= nil and not self.byId[self.selected] then
            self.selected = nil
        end
        self:Render()
    end

    -- Select a node by id and call onSelect(node). An unknown id does nothing.
    function tree:Select(id)
        local node = self.byId[id]
        if not node then
            return
        end
        self.selected = id
        self:Refresh()
        if options.onSelect then
            options.onSelect(node)
        end
    end

    -- Return the selected id and node, or nil.
    function tree:GetSelected()
        return self.selected, self.byId[self.selected]
    end

    function tree:SetCollapsed(id, collapsed)
        self.collapsed[id] = collapsed and true or nil
        self:Refresh()
    end

    function tree:IsCollapsed(id)
        return self.collapsed[id] == true
    end

    return tree
end
