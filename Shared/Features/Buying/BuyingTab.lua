local _, ns = ...

-- The Buying tab of the Auction House: the shopping list, live searches and the buy of price levels.
-- Each protected call runs directly in a click handler of the tab or of its own dialogs (D26).
-- A host (ns.AuctionTabHost) owns the Blizzard frame and the tab button.
local BuyingTab = {}
ns.BuyingTab = BuyingTab

local OWNER = "Flipside.BuyingTab"
local SEARCH_TIMEOUT = 10
local RETRY_SECONDS = 5
local LIST_WIDTH = 380
local QUOTE_WAIT = 10
local CONFIRM_WAIT = 15
local DEFAULT_JUMP = 25
local JUMP_KEY = "buying.jumpPercent"
local RED = { 1, 0.2, 0.2 }

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

-- The text of the Status column. Only "Yours" and "Above max" show; a level to buy shows no text.
function BuyingTab.StatusText(state)
    if state == "own" then
        return "Yours"
    elseif state == "above" then
        return "Above max"
    end
    return ""
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
                stackPrice = BuyingTab.StackPrice(level),
            }
        end
    end
    return out
end
-- Build the summary lines of one evaluation. result is from BuyingPlan.Evaluate.
function BuyingTab.DescribeSummary(entry, result, rows)
    local lines = {}
    if entry.noMax then
        lines[1] = "no max price set"
    elseif entry.maxPrice then
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
            if not isOwn(row) and not entry.noMax and entry.maxPrice and row.unitPrice > entry.maxPrice then
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

local dialogs = {}

-- A small dialog with a text and two buttons, made from the Kit window. One dialog for each name.
-- dialog:Open(title, text, options): options.yes and options.no are the button labels, onYes and onNo run in the click.
-- Escape or the close button counts as "no". options.red shows the text in red.
local function makeDialog(name)
    if dialogs[name] then
        return dialogs[name]
    end
    local Kit = ns.Kit
    local pad = Kit.Theme.padding
    local dialog = Kit.CreateWindow(name, { width = 380, height = 190 })
    dialogs[name] = dialog
    dialog:SetFrameStrata("FULLSCREEN_DIALOG")
    dialog:SetToplevel(true)
    dialog.text = Kit.Label(dialog, "", "normal")
    dialog.text:SetPoint("TOPLEFT", dialog, "TOPLEFT", pad + 8, -40)
    dialog.text:SetWidth(380 - 2 * pad - 16)
    dialog.text:SetJustifyH("LEFT")
    local function press(key)
        local callback = dialog[key]
        dialog.onYes, dialog.onNo = nil, nil
        dialog:Hide()
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
        if self.SetTitle then
            self:SetTitle(title or "")
        end
        self.text:SetText(text or "")
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
    local name = self.deps.itemInfo(entry.itemID or 0)
    if entry.name and (not name or name:match("^item %d+$")) then
        return entry.name
    end
    return name
end

-- Build the list again: from the groups and the operations, or from the selected search list.
function Tab:RefreshList()
    local deps = self.deps
    local lists = deps.searchLists
    if self.source == "lists" then
        local saved = lists and self.listID and lists:Get(self.listID) or nil
        if not saved then
            self.listID = nil
        end
        self.list = saved and deps.plan.ListEntries(saved.items, {
            rules = deps.rules, formulaRun = deps.formulaRun, label = "Search list: " .. saved.name,
        }) or {}
    else
        self.list = deps.plan.ShoppingList({ rules = deps.rules, formulaRun = deps.formulaRun })
    end
    if self.selectedKey and not self:_Entry(self.selectedKey) then
        self.selectedKey = nil
    end
    self:_Update()
end

-- Show the groups ("groups") or the search lists ("lists") on the left side.
function Tab:SetSource(source)
    if source ~= "groups" and not (source == "lists" and self.deps.searchLists) then
        return false
    end
    self.source = source
    self.selectedKey = nil
    self.run = nil
    if source == "lists" and not self.listID then
        local first = self.deps.searchLists:List()[1]
        self.listID = first and first.id or nil
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
    self.listID = id
    self.source = "lists"
    self.selectedKey = nil
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
        self:_Say("searching the Auction House for the name")
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
        self.run = nil
    end
    self.selectedKey = key
    self:_Update()
