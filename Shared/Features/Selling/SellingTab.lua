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

local function money(copper)
    return GetMoneyString(math.floor((copper or 0) + 0.5))
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
    if entry.status == "waiting" then
        return "not searched"
    elseif entry.status == "searching" then
        return "searching"
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
        parts = string.format("post %d at %s each", decision.quantity, money(decision.price))
    else
        parts = string.format("post %d x %d at %s each", decision.auctions, decision.quantity, money(decision.price))
    end
    local text = parts .. " | deposit " .. (entry.deposit and money(entry.deposit) or "?")
        .. " | " .. tostring(decision.duration) .. " h"
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
    local candidate = entry.candidate
    if candidate.name and candidate.name ~= "" then
        return candidate.name
    end
    return (self.deps.itemInfo(candidate.itemID or 0))
end

-- The first entry that has a post left.
function Tab:_Current()
    for _, entry in ipairs(self.entries) do
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
            self:_Say("scan finished")
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

-- Read the bags, build the candidates and search each one at a time. Makes no protected call.
function Tab:ScanBags()
    if self.queue or self.pending then
        return false, "a scan is running"
    end
    if self.awaiting then
        return false, "confirm or skip the open post first"
    end
    local deps = self.deps
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
    self.entries = {}
    for _, candidate in ipairs(candidates) do
        self.entries[#self.entries + 1] = { candidate = candidate, status = "waiting", next = 1, units = {} }
    end
    if #self.entries == 0 then
        self:_Say("no bag item is in a group with a selling operation")
        self:_Update()
        return true
    end
    self.queue = { list = { unpack(self.entries) }, pos = 0 }
    self:_Next()
    return true
end

-- Stop the queue. A search in flight still ends with its result.
function Tab:Stop()
    self.queue = nil
    self:_Say("scan stopped")
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
    self:_Update()
    return false, text
end

-- Count one finished post. After the last post of an entry, ask for a fresh owned list.
function Tab:_Advance(entry)
    entry.next = entry.next + 1
    if entry.next > #entry.units then
        entry.status = "done"
        local client = self.deps.client
        if client.IsReady() then
            pcall(client.RefreshOwned)
        end
    end
    self:_Update()
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
    self:_Advance(awaiting.entry)
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
        self:_Advance(entry)
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
    self:_Advance(entry)
    return true
end

-- Leave the current entry without a post. Makes no protected call.
function Tab:Skip()
    local entry = self.awaiting and self.awaiting.entry or self:_Current()
    if not entry then
        return false, "nothing to skip"
    end
    self.awaiting = nil
    entry.status = "skipped"
    self.deps.log:Add(entry.candidate, { action = "skip", reason = "skipped by user" })
    self:_Update()
    return true
end

local function setColor(label, grey)
    if grey then
        label:SetTextColor(0.5, 0.5, 0.5)
    else
        label:SetTextColor(1, 1, 1)
    end
end

function Tab:_InitListRow(row, entry)
    local Kit = ns.Kit
    local parts = row.parts
    if not parts then
        parts = {
            icon = row:CreateTexture(nil, "ARTWORK"),
            name = Kit.Label(row, "", "normal"),
            sub = Kit.Label(row, "", "small"),
        }
        parts.icon:SetSize(24, 24)
        parts.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
        parts.name:SetPoint("TOPLEFT", row, "TOPLEFT", 32, -3)
        parts.name:SetWidth(360)
        parts.name:SetJustifyH("LEFT")
        parts.sub:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 32, 3)
        parts.sub:SetWidth(380)
        parts.sub:SetJustifyH("LEFT")
        row.parts = parts
    end
    local _, icon = self.deps.itemInfo(entry.candidate.itemID or 0)
    parts.icon:SetTexture(icon)
    parts.name:SetText(self:_Name(entry))
    parts.sub:SetText(SellingTab.Describe(entry))
    local grey = entry.status == "skip" or entry.status == "skipped" or entry.status == "failed"
        or entry.status == "done"
    setColor(parts.name, grey)
    setColor(parts.sub, grey)
    if entry == self:_Current() then
        parts.name:SetTextColor(1, 0.82, 0)
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

-- The label of the post button from the state.
function Tab:PostLabel()
    if self.awaiting then
        return "Confirm post"
    end
    local entry = self:_Current()
    if entry and #entry.units > 1 and entry.next > 1 then
        return string.format("Post next stack (%d of %d)", entry.next, #entry.units)
    end
    return "Post next"
end

function Tab:_Update()
    local ui = self.ui
    if not ui then
        return
    end
    local client = self.deps.client
    local busy = self.pending ~= nil
    ui.scan:SetEnabled(client.CanLiveSearch() and not busy and not self.queue)
    ui.stop:SetShown(self.queue ~= nil)
    ui.logButton:SetText(self.showLog and "Items" or "Log")
    ui.list:SetData(self.entries)
    ui.list.frame:SetShown(not self.showLog)
    ui.logList.frame:SetShown(self.showLog == true)
    local current = self:_Current()
    ui.postNext:SetText(self:PostLabel())
    ui.postNext:SetEnabled(client.CanPost() and (self.awaiting ~= nil or current ~= nil))
    ui.skip:SetEnabled(self.awaiting ~= nil or current ~= nil)
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
    ui.scan = Kit.Button(content, "Scan bags", 90, function()
        self:ScanBags()
    end)
    ui.scan:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    ui.stop = Kit.Button(content, "Stop", 60, function()
        self:Stop()
    end)
    ui.stop:SetPoint("TOPLEFT", content, "TOPLEFT", 96, 0)
    ui.logButton = Kit.Button(content, "Log", 70, function()
        self:ToggleLog()
    end)
    ui.logButton:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    ui.message = Kit.Label(content, "", "small")
    ui.message:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -28)
    ui.message:SetJustifyH("LEFT")
    ui.message:SetWidth(700)

    ui.list = Kit.CreateList(content, { rowHeight = 32, inset = true, initRow = function(row, entry)
        self:_InitListRow(row, entry)
    end })
    ui.list.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -48)
    ui.list.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 30)
    ui.logList = Kit.CreateList(content, { rowHeight = 18, inset = true, initRow = function(row, data)
        self:_InitLogRow(row, data)
    end })
    ui.logList.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -48)
    ui.logList.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 30)

    -- The post button posts in its own click handler: the protected call needs the click.
    ui.postNext = Kit.Button(content, "Post next", 170, nil)
    ui.postNext:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    ui.postNext:SetScript("OnClick", function()
        self:PostNext()
    end)
    ui.skip = Kit.Button(content, "Skip", 70, function()
        self:Skip()
    end)
    ui.skip:SetPoint("LEFT", ui.postNext, "RIGHT", 6, 0)
    ui.dryRun = Kit.Check(content, "Dry run (log only)", function(checked)
        self:SetDryRun(checked)
    end)
    ui.dryRun:SetPoint("LEFT", ui.skip, "RIGHT", 10, 0)
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
        deps = resolved, entries = {}, events = {}, active = false, token = 0, dryRun = false,
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
