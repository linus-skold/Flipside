local _, ns = ...

-- The "Flipside" tab in Blizzard's Auction House frame: scan controls, scan status and price lookup.
local AuctionTab = {}
ns.AuctionTab = AuctionTab

local OWNER = "Flipside.AuctionTab"
local ADDON = "Blizzard_AuctionHouseUI"
local EVENT_FINISHED = "Flipside.ScanFinished"
local TAB_TEMPLATES = { "AuctionHouseFrameTabTemplate", "PanelTabButtonTemplate" }
local WIDTH = 740
local PRICE_SLOTS = 9
local MAX_CHOICES = 8

local REFUSALS = {
    running = "a scan is already running",
    ["api-missing"] = "the scan call is not available",
    ["ah-closed"] = "open the Auction House first",
    ["read-only"] = "scan data is read-only",
}

local MONEY_ROWS = {
    { "ScanMin", "scanMin" },
    { "ScanRecent", "scanRecent" },
    { "ScanMarket", "scanMarket" },
    { "ScanHistorical", "scanHistorical" },
}

local function refusalText(reason, detail)
    if reason == "cooldown" then
        return "scan on cooldown, " .. ns.ScanCooldown.FormatRemaining(detail) .. " left"
    end
    return REFUSALS[reason] or tostring(reason)