end

-- Store and log the result of reading the rows of one item.
function Tab:_Finish(entry, rows, silent)
    local plan = self.deps.plan
    local result = plan.Evaluate(entry, rows)
    if not entry.itemID then
        result.stop = "no item id"
    end
    self.results[entry.key] = { rows = rows, result = result }
    if not silent then
        local decision, reason = BuyingTab.DescribeDecision(result)
        self.deps.log:Add(entry, decision, reason)
    end
    self:_Update()
end

-- Start the live search of one entry. silent keeps the result out of the log.
-- Returns "started", "skipped" or "wait" with a text.
function Tab:_Start(entry, silent)
    local client = self.deps.client
    if not (entry.maxPrice or entry.noMax) or not entry.itemID then
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
    self.pending = { entry = entry, itemID = entry.itemID, token = token, silent = silent }
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
    self:_Finish(pending.entry, self.deps.client.LiveRows(pending.itemID), pending.silent)
    self:_Say("")
    self:_Next()
end

function Tab:_OnReady()
    if self.queue and not self.pending then
        self:_Next()
    end
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

-- Find the level that Buy next buys. Returns entry, level, levels and a reason if the level cannot be bought.
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
        return entry, nil, nil, "a search is running"
    end
    local plan = self.deps.plan
    local levels = plan.PriceLevels(done.rows)
    local isItem = done.rows[1] ~= nil and done.rows[1].isCommodity == false
    local lastPrice = self.run and self.run.key == entry.key and self.run.lastPrice or nil
    local level = plan.NextLevel(levels, lastPrice, isItem)
    local reason
    if not (entry.maxPrice or entry.noMax) then
        reason = "no max price"
    elseif not level then
        reason = "nothing left to buy"
    elseif level.own then
        reason = "own listing"
    elseif not withinMax(entry, level.unitPrice) then
        reason = "above max price"
    elseif not self.dryRun and not self.deps.client.CanBuy() then
        reason = "buying is not available"
    elseif not self.deps.client.IsReady() then
        reason = "waiting for the Auction House"
    end
    return entry, level, levels, reason
end

