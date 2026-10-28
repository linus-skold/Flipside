local _, ns = ...

-- The Buying tab of the Auction House: the shopping list, live searches and the buy of price levels.
-- Each protected call runs directly in a click handler of the tab or of its own dialogs (D26).
-- A host (ns.AuctionTabHost) owns the Blizzard frame and the tab button.
local BuyingTab = {}
ns.BuyingTab = BuyingTab

local OWNER = "Flipside.BuyingTab"

-- Write one line to the diagnostics log; the Log module can be missing in a spec.
local function log(level, fmt, ...)
    if ns.Log then
        ns.Log.Writef("buying", level, fmt, ...)
    end
end
local SEARCH_TIMEOUT = 10
local RETRY_SECONDS = 5
local LIST_WIDTH = 380
local QUOTE_WAIT = 10
local CONFIRM_WAIT = 15
local DEFAULT_JUMP = 25
local MESSAGE_ROOM = 12 -- height that the left column gains when the message line is empty
local SEARCH_SHIFT = 28 -- height of the name search row above the source tabs
local JUMP_KEY = "buying.jumpPercent"
local VENDOR_KEY = "buying.vendorFormula"
local VENDOR_SETTLE = 5 -- most seconds that the Vendor list waits for item data before it builds again
local VENDOR_BATCH = 100 -- most item data requests of the Vendor list that are open at one time
local VENDOR_SCAN_CAP = 500 -- most queue items that one step asks for
local RED = { 1, 0.2, 0.2 }
-- The text for the amount box when the input is not a positive whole number.
-- The units that a buy takes at first: one.
local DEFAULT_AMOUNT = 1

local AMOUNT_TEXT = "amount must be a whole number above 0"
local OWN_TEXT = "You" -- the seller text of your own auctions
local READ_RETRY = 0.5 -- seconds between checks while a page read waits for the client throttle
local MAX_CHAIN_READS = 8 -- most page reads that one Buy next step makes to find the next stack
local OWNER_WAIT = 0.3 -- seconds that a page waits for the seller names of its rows (TBC), at most OWNER_WAITS times
local OWNER_WAITS = 3

local function money(copper)
    return GetMoneyString(math.floor((copper or 0) + 0.5))
end

local function isOwn(row)
    return row.isOwn == true or row.ownerItem == true
end

-- True if the price is inside the limit of the entry. An entry with no max price has no limit.
local function withinMax(entry, price)
    if entry.noMax then
        return true
    end
    return entry.maxPrice ~= nil and price <= entry.maxPrice
end

-- True if the client has a commodity market (the flavour flag). A flavour with no flag has none.
local function hasCommodityMarket()
    return ns.Flavour ~= nil and ns.Flavour.hasCommodityMarket == true
end

-- The key of a level: the group key of a stack group, else the unit price.
local function levelId(level)
    return level.id or level.unitPrice
end

local function buyoutOf(row)
    return row.buyout or math.floor(row.unitPrice * (row.quantity or 1) + 0.5)
end

-- True if two auctions are the same stack for sale: same item, seller, buyout and stack size.
local function sameAuction(a, b)
    return ns.BuyingPlan.GroupKey(a) == ns.BuyingPlan.GroupKey(b)
end

-- The first auction of a stack group that is not yours, or nil.
local function firstFree(level)
    for _, row in ipairs(level.rows) do
        if not isOwn(row) then
            return row
        end
    end
    return nil
end

-- The time left codes 1 to 4 of the legacy client list rows.
local TIME_LEFT = { "Short", "Medium", "Long", "Very long" }

-- The stack size of a price level, or nil if the level has no stack. With a commodity market, a commodity
-- level has no stack. Other levels use the quantity of the row that Buy next buys (the first row not yours).
function BuyingTab.StackSize(level)
    local first = level.rows and level.rows[1]
    if hasCommodityMarket() and (not first or first.isCommodity ~= false) then
        return nil
    end
    if not first then
        return 1
    end
    for _, row in ipairs(level.rows) do
        if not isOwn(row) then
            return row.quantity or 1
        end
    end
    return first.quantity or 1
end

-- The stack price of a price level (unit price times stack size), or nil if the level has no stack.
function BuyingTab.StackPrice(level)
    local size = BuyingTab.StackSize(level)
    return size and level.unitPrice * size or nil
end

-- Build the price level rows to show. state is "buy", "above" or "own".
-- Levels above the maximum show only if the operation sets showAboveMax.
function BuyingTab.DescribeLevels(entry, levels, showAboveMax)
    local out = {}
    for _, level in ipairs(levels or {}) do
        local state
        if level.own then
            state = "own"
        elseif withinMax(entry, level.unitPrice) then
            state = "buy"
        elseif showAboveMax then
            state = "above"
        end
        if state then
            out[#out + 1] = {
                unitPrice = level.unitPrice, quantity = level.quantity, listings = level.listings, state = state,
                stackPrice = BuyingTab.StackPrice(level), id = level.id, stacks = level.stacks,
                stackSize = level.stackSize, owner = level.own and OWN_TEXT or level.owner,
                timeLeft = level.timeLeft,
            }
        end
    end
    return out
end
-- The totals of the price levels that you can buy: the units and the cost of all levels in the state "buy".
-- Own levels and levels above the max price are not in the totals. described is from DescribeLevels.
function BuyingTab.DescribeTotals(described)
    local totals = { quantity = 0, cost = 0 }
    for _, level in ipairs(described or {}) do
        if level.state == "buy" then
            totals.quantity = totals.quantity + level.quantity
            totals.cost = totals.cost + level.quantity * level.unitPrice
        end
    end
    return totals