end

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
            "full scan %s: %d rows, %d items, %d keys, %d new, %d changed >30%%, cpu %d ms, wall %.1f s",
            summary.result, summary.rows, summary.items, summary.keys, summary.newItems, summary.changed,
            math.floor(summary.cpuMs + 0.5), summary.wallMs / 1000)
        if summary.result == "partial" then
            lines[#lines + 1] = "partial scan, latest values only: " .. summaryReasons(summary)
        end
    elseif summary.result == "error" then
        lines[1] = "full scan failed: " .. tostring(summary.error)
    else
        lines[1] = "full scan " .. summary.result
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
    if engine and cooldown then
        local running = engine:IsRunning()
        local left = running and 0 or cooldown:Remaining()
        ui.scan:SetEnabled(not running and left == 0)
        ui.stop:SetShown(running)
        ui.reset:SetEnabled(true)
        if running then
            ui.cooldown:SetText("Scan running")
        elseif left > 0 then
            ui.cooldown:SetText("Cooldown: " .. ns.ScanCooldown.FormatRemaining(left))
        else
            ui.cooldown:SetText("Cooldown: ready")
        end
    else
        ui.scan:SetEnabled(false)
        ui.stop:SetShown(false)
        ui.reset:SetEnabled(false)
        ui.cooldown:SetText("scan is not available this session")
    end
    ui.status:SetText(self:_StatusText())
end

function Tab:_ScanClicked()
    local engine = self.deps.scanEngine
    local ok, reason, detail = engine:CanStart()
    if not ok then
        self:_Say("full scan not started: " .. refusalText(reason, detail))
        self:Refresh()
        return
    end
    self:_Say("")
    self.deps.confirmScan(function()
        local canStart, why, more = engine:CanStart()
        if canStart then
            engine:Start()
        else
            self:_Say("full scan not started: " .. refusalText(why, more))
        end
        self:Refresh()
    end)
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

-- Show the price of one stored key.
function Tab:ShowKey(key)
    local deps = self.deps
    local record = deps.scanStore:Get(key)
    self:_HideChoices()
    if not record then
        self.ui.priceMessage:SetText("no scan data for " .. key)
        return
    end
    self.ui.priceMessage:SetText("")
    local values = deps.scanSources.Compute(record, deps.serverTime())
    self:_ShowPriceRows(AuctionTab.DescribePrice(values, key))
end

function Tab:_ShowChoices(matches)
    local ui = self.ui
    ui.priceMessage:SetText(#matches .. " items match, pick one")
    for index, button in ipairs(ui.choices) do
        local match = matches[index]
        if match then
            button:SetText(ns.ItemNameIndex.Describe(match))
            button:SetScript("OnClick", function()
                self:ShowKey(match.key)
            end)
            button:Show()
        else
            button:Hide()
        end
    end
end

-- Look up a name in the scan data. Returns true if the input was handled.
function Tab:_LookupName(text)
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
    ui.pendingMessage:SetText(count > 0 and (count .. " item names are still loading") or "")
    if #result.matches == 0 then
        ui.priceMessage:SetText('no item named "' .. text .. '" in the scan data')
    elseif #result.matches == 1 then
        self:ShowKey(result.matches[1].key)
    else
        self:_ShowChoices(result.matches)
    end
    return true
end

-- Look up an item link, item id or item name in the scan data and show its prices.
function Tab:Lookup(input)
    local deps = self.deps
    local text = tostring(input or ""):match("^%s*(.-)%s*$")
    self:_ShowPriceRows(nil)
    self:_HideChoices()
    self.ui.pendingMessage:SetText("")
    if text == "" then
        self.ui.priceMessage:SetText(deps.itemNameIndex and "enter an item name, link or id"
            or "enter an item link or item id")
        return
    end
    if not (deps.scanStore and deps.formulaLookup and deps.scanSources) then
        self.ui.priceMessage:SetText("scan is not available this session")
        return
    end
    if deps.itemNameIndex and self:_LookupName(text) then
        return
    end
    local record, key, itemID = deps.formulaLookup.Find(deps.scanStore, text)
    if not itemID then
        self.ui.priceMessage:SetText("not an item: " .. text)
    elseif not record then
        self.ui.priceMessage:SetText("no scan data for " .. itemID)
    else
        self.ui.priceMessage:SetText("")
        local values = deps.scanSources.Compute(record, deps.serverTime())
        self:_ShowPriceRows(AuctionTab.DescribePrice(values, key))
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

-- Hide the Flipside content; Blizzard's own code or the frame hide takes over.
function Tab:_Deselect()
    self.active = false
    self:_StopTicker()
    self.content:Hide()
end

-- Show or hide the panes that the current display mode lists. Blizzard's state is only read.
function Tab:_SetPanes(shown)
    local frame = self.frame
    local mode = frame:GetDisplayMode()
    if type(mode) == "table" then
        for _, name in ipairs(mode) do
            if frame[name] then
                frame[name]:SetShown(shown)
            end
        end
    end
    return mode
end

-- Leave the Flipside tab: show Blizzard's panes again and select the given Blizzard tab.
function Tab:_Restore(tabIndex)
    self:_Deselect()
    self:_SetPanes(true)
    local index = tabIndex or self.previousTab
    if index then
        PanelTemplates_SetTab(self.frame, index)
    end
end

-- Show the Flipside content in place of Blizzard's panes of the current display mode.
function Tab:_Select()
    local frame = self.frame
    if not self.active then
        self.previousTab = frame.selectedTab
    end
    self.selectedMode = self:_SetPanes(false)
    self.active = true
    self.content:Show()
    self:Refresh()
    self:_StartTicker()
    PanelTemplates_SetTab(frame, self.index)
end

local function createTabButton(frame)
    local button
    for _, template in ipairs(TAB_TEMPLATES) do
        local ok, result = pcall(CreateFrame, "Button", nil, frame, template)
        if ok then
            button = result
            break
        end
    end
    return button or CreateFrame("Button", nil, frame, "PanelTabButtonTemplate")
end

function Tab:_BuildContent()
    local Kit = ns.Kit
    local padding = Kit.Theme.padding
    local content = CreateFrame("Frame", nil, self.frame)
    content:SetPoint("TOPLEFT", self.frame, "TOPLEFT", padding, -60)
    content:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -padding, 30)
    content:Hide()
    content:SetScript("OnShow", function()
        self:Refresh()
        self:_StartTicker()
    end)
    content:SetScript("OnHide", function()
        if self.active then
            self:_Restore()
        end
        self:_StopTicker()
    end)
    self.content = content

    local ui = { slots = {} }
    self.ui = ui
    local function place(widget, x, y)
        widget:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
        return widget
    end

    place(Kit.Label(content, "Full scan", "title"), 0, 0)
    ui.scan = place(Kit.Button(content, "Full scan", 120, function()
        self:_ScanClicked()
    end), 0, -24)
    ui.stop = place(Kit.Button(content, "Stop", 70, function()
        self.deps.scanEngine:Cancel()
        self:Refresh()
    end), 128, -24)
    ui.reset = place(Kit.Button(content, "Reset cooldown", 110, function()
        self:_ResetClicked()
    end), 206, -24)
    ui.cooldown = leftAligned(place(Kit.Label(content, "", "highlight"), 330, -28))
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
            money = place(Kit.Money(content), 120, y),
            value = leftAligned(place(Kit.Label(content, "", "highlight"), 120, y), 300),
        }
        ui.slots[index] = slot
    end
    self:_ShowPriceRows(nil)
