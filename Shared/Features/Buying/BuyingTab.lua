local _, ns = ...

-- The Buying tab of the Auction House: the shopping list, live searches and a dry run of the buy.
-- It makes no protected call. A host (ns.AuctionTabHost) owns the Blizzard frame and the tab button.
local BuyingTab = {}
ns.BuyingTab = BuyingTab

local OWNER = "Flipside.BuyingTab"
local SEARCH_TIMEOUT = 10
local RETRY_SECONDS = 5
local LIST_WIDTH = 380
local DRY_RUN_TEXT = "dry run — buying comes in the next update"

local function money(copper)
    return GetMoneyString(math.floor((copper or 0) + 0.5))
end

local function isOwn(row)
    return row.isOwn == true or row.ownerItem == true
end

-- Build the rows to show for one search. state is "buy", "above" or "own".
-- Rows above the maximum show only if the operation sets showAboveMax.
function BuyingTab.DescribeRows(entry, rows, showAboveMax)
    local out = {}
    for _, row in ipairs(rows or {}) do
        local state
        if isOwn(row) then
            state = "own"
        elseif entry.maxPrice and row.unitPrice <= entry.maxPrice then
            state = "buy"
        elseif showAboveMax then
            state = "above"
        end
        if state then
            out[#out + 1] = { unitPrice = row.unitPrice, quantity = row.quantity or 1, state = state }
        end
    end
    return out
end

-- Build the summary lines of one evaluation. result is from BuyingPlan.Evaluate.
function BuyingTab.DescribeSummary(entry, result, rows)
    local lines = {}
    if entry.maxPrice then
        lines[1] = "Max price: " .. money(entry.maxPrice)
    else
        lines[1] = "No max price: " .. tostring(entry.reason)
    end
    if not result then
        lines[#lines + 1] = "Not searched yet"
        return lines
    end
    lines[#lines + 1] = string.format("Buyable: %d units, total cost %s", result.quantity, money(result.cost))
    local stop = result.stop
    if not stop then
        stop = "end of results"
        for _, row in ipairs(rows or {}) do
            if not isOwn(row) and entry.maxPrice and row.unitPrice > entry.maxPrice then
                stop = "above max price"
                break
            end
        end
    end
    lines[#lines + 1] = "Stop: " .. stop
    return lines
end

-- The log decision of one evaluation: "would buy N at X", or the stop reason.
function BuyingTab.DescribeDecision(result)
    if result.first then
        local last = result.buyable[#result.buyable]
        return string.format("would buy %d at %s", result.quantity, money(last.unitPrice)),
            "cost " .. money(result.cost) .. ", max " .. money(result.maxPrice)
    end
    return result.stop
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

local Tab = {}
Tab.__index = Tab

function Tab:_Say(text)
    if self.ui then
        self.ui.message:SetText(text or "")
    end
end

function Tab:_Entry(key)
    for _, entry in ipairs(self.list) do
        if entry.key == key then
            return entry
        end
    end
    return nil
end

function Tab:_Selected()
    return self.selectedKey and self:_Entry(self.selectedKey) or nil
end

function Tab:_ItemName(entry)
    return (self.deps.itemInfo(entry.itemID or 0))
end

-- Build the shopping list again from the groups and the operations.
function Tab:RefreshList()
    local deps = self.deps
    self.list = deps.plan.ShoppingList({ rules = deps.rules, formulaRun = deps.formulaRun })
    if self.selectedKey and not self:_Entry(self.selectedKey) then
        self.selectedKey = nil
    end
    self:_Update()
end

function Tab:Select_(key)
    self.selectedKey = key
    self:_Update()
end

-- Store and log the result of reading the rows of one item.
function Tab:_Finish(entry, rows)
    local plan = self.deps.plan
    local result = plan.Evaluate(entry, rows)
    if not entry.itemID then
        result.stop = "no item id"
    end
    self.results[entry.key] = { rows = rows, result = result }
    local decision, reason = BuyingTab.DescribeDecision(result)
    self.deps.log:Add(entry, decision, reason)
    self:_Update()
end

-- Start the live search of one entry. Returns "started", "skipped" or "wait" with a text.
function Tab:_Start(entry)
    local client = self.deps.client
    if not entry.maxPrice or not entry.itemID then
        self:_Finish(entry, {})
        return "skipped"
    end
    if not client.IsReady() then
        return "wait", "waiting for the Auction House to be ready"
    end
    local ok, text = client.LiveSearch(entry.itemID)
    if not ok then
        return "wait", text or "the search was refused"
    end
    self.token = self.token + 1
    local token = self.token
    self.pending = { entry = entry, itemID = entry.itemID, token = token }
    self:_Say("searching " .. self:_ItemName(entry))
    self.deps.after(SEARCH_TIMEOUT, function()
        local pending = self.pending
        if pending and pending.token == token then
            self.pending = nil
            self.deps.log:Add(entry, "no response")
            self:_Say("no response for " .. self:_ItemName(entry))
            self:_Update()
            self:_Next()
        end
    end)
    return "started"
end

-- Search the selected item once. Returns true, or false and a text.
function Tab:Search()
    local entry = self:_Selected()
    if not entry then
        return false, "pick an item first"
    end
    if self.pending then
        return false, "a search is running"
    end
    local status, text = self:_Start(entry)
    if status == "wait" then
        self:_Say(text)
        return false, text
    end
    self:_Update()
    return true
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
            self:_Say("search all finished")
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

-- Search each item of the list, one at a time.
function Tab:SearchAll()
    if self.queue or self.pending then
        return false, "a search is running"
    end
    self.queue = { list = { unpack(self.list) }, pos = 0 }
    self:_Next()
    return true
end

-- Stop the queue. A search in flight still ends with its result.
function Tab:Stop()
    self.queue = nil
    self:_Say("search all stopped")
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
    self:_Finish(pending.entry, self.deps.client.LiveRows(pending.itemID))
    self:_Say("")
    self:_Next()
end

function Tab:_OnReady()
    if self.queue and not self.pending then
        self:_Next()
    end
end

function Tab:ToggleLog()
    self.showLog = not self.showLog
    self:_Update()
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
            price = Kit.Label(row, "", "highlight"),
            sub = Kit.Label(row, "", "small"),
        }
        parts.icon:SetSize(24, 24)
        parts.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
        parts.name:SetPoint("TOPLEFT", row, "TOPLEFT", 32, -3)
        parts.name:SetWidth(210)
        parts.name:SetJustifyH("LEFT")
        parts.price:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -3)
        parts.price:SetWidth(120)
        parts.price:SetJustifyH("RIGHT")
        parts.sub:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 32, 3)
        parts.sub:SetWidth(330)
        parts.sub:SetJustifyH("LEFT")
        row.parts = parts
    end
    local name, icon = self.deps.itemInfo(entry.itemID or 0)
    parts.icon:SetTexture(icon)
    parts.name:SetText(name)
    setColor(parts.name, false)
    if entry.maxPrice then
        parts.price:SetText(money(entry.maxPrice))
        setColor(parts.price, false)
    else
        parts.price:SetText(entry.reason or "no data")
        setColor(parts.price, true)
    end
    local sub = entry.groupPath or ""
    local done = self.results[entry.key]
    if done then
        sub = sub .. "  |  " .. tostring(BuyingTab.DescribeDecision(done.result))
    end
    parts.sub:SetText(sub)
    if entry.key == self.selectedKey then
        parts.name:SetTextColor(1, 0.82, 0)
    end
    row:SetScript("OnClick", function()
        self:Select_(entry.key)
    end)
end

local function initRowsRow(row, data)
    local Kit = ns.Kit
    local parts = row.parts
    if not parts then
        parts = {
            price = Kit.Label(row, "", "normal"),
            quantity = Kit.Label(row, "", "normal"),
            mark = Kit.Label(row, "", "small"),
        }
        parts.price:SetPoint("LEFT", row, "LEFT", 4, 0)
        parts.price:SetWidth(130)
        parts.price:SetJustifyH("LEFT")
        parts.quantity:SetPoint("LEFT", row, "LEFT", 140, 0)
        parts.quantity:SetWidth(60)
        parts.quantity:SetJustifyH("LEFT")
        parts.mark:SetPoint("LEFT", row, "LEFT", 206, 0)
        parts.mark:SetWidth(100)
        parts.mark:SetJustifyH("LEFT")
        row.parts = parts
    end
    parts.price:SetText(money(data.unitPrice))
    parts.quantity:SetText("x" .. data.quantity)
    parts.mark:SetText(data.state == "own" and "yours" or data.state == "above" and "above max" or "buy")
    setColor(parts.price, data.state == "above")
    setColor(parts.quantity, data.state == "above")
    setColor(parts.mark, data.state ~= "buy")
end

function Tab:_InitLogRow(row, data)
    local Kit = ns.Kit
    local label = row.parts
    if not label then
        label = Kit.Label(row, "", "small")
        label:SetPoint("LEFT", row, "LEFT", 4, 0)
        label:SetWidth(330)
        label:SetJustifyH("LEFT")
        row.parts = label
    end
    local text = self:_ItemName(data) .. ": " .. tostring(data.decision)
    if data.reason then
        text = text .. " (" .. data.reason .. ")"
    end
    label:SetText(text)
end

-- Update the buttons, the list and the right side from the state.
function Tab:_Update()
    local ui = self.ui
    if not ui then
        return
    end
    local client = self.deps.client
    local busy = self.pending ~= nil
    local canSearch = client.CanLiveSearch()
    local selected = self:_Selected()
    ui.search:SetEnabled(canSearch and selected ~= nil and not busy)
    ui.searchAll:SetEnabled(canSearch and #self.list > 0 and not busy and not self.queue)
    ui.stop:SetShown(self.queue ~= nil)
    ui.logButton:SetText(self.showLog and "Items" or "Log")
    ui.list:SetData(self.list)
    ui.rowsList.frame:SetShown(not self.showLog)
    ui.logList.frame:SetShown(self.showLog == true)
    ui.itemName:SetShown(not self.showLog)
    ui.summary:SetShown(not self.showLog)
    if self.showLog then
        local entries = self.deps.log:List()
        local newestFirst = {}
        for index = #entries, 1, -1 do
            newestFirst[#newestFirst + 1] = entries[index]
        end
        ui.logList:SetData(newestFirst)
        return
    end
    if not selected then
        ui.itemName:SetText("")
        ui.summary:SetText(canSearch and "Pick an item of the list." or "Live search is not available.")
        ui.rowsList:SetData({})
        return
    end
    local done = self.results[selected.key]
    ui.itemName:SetText(self:_ItemName(selected))
    local lines = BuyingTab.DescribeSummary(selected, done and done.result, done and done.rows)
    ui.summary:SetText(table.concat(lines, "\n"))
    ui.rowsList:SetData(done and BuyingTab.DescribeRows(selected, done.rows, selected.showAboveMax) or {})
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
    self:RefreshList()
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
    local function place(widget, x, y)
        widget:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
        return widget
    end
    ui.refresh = place(Kit.Button(content, "Refresh", 80, function()
        self:RefreshList()
    end), 0, 0)
    ui.search = place(Kit.Button(content, "Search", 80, function()
        self:Search()
    end), 86, 0)
    ui.searchAll = place(Kit.Button(content, "Search all", 90, function()
        self:SearchAll()
    end), 172, 0)
    ui.stop = place(Kit.Button(content, "Stop", 60, function()
        self:Stop()
    end), 268, 0)
    ui.logButton = Kit.Button(content, "Log", 70, function()
        self:ToggleLog()
    end)
    ui.logButton:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    ui.message = place(Kit.Label(content, "", "small"), 0, -28)
    ui.message:SetJustifyH("LEFT")
    ui.message:SetWidth(700)

    ui.list = Kit.CreateList(content, { rowHeight = 32, inset = true, initRow = function(row, entry)
        self:_InitListRow(row, entry)
    end })
    ui.list.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -48)
    ui.list.frame:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    ui.list.frame:SetWidth(LIST_WIDTH)

    local rightX = LIST_WIDTH + padding
    ui.itemName = place(Kit.Label(content, "", "normal"), rightX, -52)
    ui.itemName:SetJustifyH("LEFT")
    ui.summary = place(Kit.Label(content, "", "small"), rightX, -72)
    ui.summary:SetJustifyH("LEFT")
    ui.summary:SetWidth(330)
    ui.rowsList = Kit.CreateList(content, { rowHeight = 18, inset = true, initRow = function(row, data)
        initRowsRow(row, data)
    end })
    ui.rowsList.frame:SetPoint("TOPLEFT", content, "TOPLEFT", rightX, -128)
    ui.rowsList.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 30)
    ui.logList = Kit.CreateList(content, { rowHeight = 18, inset = true, initRow = function(row, data)
        self:_InitLogRow(row, data)
    end })
    ui.logList.frame:SetPoint("TOPLEFT", content, "TOPLEFT", rightX, -48)
    ui.logList.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 30)

    ui.buyNext = Kit.Button(content, "Buy next", 90, nil)
    ui.buyNext:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", rightX, 0)
    ui.buyNext:SetEnabled(false)
    ui.dryRun = Kit.Label(content, DRY_RUN_TEXT, "small")
    ui.dryRun:SetPoint("LEFT", ui.buyNext, "RIGHT", 8, 0)
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

-- Create the Buying core. The host mounts it and shows it.
-- deps: bus, rules, formulaRun, after(seconds, fn); optional client, plan, log, itemInfo.
function BuyingTab.New(deps)
    if type(deps) ~= "table" or type(deps.bus) ~= "table" then
        error("deps.bus must be a table", 2)
    end
    local resolved = {
        bus = deps.bus,
        rules = deps.rules,
        formulaRun = deps.formulaRun,
        after = deps.after or C_Timer.After,
        client = deps.client or ns.AuctionClient,
        plan = deps.plan or ns.BuyingPlan,
        itemInfo = deps.itemInfo or defaultItemInfo,
    }
    resolved.log = deps.log or resolved.plan.Log
    return setmetatable({
        deps = resolved, list = {}, results = {}, events = {}, active = false, token = 0,
    }, Tab)
end

ns.AuctionTabs.Register({
    id = "buying",
    label = "Buying",
    available = function(deps)
        return deps.rules ~= nil and deps.formulaRun ~= nil and ns.AuctionClient.CanLiveSearch() == true
    end,
    create = BuyingTab.New,
})