-- Buy next. Call it only from the click of the button. Returns true, or false and a reason.
function Tab:BuyNext()
    local entry, level, levels, reason = self:_NextBuy()
    if reason then
        self:_Say(reason)
        return false, reason
    end
    if self.dryRun then
        self.deps.log:Add(entry, string.format("would buy %d at %s", level.quantity, money(level.unitPrice)),
            "dry run")
        return true
    end
    local run = self:_Run(entry)
    local prev = run.lastPrice or levels[1].unitPrice
    local percent = self:GetJumpPercent()
    local check = self.deps.plan.JumpCheck(prev, level.unitPrice, percent)
    if check.jump then
        makeDialog("FlipsideBuyJump"):Open("Price jump",
            string.format("Price jumps from %s to %s (+%.0f%%). Keep buying?", money(prev), money(level.unitPrice),
                check.percent),
            {
                yes = "Keep buying", no = "Stop",
                onYes = function()
                    if not self.buy then
                        self:_StartBuy(entry, level)
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
    return self:_StartBuy(entry, level)
end

-- Start the buy of one level. Call it only from a click. A commodity asks for a quote; an item goes to the confirm.
function Tab:_StartBuy(entry, level)
    local client = self.deps.client
    local first = level.rows[1]
    if first.isCommodity == false then
        local row
        for _, candidate in ipairs(level.rows) do
            if not isOwn(candidate) then
                row = candidate
                break
            end
        end
        if not row then
            self:_Say("own listing")
            return false, "own listing"
        end
        local buyout = row.buyout or math.floor(row.unitPrice * (row.quantity or 1) + 0.5)
        self.buy = {
            entry = entry, level = level, isItem = true, phase = "quoted", itemID = entry.itemID,
            auctionID = row.auctionID, quantity = row.quantity or 1, unit = row.unitPrice, total = buyout,
        }
        self:_ShowConfirm()
        self:_Update()
        return true
    end
    local ok, err = pcall(client.StartCommodityPurchase, entry.itemID, level.quantity)
    if not ok then
        self.deps.log:Add(entry, "buy failed", tostring(err))
        self:_Say("the quote was refused")
        return false, "the quote was refused"
    end
    local buy = { entry = entry, level = level, phase = "quoting", itemID = entry.itemID, quantity = level.quantity }
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

local function quoteText(self, buy)
    local lines = {
        string.format("Buy %d x %s", buy.quantity, self:_ItemName(buy.entry)),
        string.format("Unit price: %s   Total: %s", money(buy.unit), money(buy.total)),
    }
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
    return table.concat(lines, "\n"), over
end

-- Show the confirm box with the server quote.
function Tab:_ShowConfirm()
    local buy = self.buy
    if not buy then
        return
    end
    local text, over = quoteText(self, buy)
    makeDialog("FlipsideBuyConfirm"):Open("Confirm purchase", text, {
        yes = over and "Buy anyway" or "Confirm", no = "Cancel", red = over,
        onYes = function()
            self:_Confirm()
        end,
        onNo = function()
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

-- Cancel an open quote or confirm box. A purchase in flight stays.
function Tab:_CancelQuote(why)
    local buy = self.buy
    if not buy or buy.phase == "confirming" then
        return
    end
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
function Tab:_Refresh(entry)
    self.refreshEntry = entry
    if self.pending then
        return
    end
    local status, text = self:_Start(entry, true)
    if status == "wait" then
        self:_Say(text)
        self.deps.after(RETRY_SECONDS, function()
            if self.refreshEntry == entry then
                self:_Refresh(entry)
            end
        end)
        return
    end
    self.refreshEntry = nil
end

-- Click 2: buy at the quote. Call it only from a click.
function Tab:_Confirm()
    local buy = self.buy
    if not buy or buy.phase ~= "quoted" then
        return
    end
    local client = self.deps.client
    buy.phase = "confirming"
    local ok, err
    if buy.isItem then
        ok, err = pcall(client.BuyItemAuction, buy.auctionID, buy.total)
    else
        ok, err = pcall(client.ConfirmCommodityPurchase, buy.itemID, buy.quantity)
    end
    if not ok then
        self:_Fail(buy, tostring(err))
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

function Tab:_Succeed(buy)
    self.buy = nil
    local run = self:_Run(buy.entry)
    run.lastPrice = buy.level.unitPrice
    run.bought = run.bought + buy.quantity
    self.deps.log:Add(buy.entry, string.format("bought %d at %s", buy.quantity, money(buy.level.unitPrice)),
        "total " .. money(buy.total))
    self:_Say("bought " .. buy.quantity .. " x " .. self:_ItemName(buy.entry))
    self:_Refresh(buy.entry)
    self:_Update()
end

function Tab:_Fail(buy, reason)
    self.buy = nil
    self.deps.log:Add(buy.entry, "buy failed", reason)
    self:_Say("buy failed: " .. reason)
    self:_Refresh(buy.entry)
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
        self:_Fail(buy, "error " .. tostring(code))
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
        parts.sub:SetWidth(310)
        parts.sub:SetJustifyH("LEFT")
        parts.remove = Kit.IconButton(row, "close", nil, "Remove from the list")
        parts.remove:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -2, 2)
        row.parts = parts
    end
    parts.remove:SetShown(self.source == "lists" and entry.listIndex ~= nil)
    parts.remove:SetScript("OnClick", function()
        self:RemoveListItem(entry.listIndex)
    end)
    local _, icon = self.deps.itemInfo(entry.itemID or 0)
    parts.icon:SetTexture(icon)
    parts.name:SetText(self:_ItemName(entry))
    setColor(parts.name, false)
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
    local sub = entry.groupPath or ""
    if type(sub) == "table" then
        sub = table.concat(sub, "/")
    end
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

-- The columns of the price level list. The header and the row cells use the same definition.
local LEVEL_COLUMNS = {
    { key = "unitPrice", title = "Unit Price", width = 104, number = true, format = money },
    { key = "stackPrice", title = "Stack Price", width = 104, number = true,
        format = function(value)
            return value and money(value) or ""
        end },
    { key = "quantity", title = "Quantity", width = 50, number = true,
        format = function(value)
            return "x" .. tostring(value)
        end },
    { key = "listings", title = "Listings", width = 56, number = true },
    { key = "status", title = "Status",
        get = function(data)
            return BuyingTab.StatusText(data.state)
        end },
}
local LEVEL_OPTIONS = { gap = 6 }

local function initRowsRow(row, data)
    local Kit = ns.Kit
    local cells = row.cells
    if not cells then
        cells = Kit.CreateColumnCells(row, LEVEL_COLUMNS, LEVEL_OPTIONS)
        row.cells = cells
    end
    Kit.SetColumnCells(cells, LEVEL_COLUMNS, data)
    setColor(cells.unitPrice, data.state == "above")
    setColor(cells.stackPrice, data.state == "above")
    setColor(cells.quantity, data.state == "above")
    setColor(cells.listings, true)
    setColor(cells.status, true)
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

-- Update the source buttons, the search list controls and the place of the list.
function Tab:_UpdateLeft()
    local ui, lists = self.ui, self.deps.searchLists
    local isLists = self.source == "lists" and lists ~= nil
    ui.groupsButton:SetEnabled(isLists)
    ui.listsButton:SetShown(lists ~= nil)
    ui.listsButton:SetEnabled(not isLists)
    for _, control in ipairs(ui.listControls) do
        control:SetShown(isLists)
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
    if self.placedFor ~= isLists then
        self.placedFor = isLists
        ui.list.frame:ClearAllPoints()
        ui.list.frame:SetPoint("TOPLEFT", ui.content, "TOPLEFT", 0, isLists and -152 or -74)
        ui.list.frame:SetPoint("BOTTOMLEFT", ui.content, "BOTTOMLEFT", 0, 0)
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
    local busy = self.pending ~= nil
    local canSearch = client.CanLiveSearch()
    local selected = self:_Selected()
    ui.search:SetEnabled(canSearch and selected ~= nil and not busy)
    ui.searchAll:SetEnabled(canSearch and #self.list > 0 and not busy and not self.queue)
    ui.stop:SetShown(self.queue ~= nil)
    ui.logButton:SetText(self.showLog and "Items" or "Log")
    ui.list:SetData(self.list)
    ui.rowsList.frame:SetShown(not self.showLog)
    ui.levelHeader.frame:SetShown(not self.showLog)
    ui.logList.frame:SetShown(self.showLog == true)
    ui.itemName:SetShown(not self.showLog)
    ui.summary:SetShown(not self.showLog)
    ui.buyNext:SetShown(not self.showLog)
    ui.dryRun:SetShown(not self.showLog)
    ui.jump:SetShown(not self.showLog)
    ui.jumpLabel:SetShown(not self.showLog)
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
        local text = canSearch and "Pick an item of the list." or "Live search is not available."
        if self.source == "lists" and not self.listID then
            text = "Make or pick a search list, then add items."
        end
        ui.summary:SetText(text)
        ui.buyNext:SetEnabled(false)
        ui.rowsList:SetData({})
        return
    end
    local done = self.results[selected.key]
    ui.itemName:SetText(self:_ItemName(selected))
    local lines = BuyingTab.DescribeSummary(selected, done and done.result, done and done.rows)
    local _, nextLevel, _, reason = self:_NextBuy()
    if done then
        if reason then
            lines[#lines + 1] = "Buy next: " .. reason
        elseif nextLevel then
            lines[#lines + 1] = string.format("Buy next: %d at %s", nextLevel.quantity, money(nextLevel.unitPrice))
        end
    end
    ui.summary:SetText(table.concat(lines, "\n"))
    ui.buyNext:SetEnabled(nextLevel ~= nil and reason == nil)
    local levels = done and self.deps.plan.PriceLevels(done.rows) or {}
    ui.rowsList:SetData(BuyingTab.DescribeLevels(selected, levels, selected.showAboveMax))
end

function Tab:IsActive()
    return self.active
end

-- Hide the panel; the host or Blizzard's own code takes over.
function Tab:Deselect()
    self:_CancelQuote("the tab was left")
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
function Tab:_BuildLeft(content, place)
    local Kit = ns.Kit
    local ui = self.ui
    ui.groupsButton = place(Kit.Button(content, "Groups", 90, function()
        self:SetSource("groups")
    end), 0, -48)
    ui.listsButton = place(Kit.Button(content, "Search lists", 100, function()
        self:SetSource("lists")
    end), 94, -48)
    ui.listControls = {}
    local function control(widget, x, y)
        ui.listControls[#ui.listControls + 1] = place(widget, x, y)
        return widget
    end
    ui.picker = control(Kit.Dropdown(content, 160, { onChange = function(id)
        self:SelectList(id)
    end }), 0, -74)
    ui.newList = control(Kit.Button(content, "New", 50, function()
        self:NewList(ui.nameInput:GetText())
    end), 164, -74)
    ui.rename = control(Kit.Button(content, "Rename", 64, function()
        self:RenameList(ui.nameInput:GetText())
    end), 218, -74)
    ui.delete = control(Kit.Button(content, "Delete", 56, function()
        local saved = self.listID and self.deps.searchLists:Get(self.listID)
        if saved then
            Kit.Confirm("FLIPSIDE_DELETE_SEARCH_LIST", "Delete the search list " .. saved.name .. "?", function()
                self:DeleteList()
            end)
        end
    end), 286, -74)
    ui.nameInput = control(Kit.Input(content, 250, nil, nil, { placeholder = "name of the list" }), 6, -102)
    ui.itemInput = control(Kit.Input(content, 250, function(text)
        self:AddItem(text)
    end, nil, { placeholder = "item name, ID, link or key" }), 6, -128)
    ui.addItem = control(Kit.Button(content, "Add", 50, function()
        self:AddItem(ui.itemInput:GetText())
    end), 262, -126)
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
    ui.content = content
    ui.list.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -74)
    ui.list.frame:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    ui.list.frame:SetWidth(LIST_WIDTH)
    self:_BuildLeft(content, place)

    local rightX = LIST_WIDTH + padding
    ui.itemName = place(Kit.Label(content, "", "normal"), rightX, -52)
    ui.itemName:SetJustifyH("LEFT")
    ui.summary = place(Kit.Label(content, "", "small"), rightX, -72)
    ui.summary:SetJustifyH("LEFT")
    ui.summary:SetWidth(330)
    ui.rowsList = Kit.CreateList(content, { rowHeight = 18, inset = true, initRow = function(row, data)
        initRowsRow(row, data)
    end })
    ui.rowsList.frame:SetPoint("TOPLEFT", content, "TOPLEFT", rightX, -148)
    ui.rowsList.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 30)
    -- The column titles over the price level list.
    local edge = ui.rowsList.contentInsets or { left = 0, right = 0 }
    ui.levelHeader = Kit.CreateColumnHeader(content, LEVEL_COLUMNS,
        { gap = LEVEL_OPTIONS.gap, left = edge.left, right = edge.right })
    ui.levelHeader.frame:SetPoint("TOPLEFT", content, "TOPLEFT", rightX, -130)
    ui.levelHeader.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -130)
    ui.levelHeader.frame:SetHeight(18)
    ui.logList = Kit.CreateList(content, { rowHeight = 18, inset = true, initRow = function(row, data)
        self:_InitLogRow(row, data)
    end })
    ui.logList.frame:SetPoint("TOPLEFT", content, "TOPLEFT", rightX, -48)
    ui.logList.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 30)

    ui.buyNext = Kit.Button(content, "Buy next", 90, function()
        self:BuyNext()
    end)
    ui.buyNext:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", rightX, 0)
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
    if hooksecurefunc and ChatEdit_InsertLink and not self.linkHooked then
        self.linkHooked = true
        hooksecurefunc("ChatEdit_InsertLink", function(text)
            local ui = self.ui
            if ui and ui.itemInput and ui.itemInput:HasFocus() and type(text) == "string" then
                ui.itemInput:Insert(text)
            end
        end)
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
    self:_Update()
end

-- Undo a failed Mount: hide the panel and keep no half-built state.
function Tab:Unmount()
    self:_CancelQuote("the tab was removed")
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
-- searchLists, itemNameIndex, ahNameSearch, keyFor(link) and isAuctionHouseOpen() (search lists and the item box).
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
        db = deps.db,
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
        source = "groups",
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
