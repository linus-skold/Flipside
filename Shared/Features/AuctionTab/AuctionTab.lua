local _, ns = ...

-- The Flipside panel of the Auction House: scan controls, scan status and price lookup.
-- A flavour host file (ns.AuctionTabHost) owns the Blizzard frame, the tab button and the show and hide of the panel.
local AuctionTab = {}
ns.AuctionTab = AuctionTab

local OWNER = "Flipside.AuctionTab"
local EVENT_FINISHED = "Flipside.ScanFinished"
local EVENT_PRICE_CAPTURED = "Flipside.PriceCaptured"
local WIDTH = 740
local COMPACT_WIDTH = 760
local PRICE_SLOTS = 9
local MAX_CHOICES = 8

local MONEY_ROWS = {
    { "ScanMin", "scanMin" },
    { "ScanRecent", "scanRecent" },
    { "ScanMarket", "scanMarket" },
    { "ScanHistorical", "scanHistorical" },
}

-- Build the price rows of one item. A money row has money = true and a copper value.
function AuctionTab.DescribePrice(values, key)
    local rows = { { label = "Key", text = tostring(key) } }
    for _, pair in ipairs(MONEY_ROWS) do
        rows[#rows + 1] = { label = pair[1], money = true, copper = values[pair[2]] }
    end
    local age = values.scanAge and string.format("%.1f h", values.scanAge) or "-"
    rows[#rows + 1] = { label = "ScanQty", text = tostring(values.scanQty or "-") }
    rows[#rows + 1] = { label = "ScanAge", text = age }
    rows[#rows + 1] = { label = "ScanSamples", text = tostring(values.scanSamples) }
    if values.scanPartial then
        rows[#rows + 1] = { label = "Partial", text = "yes" }
    end
    return rows
end

local function summaryReasons(summary)
    local reasons = {}
    if summary.itemsPendingMissing > 0 then
        reasons[#reasons + 1] = summary.itemsPendingMissing .. " items without data"
    end
    if summary.itemsUnknown > 0 then
        reasons[#reasons + 1] = summary.itemsUnknown .. " items with unknown stack size"
    end
    if summary.itemsNoLink + summary.itemsLinkMismatch > 0 then
        reasons[#reasons + 1] = (summary.itemsNoLink + summary.itemsLinkMismatch) .. " items with a bad link"
    end
    if summary.noKey > 0 then
        reasons[#reasons + 1] = summary.noKey .. " rows without a key"
    end
    return table.concat(reasons, ", ")
end

-- Build the status lines of a finished scan, with the same texts as the chat report.
function AuctionTab.DescribeSummary(summary)
    local lines = {}
    if summary.result == "ok" or summary.result == "partial" then
        lines[1] = string.format(
            "%s %s: %d rows, %d items, %d keys, %d new, %d changed >30%%, cpu %d ms, wall %.1f s",
            summary.label or "full scan", summary.result, summary.rows, summary.items, summary.keys,
            summary.newItems, summary.changed,
            math.floor(summary.cpuMs + 0.5), summary.wallMs / 1000)
        if summary.result == "partial" then
            lines[#lines + 1] = "partial scan, latest values only: " .. summaryReasons(summary)
        end
    elseif summary.result == "error" then
        lines[1] = (summary.label or "full scan") .. " failed: " .. tostring(summary.error)
    else
        lines[1] = (summary.label or "full scan") .. " " .. summary.result
    end
    local c = summary.commodityStats
    if c then
        lines[#lines + 1] = string.format(
            "commodity check: client %d, stack %d, unknown %d, mismatch %d, link fallback %d",
            c.client, c.stack, c.unknown, c.mismatch, c.linkFallback or 0)
        lines[#lines + 1] = string.format(
            "items %d: keyed %d, link fallback %d, pending %d, no link %d, link mismatch %d, unknown %d",
            summary.items, summary.itemsKeyed, summary.itemsLinkFallback, summary.itemsPendingMissing,
            summary.itemsNoLink, summary.itemsLinkMismatch, summary.itemsUnknown)
    end
    return lines
end

local Tab = {}
Tab.__index = Tab

local function leftAligned(label, width)
    if width then
        label:SetWidth(width)
    end
    label:SetJustifyH("LEFT")
    return label
end

function Tab:_Say(text)
    self.ui.message:SetText(text)
end

function Tab:_StatusText()
    local deps = self.deps
    local store, cooldown = deps.scanStore, deps.scanCooldown
    if not store then
        return "scan is not available this session"
    end
    local last = cooldown and cooldown:GetLastSuccess()
    local age = "never"
    if type(last) == "number" then
        age = string.format("%.1f h ago", (deps.serverTime() - last) / 3600)
    end
    local lines = {
        string.format("Region %s, %d items stored", store:GetRegion(), store:CountItems()),
        "Last scan: " .. age,
    }
    for _, line in ipairs(self.summaryLines) do
        lines[#lines + 1] = line
    end
    return table.concat(lines, "\n")
end

-- Update the scan buttons, the cooldown text and the status lines.
function Tab:Refresh()
    local ui = self.ui
    if not ui then
        return
    end
    local engine, cooldown = self.deps.scanEngine, self.deps.scanCooldown
    self.bar:Refresh()
    ui.reset:SetEnabled(engine ~= nil and cooldown ~= nil)
    if ui.startCheck then
        local get = self.deps.startPageEnabled
        ui.startCheck:SetChecked(not get or get() ~= false)
    end
    ui.status:SetText(self:_StatusText())
end

-- The check box of the start page scan bar: save the setting and show or hide the bar.
function Tab:_StartPageToggled(checked)
    local set = self.deps.setStartPageEnabled
    if not (set and set(checked)) then
        self:_Say("settings are read-only; the start page scan bar setting was not saved")
    end
    if self.startPage then
        self.startPage:Update()
    end
    self:Refresh()
end

function Tab:_ResetClicked()
    local engine, cooldown = self.deps.scanEngine, self.deps.scanCooldown
    if engine:IsRunning() then
        self:_Say("a scan is running; stop it first")
    elseif cooldown:Reset() then
        self:_Say("scan cooldown cleared. The server can still refuse a scan for a while; "
            .. [[Flipside then reports "no response".]])
    else
        self:_Say("settings are read-only; the cooldown was not cleared")
    end
    self:Refresh()
end

function Tab:_ShowPriceRows(rows)
    for index, slot in ipairs(self.ui.slots) do
        local row = rows and rows[index]
        slot.name:SetShown(row ~= nil)
        slot.money:SetShown(row ~= nil and row.money == true)
        slot.value:SetShown(row ~= nil and not row.money)
        if row then
            slot.name:SetText(row.label)
            if row.money then
                slot.money:SetCopper(row.copper)
            else
                slot.value:SetText(row.text)
            end
        end
    end
end

function Tab:_HideChoices()
    for _, button in ipairs(self.ui.choices) do
        button:Hide()
    end
end

-- Show the notes beside the lookup box: the loading count and the refresh state.
function Tab:_ShowNote()
    local parts = {}
    for _, text in ipairs({ self.loadingNote or "", self.refreshNote or "" }) do
        if text ~= "" then
            parts[#parts + 1] = text
        end
    end
    self.ui.pendingMessage:SetText(table.concat(parts, "; "))
end

-- Ask the Auction House for a fresh price of the item. The result comes as a price captured event.
function Tab:_RequestRefresh(itemID, name)
    local request = self.deps.requestPriceRefresh
    self.pendingItemID, self.refreshNote = nil, ""
    if request and itemID then
        local ok, err = request(itemID, name)
        if ok then
            self.pendingItemID = itemID
            self.refreshNote = "refreshing the price"
        else
            self.refreshNote = err and tostring(err) or ""
        end
    end
    self:_ShowNote()
end

-- Show the price of one stored key. A refresh from the Auction House follows unless noRefresh is true.
function Tab:ShowKey(key, noRefresh, name)
    local deps = self.deps
    local record = deps.scanStore:Get(key)
    self:_HideChoices()
    self.redisplay = function()
        self:ShowKey(key, true, name)
    end
    if not record then
        self.ui.priceMessage:SetText("no scan data for " .. key)
    else
        self.ui.priceMessage:SetText("")
        local values = deps.scanSources.Compute(record, deps.serverTime())
        self:_ShowPriceRows(AuctionTab.DescribePrice(values, key))
    end
    if not noRefresh then
        local parsed = ns.ItemString.ParseKey(key)
        self:_RequestRefresh(parsed and parsed.itemID, name)
    end
end

-- A price was stored: show the rows again if it is the item that the lookup waits for.
function Tab:_OnPriceCaptured(key)
    local base = ns.ItemString.KeyToBaseKey(key)
    if self.pendingItemID and self.redisplay and base == string.format("%d", self.pendingItemID) then
        self.pendingItemID = nil
        self.redisplay()
        self.refreshNote = "price refreshed"
        self:_ShowNote()
    end
end

function Tab:_ShowChoices(matches)
    local ui = self.ui
    ui.priceMessage:SetText(#matches .. " items match, pick one")
    for index, button in ipairs(ui.choices) do
        local match = matches[index]
        if match then
            button:SetText(ns.ItemNameIndex.Describe(match))
            button:SetScript("OnClick", function()
                self:ShowKey(match.key, false, match.name)
            end)
            button:Show()
        else
            button:Hide()
        end
    end
end

-- Look up a name in the scan data. Returns true if the input was handled.
function Tab:_LookupName(text, noRefresh)
    local ui = self.ui
    local result = self.deps.itemNameIndex:Resolve(text)
    if result.kind == "item" then
        return false
    end
    if result.kind == "error" then
        ui.priceMessage:SetText(result.message)
        return true
    end
    local count = result.pendingCount
    self.loadingNote = count > 0 and (count .. " item names are still loading") or ""
    self:_ShowNote()
    if #result.matches == 0 then
        ui.priceMessage:SetText('no item named "' .. text .. '" in the scan data')
    elseif #result.matches == 1 then
        self:ShowKey(result.matches[1].key, noRefresh, result.matches[1].name)
    else
        self:_ShowChoices(result.matches)
    end
    return true
end

-- Look up an item name, item id, item link or Flipside key (for example 25320#s-44) in the scan data.
-- It shows the stored prices, then asks the Auction House for a fresh price unless noRefresh is true.
function Tab:Lookup(input, noRefresh)
    local deps = self.deps
    local text = tostring(input or ""):match("^%s*(.-)%s*$")
    self:_ShowPriceRows(nil)
    self:_HideChoices()
    self.loadingNote, self.refreshNote, self.redisplay = "", "", nil
    if not noRefresh then
        self.pendingItemID = nil
    end
    self:_ShowNote()
    if text == "" then
        self.ui.priceMessage:SetText(deps.itemNameIndex and "enter an item name, link, id or key"
            or "enter an item link or item id")
        return
    end
    if not (deps.scanStore and deps.formulaLookup and deps.scanSources) then
        self.ui.priceMessage:SetText("scan is not available this session")
        return
    end
    if text:find("#", 1, true) and ns.ItemString.ParseKey(text) then
        self:ShowKey(text, noRefresh)
        return
    end
    if deps.itemNameIndex and self:_LookupName(text, noRefresh) then
        return
    end
    local record, key, itemID = deps.formulaLookup.Find(deps.scanStore, text)
    if not itemID then
        self.ui.priceMessage:SetText("not an item: " .. text)
        return
    end
    self.redisplay = function()
        self:Lookup(text, true)
    end
    if not record then
        self.ui.priceMessage:SetText("no scan data for " .. itemID)
    else
        self.ui.priceMessage:SetText("")
        local values = deps.scanSources.Compute(record, deps.serverTime())
        self:_ShowPriceRows(AuctionTab.DescribePrice(values, key))
    end
    if not noRefresh then
        self:_RequestRefresh(itemID, text:match("|h%[(.-)%]|h"))
    end
end

function Tab:_StartTicker()
    if not self.ticker then
        self.ticker = C_Timer.NewTicker(1, function()
            self:Refresh()
        end)
    end
end

function Tab:_StopTicker()
    if self.ticker then
        self.ticker:Cancel()
        self.ticker = nil
    end
end


function Tab:IsActive()
    return self.active
end

-- Hide the Flipside content; the host or Blizzard's own code takes over.
function Tab:Deselect()
    self.active = false
    self:_StopTicker()
    if self.content then
        self.content:Hide()
    end
end

-- Leave the panel. The host restores Blizzard's panes and tab.
-- tabIndex is the Blizzard tab, or nil for the previous one.
function Tab:Leave(tabIndex)
    self:Deselect()
    self.api.Leave(tabIndex)
end

-- Show the panel. The host hides Blizzard's panes and marks its own tab.
function Tab:Select()
    self.api.Enter(self.active)
    self.active = true
    self.content:Show()
    self:Refresh()
    self:_StartTicker()
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
    content:SetScript("OnShow", function()
        self:Refresh()
        self:_StartTicker()
    end)
    content:SetScript("OnHide", function()
        if self.active then
            self:Leave()
        end
        self:_StopTicker()
    end)
    self.content = content

    local ui = { slots = {} }
    self.ui = ui
    if api.layout == "compact" then
        self:_BuildCompact(content, ui)
    else
        self:_BuildClassic(content, ui)
    end
    self:_ShowPriceRows(nil)
end

-- Build the shared scan controls and keep the old field names of the panel.
function Tab:_BuildScanBar(content, ui, opts)
    opts.say = function(text)
        self:_Say(text)
    end
    opts.onChange = function()
        self:Refresh()
    end
    local bar = ns.ScanBar.New(content, self.deps, opts)
    self.bar = bar
    ui.scan, ui.stop, ui.cooldown, ui.modeButtons = bar.scan, bar.stop, bar.status, bar.buttons
end

-- The check box that shows or hides the scan bar on the Blizzard start page. It sits at the right edge.
function Tab:_BuildStartPageCheck(content, ui, y)
    local check = ns.Kit.Check(content, "Scan bar on the start page", function(checked)
        self:_StartPageToggled(checked)
    end)
    check:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, y)
    if check.Text then
        check.Text:ClearAllPoints()
        check.Text:SetPoint("RIGHT", check, "LEFT", -2, 0)
    end
    ui.startCheck = check
end
-- The default layout: large headings, scan block, status block and price lookup in one column.
function Tab:_BuildClassic(content, ui)
    local Kit = ns.Kit
    local function place(widget, x, y)
        widget:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
        return widget
    end

    place(Kit.Label(content, "Full scan", "title"), 0, 0)
    self:_BuildScanBar(content, ui, {
        y = -24, buttonWidth = 120, step = 128, stopWidth = 70, labelDx = 202, labelDy = -4,
    })
    ui.reset = place(Kit.Button(content, "Reset cooldown", 110, function()
        self:_ResetClicked()
    end), self.bar.stopX + 78, -24)
    self:_BuildStartPageCheck(content, ui, -26)
    ui.openMain = Kit.Button(content, "Open Flipside", 110, function()
        self.deps.openMainWindow()
    end)
    ui.openMain:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    ui.message = leftAligned(place(Kit.Label(content, "", "small"), 0, -54), WIDTH)

    place(Kit.Label(content, "Status", "title"), 0, -80)
    ui.status = leftAligned(place(Kit.Label(content, "", "normal"), 0, -102), WIDTH)

    place(Kit.Label(content, "Price lookup", "title"), 0, -200)
    ui.input = place(Kit.Input(content, 260, function(text)
        self:Lookup(text)
    end), 4, -224)
    ui.lookup = place(Kit.Button(content, "Look up", 90, function()
        self:Lookup(ui.input:GetText())
    end), 276, -224)
    ui.priceMessage = leftAligned(place(Kit.Label(content, "", "small"), 0, -252), WIDTH)
    ui.pendingMessage = leftAligned(place(Kit.Label(content, "", "small"), 376, -228), 360)
    ui.choices = {}
    for index = 1, MAX_CHOICES do
        local button = place(Kit.Button(content, "", 360, nil), 0, -270 - (index - 1) * 24)
        button:Hide()
        ui.choices[index] = button
    end

    local step = Kit.Theme.rowHeight - 2
    for index = 1, PRICE_SLOTS do
        local y = -252 - (index - 1) * step
        local slot = {
            name = leftAligned(place(Kit.Label(content, "", "normal"), 0, y), 110),
            money = place(Kit.Money(content, ns.TooltipLines and ns.TooltipLines.FormatMoney), 120, y),
            value = leftAligned(place(Kit.Label(content, "", "highlight"), 120, y), 300),
        }
        ui.slots[index] = slot
    end
end

-- The compact layout for a host with a small content area: normal fonts, a slim scan bar, no large headings.
function Tab:_BuildCompact(content, ui)
    local Kit = ns.Kit
    local function place(widget, x, y)
        widget:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
        return widget
    end

    local title = Kit.Label(content, "Flipside", "normal")
    title:SetPoint("TOP", self.parent, "TOP", 0, -18)
    -- One button for each scan mode, or one Full scan button without modes.
    self:_BuildScanBar(content, ui, { buttonWidth = 90, step = 96, stopWidth = 60, labelDx = 184, labelDy = -4 })
    ui.reset = place(Kit.Button(content, "Reset cooldown", 110, function()
        self:_ResetClicked()
    end), self.bar.stopX + 66, 0)
    self:_BuildStartPageCheck(content, ui, -26)
    ui.openMain = Kit.Button(content, "Open Flipside", 110, function()
        self.deps.openMainWindow()
    end)
    ui.openMain:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    ui.message = leftAligned(place(Kit.Label(content, "", "small"), 0, -28), COMPACT_WIDTH)
    ui.status = leftAligned(place(Kit.Label(content, "", "small"), 0, -44), COMPACT_WIDTH)

    place(Kit.Label(content, "Price lookup", "normal"), 0, -116)
    ui.input = place(Kit.Input(content, 300, function(text)
        self:Lookup(text)
    end), 84, -112)
    ui.lookup = place(Kit.Button(content, "Look up", 90, function()
        self:Lookup(ui.input:GetText())
    end), 392, -112)
    ui.pendingMessage = leftAligned(place(Kit.Label(content, "", "small"), 494, -118), 270)
    ui.priceMessage = leftAligned(place(Kit.Label(content, "", "small"), 0, -140), COMPACT_WIDTH)
    ui.choices = {}
    for index = 1, MAX_CHOICES do
        local button = place(Kit.Button(content, "", 360, nil), 0, -158 - (index - 1) * 22)
        button:Hide()
        ui.choices[index] = button
    end
    local step = Kit.Theme.rowHeight - 2
    for index = 1, PRICE_SLOTS do
        local y = -140 - (index - 1) * step
        ui.slots[index] = {
            name = leftAligned(place(Kit.Label(content, "", "normal"), 0, y), 110),
            money = place(Kit.Money(content, ns.TooltipLines and ns.TooltipLines.FormatMoney), 120, y),
            value = leftAligned(place(Kit.Label(content, "", "highlight"), 120, y), 300),
        }
    end
end

-- Build the panel in the parent frame and listen for finished scans. Errors go to the host.
-- api: Enter(wasActive), Leave(tabIndex), and optional fields.
-- insets { left, right, top, bottom } set the distance to the parent.
-- The default is the Kit padding left and right, and 0 above and below.
-- layout = "compact" selects the compact panel. Without it the default layout is used.
-- startPage = { parent, page, anchor(frame), width, buttonWidth, stopWidth } places the scan bar
-- on the Blizzard start page.
function Tab:Mount(parent, api)
    self.parent, self.api = parent, api
    self:_BuildContent()
    self:_MountStartPage()
    self.deps.bus:Subscribe(EVENT_FINISHED, OWNER, function(_, summary)
        self.summaryLines = AuctionTab.DescribeSummary(summary)
        self:Refresh()
    end)
    self.deps.bus:Subscribe(EVENT_PRICE_CAPTURED, OWNER, function(_, key)
        self:_OnPriceCaptured(key)
    end)
    self:Refresh()
end

-- Add the scan bar to the Blizzard start page. The host gives the place in api.startPage.
function Tab:_MountStartPage()
    local placement = self.api.startPage
    if not (placement and self.deps.scanEngine and self.deps.scanCooldown) then
        return
    end
    local ok, result = pcall(ns.ScanBar.MountStartPage, self.deps, placement)
    if ok then
        self.startPage = result
    elseif ns.ReportError then
        ns.ReportError("the scan bar on the start page is not available: " .. tostring(result))
    end
end

-- Undo a failed Mount: hide the panel and keep no half-built state.
function Tab:Unmount()
    if self.startPage then
        self.startPage:Destroy()
        self.startPage = nil
    end
    if self.content then
        self.content:Hide()
    end
    self:_StopTicker()
    self.deps.bus:Unsubscribe(EVENT_FINISHED, OWNER)
    self.deps.bus:Unsubscribe(EVENT_PRICE_CAPTURED, OWNER)
    self.parent, self.api, self.content, self.ui, self.active = nil, nil, nil, nil, false
end

local REQUIRED_FUNCTIONS = { "serverTime", "confirmScan", "openMainWindow" }

-- Attach the Flipside panel to the Auction House through the host, which calls Tab:Mount when its frame is ready.
-- Host interface: host.Attach(tab) -> state table (optional). The host is deps.host or ns.AuctionTabHost.
-- deps: bus, scanEngine, scanModes (optional list of scan mode names), scanCooldown, scanStore, formulaLookup,
-- scanSources, itemNameIndex (optional), requestPriceRefresh(itemID, name) -> ok, text (optional),
-- serverTime, confirmScan, openMainWindow, startPageEnabled() and setStartPageEnabled(on) -> ok (optional),
-- host (optional). Returns an object with :Refresh().
function AuctionTab.Attach(deps)
    if type(deps) ~= "table" then
        error("deps must be a table", 2)
    end
    if type(deps.bus) ~= "table" then
        error("deps.bus must be a table", 2)
    end
    for _, name in ipairs(REQUIRED_FUNCTIONS) do
        if type(deps[name]) ~= "function" then
            error("deps." .. name .. " must be a function", 2)
        end
    end
    local tab = setmetatable({ deps = deps, summaryLines = {}, active = false }, Tab)
    local host = deps.host or ns.AuctionTabHost
    if type(host) == "table" and type(host.Attach) == "function" then
        tab.hostState = host.Attach(tab)
    end
    return tab
end