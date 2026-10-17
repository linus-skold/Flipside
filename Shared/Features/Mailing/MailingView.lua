local _, ns = ...

-- The mailing view (SPEC 5.5). It shows the groups that have a mailing operation as a tree, plans the mails of the
-- selected groups, asks for one confirm and starts the send run. It takes a parent frame and knows nothing about
-- its place: a host (MailHost) anchors view.frame.
local MailingView = {}
ns.MailingView = MailingView

local Kit = ns.Kit
local BASE_GROUP = 1
local ROW_HEIGHT = 34
local RESULT_ROW_HEIGHT = 16
local TREE_INDENT = 14
local TREE_TEXT_LEAD = 20
local TREE_SIDE = 6
local TREE_TOP = -30
-- Space under the tree, from the bottom edge: the result list, the progress line, the buttons and the summary.
local RESULTS_HEIGHT = 90
local TREE_BOTTOM = 166
local SCROLL_ROOM = 24
local WARNING = "|cffffd200not one of your characters|r"
local GREY = { 0.5, 0.5, 0.5 }
local GOLD = { 1, 0.82, 0 }

-- Returns true if the recipient is a known own character. Names match without regard to case; a name without a
-- realm matches the name part.
function MailingView.IsKnownCharacter(recipient, characters)
    local wanted = recipient:lower()
    local wantedName, wantedRealm = wanted:match("^([^%-]+)%-(.+)$")
    for _, character in ipairs(characters or {}) do
        local lower = character:lower()
        local name, realm = lower:match("^([^%-]+)%-(.+)$")
        if lower == wanted then
            return true
        end
        if not wantedRealm and (name or lower) == wanted then
            return true
        end
        if wantedRealm and not realm and lower == wantedName then
            return true
        end
    end
    return false
end

local function mailsText(count)
    return count .. (count == 1 and " mail" or " mails")
end

local function unitsOf(mails)
    local units = 0
    for _, mail in ipairs(mails) do
        for _, attachment in ipairs(mail.attachments) do
            units = units + attachment.count
        end
    end
    return units
end