end

local function indexOf(list, item)
    for index, value in ipairs(list) do
        if value == item then
            return index
        end
    end
    return nil
end

-- Create the tab button after the Blizzard tabs. The tab template can add the button to frame.Tabs itself.
function Tab:_BuildTab(frame)
    local tabs = frame.Tabs
    local blizzardTabs = {}
    for index, existing in ipairs(tabs) do
        blizzardTabs[index] = existing
    end
    local last = blizzardTabs[#blizzardTabs]
    local button = createTabButton(frame)
    self.tab = button
    if not indexOf(tabs, button) then
        table.insert(tabs, button)
    end
    self.index = indexOf(tabs, button)
    button:SetID(self.index)
    button:SetText("Flipside")
    if last then
        button:SetPoint("TOPLEFT", last, "TOPRIGHT", 3, 0)
    end
    button:SetScript("OnClick", function()
        self:_Select()
    end)
    PanelTemplates_SetNumTabs(frame, #tabs)
    return blizzardTabs
end

function Tab:_BuildFrame(frame)
    self.frame = frame
    local blizzardTabs = self:_BuildTab(frame)
    self:_BuildContent()
    for blizzardIndex, blizzardTab in ipairs(blizzardTabs) do
        blizzardTab:HookScript("OnClick", function()
            if self.active then
                self:_Restore(blizzardIndex)
            end
        end)
    end
    hooksecurefunc(frame, "SetDisplayMode", function()
        -- Same mode again: Blizzard did nothing, so the tab click hook restores the panes.
        if self.active and frame:GetDisplayMode() ~= self.selectedMode then
            self:_Deselect()
        end
    end)
    self.deps.bus:Subscribe(EVENT_FINISHED, OWNER, function(_, summary)
        self.summaryLines = AuctionTab.DescribeSummary(summary)
        self:Refresh()
    end)
    self:Refresh()
end

-- Undo a failed build: hide the tab, remove it from the frame and keep no half-built state.
function Tab:_Abandon(frame)
    local tab = self.tab
    if tab then
        tab:Hide()
        local index = indexOf(frame.Tabs, tab)
        if index then
            table.remove(frame.Tabs, index)
            PanelTemplates_SetNumTabs(frame, #frame.Tabs)
        end
    end
    if self.content then
        self.content:Hide()
    end
    self.frame, self.tab, self.content, self.ui, self.index = nil, nil, nil, nil, nil
end

function Tab:_Build()
    local frame = AuctionHouseFrame
    if self.frame or not frame then
        return
    end
    local ok, err = pcall(self._BuildFrame, self, frame)
    if not ok then
        self:_Abandon(frame)
        ns.ReportError("the Auction House tab is not available: " .. tostring(err))
    end
end
local REQUIRED_FUNCTIONS = { "serverTime", "confirmScan", "openMainWindow" }

-- Attach the Flipside tab to the Auction House frame, now or when its addon loads.
-- deps: bus, scanEngine, scanCooldown, scanStore, formulaLookup, scanSources, itemNameIndex (optional),
-- serverTime, confirmScan, openMainWindow. Returns an object with :Refresh().
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
    if AuctionHouseFrame then
        tab:_Build()
    else
        deps.bus:Subscribe("ADDON_LOADED", OWNER, function(_, name)
            if name == ADDON then
                deps.bus:Unsubscribe("ADDON_LOADED", OWNER)
                tab:_Build()
            end
        end)
    end
    return tab
end
