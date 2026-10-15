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

local function prepareRow(row, skin)
    if row.kitTree then
        return
    end
    row.kitTree = true
    Kit.SkinRow(row, skin)
    row.selection = Kit.SelectionTexture(row, skin)
    row.toggle = CreateFrame("Button", nil, row)
    row.toggle:SetSize(TOGGLE_SIZE, TOGGLE_SIZE)
    row.toggle.glyph = Kit.Label(row.toggle, "-", "highlight")
    row.toggle.glyph:SetPoint("CENTER")
    row.label = Kit.Label(row, "", "normal")
    row.label:SetPoint("LEFT", row.toggle, "RIGHT", 2, 0)
    row.dropMark = row:CreateTexture(nil, "OVERLAY")
    row.dropMark:SetTexture(Kit.Theme.rowHighlight)
    row.dropMark:SetBlendMode("ADD")
    row.dropMark:SetAllPoints(row)
    row.dropMark:Hide()
end

local function forEachRow(tree, fn)
    if tree.box then
        tree.box:ForEachFrame(fn)
    else
        for _, row in ipairs(tree.list.rows) do
            if row:IsShown() then
                fn(row)
            end
        end
    end
end

-- Return the id of the row under the cursor, or nil.
local function rowUnderCursor(tree)
    local found
    forEachRow(tree, function(row)
        if row.kitId ~= nil and row:IsMouseOver() then
            found = row.kitId
        end
    end)
    return found
end

local function markRows(tree)
    forEachRow(tree, function(row)
        row.dropMark:SetShown(row.kitId ~= nil and row.kitId == tree.dropTarget)
    end)
end

-- The small frame that follows the cursor while a row is dragged.
local function dragFrame(tree)
    if tree.ghost then
        return tree.ghost
    end
    local ok, ghost = pcall(CreateFrame, "Frame", nil, UIParent, "TooltipBackdropTemplate")
    if not ok then
        ghost = CreateFrame("Frame", nil, UIParent)
    end
    ghost:SetFrameStrata("TOOLTIP")
    ghost:SetSize(160, 22)
    ghost.label = Kit.Label(ghost, "", "highlight")
    ghost.label:SetPoint("LEFT", ghost, "LEFT", Kit.Theme.gap, 0)
    ghost:SetScript("OnUpdate", function(self)
        local x, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale + 12, y / scale - 12)
        local target = rowUnderCursor(tree)
        if target == tree.dragging then
            target = nil
        end
        if target ~= tree.dropTarget then
            tree.dropTarget = target
            markRows(tree)
        end
    end)
    ghost:Hide()
    tree.ghost = ghost
    return ghost
end

local function startDrag(tree, row, options)
    local id = row.kitId
    if id == nil or (options.canDrag and options.canDrag(id) == false) then
        return
    end
    tree.dragging = id
    tree.dropTarget = nil
    local ghost = dragFrame(tree)
    ghost.label:SetText(tree.byId[id] and tree.byId[id].text or "")
    ghost:Show()
end

local function stopDrag(tree, options)
    local dragged = tree.dragging
    if dragged == nil then
        return
    end
    local target = rowUnderCursor(tree)
    tree.dragging, tree.dropTarget = nil, nil
    tree.ghost:Hide()
    markRows(tree)
    if target == dragged then
        return
    end
    if target ~= nil or tree.frame:IsMouseOver() then
        options.onDrop(dragged, target)
    end
end

-- Show an indented label and a collapse toggle. indentRow is true when the view does not indent.
local function defaultInit(tree, row, data, depth, isCollapsed, hasChildren, indentRow)
    prepareRow(row, tree.options.skin)
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
    prepareRow(row, tree.options.skin)
    row.kitId = data.id
    row.dropMark:SetShown(tree.dropTarget ~= nil and tree.dropTarget == data.id)
    if tree.options.onRightClick then
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    end
    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            if tree.options.onRightClick then
                tree.options.onRightClick(data.id, self)
            end
            return
        end
        tree:Select(data.id)
    end)
    if tree.options.onDrop then
        row:RegisterForDrag("LeftButton")
        row:SetScript("OnDragStart", function(self)
            startDrag(tree, self, tree.options)
        end)
        row:SetScript("OnDragStop", function()
            stopDrag(tree, tree.options)
        end)
    end
    if tree.initRow then
        tree.initRow(row, data, depth, isCollapsed, hasChildren)
    else
        defaultInit(tree, row, data, depth, isCollapsed, hasChildren, indentRow)
    end
end

-- Create a tree. options: rowHeight, initRow(row, node, depth, isCollapsed, hasChildren), onSelect(node),
-- onDrop(draggedId, targetId or nil), canDrag(id), onRightClick(id, rowFrame), inset (client inset background),
-- skin (client atlas names for the inset background, the row stripes, the row hover and the selection; see Kit.Inset).
-- Drag a row with the left button. A drop on a row gives its id. A drop on the empty tree gives nil.
-- A drop on the dragged row itself, or outside the tree, calls nothing. canDrag(id) false blocks the drag.
-- A node is { id, text, children }. Use tree.frame to place the tree.
-- tree.contentInsets = { left, right } is the space between the tree frame and the rows.
function Kit.CreateTree(parent, options)
    options = options or {}
    local rowHeight = options.rowHeight or Kit.Theme.rowHeight
    local tree = {
        options = options,
        roots = {},
        byId = {},
        collapsed = {},
        initRow = options.initRow,
    }

    local scrollApi = ScrollUtil and ScrollUtil.InitScrollBoxListWithScrollBar and CreateTreeDataProvider
        and CreateScrollBoxListTreeListView
    if scrollApi then
        local container = options.inset and Kit.Inset(parent, options.skin) or CreateFrame("Frame", nil, parent)
        local pad = options.inset and Kit.Theme.insetPadding or 0
        local box = CreateFrame("Frame", nil, container, "WowScrollBoxList")
        local bar = CreateFrame("EventFrame", nil, container, "MinimalScrollBar")
        box:SetPoint("TOPLEFT", pad, -pad)
        box:SetPoint("BOTTOMRIGHT", -16 - pad, pad)
        bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
        bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
        local view = CreateScrollBoxListTreeListView(INDENT)
        view:SetElementExtent(rowHeight)
        view:SetElementInitializer("Button", function(row, treeNode)
            local data = treeNode:GetData()
            renderRow(tree, row, data, treeNode:GetDepth(), treeNode:IsCollapsed(), #treeNode:GetNodes() > 0, false)
        end)
        ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
        Kit.AlternateStripes(box, options.skin)
        tree.frame = container
        tree.box = box
        tree.contentInsets = { left = pad, right = 16 + pad }
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
            inset = options.inset,
            skin = options.skin,
            initRow = function(row, entry)
                local data = entry.data
                local hasChildren = data.children ~= nil and #data.children > 0
                renderRow(tree, row, data, entry.depth, tree.collapsed[data.id] == true, hasChildren, true)
            end,
        })
        tree.frame = tree.list.frame
        tree.contentInsets = tree.list.contentInsets
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