-- The names of the recipients of a mail list, in order, with no repeat.
local function recipientsOf(mails)
    local names, seen = {}, {}
    for _, mail in ipairs(mails) do
        local id = mail.recipient:lower()
        if not seen[id] then
            seen[id] = true
            names[#names + 1] = mail.recipient
        end
    end
    return names
end

-- The confirm text, for example "Send 3 mails to Alt, Bank? The client charges the postage."
function MailingView.ConfirmText(mails)
    return string.format("Send %s to %s? The client charges the postage for each mail.", mailsText(#mails),
        table.concat(recipientsOf(mails), ", "))
end

-- The lines of the result list. result is a MailingRun result.
function MailingView.ResultLines(result, itemName, formatMoney)
    local lines = {}
    lines[#lines + 1] = string.format("Sent %s, postage %s", mailsText(result.sent), formatMoney(result.postage))
    for _, entry in ipairs(result.recipients) do
        lines[#lines + 1] = string.format("  %s: %s, %d items", entry.name, mailsText(entry.mails), entry.units)
    end
    if result.stopped then
        lines[#lines + 1] = "|cffff6060Stopped: " .. result.stopped .. "|r"
    end
    for _, skip in ipairs(result.skipped) do
        local name = skip.name or (skip.key and itemName(skip.key)) or "item"
        lines[#lines + 1] = string.format("Skipped %s x%d: %s", name, skip.count or 0, skip.reason)
    end
    return lines
end

-- The ids of the nodes of a tree, depth first.
local function collectIds(nodes, out)
    for _, node in ipairs(nodes) do
        out[node.id] = node
        collectIds(node.children, out)
    end
    return out
end

-- Draw one row of the group tree: toggle, name, and a detail line with the recipient, the mails and the items.
local function initGroupRow(view, row, node, depth, isCollapsed, hasChildren)
    local tree = view.tree
    local indent = tree.box == nil and (depth - 1) * TREE_INDENT or 0
    row.toggle:ClearAllPoints()
    row.toggle:SetPoint("LEFT", row, "LEFT", indent, 0)
    row.toggle:SetShown(hasChildren)
    row.toggle.glyph:SetText(isCollapsed and "+" or "-")
    row.toggle:SetScript("OnClick", function()
        tree:SetCollapsed(node.id, not isCollapsed)
    end)
    row.selection:SetShown(view.selected[node.id] == true)
    -- The scroll view indents a row itself, so the row width shrinks by the same depth in both views.
    local width = math.max(20, view.treeWidth - (depth - 1) * TREE_INDENT - TREE_TEXT_LEAD - SCROLL_ROOM)
    if not row.detail then
        row.detail = Kit.Label(row, "", "small")
        row.detail:SetJustifyH("LEFT")
    end
    row.label:ClearAllPoints()
    row.label:SetPoint("TOPLEFT", row, "TOPLEFT", indent + TREE_TEXT_LEAD, -4)
    row.label:SetWidth(width)
    row.label:SetJustifyH("LEFT")
    row.detail:ClearAllPoints()
    row.detail:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", indent + TREE_TEXT_LEAD, 4)
    row.detail:SetWidth(width)
    if row.label.SetWordWrap then
        row.label:SetWordWrap(false)
        row.detail:SetWordWrap(false)
    end
    row.label:SetText(node.text)
    row.detail:SetText(node.detail)
    local color = node.operated and GOLD or GREY
    row.label:SetTextColor(color[1], color[2], color[3])
end

-- deps: rules (RulesStore), client (MailClient object), newRun(callbacks) (returns a MailingRun), characters()
-- (own characters), selfName(), itemName(key), formatMoney(copper), confirm(text, onAccept), skin (optional, the
-- list skin of the Auction House tabs).
-- size (optional) is { width, height }. A host can instead anchor view.frame at two corners.
function MailingView.Create(parent, deps, size)
    local width = size and size.width or 330
    local view = { selected = {}, nodes = {}, byId = {}, deps = deps, treeWidth = width - 2 * TREE_SIDE }
    local frame = CreateFrame("Frame", nil, parent)
    if size then
        frame:SetSize(size.width, size.height)
    end
    view.frame = frame

    local title = Kit.Label(frame, "Flipside mailing", "title")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", TREE_SIDE + 2, -8)

    view.tree = Kit.CreateTree(frame, {
        rowHeight = ROW_HEIGHT,
        inset = true,
        skin = deps.skin,
        initRow = function(row, node, depth, isCollapsed, hasChildren)
            initGroupRow(view, row, node, depth, isCollapsed, hasChildren)
        end,
        onSelect = function(node)
            view.tree.selected = nil
            view:Toggle(node.id)
        end,
    })
    view.tree.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", TREE_SIDE, TREE_TOP)
    view.tree.frame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -TREE_SIDE, TREE_BOTTOM)

    view.summary = Kit.Label(frame, "", "normal")
    view.summary:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", TREE_SIDE + 4, TREE_BOTTOM - 20)

    view.send = Kit.Button(frame, "Send", 80, function()
        view:Send()
    end)
    view.send:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", TREE_SIDE, RESULTS_HEIGHT + 30)
    view.stop = Kit.Button(frame, "Stop", 80, function()
        view.run:Stop()
    end)
    view.stop:SetPoint("LEFT", view.send, "RIGHT", 8, 0)
    view.stop:Disable()

    view.progress = Kit.Label(frame, "", "small")
    view.progress:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", TREE_SIDE + 4, RESULTS_HEIGHT + 12)

    view.results = Kit.CreateList(frame, {
        rowHeight = RESULT_ROW_HEIGHT,
        inset = true,
        skin = deps.skin,
        initRow = function(row, data)
            if not row.text then
                row.text = Kit.Label(row, "", "small")
                row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            end
            row.text:SetText(data)
        end,
    })
    view.results.frame:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", TREE_SIDE, TREE_SIDE)
    view.results.frame:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", -TREE_SIDE, TREE_SIDE + RESULTS_HEIGHT)

    view.run = deps.newRun({
        onProgress = function(status)
            view:ShowProgress(status)
        end,
        onDone = function(result)
            view:ShowResult(result)
        end,
    })
    return setmetatable(view, { __index = MailingView })
end

-- The tree node of a group, with its planned mails, or nil if neither the group nor a subgroup shows.
-- A group shows if it has a mailing operation, own or inherited. A group with no operation shows (grey, no
-- click) only to hold a subgroup that shows.
function MailingView:_BuildNode(id, slots, characters)
    local deps = self.deps
    local children = {}
    for _, childID in ipairs(deps.rules:Children(id) or {}) do
        local child = self:_BuildNode(childID, slots, characters)
        if child then
            children[#children + 1] = child
        end
    end
    local opID = deps.rules:EffectiveOperation(id, "mailing")
    local operation = opID and deps.rules:GetOperation(opID)
    if not operation and #children == 0 then
        return nil
    end
    local node = { id = id, text = tostring(deps.rules:Name(id)), children = children, operated = operation ~= nil,
        detail = "no mailing operation" }
    if operation then
        local plan = ns.MailingPlan.Build({
            groups = ns.MailingPlan.GroupsFor(deps.rules, { id }), slots = slots, self = deps.selfName(),
        })
        local recipient = tostring(operation.settings.recipient or "")
        node.recipient = recipient
        node.mails, node.items = #plan.mails, unitsOf(plan.mails)
        if recipient == "" then
            node.detail = "no recipient set"
        else
            node.detail = string.format("> %s, %s, %d items", recipient, mailsText(node.mails), node.items)
            if not MailingView.IsKnownCharacter(recipient, characters) then
                node.detail = node.detail .. ", " .. WARNING
            end
        end
    end
    return node
end

-- Builds the tree of the groups that have a mailing operation and shows it. The selection stays for groups that
-- still show.
function MailingView:Refresh()
    local deps = self.deps
    self.nodes = {}
    if deps.rules then
        local slots = deps.client.ReadSlots()
        local characters = deps.characters and deps.characters() or {}
        for _, id in ipairs(deps.rules:Children(BASE_GROUP) or {}) do
            local node = self:_BuildNode(id, slots, characters)
            if node then
                self.nodes[#self.nodes + 1] = node
            end
        end
    end
    self.byId = collectIds(self.nodes, {})
    for id in pairs(self.selected) do
        if not (self.byId[id] and self.byId[id].operated) then
            self.selected[id] = nil
        end
    end
    self.tree:SetNodes(self.nodes)
    self:_ShowSummary()
end

-- Returns the planned mails of the selected groups (and their subgroups), and the skipped slots.
function MailingView:Plan()
    local ids = {}
    local function visit(nodes)
        for _, node in ipairs(nodes) do
            if self.selected[node.id] then
                ids[#ids + 1] = node.id
            end
            visit(node.children)
        end
    end
    visit(self.nodes)
    if #ids == 0 then
        return { mails = {}, skipped = {} }
    end
    return ns.MailingPlan.Build({
        groups = ns.MailingPlan.GroupsFor(self.deps.rules, ids), slots = self.deps.client.ReadSlots(),
        self = self.deps.selfName(),
    })
end

function MailingView:_ShowSummary()
    local plan = self:Plan()
    self.summaryText = string.format("%s, %d items", mailsText(#plan.mails), unitsOf(plan.mails))
    self.summary:SetText(self.summaryText)
    self.send:SetEnabled(#plan.mails > 0 and not self.run:IsRunning())
end

-- A click on a group: select it, or clear it if it is selected. Other groups stay as they are. A group with no
-- mailing operation cannot be selected.
function MailingView:Toggle(id)
    local node = self.byId[id]
    if node and node.operated then
        self.selected[id] = not self.selected[id] or nil
    end
    self.tree:Refresh()
    self:_ShowSummary()
end

-- Asks for one confirm, then starts the run.
function MailingView:Send()
    if self.run:IsRunning() then
        return
    end
    local plan = self:Plan()
    if #plan.mails == 0 then
        return
    end
    self.confirmText = MailingView.ConfirmText(plan.mails)
    self.deps.confirm(self.confirmText, function()
        self.results:SetData({})
        local ok, message = self.run:Start(plan)
        if not ok then
            self.progress:SetText(message)
        end
    end)
end

function MailingView:ShowProgress(status)
    local running = status.state ~= "idle"
    self.send:SetEnabled(not running)
    self.stop:SetEnabled(running)
    if running then
        self.progressText = string.format("Mail %d of %d (%d sent)", math.max(status.index, 1), status.total,
            status.sent)
    else
        self.progressText = ""
    end
    self.progress:SetText(self.progressText)
end

function MailingView:ShowResult(result)
    self.resultLines = MailingView.ResultLines(result, self.deps.itemName, self.deps.formatMoney)
    self.results:SetData(self.resultLines)
    self:Refresh()
end

function MailingView:Show()
    self.frame:Show()
end

function MailingView:Hide()
    self.frame:Hide()
end
