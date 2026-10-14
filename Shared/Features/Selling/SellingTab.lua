local _, ns = ...

-- The Selling tab of the Auction House: it reads the bags, searches each item, decides the post and posts it.
-- The post calls are protected (D26): only a click handler calls them, one post for each click.
-- A host (ns.AuctionTabHost) owns the Blizzard frame and the tab button.
local SellingTab = {}
ns.SellingTab = SellingTab

local OWNER = "Flipside.SellingTab"
local DIALOG = "FLIPSIDE_CONFIRM_POST"
local SEARCH_TIMEOUT = 10
local RETRY_SECONDS = 5
local SECONDS_PER_HOUR = 3600

local NONE_ID = "none"
local BASE_GROUP = 1
local ROW_HEIGHT = 22
local TREE_INDENT = 14
local NAME_WIDTH = 190
local COUNT_WIDTH = 50
local INFO_WIDTH = 230
local TREE_TOP = -48
local BAR_HEIGHT = 34

local function money(copper)
    if ns.TooltipLines and ns.TooltipLines.FormatMoney then
        return ns.TooltipLines.FormatMoney(copper)
    end
    return GetMoneyString(math.floor((copper or 0) + 0.5))
end

-- Build the tree nodes from the entries. A group node shows only if it holds a bag item, directly or deeper.
-- Items first (bag order), then the subgroups. Items of no group go to the last node "[No group]".
-- Group node: { id = "g<ID>", kind = "group", groupID, text, children }.
-- Item node: { id = "i<key>", kind = "item", entry, text }.
function SellingTab.BuildNodes(rules, entries)
    local byGroup = {}
    for _, entry in ipairs(entries) do
        local list = byGroup[entry.groupID]
        if not list then
            list = {}
            byGroup[entry.groupID] = list
        end
        list[#list + 1] = entry
    end
    local function itemNodes(groupID)
        local nodes = {}
        for _, entry in ipairs(byGroup[groupID] or {}) do
            nodes[#nodes + 1] = { id = "i" .. entry.key, kind = "item", entry = entry, text = entry.item.name }
        end
        return nodes
    end
    local function build(groupID)
        local children = itemNodes(groupID)
        for _, childID in ipairs(rules:Children(groupID)) do
            local node = build(childID)
            if node then
                children[#children + 1] = node
            end
        end
        if #children == 0 then
            return nil
        end
        return { id = "g" .. groupID, kind = "group", groupID = groupID,
            text = "[" .. tostring(rules:Name(groupID)) .. "]", children = children }
    end
    local roots = {}
    for _, childID in ipairs(rules:Children(BASE_GROUP)) do
        local node = build(childID)
        if node then
            roots[#roots + 1] = node
        end
    end
    local loose = itemNodes(BASE_GROUP)
    if #loose > 0 then
        roots[#roots + 1] = { id = NONE_ID, kind = "group", text = "[No group]", children = loose }
    end
    return roots
end

-- Add the entries below a node, in tree order, to out.
function SellingTab.CollectEntries(node, out)
    if node.entry then
        out[#out + 1] = node.entry
    end
    for _, child in ipairs(node.children or {}) do
        SellingTab.CollectEntries(child, out)
    end
    return out
end

-- Age in hours and the number of scans of a scan record; nil if there is no record.
function SellingTab.DataStats(record, now)
    local latest = record and record.latest
    if not latest then
        return nil
    end
    local samples = 0
    for _, day in ipairs(record.days or {}) do
        samples = samples + (day.scans or 0)
    end
    if record.today and record.today.snaps then
        samples = samples + #record.today.snaps
    end
    local age
    if type(now) == "number" and type(latest.time) == "number" then
        age = math.max(0, now - latest.time) / SECONDS_PER_HOUR
    end
    return { ageHours = age, samples = samples }
end

-- Split a post decision into units. A unit is one protected post: { bag, slot, quantity }.
-- A commodity is one unit. An item gives one unit for each auction, taken from the stacks in bag order.
function SellingTab.BuildUnits(candidate, decision)
    local stacks = candidate.stacks or {}
    local units = {}
    if #stacks == 0 then
        return units
    end
    if decision.commodity then
        units[1] = { bag = stacks[1].bag, slot = stacks[1].slot, quantity = decision.quantity }
        return units
    end
    local size = math.max(1, decision.quantity)
    for _, stack in ipairs(stacks) do
        local remaining = stack.count
        while remaining >= size and #units < decision.auctions do
            units[#units + 1] = { bag = stack.bag, slot = stack.slot, quantity = size }
            remaining = remaining - size
        end
    end
    if #units == 0 then
        units[1] = { bag = stacks[1].bag, slot = stacks[1].slot, quantity = math.min(size, stacks[1].count) }
    end
    return units
end

-- The text of one entry: a main line and the reason line.
function SellingTab.Describe(entry)
    local decision = entry.decision
    if entry.status == "noop" then
        return "no operation"
    elseif entry.status == "waiting" or entry.status == "searching" then
        local candidate = entry.candidate
        local text = candidate.normalPrice and ("expected " .. money(candidate.normalPrice))
            or tostring(candidate.reason or "not searched")
        return entry.status == "searching" and (text .. " (searching)") or text
    elseif entry.status == "failed" then
        return "failed: " .. tostring(entry.note)
    elseif entry.status == "skipped" then
        return "skipped by you"
    elseif entry.status == "done" then
        return "posted"
    elseif not decision then
        return "not searched"
    elseif decision.action == "skip" then
        return "skip: " .. tostring(decision.reason)
    end
    local parts
    if decision.commodity then
        parts = string.format("post %d @ %s", decision.quantity, money(decision.price))
    else
        parts = string.format("post %d x %d @ %s", decision.auctions, decision.quantity, money(decision.price))
    end
    local text = parts .. " | " .. tostring(decision.duration) .. " h"
    if entry.next > 1 then
        text = text .. " | " .. (entry.next - 1) .. " of " .. #entry.units .. " posted"
    end
    return text
end

local function defaultItemInfo(itemID)
    local name, icon
    if C_Item and C_Item.GetItemNameByID then
        name = C_Item.GetItemNameByID(itemID)
    end
    if C_Item and C_Item.GetItemIconByID then
        icon = C_Item.GetItemIconByID(itemID)
    end
    return name or ("item " .. tostring(itemID)), icon
end

local function defaultMaxStack(itemID)
    return C_Item and C_Item.GetItemMaxStackSizeByID and C_Item.GetItemMaxStackSizeByID(itemID) or 1
end

local Tab = {}
Tab.__index = Tab

function Tab:_Say(text)
    if self.ui then
        self.ui.message:SetText(text or "")
    end
end

function Tab:_Name(entry)
    local item = entry.item
    if item.name and item.name ~= "" then
        return item.name
    end
    return (self.deps.itemInfo(item.itemID or 0))
end

-- The first entry of the selection that has a post left.
function Tab:_Current()
    for _, entry in ipairs(self.selection) do
        if entry.status == "ready" then
            return entry
        end
    end
    return nil
end

-- Count the own auctions of each bag item. Each owned row counts as one auction.
function Tab:_OwnedCounts(bagItems)
    local client = self.deps.client
    local owned = {}
    if not client.CanReadOwned() then
        return owned
    end
    local ok, rows = pcall(client.OwnedAuctions)
    if not ok or type(rows) ~= "table" then
        return owned
    end
    local byID = {}
    for _, row in ipairs(rows) do
        local itemID = type(row) == "table" and type(row.itemKey) == "table" and row.itemKey.itemID
        if itemID then
            byID[itemID] = (byID[itemID] or 0) + 1
        end
    end
    for _, item in ipairs(bagItems) do
        owned[item.key] = byID[item.itemID]
    end
    return owned
end

-- Store the decision of one entry and log a skip.
function Tab:_Decide(entry, rows)
    local deps = self.deps
    local candidate = entry.candidate
    local itemID = candidate.itemID
    local okCommodity, commodity = pcall(deps.client.ItemIsCommodity, itemID)
    local decision = deps.plan.Decide(candidate, rows, {
        isCommodity = okCommodity and commodity or nil,
        maxStack = deps.maxStack(itemID),
    })
    entry.decision = decision
    entry.units, entry.next = {}, 1
    if decision.action == "post" then
        entry.units = SellingTab.BuildUnits(candidate, decision)
        if #entry.units == 0 then
            entry.decision = { action = "skip", reason = "no bag stack found", key = candidate.key }
        end
    end
    if entry.decision.action == "post" then
        entry.status = "ready"
        local total
        for _, unit in ipairs(entry.units) do
            local ok, deposit = pcall(deps.client.Deposit, unit.bag, unit.slot, decision.duration,
                unit.quantity, decision.commodity == true)
            if ok and type(deposit) == "number" then
                total = (total or 0) + deposit
            end
        end
        entry.deposit = total
    else
        entry.status = "skip"
        deps.log:Add(candidate, entry.decision)
    end
    self:_Update()
end

-- Start the live search of one entry. Returns "started", "skipped" or "wait" with a text.
function Tab:_Start(entry)
    local client = self.deps.client
    local candidate = entry.candidate
    if candidate.reason or not candidate.itemID then
        self:_Decide(entry, {})
        return "skipped"
    end
    if not client.IsReady() then
        return "wait", "waiting for the Auction House to be ready"
    end
    local ok, text = client.LiveSearch(candidate.itemID)
    if not ok then
        return "wait", text or "the search was refused"
    end
    self.token = self.token + 1
    local token = self.token
    entry.status = "searching"
    self.pending = { entry = entry, itemID = candidate.itemID, token = token }
    self:_Say("searching " .. self:_Name(entry))
    self.deps.after(SEARCH_TIMEOUT, function()
        local pending = self.pending
        if pending and pending.token == token then
            self.pending = nil
            entry.status = "skip"
            entry.decision = { action = "skip", reason = "no response", key = candidate.key }
            self.deps.log:Add(candidate, entry.decision)
            self:_Say("no response for " .. self:_Name(entry))
            self:_Update()
            self:_Next()
        end
    end)
    return "started"
end

function Tab:_ScheduleRetry()
    if self.retrying then
        return
    end
    self.retrying = true
    self.deps.after(RETRY_SECONDS, function()
        self.retrying = false
        self:_Next()
    end)
end

-- Take the next entry of the queue, if no search runs. A refused search waits for the ready event or a retry.
function Tab:_Next()
    local queue = self.queue
    if not queue or self.pending then
        return
    end
    while true do
        local entry = queue.list[queue.pos + 1]
        if not entry then
            self.queue = nil
            self:_Say("search finished")
            self:_Update()
            return
        end
        local status, text = self:_Start(entry)
        if status == "wait" then
            self:_Say(text)
            self:_ScheduleRetry()
            return
        end
        queue.pos = queue.pos + 1
        if status == "started" then
            self:_Update()
            return
        end
    end
end

-- Read the bags again and build the tree. It starts no search and makes no protected call.
function Tab:RefreshBags()
    if self.awaiting then
        return false, "confirm or skip the open post first"
    end
    local deps = self.deps
    self.queue = nil
    local bagItems = deps.readBags()
    local candidates = deps.plan.Candidates({
        rules = deps.rules,
        formulaRun = deps.formulaRun,
        bagItems = bagItems,
        owned = self:_OwnedCounts(bagItems),
        dataStats = deps.getRecord and function(key)
            return SellingTab.DataStats(deps.getRecord(key), deps.now and deps.now() or nil)
        end or nil,
    })
    local byKey = {}
    for _, candidate in ipairs(candidates) do
        byKey[candidate.key] = candidate
    end
    self.entries, self.selection, self.selectedId, self.postedCount = {}, {}, nil, 0
    for _, item in ipairs(bagItems) do
        local candidate = byKey[item.key]
        self.entries[#self.entries + 1] = {
            item = item, key = item.key, candidate = candidate, groupID = deps.rules:GroupOf(item.key),
            status = candidate and "waiting" or "noop", next = 1, posted = 0, units = {},
        }
    end
    self.nodes = SellingTab.BuildNodes(deps.rules, self.entries)
    if self.ui then
        self.ui.tree.selected = nil
        self.ui.tree:SetNodes(self.nodes)
    end
    self:_Say(#self.entries == 0 and "no tradable item in the bags" or "pick a group or an item")
    self:_Update()
    return true
end

-- Select a tree node: the group and its subgroups, or one item. Start the live searches of the entries that
-- have no result yet. It makes no protected call.
function Tab:SelectNode(node)
    if self.awaiting then
        self:_Say("confirm or skip the open post first")
        if self.ui then
            self.ui.tree.selected = self.selectedId
            self.ui.tree:Refresh()
        end
        return false
    end
    self.selectedId = node.id
    self.selection = SellingTab.CollectEntries(node, {})
    self.postedCount = 0
    local list = {}
    for _, entry in ipairs(self.selection) do
        if entry.status == "waiting" then
            list[#list + 1] = entry
        end
    end
    if #list == 0 then
        self.queue = nil
        self:_Update()
        return true
    end
    self.queue = { list = list, pos = 0 }
    self:_Next()
    return true
end

-- Stop the queue. A search in flight still ends with its result.
function Tab:Stop()
    self.queue = nil
    self:_Say("search stopped")
    self:_Update()
end

function Tab:_OnResult(arg)
    local pending = self.pending
    if not pending then
        return
    end
    local id = type(arg) == "table" and arg.itemID or arg
    if type(id) == "number" and id ~= pending.itemID then
        return
    end
    self.pending = nil
    self:_Decide(pending.entry, self.deps.client.LiveRows(pending.itemID))
    self:_Say("")
    self:_Next()
end

function Tab:_OnReady()
    if self.queue and not self.pending then
        self:_Next()
    end
end

function Tab:_OnPosted()
    self:_Say("auction created")
end

function Tab:ToggleLog()
    self.showLog = not self.showLog
    self:_Update()
end

function Tab:SetDryRun(value)
    self.dryRun = value == true
    self:_Update()
end

-- Log one post (or one dry run post) of a unit.
function Tab:_Record(entry, quantity, kind)
    local decision = entry.decision
    self.deps.log:Add(entry.candidate, {
        action = kind, reason = decision.reason, price = decision.price, quantity = quantity, auctions = 1,
    })
end

function Tab:_Fail(entry, text)
    entry.status = "failed"
    entry.note = text
    self.awaiting = nil
    local price = entry.decision and entry.decision.price
    self.deps.log:Add(entry.candidate, { action = "failed", reason = text, price = price })
    self:_Say(self:_Name(entry) .. ": " .. text)
    self:_AfterStep()
    return false, text
end

-- Update the view. If the selection has no post left and no search runs, say so and read the bags again.
function Tab:_AfterStep()
    self:_Update()
    if self:_Current() or self.pending or self.queue then
        return
    end
    self:_Say(self.postedCount > 0 and "all posted" or "nothing left to post")
    if not self.dryRun then
        local say = self.ui and self.ui.message:GetText()
        self:RefreshBags()
        self:_Say(say)
    end
end

-- Count one finished unit (a post or a skip). After the last unit of an entry, ask for a fresh owned list.
function Tab:_Advance(entry, posted)
    entry.next = entry.next + 1
    if posted then
        entry.posted = entry.posted + 1
        self.postedCount = self.postedCount + 1
    end
    if entry.next > #entry.units then
        entry.status = entry.posted > 0 and "done" or "skipped"
        local client = self.deps.client
        if entry.posted > 0 and client.IsReady() then
            pcall(client.RefreshOwned)
        end
    end
    self:_AfterStep()
end

function Tab:_ConfirmText()
    local awaiting = self.awaiting
    return string.format("Post %d x %s at %s each?", awaiting.quantity, self:_Name(awaiting.entry),
        money(awaiting.entry.decision.price))
end

function Tab:_ShowConfirm()
    self.deps.confirm(DIALOG, self:_ConfirmText(), function()
        self:_Confirmed()
    end)
end

-- Run on the Accept click of the confirm: the second protected call of the post.
function Tab:_Confirmed()
    local awaiting = self.awaiting
    if not awaiting then
        return
    end
    local ok, err = pcall(awaiting.confirm)
    self.awaiting = nil
    if not ok then
        return self:_Fail(awaiting.entry, tostring(err))
    end
    self:_Record(awaiting.entry, awaiting.quantity, "post")
    self:_Advance(awaiting.entry, true)
end

-- Post the next unit of the first ready entry. Call it only from the click of the post button.
-- One call makes one protected post. Returns true, or false and a text.
function Tab:PostNext()
    if self.awaiting then
        self:_ShowConfirm()
        return true
    end
    local entry = self:_Current()
    if not entry then
        self:_Say("nothing to post")
        return false, "nothing to post"
    end
    local unit = entry.units[entry.next]
    local decision = entry.decision
    if self.dryRun then
        self:_Record(entry, unit.quantity, "dry run")
        self:_Say("dry run: no post was made")
        self:_Advance(entry, true)
        return true
    end
    local client = self.deps.client
    local okValid, valid = pcall(client.IsSellItemValid, unit.bag, unit.slot)
    if okValid and valid == false then
        return self:_Fail(entry, "the item cannot be posted")
    end
    local quantity = unit.quantity
    local okCount, available = pcall(client.AvailablePostCount, unit.bag, unit.slot)
    if okCount and type(available) == "number" then
        quantity = math.min(quantity, available)
    end
    if quantity < 1 then
        return self:_Fail(entry, "no item left to post")
    end
    local call, confirm
    if decision.commodity then
        call = function()
            return client.PostCommodity(unit.bag, unit.slot, decision.duration, quantity, decision.price)
        end
        confirm = function()
            return client.ConfirmPostCommodity(unit.bag, unit.slot, decision.duration, quantity, decision.price)
        end
    else
        local buyout = decision.price * quantity
        call = function()
            return client.PostItem(unit.bag, unit.slot, decision.duration, quantity, nil, buyout)
        end
        confirm = function()
            return client.ConfirmPostItem(unit.bag, unit.slot, decision.duration, quantity, nil, buyout)
        end
    end
    local ok, needsConfirmation = pcall(call)
    if not ok then
        return self:_Fail(entry, tostring(needsConfirmation))
    end
    if needsConfirmation then
        self.awaiting = { entry = entry, unit = unit, quantity = quantity, confirm = confirm }
        self:_ShowConfirm()
        self:_Update()
        return true
    end
    self:_Record(entry, quantity, "post")
    self:_Advance(entry, true)
    return true
end

-- Leave the next auction of the queue without a post. Makes no protected call.
function Tab:Skip()
    local entry = self.awaiting and self.awaiting.entry or self:_Current()
    if not entry then
        return false, "nothing to skip"
    end
    self.awaiting = nil
    self.deps.log:Add(entry.candidate, { action = "skip", reason = "skipped by user" })
    self:_Advance(entry, false)
    return true
end

local function setColor(label, grey)
    if grey then
        label:SetTextColor(0.5, 0.5, 0.5)
    else
        label:SetTextColor(1, 1, 1)
    end
end

-- Draw one tree row: a group (toggle and name) or a bag item (icon, name, count and the decision).
function Tab:_InitTreeRow(row, node, depth, isCollapsed, hasChildren)
    local Kit = ns.Kit
    local parts = row.sellParts
    if not parts then
        parts = {
            icon = row:CreateTexture(nil, "ARTWORK"),
            count = Kit.Label(row, "", "small"),
            info = Kit.Label(row, "", "small"),
        }
        parts.icon:SetSize(18, 18)
        parts.info:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        parts.info:SetWidth(INFO_WIDTH)
        parts.info:SetJustifyH("RIGHT")
        parts.count:SetPoint("RIGHT", row, "RIGHT", -(INFO_WIDTH + 8), 0)
        parts.count:SetWidth(COUNT_WIDTH)
        parts.count:SetJustifyH("RIGHT")
        row.sellParts = parts
    end
    local tree = self.ui.tree
    local indent = tree.box == nil and (depth - 1) * TREE_INDENT or 0
    row.toggle:ClearAllPoints()
    row.toggle:SetPoint("LEFT", row, "LEFT", indent, 0)
    row.toggle:SetShown(hasChildren)
    row.toggle.glyph:SetText(isCollapsed and "+" or "-")
    row.toggle:SetScript("OnClick", function()
        tree:SetCollapsed(node.id, not isCollapsed)
    end)
    row.selection:SetShown(tree.selected ~= nil and tree.selected == node.id)
    row.label:ClearAllPoints()
    row.label:SetWidth(NAME_WIDTH)
    row.label:SetJustifyH("LEFT")
    if node.kind == "group" then
        parts.icon:Hide()
        parts.count:SetText("")
        parts.info:SetText("")
        row.label:SetPoint("LEFT", row.toggle, "RIGHT", 2, 0)
        row.label:SetText(node.text)
        row.label:SetTextColor(1, 0.82, 0)
        return
    end
    local entry = node.entry
    local _, icon = self.deps.itemInfo(entry.item.itemID or 0)
    parts.icon:SetTexture(icon)
    parts.icon:ClearAllPoints()
    parts.icon:SetPoint("LEFT", row.toggle, "RIGHT", 2, 0)
    parts.icon:Show()
    row.label:SetPoint("LEFT", parts.icon, "RIGHT", 4, 0)
    row.label:SetText(self:_Name(entry))
    parts.count:SetText("x" .. tostring(entry.item.count))
    parts.info:SetText(SellingTab.Describe(entry))
    local grey = entry.status ~= "ready"
    setColor(row.label, entry.status == "noop" or entry.status == "done" or entry.status == "skipped"
        or entry.status == "failed")
    setColor(parts.count, grey)
    setColor(parts.info, grey)
    if entry == self:_Current() then
        row.label:SetTextColor(1, 0.82, 0)
    end
end
function Tab:_InitLogRow(row, data)
    local Kit = ns.Kit
    local label = row.parts
    if not label then
        label = Kit.Label(row, "", "small")
        label:SetPoint("LEFT", row, "LEFT", 4, 0)
        label:SetWidth(320)
        label:SetJustifyH("LEFT")
        row.parts = label
    end
    local name = (self.deps.itemInfo(data.itemID or 0))
    local text = name .. ": " .. tostring(data.decision)
    if data.quantity and data.quantity > 0 and data.price then
        text = text .. " " .. data.quantity .. " at " .. money(data.price)
    end
    if data.reason then
        text = text .. " (" .. data.reason .. ")"
    end
    label:SetText(text)
end

-- Count the units of the selection: total to post and done (posted or skipped). Also the deposit still to pay.
function Tab:_Progress()
    local total, done, deposit = 0, 0, nil
    for _, entry in ipairs(self.selection) do
        if entry.decision and entry.decision.action == "post" then
            local count = #entry.units
            done = done + math.min(entry.next - 1, count)
            if entry.status == "ready" or entry.status == "done" then
                total = total + count
            else
                total = total + math.min(entry.next - 1, count)
            end
            if entry.status == "ready" and entry.deposit and count > 0 then
                deposit = (deposit or 0) + entry.deposit * (count - (entry.next - 1)) / count
            end
        end
    end
    return total, done, deposit
end

-- The label of the post button from the state.
function Tab:PostLabel()
    local total, done = self:_Progress()
    local suffix = total > 0 and string.format(" (%d of %d)", math.min(done + 1, total), total) or ""
    if self.awaiting then
        return "Confirm post" .. suffix
    end
    if self:_Current() then
        return "Post" .. suffix
    end
    return "Post"
end

function Tab:_Update()
    local ui = self.ui
    if not ui then
        return
    end
    local client = self.deps.client
    ui.refresh:SetEnabled(self.awaiting == nil)
    ui.stop:SetShown(self.queue ~= nil)
    ui.logButton:SetText(self.showLog and "Items" or "Log")
    ui.tree:Refresh()
    ui.tree.frame:SetShown(not self.showLog)
    ui.logList.frame:SetShown(self.showLog == true)
    local current = self:_Current()
    ui.postNext:SetText(self:PostLabel())
    ui.postNext:SetEnabled(client.CanPost() and (self.awaiting ~= nil or current ~= nil))
    ui.skip:SetEnabled(self.awaiting ~= nil or current ~= nil)
    local _, _, deposit = self:_Progress()
    ui.deposit:SetText(deposit and ("Deposit: " .. money(deposit)) or "")
    if self.showLog then
        local entries = self.deps.log:List()
        local newestFirst = {}
        for index = #entries, 1, -1 do
            newestFirst[#newestFirst + 1] = entries[index]
        end
        ui.logList:SetData(newestFirst)
    end
end
function Tab:IsActive()
    return self.active
end

-- Hide the panel; the host or Blizzard's own code takes over.
function Tab:Deselect()
    self.active = false
    if self.content then
        self.content:Hide()
    end
end

-- Leave the panel. The host restores Blizzard's panes and tab.
function Tab:Leave(tabIndex)
    self:Deselect()
    self.api.Leave(tabIndex)
end

-- Show the panel. The host hides Blizzard's panes and marks its own tab.
function Tab:Select()
    self.api.Enter(self.active)
    self.active = true
    self.content:Show()
    if not self.loaded then
        self.loaded = true
        self:RefreshBags()
    end
    self:_Update()
end

function Tab:_BuildContent()
    local Kit = ns.Kit
    local padding = Kit.Theme.padding
    local parent, api = self.parent, self.api
    local insets = api.insets or {}
    local content = CreateFrame("Frame", nil, parent)
    content:SetPoint("TOPLEFT", parent, "TOPLEFT", insets.left or padding, -(insets.top or 0))
    content:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -(insets.right or padding), insets.bottom or 0)
    content:Hide()
    content:SetScript("OnHide", function()
        if self.active then
            self:Leave()
        end
    end)
    self.content = content

    local ui = {}
    self.ui = ui
    ui.refresh = Kit.Button(content, "Refresh bags", 100, function()
        self:RefreshBags()
    end)
    ui.refresh:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    ui.stop = Kit.Button(content, "Stop", 60, function()
        self:Stop()
    end)
    ui.stop:SetPoint("TOPLEFT", content, "TOPLEFT", 106, 0)
    ui.logButton = Kit.Button(content, "Log", 70, function()
        self:ToggleLog()
    end)
    ui.logButton:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    ui.message = Kit.Label(content, "", "small")
    ui.message:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -28)
    ui.message:SetJustifyH("LEFT")
    ui.message:SetWidth(700)

    ui.tree = Kit.CreateTree(content, { rowHeight = ROW_HEIGHT, inset = true,
        initRow = function(row, node, depth, isCollapsed, hasChildren)
            self:_InitTreeRow(row, node, depth, isCollapsed, hasChildren)
        end,
        onSelect = function(node)
            self:SelectNode(node)
        end })
    ui.tree.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, TREE_TOP)
    ui.tree.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, BAR_HEIGHT)
    ui.logList = Kit.CreateList(content, { rowHeight = 18, inset = true, initRow = function(row, data)
        self:_InitLogRow(row, data)
    end })
    ui.logList.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, TREE_TOP)
    ui.logList.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, BAR_HEIGHT)
    -- The post button posts in its own click handler: the protected call needs the click.
    ui.postNext = Kit.Button(content, "Post", 170, nil)
    ui.postNext:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    ui.postNext:SetScript("OnClick", function()
        self:PostNext()
    end)
    ui.skip = Kit.Button(content, "Skip", 70, function()
        self:Skip()
    end)
    ui.skip:SetPoint("LEFT", ui.postNext, "RIGHT", 6, 0)
    ui.deposit = Kit.Label(content, "", "small")
    ui.deposit:SetPoint("LEFT", ui.skip, "RIGHT", 10, 0)
    ui.deposit:SetWidth(170)
    ui.deposit:SetJustifyH("LEFT")
    ui.dryRun = Kit.Check(content, "Dry run (log only)", function(checked)
        self:SetDryRun(checked)
    end)
    ui.dryRun:SetPoint("LEFT", ui.deposit, "RIGHT", 6, 0)
end

-- Build the panel in the parent frame and listen for the search events.
-- api: Enter(wasActive), Leave(tabIndex) and optional insets.
function Tab:Mount(parent, api)
    self.parent, self.api = parent, api
    self:_BuildContent()
    local bus, client = self.deps.bus, self.deps.client
    local commodityEvent, itemEvent = client.LiveResultEvents()
    for _, event in ipairs({ commodityEvent, itemEvent }) do
        bus:Subscribe(event, OWNER, function(_, arg)
            self:_OnResult(arg)
        end)
        self.events[#self.events + 1] = event
    end
    local ready = client.ReadyEvent()
    if ready then
        bus:Subscribe(ready, OWNER, function()
            self:_OnReady()
        end)
        self.events[#self.events + 1] = ready
    end
    local posted = client.PostedEvent()
    if posted then
        bus:Subscribe(posted, OWNER, function()
            self:_OnPosted()
        end)
        self.events[#self.events + 1] = posted
    end
    self:_Update()
end

-- Undo a failed Mount: hide the panel and keep no half-built state.
function Tab:Unmount()
    if self.content then
        self.content:Hide()
    end
    for _, event in ipairs(self.events) do
        self.deps.bus:Unsubscribe(event, OWNER)
    end
    self.events = {}
    self.parent, self.api, self.content, self.ui, self.active = nil, nil, nil, nil, false
end

-- Create the Selling core. The host mounts it and shows it.
-- deps: bus, rules, formulaRun, readBags() (bag items with stacks); optional after(seconds, fn), client, plan, log,
-- itemInfo, maxStack(itemID), confirm(name, text, onAccept), getRecord(key), now().
function SellingTab.New(deps)
    if type(deps) ~= "table" or type(deps.bus) ~= "table" then
        error("deps.bus must be a table", 2)
    end
    local resolved = {
        bus = deps.bus,
        rules = deps.rules,
        formulaRun = deps.formulaRun,
        readBags = deps.readBags,
        getRecord = deps.getRecord,
        now = deps.now,
        after = deps.after or C_Timer.After,
        client = deps.client or ns.AuctionClient,
        plan = deps.plan or ns.SellingPlan,
        itemInfo = deps.itemInfo or defaultItemInfo,
        maxStack = deps.maxStack or defaultMaxStack,
        confirm = deps.confirm or function(...)
            return ns.Kit.Confirm(...)
        end,
    }
    resolved.log = deps.log or resolved.plan.Log
    return setmetatable({
        deps = resolved, entries = {}, selection = {}, events = {}, active = false, token = 0, dryRun = false,
        postedCount = 0,
    }, Tab)
end

ns.AuctionTabs.Register({
    id = "selling",
    label = "Selling",
    available = function(deps)
        local client = ns.AuctionClient
        return deps.rules ~= nil and deps.formulaRun ~= nil and type(deps.readBags) == "function"
            and client.CanLiveSearch() == true and client.CanPost() == true
    end,
    create = SellingTab.New,
})