end
-- The log decision of one evaluation: "would buy N at X", or the stop reason.
function BuyingTab.DescribeDecision(result)
    if result.first then
        local last = result.buyable[#result.buyable]
        local limit = result.maxPrice and (", max " .. money(result.maxPrice)) or ", no max price"
        return string.format("would buy %d at %s", result.quantity, money(last.unitPrice)),
            "cost " .. money(result.cost) .. limit
    end
    return result.stop
end

local function itemOf(itemID, key, name)
    return { itemID = itemID, key = key, name = name }
end

local function itemFromMatch(match)
    return itemOf(match.itemID, match.key, match.name)
end

local function resolveMatches(matches, text, callback)
    if #matches == 0 then
        callback({ kind = "error", message = 'no item named "' .. text .. '"' })
    elseif #matches == 1 then
        callback({ kind = "item", item = itemFromMatch(matches[1]) })
    else
        local choices = {}
        for index, match in ipairs(matches) do
            choices[index] = itemFromMatch(match)
        end
        callback({ kind = "choices", choices = choices })
    end
end

-- Read the text of the item box: an item ID, an item link, a Flipside key or an item name.
-- callback(result) runs once, at once or after an Auction House name search. result is
-- { kind = "item", item }, { kind = "choices", choices } or { kind = "error", message }.
-- deps: itemNameIndex, ahNameSearch, keyFor(link), isAuctionHouseOpen() (all optional).
function BuyingTab.ParseInput(input, deps, callback)
    local text = tostring(input or ""):match("^%s*(.-)%s*$")
    local ItemString = ns.ItemString
    if text == "" then
        callback({ kind = "error", message = "enter an item name, ID, link or key" })
        return
    end
    if text:match("^%d+$") then
        local itemID = tonumber(text)
        if itemID < 1 then
            callback({ kind = "error", message = "not an item: " .. text })
            return
        end
        callback({ kind = "item", item = itemOf(itemID, string.format("%d", itemID)) })
        return
    end
    local parsed = ItemString.ParseKey(text)
    if parsed then
        callback({ kind = "item", item = itemOf(parsed.itemID, text) })
        return
    end
    if ItemString.IsItemLink(text) then
        local fields = ItemString.ParseLink(text)
        local key = deps.keyFor and deps.keyFor(text) or ItemString.ToExactKey(text)
        callback({ kind = "item", item = itemOf(fields.itemID, key, text:match("|h%[(.-)%]|h")) })
        return
    end
    local index = deps.itemNameIndex
    local result = index and index:Resolve(text) or nil
    if result and result.kind == "error" then
        callback({ kind = "error", message = result.message })
        return
    end
    if result and result.kind == "name" and #result.matches > 0 then
        resolveMatches(result.matches, text, callback)
        return
    end
    local search = deps.ahNameSearch
    local open = deps.isAuctionHouseOpen and deps.isAuctionHouseOpen()
    if search and open then
        local query = ns.ItemNameIndex and ns.ItemNameIndex.ParseQuery(text) or { raw = text }
        search:Find(query.raw, function(items, err)
            if not items then
                callback({ kind = "error", message = err or "the search failed" })
            else
                resolveMatches(items, text, callback)
            end
        end, { exact = query.exact })
        return
    end
    if not index and not search then
        callback({ kind = "error", message = "item names are not available" })
    else
        callback({ kind = "error", message = 'no item named "' .. text .. '" in the scan data' })
    end
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

-- The item link and the quality of an item, or nil while the item data is not loaded. Asks the client to load it.
local function defaultItemLink(itemID)
    if not (C_Item and C_Item.GetItemInfo) then
        return nil
    end
    local _, link, quality = C_Item.GetItemInfo(itemID)
    if not link and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(itemID)
    end
    return link, quality
end

local dialogs = {}

-- A small dialog with a text and two buttons, made from the Kit window. One dialog for each name.
-- dialog:Open(title, text, options): options.yes and options.no are the button labels, onYes and onNo run in the click.
-- Escape or the close button counts as "no". options.red shows the text in red.
-- options.keep keeps the box open after yes, with the yes button off, until the next Open.
local function makeDialog(name)
    if dialogs[name] then
        return dialogs[name]
    end
    local Kit = ns.Kit
    local pad = Kit.Theme.padding
    local dialog = Kit.CreateWindow(name, { width = 380, height = 190, square = true })
    dialogs[name] = dialog
    dialog:SetFrameStrata("FULLSCREEN_DIALOG")
    dialog:SetToplevel(true)
    -- The text sits in a frame that takes hyperlinks, so an item link shows the item tooltip.
    local textWidth = 380 - 2 * pad - 16
    dialog.textFrame = CreateFrame("Frame", nil, dialog)
    dialog.textFrame:SetPoint("TOP", dialog, "TOP", 0, -40)
    dialog.textFrame:SetSize(textWidth, 20)
    dialog.textFrame:SetHyperlinksEnabled(true)
    dialog.textFrame:SetScript("OnHyperlinkEnter", function(frame, link)
        GameTooltip:SetOwner(frame, "ANCHOR_CURSOR")
        GameTooltip:SetHyperlink(link)
        GameTooltip:Show()
    end)
    dialog.textFrame:SetScript("OnHyperlinkLeave", function()
        GameTooltip:Hide()
    end)
    dialog.text = Kit.Label(dialog.textFrame, "", "normal")
    dialog.text:SetPoint("TOP", dialog.textFrame, "TOP", 0, 0)
    dialog.text:SetWidth(textWidth)
    dialog.text:SetJustifyH("CENTER")
    local function press(key)
        local callback = dialog[key]
        if key == "onYes" and dialog.keep then
            -- The box stays open. The yes button is off until the next Open.
            dialog.onYes = nil
            dialog.yesButton:SetEnabled(false)
        else
            dialog.onYes, dialog.onNo = nil, nil
            dialog:Hide()
        end
        if callback then
            callback()
        end
    end
    dialog.yesButton = Kit.Button(dialog, "", 130, function()
        press("onYes")
    end)
    dialog.yesButton:SetPoint("BOTTOM", dialog, "BOTTOM", -70, pad + 4)
    dialog.noButton = Kit.Button(dialog, "", 100, function()
        press("onNo")
    end)
    dialog.noButton:SetPoint("BOTTOM", dialog, "BOTTOM", 70, pad + 4)
    dialog:HookScript("OnHide", function()
        local callback = dialog.onNo
        dialog.onYes, dialog.onNo = nil, nil
        if callback then
            callback()
        end
    end)

    function dialog:Open(title, text, options)
        self.onYes, self.onNo = options.onYes, options.onNo
        self.keep = options.keep == true
        self.yesButton:SetEnabled(true)
        if self.SetTitle then
            self:SetTitle(title or "")
        end
        self.text:SetText(text or "")
        -- Size the box so that the text fits above the buttons.
        local textHeight = self.text.GetStringHeight and self.text:GetStringHeight() or 14
        self.textFrame:SetHeight(textHeight)
        self:SetHeight(math.max(150, 40 + textHeight + 20 + 22 + pad + 8))
        if options.red then
            self.text:SetTextColor(RED[1], RED[2], RED[3])
        else
            self.text:SetTextColor(1, 1, 1)
        end
        self.yesButton:SetText(options.yes or "OK")
        self.noButton:SetText(options.no or "Cancel")
        self:Show()
        self:Raise()
    end
    -- Hide with no callback.
    function dialog:Close()
        self.onYes, self.onNo = nil, nil
        self:Hide()
    end
    return dialog
end

local Tab = {}
Tab.__index = Tab

function Tab:_Say(text)
    if self.ui then
        text = text or ""
        self.ui.message:SetText(text)
        self.ui.message:SetShown(text ~= "")
        self:_Layout()
    end
end

-- Move the left column up when the message line is empty.
function Tab:_Layout()
    local ui = self.ui
    if ui and ui.leftTop then
        ui.leftTop:ClearAllPoints()
        ui.leftTop:SetPoint("TOPLEFT", ui.content, "TOPLEFT", 0, ui.message:IsShown() and 0 or MESSAGE_ROOM)
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
    local name = self.deps.itemInfo(entry.itemID or 0)
    if not name or name:match("^item %d+$") then
        -- No name yet: ask the client once; ITEM_DATA_LOAD_RESULT draws the list again.
        local itemID = entry.itemID
        if type(itemID) == "number" and not self.requested[itemID] then
            self.requested[itemID] = true
            pcall(self.deps.requestItem, itemID)
        end
        if entry.name then
            return entry.name
        end
    end
    return name
end

-- Item data arrived for an item that the list asked for: draw the list again.
function Tab:_OnItemLoaded(itemID)
    if self.requested[itemID] == true then
        self.requested[itemID] = false
        if self.active and self.ui then
            self:_Update()
        end
    end
end

-- Build the list again: from the groups and the operations, or from the selected search list.
function Tab:RefreshList()
    local deps = self.deps
    local lists = deps.searchLists
    if self.searchResults then
        self.list = self.searchResults
    elseif self.source == "lists" then
        local saved = lists and self.listID and lists:Get(self.listID) or nil
        if not saved then
            self.listID = nil
        end
        self.list = saved and deps.plan.ListEntries(saved.items, {
            rules = deps.rules, formulaRun = deps.formulaRun, label = "Search list: " .. saved.name,
        }) or {}
    elseif self.source == "vendor" then
        self:_EnsureVendor()
        self.list = self.vendorList or {}
    else
        self.list = deps.plan.ShoppingList({ rules = deps.rules, formulaRun = deps.formulaRun })
    end
    if self.selectedKey and not self:_Entry(self.selectedKey) then
        self.selectedKey = nil
        self.levelSel = nil
    end
    self:_Update()
end

-- The max price formula of the Vendor source. It is saved in the profile (buying.vendorFormula).
function Tab:GetVendorFormula()
    local db = self.deps.db
    local value = db and db:Get("profile", VENDOR_KEY) or self.vendorFormula
    if type(value) ~= "string" or value:match("^%s*$") then
        return self.deps.plan.VENDOR_FORMULA
    end
    return value
end

-- Save a new max price formula and build the Vendor list again. A formula that does not compile is not saved.
-- Returns true, or false and a text.
function Tab:SetVendorFormula(text)
    text = type(text) == "string" and text:match("^%s*(.-)%s*$") or ""
    local err = self:_CheckVendorFormula(text)
    local db = self.deps.db
    if not err and text ~= self:GetVendorFormula() then
        if db and not db:Set("profile", VENDOR_KEY, text) then
            err = "settings are read-only"
        else
            self.vendorFormula = text
            self.vendorDirty = true
        end
    end
    self.vendorError = err
    if not err and self.source == "vendor" then
        self:RefreshList()
    else
        self:_Update()
    end
    return err == nil, err
end

-- Returns nil if the text is a valid formula, or the error text.
function Tab:_CheckVendorFormula(text)
    if text == "" then
        return "enter a formula"
    end
    local run = self.deps.formulaRun
    if run and run.Compile then
        local compiled, err = run:Compile(text)
        if not compiled then
            return err and err.message or "formula error"
        end
    end
    return nil
end

-- The profile and the formula of a Vendor list. A list built for other values is old.
function Tab:_VendorKey()
    local db = self.deps.db
    return tostring(db and db:GetProfile() or "") .. "|" .. self:GetVendorFormula()
end

-- Build the Vendor list if it is not built or a scan, a new formula or another profile made it old.
function Tab:_EnsureVendor()
    if self.vendorBuilding then
        return
    end
    if self.vendorDirty or self.vendorList == nil or self.vendorKey ~= self:_VendorKey() then
        self:_BuildVendor()
    end
end

-- The job did not end well: show a text, write the error to the log and try again at the next refresh.
function Tab:_VendorFailed(message)
    log("error", "vendor list failed: %s", tostring(message))
    self.vendorBuilding = false
    self.vendorJob = nil
    self.vendorList = self.vendorList or {}
    self.vendorFailed = true
    self.vendorDirty = true
    if self.ui then
        self:_Update()
    end
end

-- Build the Vendor list in a scheduler job. The job gives one checkpoint for each record.
function Tab:_BuildVendor()
    local deps = self.deps
    self.vendorToken = self.vendorToken + 1
    local token = self.vendorToken
    if self.vendorJob and self.vendorJob.Cancel then
        self.vendorJob:Cancel()
    end
    self.vendorJob = nil
    self.vendorDirty = false
    self.vendorFailed = false
    self.vendorKey = self:_VendorKey()
    self.vendorPending = false
    self.vendorQueue, self.vendorPos = {}, 1
    local since = deps.lastScan and deps.lastScan() or nil
    if not (since and deps.scanStore and deps.itemCache) then
        self.vendorBuilding = false
        self.vendorList = {}
        return
    end
    self.vendorBuilding = true
    local function work(job)
        local entries, stats = deps.plan.VendorEntries({
            store = deps.scanStore, itemCache = deps.itemCache, formulaRun = deps.formulaRun,
            formula = self:GetVendorFormula(), since = since,
        }, job)
        if token ~= self.vendorToken then
            return
        end
        self.vendorJob = nil
        self.vendorList, self.vendorBuilding = entries, false
        self.vendorQueue, self.vendorPos = stats.queue, 1
        -- Keep the open requests. An item that loaded while the job ran needs a new build.
        local waiting = {}
        local function keep(itemID)
            if deps.itemCache:GetState(itemID) == "requested" then
                waiting[itemID] = true
            else
                self.vendorPending = true
            end
        end
        for itemID in pairs(self.vendorWaiting) do
            keep(itemID)
        end
        for _, itemID in ipairs(stats.waiting) do
            keep(itemID)
        end
        self.vendorWaiting = waiting
        -- Show the list first. The pump only asks for item data and does not start a build itself.
        if self.source == "vendor" then
            self:RefreshList()
        end
        self:_PumpVendor()
    end
    if deps.runJob then
        local job = deps.runJob("buying-vendor", work)
        self.vendorJob = job
        if job and job.OnDone then
            job:OnDone(function(_, status, message)
                if token == self.vendorToken and status ~= "done" then
                    self:_VendorFailed(status == "failed" and message or status)
                end
            end)
        end
    else
        work(nil)
    end
end

-- Ask for the item data of the next items in the queue, so that at most VENDOR_BATCH requests are open. An item that
-- the cache has at once does not count. The list is built again when no request is open and the queue is empty.
function Tab:_PumpVendor()
    local cache, queue = self.deps.itemCache, self.vendorQueue
    if not (cache and queue) then
        return
    end
    local open = 0
    for _ in pairs(self.vendorWaiting) do
        open = open + 1
    end
    local token, scanned, resolved = self.vendorToken, 0, false
    while self.vendorPos <= #queue and open < VENDOR_BATCH and scanned < VENDOR_SCAN_CAP do
        local itemID = queue[self.vendorPos]
        self.vendorPos = self.vendorPos + 1
        scanned = scanned + 1
        cache:Request(itemID)
        if cache:GetState(itemID) == "requested" then
            self.vendorWaiting[itemID] = true
            open = open + 1
        else
            resolved = true
        end
    end
    if resolved then
        self.vendorPending = true
    end
    if self.vendorPos <= #queue then
        if open < VENDOR_BATCH then
            self.deps.after(0.1, function()
                if token == self.vendorToken then
                    self:_PumpVendor()
                end
            end)
        end
    elseif open == 0 and self.vendorPending then
        self:_ScheduleVendor(0)
    end
    if resolved and open > 0 then
        self:_ScheduleVendor(VENDOR_SETTLE, true)
    end
end

-- Draw the Vendor list again after delay seconds, if the source shows. A call with keep true leaves a timer that waits.
function Tab:_ScheduleVendor(delay, keep)
    if keep and self.vendorTimer then
        return
    end
    self.vendorTimerToken = (self.vendorTimerToken or 0) + 1
    local token = self.vendorTimerToken
    self.vendorTimer = true
    self.deps.after(delay, function()
        if token ~= self.vendorTimerToken then
            return
        end
        self.vendorTimer = false
        if self.vendorPending then
            self.vendorDirty = true
        end
        if self.active and self.ui and self.source == "vendor" then
            self:RefreshList()
        end
    end)
end

-- A scan ended: the Vendor list is old now.
function Tab:_OnVendorScan()
    self.vendorDirty = true
    if self.active and self.source == "vendor" then
        self:RefreshList()
    end
end

-- Item data arrived for an item that the Vendor list asked for. Ask for the next items. Build the list again when
-- all requests ended, or after VENDOR_SETTLE seconds if some are still open.
function Tab:_OnVendorItem(itemID)
    if not self.vendorWaiting[itemID] then
        return
    end
    self.vendorWaiting[itemID] = nil
    self.vendorPending = true
    self:_PumpVendor()
    if self.vendorPos > #self.vendorQueue and next(self.vendorWaiting) == nil then
        self:_ScheduleVendor(0)
    else
        self:_ScheduleVendor(VENDOR_SETTLE, true)
    end
end

-- The text for the state of the Vendor list: it builds, it failed, there is no full scan, or no item is below its max
-- price. Returns nil for a list with rows.
function Tab:_VendorState()
    if self.vendorBuilding then
        return "Building list..."
    end
    if self.vendorFailed then
        return "The list could not be built."
    end
    local last, partial = nil, false
    if self.deps.lastScan then
        last, partial = self.deps.lastScan()
    end
    if partial and (not last or #(self.vendorList or {}) == 0) then
        return "The last scan was partial. Run a full scan."
    end
    if not last then
        return "Run a full scan first."
    end
    if #(self.vendorList or {}) == 0 then
        return "No items below the max price in the last scan."
    end
    return nil
end

-- Show the groups ("groups"), the search lists ("lists") or the vendor flips ("vendor") on the left side.
function Tab:SetSource(source)
    local deps = self.deps
    if source ~= "groups" and not (source == "lists" and deps.searchLists)
        and not (source == "vendor" and deps.scanStore) then
        return false
    end
    self:_DropSearch()
    self.source = source
    self.selectedKey = nil
    self.levelSel = nil
    self.run = nil
    if source == "lists" and not self.listID then
        local first = self.deps.searchLists:List()[1]
        self.listID = first and first.id or nil
    end
    if source == "vendor" and self.ui then
        self.vendorError = nil
        self.ui.vendorInput:SetText(self:GetVendorFormula())
    end
    self:RefreshList()
    return true
end

-- Select a search list and show it.
function Tab:SelectList(id)
    local lists = self.deps.searchLists
    if not lists or not lists:Get(id) then
        return false
    end
    self:_DropSearch()
    self.listID = id
    self.source = "lists"
    self.selectedKey = nil
    self.levelSel = nil
    self.run = nil
    self:RefreshList()
    return true
end

-- Make a search list with the name. Returns true, or false and a text.
function Tab:NewList(name)
    local lists = self.deps.searchLists
    local id, err = lists:Create(name, {})
    if not id then
        self:_Say(err)
        return false, err
    end
    if self.ui then
        self.ui.nameInput:SetText("")
    end
    self:SelectList(id)
    return true
end

function Tab:RenameList(name)
    local lists = self.deps.searchLists
    if not self.listID then
        self:_Say("pick a search list first")
        return false, "pick a search list first"
    end
    local ok, err = lists:Rename(self.listID, name)
    if not ok then
        self:_Say(err)
        return false, err
    end
    self:_Update()
    return true
end

function Tab:DeleteList()
    local lists = self.deps.searchLists
    if not self.listID then
        return false
    end
    local ok, err = lists:Delete(self.listID)
    if not ok then
        self:_Say(err)
        return false, err
    end
    self.listID = nil
    self:SetSource("lists")
    return true
end

-- Remove one item of the selected search list by its place in the list.
function Tab:RemoveListItem(index)
    local lists = self.deps.searchLists
    if not (lists and self.listID) then
        return false
    end
    local ok, err = lists:RemoveItem(self.listID, index)
    if not ok then
        self:_Say(err)
        return false, err
    end
    self:RefreshList()
    return true
end

local QUICK_LIST = "Quick search"
local NAME_SETTLE_SECONDS = 1 -- a name search ends after this many seconds with no new results

-- Forget the name search results and the saved selection. The caller sets the new selection.
function Tab:_DropSearch()
    self.searchResults, self.searchText, self.preSearchKey = nil, nil, nil
    if self.ui then
        self.ui.searchInput:SetText("")
    end
end

-- Search the Auction House for items by name. Every match shows in the list, also items in no group.
-- A searched item has no operation, so it has no max price. Empty text clears the search.
-- Returns true, or false and a text.
function Tab:SearchName(text)
    local deps = self.deps
    text = tostring(text or ""):match("^%s*(.-)%s*$")
    if text == "" then
        return self:ClearSearch()
    end
    local finder = deps.ahNameSearch
    if not finder then
        self:_Say("name search is not available")
        return false, "name search is not available"
    end
    if self.pending or self.queue or self.buy or self.nameSearching then
        self:_Say("a search is running")
        return false, "a search is running"
    end
    if not deps.client.IsReady() then
        self:_Say("waiting for the Auction House")
        return false, "waiting for the Auction House"
    end
    local query = ns.ItemNameIndex and ns.ItemNameIndex.ParseQuery(text) or { raw = text }
    self.nameSearching = true
    -- The finder reports the items found so far on each result event, then the end. All of them add to one list.
    local shown = false
    local function show(items)
        if shown and not self.searchResults then
            return
        end
        self:_ShowSearch(text, items, shown)
        shown = true
    end
    finder:Find(query.raw, function(items, err)
        self.nameSearching = false
        if not items then
            self:_Say(err or "the search failed")
            return
        end
        show(items)
        -- A name in quotes that matches one item opens its stacks at once, unless the user picked an item meanwhile.
        if query.exact and #items == 1 and self.searchResults and not self.selectedKey then
            local entry = self:_Entry(items[1].key)
            if entry then
                self:_OnTreeSelect({ kind = "item", entry = entry })
            end
        end
    end, { exact = query.exact, settle = NAME_SETTLE_SECONDS, onItems = show })
    return true
end

-- True if a chat edit box is open. Chat then gets a shift-clicked link.
local function chatEditActive()
    local util = _G.ChatFrameUtil
    local getActive = type(util) == "table" and util.GetActiveWindow or _G.ChatEdit_GetActiveWindow
    return type(getActive) == "function" and getActive() ~= nil
end

-- A shift-clicked item: show it as the one item of the search list, select it and start its item search at once.
-- There is no browse query. It acts only while this tab is shown, the Auction House is open and no chat edit box is
-- open. Returns true if it took the link.
function Tab:SearchLink(link)
    local ItemString = ns.ItemString
    if not (self.active and self.ui and self.content and self.content:IsShown()) then
        return false
    end
    if not self.deps.isAuctionHouseOpen() or chatEditActive() or not ItemString.IsItemLink(link) then
        return false
    end
    local fields = ItemString.ParseLink(link)
    local itemID = fields and fields.itemID
    if not itemID then
        return false
    end
    if self.nameSearching then
        self:_Say("a search is running")
        return true
    end
    local name = link:match("|h%[(.-)%]|h")
    if not name or name == "" then
        name = nil
    end
    local key = self.deps.keyFor and self.deps.keyFor(link) or ItemString.ToExactKey(link)
    local text = name or string.format("%d", itemID)
    self.ui.searchInput:SetText('"' .. text .. '"')
    log("info", "link search for item %s", itemID)
    self:_ShowSearch(text, { { itemID = itemID, key = key or string.format("%d", itemID), name = name } }, false)
    local entry = self.list[1]
    if entry then
        self:_OnTreeSelect({ kind = "item", entry = entry })
    end
    return true
end

-- Show the items of a name search in the list. keep is true for a later update of the same search.
function Tab:_ShowSearch(text, items, keep)
    if not self.searchResults then
        self.preSearchKey = self.selectedKey
    end
    self.searchText = text
    self.searchResults = self.deps.plan.ListEntries(items, { formulaRun = self.deps.formulaRun, label = "Search" })
    if not keep then
        self.selectedKey, self.levelSel, self.run = nil, nil, nil
        self:_CancelQuote("the list changed")
    end
    self:RefreshList()
    self:_Say(#self.searchResults == 0 and "no items found" or "")
end

-- Leave the name search and show the groups or the search list again. The earlier selection comes back.
function Tab:ClearSearch()
    if not self.searchResults then
        if self.ui then
            self.ui.searchInput:SetText("")
        end
        return true
    end
    local key = self.preSearchKey
    self:_CancelQuote("the list changed")
    self:_DropSearch()
    self.levelSel, self.run = nil, nil
    self:RefreshList()
    self.selectedKey = key and self:_Entry(key) and key or nil
    self:_Update()
    self:_Say("")
    return true
end

-- Add a resolved item to the selected search list. With no list, it uses the list "Quick search".
function Tab:_AddResolved(item)
    local lists = self.deps.searchLists
    if not self.listID then
        local id
        for _, saved in ipairs(lists:List()) do
            if saved.name == QUICK_LIST then
                id = saved.id
            end
        end
        if not id then
            local err
            id, err = lists:Create(QUICK_LIST, {})
            if not id then
                self:_Say(err)
                return false, err
            end
        end
        self.listID = id
    end
    local ok, err = lists:AddItem(self.listID, item)
    if not ok then
        self:_Say(err)
        return false, err
    end
    self:_DropSearch()
    self.source = "lists"
    if self.ui then
        self.ui.itemInput:SetText("")
    end
    self:RefreshList()
    self:Select_(item.key)
    self:_Say("added " .. (item.name or self.deps.itemInfo(item.itemID)))
    return true
end

-- Add the item that the text names (name, ID, link or key) to the current search list.
function Tab:AddItem(text)
    local deps = self.deps
    if not deps.searchLists then
        return false, "search lists are not available"
    end
    local handled, ok, err = false, nil, nil
    BuyingTab.ParseInput(text, deps, function(result)
        handled = true
        if result.kind == "item" then
            ok, err = self:_AddResolved(result.item)
        elseif result.kind == "choices" then
            self.choices = result.choices
            self:_Say(#result.choices .. " items match, pick one")
            self:_ShowChoices(result.choices)
            ok = true
        else
            self:_Say(result.message)
            ok, err = false, result.message
        end
    end)
    if not handled then
        return true
    end
    return ok, err
end

-- Open a menu with the matching items. The pick adds the item.
function Tab:_ShowChoices(choices)
    local ui = self.ui
    if not (ui and ns.Kit.ContextMenu) then
        return
    end
    local entries = {}
    for index = 1, math.min(#choices, 12) do
        local item = choices[index]
        entries[index] = {
            text = (item.name or ("item " .. item.itemID)) .. " (" .. item.key .. ")",
            onClick = function()
                self.choices = nil
                self:_AddResolved(item)
            end,
        }
    end
    ns.Kit.ContextMenu(ui.itemInput, entries, { title = "Pick an item" })
end

-- Apply a request to open a search list; start the search if autoSearch is true.
function Tab:OpenList(id, autoSearch)
    if not self:SelectList(id) then
        return false
    end
    if autoSearch == true and self.deps.client.CanLiveSearch() then
        self:SearchAll()
    end
    return true
end

-- The event "Flipside.SearchListOpen". The search lists object records the request while the AH is closed.
function Tab:_OnOpenList(id, autoSearch)
    if self.deps.isAuctionHouseOpen() then
        self:OpenList(id, autoSearch)
    end
end

function Tab:Select_(key)
    if key ~= self.selectedKey then
        -- The confirm box closes when the item changes. A purchase in flight stays.
        if self.buy then
            self:_CancelQuote("the item changed")
        else
            self:_CloseConfirm()
        end
        self.run = nil
        self.levelSel = nil
        self.amount, self.amountBad, self.amountEdit = DEFAULT_AMOUNT, false, false
    end
    self.selectedKey = key
    self:_Update()
end

-- Store and log the result of reading the rows of one item. more = { next, total } if sorted pages are not read
-- yet: pages 0 to next - 1 are in the rows.
function Tab:_Finish(entry, rows, silent, more)
    local plan = self.deps.plan
    local raw = rows
    rows = self:_DropKnown(entry, rows)
    local result = plan.Evaluate(entry, rows)
    if not entry.itemID then
        result.stop = "no item id"
    end
    self.results[entry.key] = { rows = rows, raw = raw, result = result, more = more }
    if not silent then
        local decision, reason = BuyingTab.DescribeDecision(result)
        self.deps.log:Add(entry, decision, reason)
    end
    self:_Update()
end

-- Start the no-response timer of a search or of one page of a read. A new page restarts it.
function Tab:_Arm(pending)
    pending.stamp = (pending.stamp or 0) + 1
    local stamp, entry = pending.stamp, pending.entry
    self.deps.after(SEARCH_TIMEOUT, function()
        if self.pending == pending and pending.stamp == stamp then
            self.pending = nil
            self.livePage = nil
            log("warn", "search for item %s: no response", entry.itemID)
            if self.continueKey == entry.key then
                self:_CloseConfirm()
            end
            self.deps.log:Add(entry, "no response")
            self:_Say("no response for " .. self:_ItemName(entry))
            self:_Update()
            self:_RunHeldSearch()
            self:_Next()
        end
    end)
end

-- Start the live search of one entry. silent keeps the result out of the log.
-- range = { from, to } (0-based pages) reads only these pages again, the last one first, and puts them into the
-- rows of the earlier read. Without a range, the search reads all pages of the result.
-- Returns "started", "skipped" or "wait" with a text.
function Tab:_Start(entry, silent, range)
    local client = self.deps.client
    if not (entry.maxPrice or entry.noMax) or not entry.itemID then
        self:_Finish(entry, {})
        return "skipped"
    end
    if not client.IsReady() then
        return "wait", "waiting for the Auction House to be ready"
    end
    local first = range and range.to or 0
    local ok, text = client.LiveSearch(entry.itemID, first)
    if not ok then
        log("debug", "search for item %s refused: %s", entry.itemID, text)
        return "wait", text or "the search was refused"
    end
    log("info", "search for item %s started (page %d)", entry.itemID, first)
    self.token = self.token + 1
    local pending = {
        entry = entry, itemID = entry.itemID, token = self.token, silent = silent, at = first,
        read = { rows = {}, queue = {}, range = range },
    }
    for page = (range and range.to or 0) - 1, range and range.from or 0, -1 do
        pending.read.queue[#pending.read.queue + 1] = page
    end
    pending.read.multi = #pending.read.queue > 0
    self.pending = pending
    self:_Arm(pending)
    return "started"
end

-- True if a read of more than one page is on its way.
function Tab:_Reading()
    local pending = self.pending
    return pending ~= nil and pending.read ~= nil and pending.read.multi == true
end

-- Stop a read of several pages and keep the earlier result. Returns true if a read was stopped.
function Tab:_CancelRead(why)
    if not self:_Reading() then
        return false
    end
    local pending = self.pending
    self.pending, self.livePage = nil, nil
    log("info", "read of item %s stopped: %s", pending.itemID, why)
    if self.continueKey == pending.entry.key then
        self:_CloseConfirm()
    end
    self:_Say(why)
    self:_Update()
    return true
end

-- Search the selected item once. A new search stops a read of several pages. Returns true, or false and a text.
function Tab:Search()
    local entry = self:_Selected()
    if not entry then
        return false, "pick an item first"
    end
    if self.pending and not self:_CancelRead("read stopped") then
        return false, "a search is running"
    end
    if self.run and self.run.key == entry.key then
        -- A search of the user shows the list as it is: the failed auctions come back.
        self.run.dropped, self.run.dropWatch = nil, nil
    end
    local status, text = self:_Start(entry)
    if status == "wait" then
        self:_Say(text)
        return false, text
    end
    self:_Update()
    return true
end

-- Read the next page of a sorted result (the Load more button, and Buy next when it has no stack left).
-- Returns true, or false and a text.
function Tab:LoadMore()
    local entry = self:_Selected()
    local done = entry and self.results[entry.key]
    if not (done and done.more) then
        return false, "no more pages"
    end
    if self.pending or self.buy then
        return false, "a search is running"
    end
    local page = done.more.next
    self:_Refresh(entry, { from = page, to = page, loadMore = true })
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

-- Stop the queue and a read of several pages. A search of one page in flight still ends with its result.
function Tab:Stop()
    local reading = self:_CancelRead("read stopped")
    local queued = self.queue ~= nil
    self.queue = nil
    if queued or not reading then
        self:_Say("search all stopped")
    end
    self:_Update()
end

-- The search of the item came to its end: store the rows and go on with the buy box, the held search and the queue.
function Tab:_Complete(pending, rows)
    self.pending = nil
    self:_Finish(pending.entry, rows, pending.silent, pending.more)
    self:_Say("")
    if self.continueKey and self.continueKey == pending.entry.key then
        self:_ContinueBuy()
    else
        self:_EnsureLive(pending.entry)
    end
    self:_RunHeldSearch()
    self:_Next()
end

-- Send the query of the next page of a read. It waits for the client throttle and tries again on the ready event.
function Tab:_ReadNext(pending)
    local read = pending.read
    if self.pending ~= pending or not read.next then
        return
    end
    local client = self.deps.client
    local ok, text = false, nil
    if client.IsReady() then
        ok, text = client.LiveSearch(pending.itemID, read.next)
    end
    if not ok then
        if not read.waiting then
            read.waiting = true
            self:_Arm(pending)
        end
        self:_Say(text or string.format("Waiting to read page %d of %d", read.next + 1, read.total))
        if not read.retrying then
            read.retrying = true
            self.deps.after(READ_RETRY, function()
                read.retrying = false
                self:_ReadNext(pending)
            end)
        end
        return
    end
    pending.at, read.waiting = read.next, false
    read.next = nil
    self:_Arm(pending)
    self:_Say(string.format("Reading page %d of %d", pending.at + 1, read.total))
    self:_Update()
end

-- TBC: the client gives the seller names of the rows late and sends the list update again. Wait a short, bounded time
-- for them, because the seller is part of the stack group. Returns true if the page must wait.
function Tab:_OwnersPending(pending)
    local client = self.deps.client
    local missing = client.LiveOwnersPending and client.LiveOwnersPending(pending.itemID)
    if not missing or (pending.ownerWaits or 0) >= OWNER_WAITS then
        pending.ownerToken, pending.ownerWaiting, pending.ownerWaits = (pending.ownerToken or 0) + 1, false, 0
        return false
    end
    if not pending.ownerWaiting then
        pending.ownerWaiting = true
        pending.ownerToken = pending.ownerToken or 0
        local token = pending.ownerToken
        self.deps.after(OWNER_WAIT, function()
            if self.pending == pending and pending.ownerToken == token and pending.ownerWaiting then
                pending.ownerWaiting = false
                pending.ownerWaits = (pending.ownerWaits or 0) + 1
                self:_OnPage(pending)
            end
        end)
    end
    return true
end

-- The pages that are loaded after a read with pages: old is the earlier result, range the pages read, count the
-- pages now. Returns { next, total }, or nil if all pages are loaded or the read has no sorted pages.
local function nextMore(old, range, count)
    local loaded = old and old.more and old.more.next
    if not loaded then
        return nil
    end
    if range.loadMore then
        loaded = range.to + 1
    end
    return loaded < count and { next = loaded, total = count } or nil
end

-- One page of the result came. Add its rows. Ask for the next page, or finish the read.
-- With sorted pages, a full read stops after page 1 (see LoadMore).
function Tab:_OnPage(pending)
    local client = self.deps.client
    local read = pending.read
    if self:_OwnersPending(pending) then
        return
    end
    local rows = client.LiveRows(pending.itemID)
    local count = client.LivePageCount and client.LivePageCount() or nil
    if not count then
        -- The client has no pages: this is the whole result.
        self.livePage = nil
        self:_Complete(pending, rows)
        return
    end
    for _, row in ipairs(rows) do
        row.page = pending.at
        read.rows[#read.rows + 1] = row
    end
    self.livePage = pending.at
    read.total = count
    local sorted = client.SortedPaging ~= nil and client.SortedPaging() == true
    if not read.range and not read.started then
        -- The first page of a full read tells how many pages there are. With sorted pages, page 1 holds the cheapest
        -- auctions: it shows at once and the other pages wait for LoadMore.
        read.started = true
        for page = 1, sorted and 0 or count - 1 do
            read.queue[#read.queue + 1] = page
        end
        read.multi = #read.queue > 0
    end
    read.next = table.remove(read.queue, 1)
    if read.next then
        self:_ReadNext(pending)
        return
    end
    if read.range then
        local old = self.results[pending.entry.key]
        rows = self.deps.plan.MergePages(old and old.raw or {}, read.range.from, read.range.to, read.rows, count)
        pending.more = nextMore(old, read.range, count)
    else
        rows = self.deps.plan.SortRows(read.rows)
        pending.more = sorted and count > 1 and { next = 1, total = count } or nil
    end
    self:_Complete(pending, rows)
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
    pending.read = pending.read or { rows = {}, queue = {} }
    if pending.read.next then
        -- A late update of the page before: the next page is not sent yet.
        return
    end
    self:_OnPage(pending)
end

-- The throttle is ready again. A search result can come while the client is still not ready, so the buy controls
-- must be drawn again here.
function Tab:_OnReady()
    -- A read of several pages waits for the throttle before it sends the next page.
    if self.pending and self.pending.read and self.pending.read.next then
        self:_ReadNext(self.pending)
    end
    -- A refresh after a buy waits for the throttle. Start it as soon as the client is ready.
    if self.refreshEntry and not self.pending then
        self:_Refresh(self.refreshEntry, self.refreshRange)
    end
    -- Buy next waited for the throttle: show the next stack now.
    local retry = self.chainRetry
    self.chainRetry = nil
    if retry and not self.pending and not self.buy then
        self.continueKey = retry
        self:_ContinueBuy()
    end
    local selected = self:_Selected()
    if selected and not self.pending then
        self:_EnsureLive(selected)
    end
    if self.queue and not self.pending then
        self:_Next()
    end
    self:_Update()
end

-- The jump warning threshold in percent. It is saved in the profile (buying.jumpPercent).
function Tab:GetJumpPercent()
    local db = self.deps.db
    local value = db and db:Get("profile", JUMP_KEY) or self.jumpPercent
    if type(value) ~= "number" then
        return DEFAULT_JUMP
    end
    return value
end

function Tab:SetJumpPercent(value)
    if type(value) ~= "number" or value <= 0 then
        return false
    end
    self.jumpPercent = value
    if self.deps.db then
        self.deps.db:Set("profile", JUMP_KEY, value)
    end
    return true
end

function Tab:SetDryRun(on)
    self.dryRun = on == true
    self:_Update()
end

-- The run of the selected item: the price of the level bought last.
function Tab:_Run(entry)
    if not self.run or self.run.key ~= entry.key then
        self.run = { key = entry.key, bought = 0 }
    end
    return self.run
end

local function findLevel(levels, id)
    for _, level in ipairs(levels) do
        if levelId(level) == id then
            return level
        end
    end
    return nil
end

-- The first level of the stack that Buy next follows (see BuyingPlan.ChainKey) that has a free auction, or nil.
local function chainLevel(levels, key)
    for _, level in ipairs(levels) do
        local row = not level.own and firstFree(level) or nil
        if row and ns.BuyingPlan.ChainKey(row) == key then
            return level
        end
    end
    return nil
end

-- The levels of the rows: one for each unit price (a commodity), or one for each stack group (an item).
function Tab:_Levels(rows)
    return self.deps.plan.PriceLevels(rows)
end

-- The pages that the rows of a stack group are on, as { from, to }, or nil if the rows have no pages.
local function pageRange(level)
    local from, to
    for _, row in ipairs(level.rows) do
        if row.page then
            from = math.min(from or row.page, row.page)
            to = math.max(to or row.page, row.page)
        end
    end
    return from and { from = from, to = to } or nil
end

-- The next auction to buy after lastPrice: the first auction of that unit price or more that is not yours.
local function nextAuction(levels, lastPrice)
    for _, level in ipairs(levels) do
        if not level.own and (lastPrice == nil or level.unitPrice >= lastPrice) then
            return level
        end
    end
    return nil
end

-- The cheapest level that is not yours. With none, the first level.
local function cheapestBuyable(levels)
    for _, level in ipairs(levels) do
        if not level.own then
            return level
        end
    end
    return levels[1]
end

-- Set the amount of units from the text of the amount box. Empty means all units up to the level. Any other text
-- must be a whole number above 0. Else the buy is refused until the text is right.
function Tab:SetAmount(text)
    text = tostring(text or ""):match("^%s*(.-)%s*$")
    if self.fillingAmount then
        return
    end
    self.amountEdit = true
    self.amount, self.amountBad = nil, false
    if text ~= "" then
        local number = text:match("^%d+$") and tonumber(text) or nil
        if number and number > 0 then
            self.amount = number
        else
            self.amountBad = true
        end
    end
    self:_Update()
    if self.amountBad then
        self:_Say(AMOUNT_TEXT)
    end
end

-- Select a price level of the item by its key (the unit price; the auction index on TBC).
-- A second click on the same level clears the selection.
-- The selection never starts a buy. Returns true, or false and a reason.
function Tab:SelectLevel(price)
    if not self:_Selected() then
        return false, "pick an item first"
    end
    self.levelSel = (self.levelSel ~= price) and price or nil
    self.amount, self.amountBad, self.amountEdit = DEFAULT_AMOUNT, false, false
    self:_Update()
    if self.levelSel then
        -- A group on another page needs that page in the client list before a buy.
        self:_EnsureLive(self:_Selected())
        local _, _, _, reason = self:_NextBuy()
        self:_Say(reason or "")
        return true, reason
    end
    self:_Say("")
    return true
end

-- The units that one purchase covers. For a commodity, the purchase takes the cheapest units first: from the level
-- first up to the level target, and at most amount units (nil means all). For an item, it is one stack of target.
-- Returns { quantity, cost, covered = { [unitPrice] = true }, last = the highest level reached, levels = count,
-- complete = true if the last level is taken whole, own = true if a level in the range is yours }.
local function coverPlan(levels, first, target, amount, isItem)
    local plan = { quantity = 0, cost = 0, covered = {}, levels = 0, complete = true, own = false, isItem = isItem }
    if isItem then
        local size = target.stackSize or target.quantity
        plan.quantity, plan.cost = size, target.unitPrice * size
        plan.covered[levelId(target)], plan.last, plan.levels = true, target, 1
        return plan
    end
    local left = amount or math.huge
    for _, level in ipairs(levels) do
        if level.unitPrice >= first.unitPrice and level.unitPrice <= target.unitPrice and left > 0 then
            local take = math.min(level.quantity, left)
            left = left - take
            plan.quantity = plan.quantity + take
            plan.cost = plan.cost + take * level.unitPrice
            plan.covered[level.unitPrice] = true
            plan.last, plan.levels = level, plan.levels + 1
            plan.complete = take == level.quantity
            plan.own = plan.own or level.own
        end
    end
    return plan
end

-- Find the level that Buy next or Buy buys. With a selected level, it is that level.
-- Returns entry, level, levels, a reason if the level cannot be bought, and the cover plan of the purchase.
function Tab:_NextBuy()
    local entry = self:_Selected()
    if not entry then
        return nil, nil, nil, "pick an item first"
    end
    local done = self.results[entry.key]
    if not done then
        return entry, nil, nil, "search first"
    end
    if self.buy then
        return entry, nil, nil, "a buy is open"
    end
    if self.pending then
        return entry, nil, nil, self:_Reading() and "reading the pages" or "a search is running"
    end
    local plan = self.deps.plan
    local levels = self:_Levels(done.rows)
    local isItem = done.rows[1] ~= nil and done.rows[1].isCommodity == false
    local lastPrice = self.run and self.run.key == entry.key and self.run.lastPrice or nil
    local chosen = self.levelSel and findLevel(levels, self.levelSel) or nil
    if isItem and self.chainGroup then
        -- Buy next stays with the stack of the last buy (same buyout and stack size).
        chosen = chainLevel(levels, self.chainGroup)
    end
    local nextLevel
    if isItem then
        nextLevel = nextAuction(levels, lastPrice)
    else
        nextLevel = plan.NextLevel(levels, lastPrice)
    end
    local level = chosen or nextLevel
    local reason
    local cover = level and (isItem or nextLevel) and coverPlan(levels, nextLevel, level, self.amount, isItem) or nil
    if not (entry.maxPrice or entry.noMax) then
        reason = "no max price"
    elseif not level then
        reason = "nothing left to buy"
    elseif level.own then
        reason = "own listing"
    elseif not withinMax(entry, level.unitPrice) then
        reason = "above max price"
    elseif not cover or not cover.last then
        reason = "nothing left to buy"
    elseif cover.own then
        -- The API cannot skip own units: a purchase takes the cheapest units of the market.
        reason = "own listing below the selected level"
    elseif not isItem and self.amountBad then
        reason = AMOUNT_TEXT
    elseif not self.dryRun and not self.deps.client.CanBuy() then
        reason = "buying is not available"
    elseif not self.deps.client.IsReady() then
        reason = "waiting for the Auction House"
    end
    return entry, level, levels, reason, cover
end

-- Buy next. Call it only from the click of the button. Returns true, or false and a reason.
function Tab:BuyNext()
    local entry, _, levels, reason, cover = self:_NextBuy()
    if reason then
        self:_Say(reason)
        return false, reason
    end
    local level = cover.last
    if self.dryRun then
        self.deps.log:Add(entry, string.format("would buy %d at %s", cover.quantity, money(level.unitPrice)),
            "dry run")
        return true
    end
    local run = self:_Run(entry)
    local prev = run.lastPrice or cheapestBuyable(levels).unitPrice
    local percent = self:GetJumpPercent()
    local check = self.deps.plan.JumpCheck(prev, level.unitPrice, percent)
    if check.jump and cover.isItem then
        -- An item: the warning shows in the confirm box, before the click that buys the stack.
        return self:_StartBuy(entry, cover, { prev = prev, percent = check.percent })
    end
    if check.jump then
        makeDialog("FlipsideBuyJump"):Open("Price jump",
            string.format("Price jumps from %s to %s (+%.0f%%). Keep buying?", money(prev), money(level.unitPrice),
                check.percent),
            {
                yes = "Keep buying", no = "Stop",
                onYes = function()
                    if not self.buy then
                        self:_StartBuy(entry, cover)
                    end
                end,
                onNo = function()
                    self.run = nil
                    self:_Say("buying stopped")
                    self:_Update()
                end,
            })
        return true
    end
    return self:_StartBuy(entry, cover)
end

-- Start the buy of one level. Call it only from a click. A commodity asks for a quote; an item goes to the confirm.
function Tab:_StartBuy(entry, cover, jump)
    local level = cover.last
    local first = level.rows[1]
    if first.isCommodity == false then
        local row = firstFree(level)
        if not row then
            self:_Say("own listing")
            return false, "own listing"
        end
        self.buy = {
            entry = entry, level = level, row = row, isItem = true, phase = "quoted", itemID = entry.itemID,
            auctionID = row.auctionID, quantity = row.quantity or 1, unit = row.unitPrice, total = buyoutOf(row),
            jump = jump, stacks = level.stacks,
        }
        self:_ShowConfirm()
        self:_Update()
        return true
    end
    local buy = { entry = entry, level = level, row = first, phase = "quoting", itemID = entry.itemID,
        quantity = cover.quantity, complete = cover.complete }
    if self.previewQuote then
        -- StartCommodityPurchase is protected: no event may call it. The box shows an estimate and the
        -- Get quote button (a click) asks for the quote.
        buy.phase, buy.unit, buy.total = "preview", cover.cost / cover.quantity, cover.cost
        self.buy = buy
        self:_ShowConfirm()
        self:_Update()
        return true
    end
    return self:_RequestQuote(buy)
end

-- Ask for the quote of a commodity buy. Call it only from a click.
function Tab:_RequestQuote(buy)
    local entry = buy.entry
    local ok, err = pcall(self.deps.client.StartCommodityPurchase, buy.itemID, buy.quantity)
    if not ok then
        self.deps.log:Add(entry, "buy failed", tostring(err))
        self:_Say("the quote was refused")
        return false, "the quote was refused"
    end
    buy.phase = "quoting"
    self.buy = buy
    self:_Say("waiting for the quote of " .. self:_ItemName(entry))
    self.deps.after(QUOTE_WAIT, function()
        if self.buy == buy and buy.phase == "quoting" then
            self:_CancelQuote("no quote came")
        end
    end)
    self:_Update()
    return true
end

-- The item as a link in the quality colour. Returns nil while the client has no link yet.
function Tab:_ItemLink(entry, row)
    local link, quality = self.deps.itemLink(entry.itemID or 0)
    if type(row) == "table" and type(row.itemLink) == "string" then
        link = row.itemLink
    end
    if not link then
        return nil
    end
    if link:find("^|c") then
        return link
    end
    local _, _, _, hex = ns.Kit.QualityColor(quality)
    return "|c" .. hex .. link .. "|r"
end

local function quoteText(self, buy)
    local link = self:_ItemLink(buy.entry, buy.row)
    buy.linkMissing = link == nil
    local lines = {
        string.format("Buy %d x %s", buy.quantity, link or self:_ItemName(buy.entry)),
        string.format("Unit price: %s   Total: %s", money(buy.unit), money(buy.total)),
    }
    if buy.isItem then
        lines[1] = string.format("Buy one stack: %d x %s", buy.quantity, link or self:_ItemName(buy.entry))
        local owner, left = buy.row.owner, ns.Flavour and ns.Flavour.hasCommodityMarket == false
            and TIME_LEFT[buy.row.timeLeft or 0] or nil
        if owner or left then
            lines[#lines + 1] = string.format("Seller: %s   Time left: %s", owner or "?", left or "?")
        end
        lines[#lines + 1] = "Available: " .. ns.BuyingPlan.AvailableText(buy.stacks or 1, buy.quantity)
        if self.boxNote then
            table.insert(lines, 1, self.boxNote)
        end
    end
    if not buy.isItem and buy.left then
        lines[#lines + 1] = "Quote time left: " .. buy.left .. " s"
    end
    local limit = nil
    if not buy.entry.noMax then
        limit = (buy.entry.maxPrice or 0) * buy.quantity
    end
    local over = limit ~= nil and buy.total > limit
    if over then
        lines[#lines + 1] = "Above your max price: " .. money(limit)
    end
    if buy.jump then
        lines[#lines + 1] = string.format("Price jumps from %s to %s (+%.0f%%)", money(buy.jump.prev),
            money(buy.unit), buy.jump.percent)
    end
    return table.concat(lines, "\n"), over, buy.jump ~= nil
end

-- Show the confirm box with the server quote.
function Tab:_ShowConfirm()
    local buy = self.buy
    if not buy then
        return
    end
    local text, over, jumped = quoteText(self, buy)
    -- A link that is not loaded shows the plain name. Draw the box again when the item data may have come.
    if buy.linkMissing and (buy.linkTries or 0) < 5 and not buy.linkWait then
        buy.linkWait, buy.linkTries = true, (buy.linkTries or 0) + 1
        self.deps.after(1, function()
            buy.linkWait = false
            if self.buy == buy and buy.phase == "quoted" then
                self:_ShowConfirm()
            end
        end)
    end
    local preview = buy.phase == "preview"
    if preview then
        text = text .. "\nThis is an estimate. Get the quote first."
    end
    local yes = preview and "Get quote" or (over and "Buy anyway" or "Confirm")
    if buy.isItem then
        yes = self.chain and "Buy next" or "Buy"
    end
    makeDialog("FlipsideBuyConfirm"):Open(preview and "Next purchase" or "Confirm purchase", text, {
        yes = yes, no = "Cancel", red = over or jumped, keep = true,
        onYes = function()
            if preview then
                if not self:_RequestQuote(buy) then
                    self:_CancelQuote("the quote was refused")
                end
            else
                self:_Confirm()
            end
        end,
        onNo = function()
            self.continueKey, self.chain, self.chainGroup = nil, nil, nil
            self:_CancelQuote("cancelled")
        end,
    })
end

-- Show the time left of the quote each second until the quote ends.
function Tab:_TickQuote(buy)
    self.deps.after(1, function()
        if self.buy ~= buy or buy.phase ~= "quoted" then
            return
        end
        local left = self.deps.client.QuoteSecondsLeft()
        if left == 0 then
            self:_CancelQuote("the quote ended")
            return
        end
        buy.left = left
        self:_ShowConfirm()
        self:_TickQuote(buy)
    end)
end

-- The server quote came: show it in the confirm box.
function Tab:_OnQuote(unit, total)
    local buy = self.buy
    if not buy or buy.isItem or (buy.phase ~= "quoting" and buy.phase ~= "quoted") then
        return
    end
    local first = buy.phase == "quoting"
    buy.phase = "quoted"
    buy.unit, buy.total = unit, total
    buy.left = self.deps.client.QuoteSecondsLeft()
    self:_Say("")
    self:_ShowConfirm()
    if first then
        self:_TickQuote(buy)
    end
    self:_Update()
end

function Tab:_OnQuoteUnavailable()
    local buy = self.buy
    if buy and not buy.isItem and (buy.phase == "quoting" or buy.phase == "quoted") then
        self:_CancelQuote("the price is not available")
        self:_Refresh(buy.entry)
    end
end

-- Close the confirm box and stop the move to the next row. A purchase in flight stays.
function Tab:_CloseConfirm()
    self.continueKey, self.chain, self.boxNote, self.chainGroup = nil, nil, nil, nil
    if dialogs.FlipsideBuyConfirm then
        dialogs.FlipsideBuyConfirm:Close()
    end
end

-- Cancel an open quote or confirm box. A purchase in flight stays.
function Tab:_CancelQuote(why)
    local buy = self.buy
    if not buy or buy.phase == "confirming" then
        self:_CloseConfirm()
        return
    end
    self.continueKey, self.chain, self.boxNote, self.chainGroup = nil, nil, nil, nil
    self.buy = nil
    if dialogs.FlipsideBuyConfirm then
        dialogs.FlipsideBuyConfirm:Close()
    end
    if not buy.isItem then
        pcall(self.deps.client.CancelCommodityPurchase)
    end
    self.deps.log:Add(buy.entry, "buy cancelled", why)
    self:_Say(why)
    self:_Update()
end

-- Ask the AH for the rows of the item again, without a log line. It waits for the ready event or a retry.
-- range = { from, to } reads only these pages again (see _Start).
function Tab:_Refresh(entry, range)
    self.refreshEntry, self.refreshRange = entry, range
    if self.pending then
        return
    end
    local status, text = self:_Start(entry, true, range)
    if status == "wait" then
        self:_Say(text)
        self.deps.after(RETRY_SECONDS, function()
            if self.refreshEntry == entry then
                self:_Refresh(entry, range)
            end
        end)
        return
    end
    self.refreshEntry, self.refreshRange = nil, nil
end

-- Make the page of the next stack the page that the client list shows: a buy click needs that list. The selection
-- of a group and the end of a read call this. It reads one page and returns true, or returns false.
function Tab:_EnsureLive(entry)
    if self.livePage == nil or self.buy or self.pending or entry.key ~= self.selectedKey then
        return false
    end
    local _, _, _, reason, cover = self:_NextBuy()
    local ready = reason == nil or reason == "waiting for the Auction House"
    local row = ready and cover and cover.isItem and firstFree(cover.last) or nil
    if not (row and row.page) or row.page == self.livePage then
        return false
    end
    self:_Refresh(entry, { from = row.page, to = row.page })
    self:_Update()
    return true
end

-- Click 2: buy at the quote. Call it only from a click.
function Tab:_Confirm()
    local buy = self.buy
    if not buy or buy.phase ~= "quoted" then
        return
    end
    local client = self.deps.client
    buy.phase = "confirming"
    log("info", "buy click: item %s, quantity %s, total %s, %s", buy.itemID, buy.quantity, buy.total,
        buy.isItem and "item auction" or "commodity")
    -- The box stays open after the buy and shows the next row (see _ContinueBuy).
    self.continueKey = buy.entry.key
    self.chain, self.boxNote = true, nil
    if buy.isItem then
        self.chainGroup, self.chainReads = ns.BuyingPlan.ChainKey(buy.row), 0
    end
    local ok, err
    if buy.isItem then
        -- The list indexes shift after a buy. Find an identical auction in the list again before the call.
        local index = self:_Refind(buy)
        if not index then
            self:_Fail(buy, "the auction is gone")
            return
        end
        buy.auctionID = index
    end
    if buy.isItem then
        ok, err = pcall(client.BuyItemAuction, buy.auctionID, buy.total)
    else
        ok, err = pcall(client.ConfirmCommodityPurchase, buy.itemID, buy.quantity)
    end
    if not ok then
        self:_Fail(buy, tostring(err), true)
        return
    end
    self:_Say("buying " .. self:_ItemName(buy.entry))
    self.deps.after(CONFIRM_WAIT, function()
        if self.buy == buy and buy.phase == "confirming" then
            self:_Fail(buy, "no response")
        end
    end)
    self:_Update()
end

-- The index in the current list of an auction like buy.row (same item, stack size, buyout and seller), or nil.
-- It never gives your own auction or an auction of another price or stack size. The shown auction comes first.
function Tab:_Refind(buy)
    local found
    for _, row in ipairs(self.deps.client.LiveRows(buy.itemID) or {}) do
        if not isOwn(row) and sameAuction(row, buy.row) then
            if row.auctionID == buy.row.auctionID then
                return row.auctionID
            end
            found = found or row.auctionID
        end
    end
    return found
end

function Tab:_Succeed(buy)
    self.buy = nil
    self.boxNote = nil
    local run = self:_Run(buy.entry)
    -- A level that is taken in part still has units, so only a whole level moves the run on.
    if buy.complete ~= false then
        run.lastPrice = buy.level.unitPrice
    end
    run.bought = run.bought + buy.quantity
    -- A buy changes the list: the failed auctions (list places) of before are not valid any more.
    run.dropped, run.dropWatch = nil, nil
    log("info", "bought %s of item %s, total %s", buy.quantity, buy.itemID, buy.total)
    self.deps.log:Add(buy.entry, string.format("bought %d at %s", buy.quantity, money(buy.level.unitPrice)),
        "total " .. money(buy.total))
    self:_Say("bought " .. buy.quantity .. " x " .. self:_ItemName(buy.entry))
    self:_Refresh(buy.entry, buy.isItem and pageRange(buy.level) or nil)
    self:_AwaitRows()
    self:_Update()
end

-- Wait for the new rows of a buy. If no search for this item is on its way, close the box.
function Tab:_AwaitRows()
    if self.continueKey then
        local waiting = (self.pending and self.pending.entry.key == self.continueKey)
            or (self.pending == nil and self.refreshEntry ~= nil)
        if not waiting then
            self:_CloseConfirm()
        end
    end
end

-- An item stack group: the box shows that no stack is left. Only Close works.
function Tab:_ShowEnd(reason)
    local text = "No more stacks of this item"
    if reason and reason ~= "nothing left to buy" then
        text = text .. "\n" .. reason
    end
    if self.boxNote then
        text = self.boxNote .. "\n" .. text
    end
    self.continueKey, self.boxNote, self.chainGroup = nil, nil, nil
    local box = makeDialog("FlipsideBuyConfirm")
    box:Open("Confirm purchase", text, {
        yes = "Buy next", no = "Close",
        onNo = function()
            self.chain = nil
        end,
    })
    box.yesButton:SetEnabled(false)
    self:_Update()
end

-- The new rows came after an item buy. Show the next stack of the group in the open box, or the end.
-- The next stack is an identical one: same item, seller, buyout and stack size. Its page must be the page of the
-- client list, so the box may first read that page. This only shows the stack; the buy needs a click.
function Tab:_ContinueItem(key)
    local entry = self:_Selected()
    if self.dryRun then
        self:_CloseConfirm()
        return
    end
    local done = self.results[key]
    local rows = done and done.rows or {}
    local levels = self:_Levels(rows)
    -- The same stack (buyout and stack size) comes first. If none is left, Buy next goes on with the next cheapest
    -- stack of the item.
    local level = chainLevel(levels, self.chainGroup)
    local identical = level ~= nil
    if not level then
        local run = self.run
        level = nextAuction(levels, run and run.key == key and run.lastPrice or nil)
    end
    local tail = rows[#rows]
    local atTail = level ~= nil and withinMax(entry, level.unitPrice) and tail ~= nil
        and level.unitPrice >= tail.unitPrice
    if done and done.more and not identical and (not level or atTail) then
        -- The loaded pages have no stack left, or the next stack is at the price of the last row: the next page may
        -- hold a cheaper or an identical one. The result comes back here.
        self.continueKey = key
        self:_Refresh(entry, { from = done.more.next, to = done.more.next, loadMore = true })
        return
    end
    local row = level and firstFree(level) or nil
    if not row then
        self:_Say("No more stacks of this item")
        self:_ShowEnd()
        return
    end
    self.chainGroup = ns.BuyingPlan.ChainKey(row)
    if row.page and row.page ~= self.livePage and (self.chainReads or 0) < MAX_CHAIN_READS then
        -- Wait for the page of the next stack. The result comes back here.
        self.chainReads = (self.chainReads or 0) + 1
        self.continueKey = key
        self:_Refresh(entry, { from = row.page, to = row.page })
        return
    end
    self.levelSel = level.id
    self:BuyNext()
    -- A refusal leaves no open buy: the box shows the end with the reason.
    if not self.buy then
        local _, _, _, reason = self:_NextBuy()
        if reason == "waiting for the Auction House" then
            -- The throttle is not ready: the box waits and goes on at the ready event (see _OnReady).
            self.chainRetry = key
            self:_Say(reason)
            return
        end
        self:_ShowEnd(reason)
    end
end

-- The new rows came after a buy. Show the next row in the open confirm box, or close the box.
-- This only shows the row; the buy needs a click on Confirm.
function Tab:_ContinueBuy()
    local key = self.continueKey
    self.continueKey = nil
    local box = dialogs.FlipsideBuyConfirm
    if not key or key ~= self.selectedKey or not (box and box:IsShown()) then
        self:_CloseConfirm()
        return
    end
    if self.chainGroup then
        self:_ContinueItem(key)
        return
    end
    -- The selection moves to the row in the box.
    self.levelSel = nil
    local _, _, _, reason, cover = self:_NextBuy()
    if reason or self.dryRun then
        self:_CloseConfirm()
        self:_Say(reason or "")
        self:_Update()
        return
    end
    self.levelSel = levelId(cover.last)
    self.previewQuote = true
    self:BuyNext()
    self.previewQuote = nil
    -- A price jump warning or a refusal leaves no open buy: close the box.
    if not self.buy then
        self:_CloseConfirm()
    end
end

local function countSame(rows, row)
    local count = 0
    for _, other in ipairs(rows) do
        if sameAuction(other, row) then
            count = count + 1
        end
    end
    return count
end

-- True if the row is the failed auction: same list place (auction ID and page) and the same stack.
local function isFailed(row, failed)
    return row.auctionID == failed.id and (row.page or 0) == (failed.page or 0) and sameAuction(row, failed.row)
end

-- Items: remove the auctions that failed from fresh rows. Only the failed auction goes (by auction ID and page), not
-- an identical stack. An auction that failed and is still in the list stays out of it, so Buy next does not offer it
-- again. A gone auction needs no removal. A successful buy or a new search of the user clears the list of the failed.
function Tab:_DropKnown(entry, rows)
    local run = self.run
    if not (run and run.key == entry.key) or (rows[1] ~= nil and rows[1].isCommodity ~= false) then
        return rows
    end
    local function without(list, failed)
        local out = {}
        for _, other in ipairs(list) do
            if not isFailed(other, failed) then
                out[#out + 1] = other
            end
        end
        return out
    end
    for _, failed in ipairs(run.dropped or {}) do
        rows = without(rows, failed)
    end
    local watch = run.dropWatch
    run.dropWatch = nil
    if watch and countSame(rows, watch.row) >= watch.before then
        local out = without(rows, watch)
        if #out < #rows then
            run.dropped = run.dropped or {}
            run.dropped[#run.dropped + 1] = watch
            rows = out
        end
    end
    return rows
end

-- drop is true if the auction can stay in the list after the failure (TBC: it must not come up again).
function Tab:_Fail(buy, reason, drop)
    local each = buy.isItem and self.continueKey ~= nil
    if not each then
        self:_CloseConfirm()
    end
    self.buy = nil
    log("warn", "buy of item %s failed: %s", buy.itemID, reason)
    self.deps.log:Add(buy.entry, "buy failed", reason)
    self:_Say("buy failed: " .. reason)
    if each then
        -- The box stays open with the error. The fresh rows give the next auction.
        self.boxNote = "Error: " .. reason
        local done = self.results[buy.entry.key]
        if drop and done then
            self:_Run(buy.entry).dropWatch = {
                row = buy.row, id = buy.auctionID, page = buy.row.page, before = countSame(done.rows, buy.row),
            }
        end
    end
    self:_Refresh(buy.entry, buy.isItem and pageRange(buy.level) or nil)
    if each then
        self:_AwaitRows()
    end
    self:_Update()
end

function Tab:_OnCommodityResult(ok)
    local buy = self.buy
    if buy and buy.phase == "confirming" and not buy.isItem then
        if ok then
            self:_Succeed(buy)
        else
            self:_Fail(buy, "the server refused the purchase")
        end
    end
end

function Tab:_OnItemCompleted(auctionID)
    local buy = self.buy
    if buy and buy.phase == "confirming" and buy.isItem and auctionID == buy.auctionID then
        self:_Succeed(buy)
    end
end

function Tab:_OnItemError(code)
    local buy = self.buy
    if buy and buy.phase == "confirming" and buy.isItem then
        self:_Fail(buy, "error " .. tostring(code), true)
    end
end

local function setColor(label, grey)
    if grey then
        label:SetTextColor(0.5, 0.5, 0.5)
    else
        label:SetTextColor(1, 1, 1)
    end
end

local ROW_HEIGHT = 22
local TREE_INDENT = 14
local NAME_WIDTH = 140
local PRICE_WIDTH = 96
local NONE_ID = "none"
local BASE_GROUP = 1

-- Build the tree nodes from the entries. Items first, then the subgroups; an empty group does not show.
-- An item with no group goes to the last node "Not in a group".
-- Group node: { id = "g<ID>", kind = "group", text, children }.
-- Item node: { id = "i<key>", kind = "item", entry, text }.
function BuyingTab.BuildNodes(rules, entries, nameOf)
    local byGroup, placed = {}, {}
    for _, entry in ipairs(entries) do
        local groupID = entry.groupID or BASE_GROUP
        byGroup[groupID] = byGroup[groupID] or {}
        table.insert(byGroup[groupID], entry)
    end
    local function itemNodes(groupID)
        local nodes = {}
        for _, entry in ipairs(byGroup[groupID] or {}) do
            placed[entry] = true
            nodes[#nodes + 1] = { id = "i" .. entry.key, kind = "item", entry = entry, text = nameOf(entry) }
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
        return { id = "g" .. groupID, kind = "group", text = tostring(rules:Name(groupID)), children = children }
    end
    local roots = {}
    for _, childID in ipairs(rules:Children(BASE_GROUP)) do
        local node = build(childID)
        if node then
            roots[#roots + 1] = node
        end
    end
    local loose = itemNodes(BASE_GROUP)
    for _, entry in ipairs(entries) do
        if not placed[entry] then
            placed[entry] = true
            loose[#loose + 1] = { id = "i" .. entry.key, kind = "item", entry = entry, text = nameOf(entry) }
        end
    end
    if #loose > 0 then
        roots[#roots + 1] = { id = NONE_ID, kind = "group", text = "Not in a group", children = loose }
    end
    return roots
end

local function makeItemParts(row)
    local Kit = ns.Kit
    local parts = {
        icon = row:CreateTexture(nil, "ARTWORK"),
        price = Kit.Label(row, "", "highlight"),
    }
    parts.icon:SetSize(16, 16)
    parts.price:SetWidth(PRICE_WIDTH)
    parts.price:SetJustifyH("RIGHT")
    parts.remove = Kit.IconButton(row, "close", nil, "Remove from the list")
    parts.remove:SetSize(16, 16)
    parts.remove:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    return parts
end

-- Draw one tree row: a group (toggle and name) or an item (icon, name and max price).
function Tab:_InitTreeRow(row, node, depth, isCollapsed, hasChildren)
    local parts = row.parts
    if not parts then
        parts = makeItemParts(row)
        row.parts = parts
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
    row.selection:SetShown(node.kind == "item" and tree.selected ~= nil and tree.selected == node.id)
    row.label:ClearAllPoints()
    row.label:SetJustifyH("LEFT")
    if row.label.SetWordWrap then
        row.label:SetWordWrap(false)
    end
    if node.kind == "group" then
        -- A click on a group only collapses or expands it.
        row:SetScript("OnClick", function()
            tree:SetCollapsed(node.id, not isCollapsed)
        end)
        parts.icon:Hide()
        parts.price:SetText("")
        parts.remove:Hide()
        row.label:SetWidth(NAME_WIDTH + PRICE_WIDTH)
        row.label:SetPoint("LEFT", row.toggle, "RIGHT", 2, 0)
        row.label:SetText(node.text)
        row.label:SetTextColor(1, 0.82, 0)
        return
    end
    local entry = node.entry
    local _, icon = self.deps.itemInfo(entry.itemID or 0)
    parts.icon:SetTexture(icon)
    parts.icon:ClearAllPoints()
    parts.icon:SetPoint("LEFT", row.toggle, "RIGHT", 2, 0)
    parts.icon:Show()
    row.label:SetWidth(math.max(20, NAME_WIDTH - (depth - 1) * TREE_INDENT))
    row.label:SetPoint("LEFT", parts.icon, "RIGHT", 4, 0)
    row.label:SetText(node.text)
    if node.id == tree.selected then
        row.label:SetTextColor(1, 0.82, 0)
    else
        row.label:SetTextColor(1, 1, 1)
    end
    local removable = self.source == "lists" and entry.listIndex ~= nil
    parts.remove:SetShown(removable)
    parts.remove:SetScript("OnClick", function()
        self:RemoveListItem(entry.listIndex)
    end)
    parts.price:ClearAllPoints()
    parts.price:SetPoint("RIGHT", row, "RIGHT", removable and -20 or -4, 0)
    if entry.noMax then
        parts.price:SetText("no max")
        setColor(parts.price, false)
    elseif entry.maxPrice then
        parts.price:SetText(money(entry.maxPrice))
        setColor(parts.price, false)
    else
        parts.price:SetText(entry.reason or "no data")
        setColor(parts.price, true)
    end
end

-- The tree id of an entry.
local function nodeID(key)
    return key and ("i" .. key) or nil
end

-- A click on an item selects it and starts its search at once. A busy search holds the new one until it ends.
function Tab:_OnTreeSelect(node)
    if node.kind ~= "item" then
        return
    end
    self:Select_(node.entry.key)
    if not self.deps.client.CanLiveSearch() then
        return
    end
    if self.pending and not self:_CancelRead("read stopped") then
        self.nextSearchKey = node.entry.key
        self:_Say("search queued: " .. self:_ItemName(node.entry))
        return
    end
    self.nextSearchKey = nil
    self:Search()
end

-- Start the search that a click held while another search ran.
function Tab:_RunHeldSearch()
    local key = self.nextSearchKey
    self.nextSearchKey = nil
    if key and key == self.selectedKey and not self.pending then
        self:Search()
    end
end

-- The columns of the price level list. The header, the totals row and the row cells use the same definition.
-- Each column takes an equal share of the width and the text is right-aligned.
-- The Available column shows "50 stacks of 1" for a stack group (an item), and "x5" for a commodity level.
-- The seller and the time left show only for stack groups (the time left on TBC only).
local LEVEL_COLUMNS = {
    { key = "unitPrice", title = "Unit Price", width = { share = 1 }, number = true, format = money },
    { key = "stackPrice", title = "Stack Price", width = { share = 1 }, number = true,
        format = function(value)
            return value and money(value) or ""
        end },
    { key = "quantity", title = "Available", width = { share = 1 }, number = true,
        format = function(value, data)
            if data and data.stacks then
                return ns.BuyingPlan.AvailableText(data.stacks, data.stackSize)
            end
            return "x" .. tostring(value)
        end },
    { key = "owner", title = "Seller", width = { share = 1 }, hidden = true,
        format = function(value)
            return value or ""
        end },
    { key = "timeLeft", title = "Time left", width = { share = 1 }, hidden = true,
        format = function(value)
            return TIME_LEFT[value or 0] or ""
        end },
}
local LEVEL_OPTIONS = { gap = 6 }
local STACK_COLUMN, QUANTITY_COLUMN = LEVEL_COLUMNS[2], LEVEL_COLUMNS[3]
local OWNER_COLUMN, TIME_COLUMN = LEVEL_COLUMNS[4], LEVEL_COLUMNS[5]
-- The share of the Available column when it shows the text of a stack group.
local WIDE_SHARE = 1.6

local function initRowsRow(row, data)
    local Kit = ns.Kit
    local cells = row.cells
    if not cells then
        cells = Kit.CreateColumnCells(row, LEVEL_COLUMNS, LEVEL_OPTIONS)
        row.cells = cells
    end
    local hiddenNow = tostring(STACK_COLUMN.hidden) .. tostring(OWNER_COLUMN.hidden) .. tostring(TIME_COLUMN.hidden)
        .. tostring(QUANTITY_COLUMN.width.share)
    if row.cellsHidden ~= hiddenNow then
        row.cellsHidden = hiddenNow
        Kit.LayoutColumnLabels(cells, row, LEVEL_COLUMNS, LEVEL_OPTIONS)
    end
    Kit.SetColumnCells(cells, LEVEL_COLUMNS, data)
    local grey = data.state ~= "buy"
    setColor(cells.unitPrice, grey)
    setColor(cells.stackPrice, grey)
    setColor(cells.quantity, grey)
end

-- Draw one price level row: the cells, the selection highlight and the click that selects the level.
function Tab:_InitLevelRow(row, data)
    initRowsRow(row, data)
    if not row.selection then
        row.selection = ns.Kit.SelectionTexture(row, self.skin)
    end
    local id = data.id or data.unitPrice
    local selected = self.levelSel ~= nil and self.levelSel == id
    row.selection:SetShown(selected)
    -- The rows that the next click buys get a fainter highlight. The selected row keeps the selection highlight.
    if not row.cover then
        row.cover = ns.Kit.SelectionTexture(row, self.skin, 0.4)
    end
    row.cover:SetShown(not selected and self.covered ~= nil and self.covered[id] == true)
    row:SetScript("OnClick", function()
        self:SelectLevel(id)
    end)
end

-- Update the source buttons, the search list controls and the place of the list.
function Tab:_UpdateLeft()
    local ui, lists = self.ui, self.deps.searchLists
    local isLists = self.source == "lists" and lists ~= nil and not self.searchResults
    local isVendor = self.source == "vendor" and self.deps.scanStore ~= nil and not self.searchResults
    ui.sourceTabs.buttons[2]:SetShown(lists ~= nil)
    ui.sourceTabs.buttons[3]:SetShown(self.deps.scanStore ~= nil)
    self.syncingTabs = true
    ui.sourceTabs:Select(isLists and "lists" or (isVendor and "vendor" or "groups"))
    self.syncingTabs = false
    for _, control in ipairs(ui.listControls) do
        control:SetShown(isLists)
    end
    for _, control in ipairs(ui.vendorControls) do
        control:SetShown(isVendor)
    end
    if isVendor then
        local state = self:_VendorState()
        ui.vendorStatus:SetText(self.vendorError and ("Formula error: " .. self.vendorError) or state or "")
        setColor(ui.vendorStatus, false)
        if self.vendorError then
            ui.vendorStatus:SetTextColor(RED[1], RED[2], RED[3])
        end
    end
    if isLists then
        local items = {}
        for _, saved in ipairs(lists:List()) do
            items[#items + 1] = { value = saved.id, text = saved.name .. " (" .. saved.count .. ")" }
        end
        ui.picker:SetItems(items)
        ui.picker:SetValue(self.listID)
        ui.rename:SetEnabled(self.listID ~= nil)
        ui.delete:SetEnabled(self.listID ~= nil)
    end
    local mode = isLists and "lists" or (isVendor and "vendor" or "groups")
    if self.placedFor ~= mode then
        self.placedFor = mode
        ui.tree.frame:ClearAllPoints()
        local top = ({ lists = 122, vendor = 94, groups = 44 })[mode] + SEARCH_SHIFT
        ui.tree.frame:SetPoint("TOPLEFT", ui.leftTop, "TOPLEFT", 0, -top)
        ui.tree.frame:SetPoint("BOTTOMLEFT", ui.content, "BOTTOMLEFT", 0, 0)
    end
end

-- Update the buttons, the list and the right side from the state.
function Tab:_Update()
    local ui = self.ui
    if not ui then
        return
    end
    self:_UpdateLeft()
    local client = self.deps.client
    local canSearch = client.CanLiveSearch()
    local selected = self:_Selected()
    ui.stop:SetShown(self.queue ~= nil or self:_Reading())
    if self.searchResults or self.source == "vendor" then
        -- The results and the vendor flips are a flat list of items, with no group nodes.
        self.nodes = {}
        for index, entry in ipairs(self.list) do
            self.nodes[index] = { id = "i" .. entry.key, kind = "item", entry = entry, text = self:_ItemName(entry) }
        end
    else
        self.nodes = BuyingTab.BuildNodes(self.deps.rules, self.list, function(entry)
            return self:_ItemName(entry)
        end)
    end
    ui.searchClear:SetEnabled(self.searchResults ~= nil)
    ui.tree.selected = nodeID(self.selectedKey)
    ui.tree:SetNodes(self.nodes)
    if not selected then
        local text = canSearch and "" or "Live search is not available."
        if self.source == "lists" and not self.listID then
            text = "Make or pick a search list, then add items."
        end
        if self.source == "vendor" then
            text = self:_VendorState() or text
        end
        if self.searchResults then
            text = #self.list == 0 and "no items found" or "Pick an item. A searched item has no max price."
        end
        ui.summary:SetText(text)
        ui.buyNext:SetText("Buy")
        ui.buyNext:SetEnabled(false)
        ui.amount:SetEnabled(true)
        self:_FillAmount(nil)
        ui.totals:Hide()
        ui.loadMore:Hide()
        self.covered = {}
        ui.rowsList:SetData({})
        return
    end
    local done = self.results[selected.key]
    local more = done and done.more
    ui.loadMore:SetShown(more ~= nil)
    if more then
        ui.loadMore:SetText(string.format("Load more (%d/%d)", more.next, more.total))
        ui.loadMore:SetEnabled(self.pending == nil and self.buy == nil)
    end
    local levels = done and self:_Levels(done.rows) or {}
    local described = BuyingTab.DescribeLevels(selected, levels, selected.showAboveMax)
    -- The selection stays on the same unit price if the level is still in the list. Else it clears.
    if self.levelSel then
        local shown = false
        for _, data in ipairs(described) do
            shown = shown or (data.id or data.unitPrice) == self.levelSel
        end
        if not shown then
            self.levelSel = nil
        end
    end
    local _, nextLevel, _, reason, cover = self:_NextBuy()
    local verb = "Buy"
    -- The amount box does not apply to an item: an item buy is one stack.
    local isItem = done ~= nil and done.rows[1] ~= nil and done.rows[1].isCommodity == false
    ui.amount:SetEnabled(not isItem)
    self.covered = (reason == nil and cover) and cover.covered or {}
    -- The line shows only the reason why the button is off.
    local text = reason and (verb .. ": " .. reason) or ""
    if self.searchResults then
        text = (text ~= "" and (text .. ". ") or "") .. "No max price for a searched item."
    end
    ui.summary:SetText(text)
    self:_FillAmount(cover)
    ui.totals:SetShown(done ~= nil)
    local totals = BuyingTab.DescribeTotals(described)
    ns.Kit.SetColumnCells(ui.totalCells, LEVEL_COLUMNS,
        { unitPrice = totals.cost, stackPrice = totals.cost, quantity = totals.quantity })
    -- The label is in the same text as the cost, so the two never overlap.
    -- With no commodity market (TBC) the cost is a sum of stack prices, so it sits under the Stack Price column.
    local costKey = hasCommodityMarket() and "unitPrice" or "stackPrice"
    ui.totalCells.unitPrice:SetText("")
    ui.totalCells.stackPrice:SetText("")
    ui.totalCells[costKey]:SetText("Total  " .. money(totals.cost))
    ui.buyNext:SetText(verb)
    ui.buyNext:SetEnabled(nextLevel ~= nil and reason == nil)
    self:_ShowColumns(levels)
    ui.rowsList:SetData(described)
end

-- Show or hide the Stack Price column and the Seller and Time left columns (header and cells). A commodity level has
-- no stack price. levels are the levels of the shown item.
function Tab:_ShowColumns(levels)
    local Kit, ui = ns.Kit, self.ui
    local hide = levels[1] ~= nil and BuyingTab.StackSize(levels[1]) == nil
    local groups = levels[1] ~= nil and levels[1].stacks ~= nil
    local sellers = false
    for _, level in ipairs(levels) do
        sellers = sellers or level.owner ~= nil or level.own
    end
    local hideOwner = not (groups and sellers)
    local hideTime = not (groups and not hasCommodityMarket())
    local share = groups and WIDE_SHARE or 1
    if (STACK_COLUMN.hidden or false) == hide and (OWNER_COLUMN.hidden or false) == hideOwner
        and (TIME_COLUMN.hidden or false) == hideTime and QUANTITY_COLUMN.width.share == share then
        return
    end
    STACK_COLUMN.hidden, OWNER_COLUMN.hidden, TIME_COLUMN.hidden = hide, hideOwner, hideTime
    QUANTITY_COLUMN.width.share = share
    local edge = ui.rowsList.contentInsets or { left = 0, right = 0 }
    local options = { gap = LEVEL_OPTIONS.gap, left = edge.left, right = edge.right }
    Kit.LayoutColumnLabels(ui.levelHeader.labels, ui.levelHeader.frame, LEVEL_COLUMNS, options)
    Kit.LayoutColumnLabels(ui.totalCells, ui.totals, LEVEL_COLUMNS, options)
end

-- Show the units and the total price of the purchase in the amount box and next to it.
-- The text that the user typed stays.
function Tab:_FillAmount(cover)
    local ui = self.ui
    if not self.amountEdit then
        self.fillingAmount = true
        ui.amount:SetText(cover and tostring(cover.quantity) or "")
        self.fillingAmount = false
    end
    ui.amountTotal:SetText(cover and money(cover.cost) or "")
end

function Tab:IsActive()
    return self.active
end

-- Hide the panel; the host or Blizzard's own code takes over.
function Tab:Deselect()
    self:_CancelQuote("the tab was left")
    self:_CancelRead("read stopped")
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
    local lists = self.deps.searchLists
    local request = lists and lists.Requested and lists:Requested()
    if request then
        lists:ClearRequested()
        self:SelectList(request.id)
        if request.autoSearch and self.deps.client.CanLiveSearch() then
            self:SearchAll()
        end
        return
    end
    self:RefreshList()
end

-- The source buttons and the search list controls above the list.
function Tab:_BuildLeft(content)
    local Kit = ns.Kit
    local ui = self.ui
    -- The source tabs sit on the top edge of the list (the host is 30 px high, the list starts below it).
    local function place(widget, x, y)
        widget:SetPoint("TOPLEFT", ui.leftTop, "TOPLEFT", x, y)
        return widget
    end
    local host = place(CreateFrame("Frame", nil, content), 0, -14 - SEARCH_SHIFT)
    host:SetSize(LIST_WIDTH, 30)
    local flavour = ns.Flavour or {}
    local sources = { { "groups", "Groups" }, { "lists", "Lists" }, { "vendor", "Vendor" } }
    ui.sourceTabs = Kit.CreateTopTabs(host, sources, {
        template = flavour.topTabTemplate,
        tabPadding = flavour.topTabPadding,
        minTabWidth = flavour.topTabMinWidth,
        onSelect = function(key)
            if not self.syncingTabs then
                self:SetSource(key)
            end
        end,
    })
    ui.listControls = {}
    local function control(widget, x, y)
        ui.listControls[#ui.listControls + 1] = place(widget, x, y)
        return widget
    end
    ui.picker = control(Kit.Dropdown(content, 160, { onChange = function(id)
        self:SelectList(id)
    end }), 0, -44 - SEARCH_SHIFT)
    ui.newList = control(Kit.Button(content, "New", 50, function()
        self:NewList(ui.nameInput:GetText())
    end), 164, -44 - SEARCH_SHIFT)
    ui.rename = control(Kit.Button(content, "Rename", 64, function()
        self:RenameList(ui.nameInput:GetText())
    end), 218, -44 - SEARCH_SHIFT)
    ui.delete = control(Kit.Button(content, "Delete", 56, function()
        local saved = self.listID and self.deps.searchLists:Get(self.listID)
        if saved then
            Kit.Confirm("FLIPSIDE_DELETE_SEARCH_LIST", "Delete the search list " .. saved.name .. "?", function()
                self:DeleteList()
            end)
        end
    end), 286, -44 - SEARCH_SHIFT)
    ui.nameInput = control(Kit.Input(content, 250, nil, nil, { placeholder = "name of the list" }), 6,
        -72 - SEARCH_SHIFT)
    ui.itemInput = control(Kit.Input(content, 250, function(text)
        self:AddItem(text)
    end, nil, { placeholder = "item name, ID, link or key" }), 6, -98 - SEARCH_SHIFT)
    ui.addItem = control(Kit.Button(content, "Add", 50, function()
        self:AddItem(ui.itemInput:GetText())
    end), 262, -96 - SEARCH_SHIFT)
    -- The Vendor source: the max price formula and the state of the list.
    ui.vendorControls = {}
    local function vendorControl(widget, x, y)
        ui.vendorControls[#ui.vendorControls + 1] = place(widget, x, y)
        return widget
    end
    local function saveVendor(text)
        self:SetVendorFormula(text)
    end
    ui.vendorInput = vendorControl(Kit.Input(content, 340, saveVendor, saveVendor,
        { placeholder = "max price formula" }), 6, -46 - SEARCH_SHIFT)
    ui.vendorInput:HookScript("OnTextChanged", function(box, userInput)
        if userInput and self.ui then
            self.vendorError = self:_CheckVendorFormula(box:GetText():match("^%s*(.-)%s*$"))
            self:_UpdateLeft()
        end
    end)
    ui.vendorStatus = vendorControl(Kit.Label(content, "", "small"), 6, -70 - SEARCH_SHIFT)
    ui.vendorStatus:SetJustifyH("LEFT")
    ui.vendorStatus:SetWidth(LIST_WIDTH - 12)
    -- The name search row: find any item on the Auction House, also an item in no group.
    ui.searchInput = place(Kit.Input(content, 206, function(text)
        self:SearchName(text)
    end, nil, { placeholder = "search the Auction House by name" }), 6, -16)
    ui.searchButton = place(Kit.Button(content, "Search", 70, function()
        self:SearchName(ui.searchInput:GetText())
    end), 218, -14)
    ui.searchClear = place(Kit.Button(content, "Clear", 60, function()
        self:ClearSearch()
    end), 292, -14)
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
    ui.stop = place(Kit.Button(content, "Stop", 60, function()
        self:Stop()
    end), 268, 0)
    ui.message = place(Kit.Label(content, "", "small"), 0, -4)
    ui.message:SetJustifyH("LEFT")
    ui.message:SetWidth(260)
    ui.leftTop = CreateFrame("Frame", nil, content)
    ui.leftTop:SetSize(1, 1)

    local skin = ns.AuctionTabs and ns.AuctionTabs.Skin
    self.skin = skin
    ui.tree = Kit.CreateTree(content, { rowHeight = ROW_HEIGHT, inset = true, skin = skin,
        initRow = function(row, node, depth, isCollapsed, hasChildren)
            self:_InitTreeRow(row, node, depth, isCollapsed, hasChildren)
        end,
        onSelect = function(node)
            self:_OnTreeSelect(node)
        end })
    ui.content = content
    ui.tree.frame:SetPoint("TOPLEFT", ui.leftTop, "TOPLEFT", 0, -44 - SEARCH_SHIFT)
    ui.tree.frame:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    ui.tree.frame:SetWidth(LIST_WIDTH)
    self:_BuildLeft(content)
    self:_Say("")

    local rightX = LIST_WIDTH + padding
    ui.summary = place(Kit.Label(content, "", "small"), rightX, -4)
    ui.summary:SetJustifyH("LEFT")
    ui.summary:SetWidth(330)
    -- Shown only if sorted pages are not all read (TBC). It reads the next page of the item.
    ui.loadMore = Kit.Button(content, "Load more", 100, function()
        self:LoadMore()
    end)
    ui.loadMore:SetHeight(18)
    ui.loadMore:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    ui.loadMore:Hide()
    ui.rowsList = Kit.CreateList(content, { rowHeight = 18, inset = true, skin = skin, initRow = function(row, data)
        self:_InitLevelRow(row, data)
    end })
    ui.rowsList.frame:SetPoint("TOPLEFT", content, "TOPLEFT", rightX, -38)
    ui.rowsList.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 78)
    -- The column titles over the price level list.
    local edge = ui.rowsList.contentInsets or { left = 0, right = 0 }
    ui.levelHeader = Kit.CreateColumnHeader(content, LEVEL_COLUMNS,
        { gap = LEVEL_OPTIONS.gap, left = edge.left, right = edge.right })
    ui.levelHeader.frame:SetPoint("TOPLEFT", content, "TOPLEFT", rightX, -20)
    ui.levelHeader.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -20)
    ui.levelHeader.frame:SetHeight(18)
    -- The totals row: same columns as the list, below the list. It is not a list row, so it is not selectable.
    local options = { gap = LEVEL_OPTIONS.gap, left = edge.left, right = edge.right, role = "highlight" }
    ui.totals = CreateFrame("Frame", nil, content)
    ui.totals:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", rightX, 58)
    ui.totals:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 58)
    ui.totals:SetHeight(18)
    ui.totals:EnableMouse(true)
    ui.totalsBackground = ui.totals:CreateTexture(nil, "BACKGROUND")
    ui.totalsBackground:SetTexture(Kit.Theme.rowHighlight)
    ui.totalsBackground:SetBlendMode("ADD")
    ui.totalsBackground:SetAlpha(0.6)
    ui.totalsBackground:SetAllPoints(ui.totals)
    ui.totalCells = Kit.CreateColumnCells(ui.totals, LEVEL_COLUMNS, options)
    Kit.Tooltip(ui.totals, "Total to buy", { "All units and the cost of all price levels that you can buy.",
        "Your own levels and levels above the max price are not in the total." })
    ui.totals:Hide()
    ui.buyNext = Kit.Button(content, "Buy", 100, function()
        self:BuyNext()
    end)
    ui.buyNext:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", rightX, 0)
    -- The amount box: units to buy for a commodity. Empty means all units up to the level.
    ui.amountLabel = Kit.Label(content, "Amount", "small")
    ui.amountLabel:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", rightX, 34)
    ui.amount = Kit.Input(content, 70, nil, nil, { placeholder = "all" })
    ui.amount:SetNumeric(true)
    ui.amount:SetPoint("LEFT", ui.amountLabel, "RIGHT", 8, 0)
    ui.amount:HookScript("OnTextChanged", function(box)
        self:SetAmount(box:GetText())
    end)
    -- The total price of the purchase, on the right of the amount box.
    ui.amountTotal = Kit.Label(content, "", "highlight")
    ui.amountTotal:SetPoint("LEFT", ui.amount, "RIGHT", 10, 0)
    ui.buyNext:SetEnabled(false)
    ui.dryRun = Kit.Check(content, "Dry run", function(checked)
        self:SetDryRun(checked)
    end)
    ui.dryRun:SetPoint("LEFT", ui.buyNext, "RIGHT", 4, 0)
    ui.dryRun:SetChecked(self.dryRun)
    -- The jump label anchors to the end of the Dry run text, and the input anchors to the label.
    ui.jumpLabel = Kit.Label(content, "Jump warning %", "small")
    ui.jumpLabel:SetPoint("LEFT", ui.dryRun.Text or ui.dryRun, "RIGHT", ui.dryRun.Text and 14 or 70, 0)
    ui.jump = Kit.NumberInput(content, 36, { min = 1, max = 1000, hint = "1 - 1000", onChange = function(number)
        self:SetJumpPercent(number)
    end })
    ui.jump:SetPoint("LEFT", ui.jumpLabel, "RIGHT", 6, 0)
    ui.jump:SetJustifyH("CENTER")
    ui.jump:SetNumber(self:GetJumpPercent())
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
    local buyEvents = client.BuyEvents()
    if buyEvents then
        local function listen(event, fn)
            bus:Subscribe(event, OWNER, fn)
            self.events[#self.events + 1] = event
        end
        listen(buyEvents.priceUpdated, function(_, unit, total)
            self:_OnQuote(unit, total)
        end)
        listen(buyEvents.priceUnavailable, function()
            self:_OnQuoteUnavailable()
        end)
        listen(buyEvents.commoditySucceeded, function()
            self:_OnCommodityResult(true)
        end)
        listen(buyEvents.commodityFailed, function()
            self:_OnCommodityResult(false)
        end)
        listen(buyEvents.itemCompleted, function(_, auctionID)
            self:_OnItemCompleted(auctionID)
        end)
        listen(buyEvents.itemError, function(_, code)
            self:_OnItemError(code)
        end)
    end
    if self.deps.searchLists then
        bus:Subscribe("Flipside.SearchListOpen", OWNER, function(_, id, autoSearch)
            self:_OnOpenList(id, autoSearch)
        end)
        bus:Subscribe("Flipside.SearchListsChanged", OWNER, function()
            if self.source == "lists" then
                self:RefreshList()
            end
        end)
        self.events[#self.events + 1] = "Flipside.SearchListOpen"
        self.events[#self.events + 1] = "Flipside.SearchListsChanged"
    end
    -- A shift-click on an item link puts the link into the item box while it has focus.
    -- With no box in focus, the link becomes the name search (Tab:SearchLink).
    local function onLink(text)
        local ui = self.ui
        if ui and ui.itemInput and ui.itemInput:HasFocus() and type(text) == "string" then
            ui.itemInput:Insert(text)
        elseif type(text) == "string" then
            self:SearchLink(text)
        end
    end
    if hooksecurefunc and not self.linkHooked then
        self.linkHooked = true
        -- WoW: Forever calls ChatFrameUtil.InsertLink from HandleModifiedItemClick. ChatEdit_InsertLink is only an
        -- alias that was copied at load time, so each name needs its own hook. TBC has the global only.
        local frameUtil = _G.ChatFrameUtil
        if type(frameUtil) == "table" and type(frameUtil.InsertLink) == "function" then
            hooksecurefunc(frameUtil, "InsertLink", onLink)
        end
        if type(_G.ChatEdit_InsertLink) == "function" then
            hooksecurefunc("ChatEdit_InsertLink", onLink)
        end
    end
    local closeEvent = client.CloseEvent()
    if closeEvent then
        bus:Subscribe(closeEvent, OWNER, function()
            self:_CancelQuote("the Auction House closed")
        end)
        self.events[#self.events + 1] = closeEvent
    end
    local ready = client.ReadyEvent()
    if ready then
        bus:Subscribe(ready, OWNER, function()
            self:_OnReady()
        end)
        self.events[#self.events + 1] = ready
    end
    bus:Subscribe("ITEM_DATA_LOAD_RESULT", OWNER, function(_, itemID)
        self:_OnItemLoaded(itemID)
        self:_OnVendorItem(itemID)
    end)
    self.events[#self.events + 1] = "ITEM_DATA_LOAD_RESULT"
    if self.deps.scanStore then
        bus:Subscribe("Flipside.ScanFinished", OWNER, function()
            self:_OnVendorScan()
        end)
        self.events[#self.events + 1] = "Flipside.ScanFinished"
    end
    self:_Update()
end

-- Undo a failed Mount: hide the panel and keep no half-built state.
function Tab:Unmount()
    self:_CancelQuote("the tab was removed")
    self.vendorToken = self.vendorToken + 1
    if self.vendorJob and self.vendorJob.Cancel then
        self.vendorJob:Cancel()
    end
    self.vendorJob, self.vendorBuilding = nil, false
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
-- deps: bus, rules, formulaRun, after(seconds, fn); optional client, plan, log, itemInfo, db (the settings DB),
-- itemLink(itemID) (link, quality), scanStore, itemCache, lastScan() (time of the last full scan, and true if a
-- partial scan came after it) and runJob(name, fn) (the Vendor source),
-- searchLists, itemNameIndex, ahNameSearch, keyFor(link) and isAuctionHouseOpen()
-- (search lists and the item box).
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
        itemLink = deps.itemLink or defaultItemLink,
        requestItem = deps.requestItem or function(itemID)
            if C_Item and C_Item.RequestLoadItemDataByID then
                C_Item.RequestLoadItemDataByID(itemID)
            end
        end,
        db = deps.db,
        scanStore = deps.scanStore or nil,
        itemCache = deps.itemCache,
        lastScan = deps.lastScan,
        runJob = deps.runJob,
        searchLists = deps.searchLists or nil,
        itemNameIndex = deps.itemNameIndex,
        ahNameSearch = deps.ahNameSearch,
        keyFor = deps.keyFor,
        isAuctionHouseOpen = deps.isAuctionHouseOpen or function()
            return ns.IsAuctionHouseOpen ~= nil and ns.IsAuctionHouseOpen() == true
        end,
    }
    resolved.log = deps.log or resolved.plan.Log
    return setmetatable({
        deps = resolved, list = {}, results = {}, events = {}, active = false, token = 0, dryRun = false,
        source = "groups", amount = DEFAULT_AMOUNT, requested = {},
        vendorToken = 0, vendorWaiting = {},
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
