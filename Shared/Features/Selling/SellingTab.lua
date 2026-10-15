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
local ITEM_WIDTH = 244
local ITEM_LEAD = 18
local ICON_LEAD = 22
local COLUMN_GAP = 6
local DETAILS_TOP = -28
local DETAILS_HEIGHT = 72
local HEADER_HEIGHT = 18
local TREE_TOP = DETAILS_TOP - DETAILS_HEIGHT - 4 - HEADER_HEIGHT
local BAR_HEIGHT = 34
local RED = { 1, 0.3, 0.3 }
local GREEN = { 0.4, 1, 0.4 }
local WHITE = { 1, 1, 1 }
local GREY = { 0.5, 0.5, 0.5 }
local ORANGE = { 1, 0.6, 0.2 }
local MAX_PRICE = 100000000000
local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD = 10000
local DEFAULT_DURATION = 24
-- Client arrow textures (pet battle strong and weak badges: a green arrow up and a red arrow down).
local ARROW_UP = "|TInterface\\PetBattles\\BattleBar-AbilityBadge-Strong:14:14|t"
local ARROW_DOWN = "|TInterface\\PetBattles\\BattleBar-AbilityBadge-Weak:14:14|t"
local LOWEST_TIP = "The lowest unit price of another seller in the live search of this item. "
    .. "Your own auctions do not count. It reads \"none\" when no other seller has an auction."

-- The columns of the item list (Kit.ColumnLayout): the header and every row share them.
-- The item cell (icon and name) is drawn by the row itself. The Info column fills the rest.
local COLUMNS = {
    { key = "item", title = "Item", width = ITEM_WIDTH, owned = true },
    { key = "price", title = "Your price", width = 78, number = true },
    { key = "operation", title = "Operation", width = 80 },
    { key = "lowest", title = "Lowest on AH", width = 92, number = true },
    { key = "net", title = "Net", width = 78, number = true },
    { key = "info", title = "Info" },
}
local COLUMN_OPTIONS = { gap = COLUMN_GAP }
SellingTab.COLUMNS = COLUMNS
SellingTab.ARROW_UP = ARROW_UP
SellingTab.ARROW_DOWN = ARROW_DOWN
SellingTab.LOWEST_TIP = LOWEST_TIP

local function money(copper)
    if ns.TooltipLines and ns.TooltipLines.FormatMoney then
        return ns.TooltipLines.FormatMoney(copper)
    end
    return GetMoneyString(math.floor((copper or 0) + 0.5))
end

-- Read a price that the user typed. "1g 20s 5c", "120s" and "1g20s" work. A plain number is copper.
-- Each unit (g, s, c) can show once, from big to small. Returns the copper, or nil and a reason.
function SellingTab.ParsePrice(text)
    if type(text) ~= "string" then
        return nil, "type a price, for example 1g 20s"
    end
    local s = text:lower():match("^%s*(.-)%s*$")
    if s == "" then
        return nil, "type a price, for example 1g 20s"
    end
    local total = 0
    if s:match("^%d+$") then
        total = tonumber(s)
    else
        local factor = { g = COPPER_PER_GOLD, s = COPPER_PER_SILVER, c = 1 }
        local rank = { g = 3, s = 2, c = 1 }
        local last, pos = 4, 1
        while pos <= #s do
            local _, stop, number, unit = s:find("^(%d+)%s*([gsc])%s*", pos)
            if not stop then
                return nil, "use whole numbers with g, s or c, for example 1g 20s 5c"
            end
            if rank[unit] >= last then
                return nil, "write g, then s, then c, and use each one once"
            end
            last = rank[unit]
            total = total + tonumber(number) * factor[unit]
            pos = stop + 1
        end
    end
    if total < 1 then
        return nil, "the price must be at least 1c"
    end
    if total > MAX_PRICE then
        return nil, "the price is too large"
    end
    return total
end

-- The price as text for the price box, for example 1g 20s 5c. ParsePrice reads it back.
function SellingTab.PriceText(copper)
    copper = math.floor((copper or 0) + 0.5)
    local gold = math.floor(copper / COPPER_PER_GOLD)
    local silver = math.floor((copper % COPPER_PER_GOLD) / COPPER_PER_SILVER)
    local rest = copper % COPPER_PER_SILVER
    local parts = {}
    if gold > 0 then
        parts[#parts + 1] = gold .. "g"
    end
    if silver > 0 then
        parts[#parts + 1] = silver .. "s"
    end
    if rest > 0 or #parts == 0 then
        parts[#parts + 1] = rest .. "c"
    end
    return table.concat(parts, " ")
end

-- Build the tree nodes from the entries. A group node shows only if it holds a bag item, directly or deeper.
-- Items first (bag order), then the subgroups. Items of no group go to the last node "[No group]".
-- Group node: { id = "g<ID>", kind = "group", groupID, text, children }.
-- Item node: { id = "i<key>", kind = "item", entry, text }.
function SellingTab.BuildNodes(rules, entries)
    local byGroup = {}
    for _, entry in ipairs(entries) do
        -- An item that is posted for real is on the AH now, so the list does not show it.
        if not (entry.status == "done" and entry.real) then
            local list = byGroup[entry.groupID]
            if not list then
                list = {}
                byGroup[entry.groupID] = list
            end
            list[#list + 1] = entry
        end
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

-- True if the minimum price of the candidate is the vendor price floor of the Default operation.
local function floorIsVendor(candidate)
    local schema = ns.OperationSchema
    return schema ~= nil and candidate.settings ~= nil and candidate.settings.minPrice == schema.VENDOR_FLOOR
end

local SKIP_TEXT = {
    ["keep in bags reached"] = "keep in bags reached",
    ["post cap reached"] = "post cap reached",
    ["already lowest"] = "you are already lowest",
    ["vendor pays more than the AH"] = "vendor pays more, skipped",
    ["no response"] = "no response from the Auction House",
    ["skipped by user"] = "skipped by you",
}

-- The short reason of one entry, for the Info column.
function SellingTab.InfoText(entry)
    local status, decision, candidate = entry.status, entry.decision, entry.candidate
    if status == "noop" then
        return "no operation"
    elseif status == "waiting" then
        return candidate and candidate.reason or "not searched yet"
    elseif status == "searching" then
        return "searching"
    elseif status == "failed" then
        return "failed: " .. tostring(entry.note)
    elseif status == "skipped" then
        return "skipped by you"
    elseif status == "done" then
        return "posted"
    elseif not decision then
        return "not searched yet"
    end
    local reason = decision.reason or ""
    if decision.action == "skip" then
        if reason == "below minimum" then
            return (candidate and floorIsVendor(candidate) and "below vendor price" or "below min price") .. ", skipped"
        elseif reason:match("^no price") then
            return "no competitor, no market value"
        end
        return SKIP_TEXT[reason] or reason
    end
    if reason == "undercut" then
        return money((decision.competitor or 0) - decision.price) .. " under lowest"
    elseif reason == "normal price" then
        return "no competitor, normal price"
    elseif reason == "above max, at max" then
        return "capped at max price"
    elseif reason == "above max, at normal" then
        return "above max, at normal price"
    elseif reason == "below min, at min" then
        return "raised to " .. (candidate and floorIsVendor(candidate) and "vendor" or "min") .. " price"
    end
    return reason
end

-- The potential profit of the auctions that are left in one entry, or nil if the entry has no post left.
-- vendorPrice is the vendor sell price of one item or nil. Returns the table of SellingPlan.Profit.
-- price is optional: the price per item that the user typed instead of the suggested price.
function SellingTab.EntryProfit(entry, vendorPrice, price)
    if entry.status ~= "ready" or not entry.decision or entry.decision.action ~= "post" then
        return nil
    end
    local left = {}
    for index = entry.next, #entry.units do
        left[#left + 1] = entry.units[index]
    end
    if #left == 0 then
        return nil
    end
    local profit = ns.SellingPlan.Profit(price or entry.decision.price, left, vendorPrice)
    profit.auctions = #left
    return profit
end

-- The values of the details pane for the next post of an entry; nil if the entry has no post left.
-- price is optional: the price per item that the user typed.
function SellingTab.Details(entry, vendorPrice, price)
    local profit = SellingTab.EntryProfit(entry, vendorPrice, price)
    if not profit then
        return nil
    end
    local decision, unit = entry.decision, entry.units[entry.next]
    price = price or decision.price
    return {
        operation = entry.candidate and entry.candidate.operationName,
        unitPrice = price,
        buyout = price * unit.quantity,
        auctions = profit.auctions,
        stackSize = unit.quantity,
        duration = decision.duration,
        deposit = profit.deposit,
        lowest = decision.competitor,
        net = profit.net,
        vs = profit.vs,
    }
end

-- The text of the net line and its colour: green with an up arrow above 0, red with a down arrow below 0.
function SellingTab.NetStyle(net)
    if net > 0 then
        return "Net: " .. ARROW_UP .. " " .. money(net), GREEN
    elseif net < 0 then
        return "Net: " .. ARROW_DOWN .. " " .. money(net), RED
    end
    return "Net: " .. money(net), WHITE
end

-- Tell if the vendor pays more than the AH for the next post. Returns the vendor total and the net, or nil.
-- unit is { quantity, deposit }; price is per item; vendorPrice is per item or nil.
function SellingTab.VendorBetter(price, unit, vendorPrice)
    if not vendorPrice or not unit or not price then
        return nil
    end
    local profit = ns.SellingPlan.Profit(price, { unit }, vendorPrice)
    if profit.vendor and profit.vendor > profit.net then
        return profit.vendor, profit.net
    end
    return nil
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

-- The vendor sell price of one item in copper (return 11 of C_Item.GetItemInfo); nil if unknown or 0.
local function defaultVendorPrice(itemID)
    if not (C_Item and C_Item.GetItemInfo) then
        return nil
    end
    local price = select(11, C_Item.GetItemInfo(itemID))
    if type(price) == "number" and price > 0 then
        return price
    end
    return nil
end

local function defaultMaxStack(itemID)
    return C_Item and C_Item.GetItemMaxStackSizeByID and C_Item.GetItemMaxStackSizeByID(itemID) or 1
end

-- The item link and the quality of an item; nil while the client has no data yet.
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

local warnDialog

-- The warning box: a square Kit window with a text and two buttons. onYes runs in the click of the yes button.
local function openWarning(title, text, yesLabel, onYes)
    local Kit = ns.Kit
    if not warnDialog then
        local pad = Kit.Theme.padding
        local dialog = Kit.CreateWindow("FlipsideSellWarning", { width = 380, height = 190, square = true })
        warnDialog = dialog
        dialog:SetFrameStrata("FULLSCREEN_DIALOG")
        dialog:SetToplevel(true)
        local textWidth = 380 - 2 * pad - 16
        -- The text frame takes hyperlinks, so an item link shows the item tooltip.
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
        dialog.yesButton = Kit.Button(dialog, "", 130, function()
            local callback = dialog.onYes
            dialog.onYes = nil
            dialog:Hide()
            if callback then
                callback()
            end
        end)
        dialog.yesButton:SetPoint("BOTTOM", dialog, "BOTTOM", -70, pad + 4)
        dialog.noButton = Kit.Button(dialog, "Cancel", 100, function()
            dialog.onYes = nil
            dialog:Hide()
        end)
        dialog.noButton:SetPoint("BOTTOM", dialog, "BOTTOM", 70, pad + 4)
    end
    local dialog = warnDialog
    dialog.onYes = onYes
    if dialog.SetTitle then
        dialog:SetTitle(title or "")
    end
    dialog.text:SetText(text or "")
    local textHeight = dialog.text.GetStringHeight and dialog.text:GetStringHeight() or 14
    dialog.textFrame:SetHeight(textHeight)
    dialog:SetHeight(math.max(150, 40 + textHeight + 20 + 22 + Kit.Theme.padding + 8))
    dialog.text:SetTextColor(ORANGE[1], ORANGE[2], ORANGE[3])
    dialog.yesButton:SetText(yesLabel or "OK")
    dialog:Show()
    dialog:Raise()
end

local Tab = {}
Tab.__index = Tab

function Tab:_Say(text)
    if self.ui then
        self.ui.message:SetText(text or "")
    end
end

-- The vendor sell price of one item of an entry, or nil. It asks the client again until it has a price.
function Tab:_Vendor(entry)
    if entry.vendor == nil then
        local ok, price = pcall(self.deps.vendorPrice, entry.item.itemID or 0)
        if ok and type(price) == "number" and price > 0 then
            entry.vendor = price
        end
    end
    return entry.vendor
end

-- The potential profit of one entry, or nil.
function Tab:_Profit(entry)
    return SellingTab.EntryProfit(entry, self:_Vendor(entry))
end

-- The total potential profit of the selection: { net, vs, deposit } over the auctions that are left.
-- vs is nil if the vendor price of an item with a post is not known.
function Tab:QueueProfit()
    local net, vs, deposit, count = 0, 0, 0, 0
    for _, entry in ipairs(self.selection) do
        local profit = self:_Profit(entry)
        if profit then
            count = count + 1
            net = net + profit.net
            deposit = deposit + profit.deposit
            if profit.vs and vs then
                vs = vs + profit.vs
            else
                vs = nil
            end
        end
    end
    if count == 0 then
        return nil
    end
    return { net = net, vs = vs, deposit = deposit }
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

-- Count the own auctions of each bag item (each owned row is one auction), and the units in them.
function Tab:_OwnedCounts(bagItems)
    local client = self.deps.client
    local owned, units = {}, {}
    if not client.CanReadOwned() then
        return owned, units
    end
    local ok, rows = pcall(client.OwnedAuctions)
    if not ok or type(rows) ~= "table" then
        return owned, units
    end
    local byID, unitsByID = {}, {}
    for _, row in ipairs(rows) do
        local itemID = type(row) == "table" and type(row.itemKey) == "table" and row.itemKey.itemID
        if itemID then
            byID[itemID] = (byID[itemID] or 0) + 1
            unitsByID[itemID] = (unitsByID[itemID] or 0) + (tonumber(row.quantity) or 1)
        end
    end
    for _, item in ipairs(bagItems) do
        owned[item.key] = byID[item.itemID]
        units[item.key] = unitsByID[item.itemID]
    end
    return owned, units
end

-- Ask the client for the deposit of each unit of an entry and store the sum.
function Tab:_Quote(entry)
    local decision = entry.decision
    local total
    for _, unit in ipairs(entry.units) do
        local ok, deposit = pcall(self.deps.client.Deposit, unit.bag, unit.slot, decision.duration,
            unit.quantity, decision.commodity == true)
        if ok and type(deposit) == "number" then
            total = (total or 0) + deposit
            unit.deposit = deposit
        end
    end
    entry.deposit = total
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
    entry.market = { commodity = okCommodity and commodity == true, maxStack = deps.maxStack(itemID) }
    entry.units, entry.next = {}, 1
    if decision.action == "post" then
        entry.units = SellingTab.BuildUnits(candidate, decision)
        if #entry.units == 0 then
            entry.decision = { action = "skip", reason = "no bag stack found", key = candidate.key }
        end
    end
    if entry.decision.action == "post" then
        entry.status = "ready"
        self:_Quote(entry)
        local skip = deps.plan.VendorSkip(candidate, entry.decision, entry.units, self:_Vendor(entry))
        if skip then
            entry.decision, entry.units, entry.status = skip, {}, "skip"
            deps.log:Add(candidate, skip)
        end
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
    local byKey = self:_CandidatesByKey(bagItems)
    self.entries, self.selection, self.selectedId, self.postedCount = {}, {}, nil, 0
    self.priceEntry = nil
    for _, item in ipairs(bagItems) do
        self.entries[#self.entries + 1] = self:_NewEntry(item, byKey[item.key])
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

-- The selling candidates of the bag items, by item key.
function Tab:_CandidatesByKey(bagItems)
    local deps = self.deps
    local owned, ownedUnits = self:_OwnedCounts(bagItems)
    local candidates = deps.plan.Candidates({
        rules = deps.rules,
        formulaRun = deps.formulaRun,
        bagItems = bagItems,
        owned = owned,
        ownedUnits = ownedUnits,
        dataStats = deps.getRecord and function(key)
            return SellingTab.DataStats(deps.getRecord(key), deps.now and deps.now() or nil)
        end or nil,
    })
    local byKey = {}
    for _, candidate in ipairs(candidates) do
        byKey[candidate.key] = candidate
    end
    return byKey
end

function Tab:_NewEntry(item, candidate)
    return {
        item = item, key = item.key, candidate = candidate, groupID = self.deps.rules:GroupOf(item.key),
        status = candidate and "waiting" or "noop", next = 1, posted = 0, units = {},
    }
end

-- Find a node by id in a node list.
local function findNode(nodes, id)
    for _, node in ipairs(nodes) do
        if node.id == id then
            return node
        end
        local found = node.children and findNode(node.children, id)
        if found then
            return found
        end
    end
    return nil
end

-- Build the tree nodes again from the entries. The selection stays as it is, so the queue keeps its count.
function Tab:_RebuildNodes()
    self.nodes = SellingTab.BuildNodes(self.deps.rules, self.entries)
    if self.ui then
        local tree = self.ui.tree
        tree.selected = findNode(self.nodes, self.selectedId or "") and self.selectedId or nil
        tree:SetNodes(self.nodes)
    end
end

-- Take the units that are left of a ready entry from the new bag stacks. A post that ran changed the stacks.
function Tab._Restack(_, entry, item)
    local candidate, decision = entry.candidate, entry.decision
    entry.item = item
    candidate.stacks, candidate.count = item.stacks, item.count
    if entry.status ~= "ready" then
        return
    end
    local left = #entry.units - (entry.next - 1)
    local old = {}
    for index = entry.next, #entry.units do
        old[#old + 1] = entry.units[index]
    end
    for index = #entry.units, entry.next, -1 do
        entry.units[index] = nil
    end
    local fresh = SellingTab.BuildUnits(candidate, { quantity = decision.quantity, auctions = left,
        commodity = decision.commodity })
    for index, unit in ipairs(fresh) do
        unit.deposit = old[index] and old[index].deposit
        entry.units[#entry.units + 1] = unit
    end
    local total
    for _, unit in ipairs(entry.units) do
        if unit.deposit then
            total = (total or 0) + unit.deposit
        end
    end
    entry.deposit = total
    if entry.next > #entry.units then
        entry.status = entry.posted > 0 and "done" or "skipped"
        entry.real = entry.posted > 0
    end
end

-- Read the bags again after a post, with no wait for a tab switch. It keeps the decisions of the entries.
-- An item that is posted leaves the list. If part of the stack stays in the bags, the rest shows as a new entry.
function Tab:SyncBags()
    if self.awaiting or self.dryRun or not self.ui or not self.loaded then
        return false
    end
    local bagItems = self.deps.readBags()
    local byKey = self:_CandidatesByKey(bagItems)
    local oldByKey = {}
    for _, entry in ipairs(self.entries) do
        oldByKey[entry.key] = entry
    end
    local entries, fresh = {}, false
    for _, item in ipairs(bagItems) do
        local old = oldByKey[item.key]
        local candidate = byKey[item.key]
        local used = old and item.count < old.item.count
        if old and old.status == "done" and old.real and used then
            old = nil
        end
        if old and old.candidate then
            if used then
                self:_Restack(old, item)
            elseif item.count ~= old.item.count then
                old.item = item
                old.candidate.stacks, old.candidate.count = item.stacks, item.count
            end
            entries[#entries + 1] = old
        elseif old then
            old.item = item
            entries[#entries + 1] = old
        else
            local entry = self:_NewEntry(item, candidate)
            entries[#entries + 1] = entry
            fresh = fresh or entry.status == "waiting"
        end
    end
    self.entries = entries
    self:_RebuildNodes()
    self:_Reselect(fresh)
    return true
end

-- After a bag sync: pick the selection again from its node. Search the entries that are new.
function Tab:_Reselect(search)
    local node = self.selectedId and findNode(self.nodes, self.selectedId)
    if not node then
        local kept = {}
        for _, entry in ipairs(self.selection) do
            for _, current in ipairs(self.entries) do
                if current == entry then
                    kept[#kept + 1] = entry
                end
            end
        end
        self.selection = kept
        if #kept == 0 then
            self.selectedId = nil
        end
    else
        self.selection = SellingTab.CollectEntries(node, {})
    end
    if search and not self.queue then
        local list = {}
        for _, entry in ipairs(self.selection) do
            if entry.status == "waiting" then
                list[#list + 1] = entry
            end
        end
        if #list > 0 then
            self.queue = { list = list, pos = 0 }
            self:_Next()
        end
    end
    self:_Update()
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
    self.priceEntry = nil
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
    self:SyncBags()
end

function Tab:_OnBags()
    self:SyncBags()
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
function Tab:_Record(entry, quantity, kind, price)
    local decision = entry.decision
    self.deps.log:Add(entry.candidate, {
        action = kind, reason = decision.reason, price = price or decision.price, quantity = quantity, auctions = 1,
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
        -- A real post puts the item on the AH: the list drops it now.
        if entry.status == "done" and entry.real then
            self:_RebuildNodes()
        end
    end
    self:_AfterStep()
end

function Tab:_ConfirmText()
    local awaiting = self.awaiting
    return string.format("Post %d x %s at %s each?", awaiting.quantity, self:_Name(awaiting.entry),
        money(awaiting.price))
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
    awaiting.entry.real = true
    self:_Record(awaiting.entry, awaiting.quantity, "post", awaiting.price)
    self:_Advance(awaiting.entry, true)
end

-- The item as a link in the quality colour; nil while the client has no link yet.
function Tab:_ItemLink(entry)
    local link, quality = self.deps.itemLink(entry.item.itemID or 0)
    if not link then
        return nil
    end
    if link:find("^|c") then
        return link
    end
    local _, _, _, hex = ns.Kit.QualityColor(quality)
    return "|c" .. hex .. link .. "|r"
end

-- The entry that a click on Post works on. Post all works only on the ready entries of the selection.
-- Post can also work on one selected item that the rule skips, after a warning.
function Tab:_Focus(all)
    local current = self:_Current()
    if current or all then
        return current
    end
    local only = #self.selection == 1 and self.selectedId and self.selectedId:sub(1, 1) == "i" and self.selection[1]
    if only and only.status == "skip" and only.market and only.candidate
        and #(only.candidate.stacks or {}) > 0 and SellingTab.CanForce(only) then
        return only
    end
    return nil
end

-- Tell if a manual post can override the skip of an entry. The kept items are never posted.
function SellingTab.CanForce(entry)
    local candidate = entry.candidate
    local keep = tonumber(candidate.settings and candidate.settings.keepInBags) or 0
    return (candidate.count or 0) - keep > 0
end

-- The decision and the units of a manual post of an item that the rule skips: one auction.
-- It follows the keep quantity and the max stack size of the rule.
function Tab._ManualPlan(_, entry, price)
    local candidate, market = entry.candidate, entry.market or {}
    local stacks = candidate.stacks
    local commodity = market.commodity == true
    local settings = candidate.settings or {}
    local available = math.max(1, (candidate.count or stacks[1].count) - (tonumber(settings.keepInBags) or 0))
    local quantity
    if commodity then
        quantity = available
    else
        local size = math.max(1, market.maxStack or 1)
        local limit = tonumber(settings.stackSize) or 0
        if limit > 0 then
            size = math.min(size, limit)
        end
        quantity = math.min(size, stacks[1].count, available)
    end
    local decision = { action = "post", price = price, quantity = quantity, auctions = 1, commodity = commodity,
        reason = "manual post", key = candidate.key, duration = tonumber(settings.duration) or DEFAULT_DURATION }
    return decision, SellingTab.BuildUnits(candidate, decision)
end

-- Turn a skipped entry into a ready entry with one manual post.
function Tab:_ForcePlan(entry, price)
    local decision, units = self:_ManualPlan(entry, price)
    entry.skipDecision = entry.decision
    entry.decision, entry.units, entry.next = decision, units, 1
    entry.status, entry.manual = "ready", true
    self:_Quote(entry)
end

-- The price per item for a click: the text of the price box for the shown entry, else the suggested price.
-- Returns the copper, or nil and a reason.
function Tab:_PostPrice(entry)
    if self.ui and self.priceEntry == entry then
        local price, why = SellingTab.ParsePrice(self.ui.details.priceInput:GetText())
        if not price then
            return nil, "invalid price: " .. why
        end
        return price
    end
    local decision = entry.decision
    local suggested = decision and (decision.action == "post" and decision.price or decision.suggested)
    if suggested then
        return suggested
    end
    return nil, "type a price first"
end

-- The warning lines for the next post of an entry at a price. An empty list means no warning.
-- Post all gives no vendor warning: the vendorSkip rule already chose the entries of its queue.
function Tab:_Warnings(entry, price, all)
    local lines = {}
    local unit
    if entry.status == "ready" then
        unit = entry.units[entry.next]
    else
        local reason = entry.decision and entry.decision.reason or "no decision"
        lines[1] = "The rule skips this item: " .. (SKIP_TEXT[reason] or reason) .. "."
        unit = select(2, self:_ManualPlan(entry, price))[1]
    end
    local vendor, net
    if not (all and entry.status == "ready") then
        vendor, net = SellingTab.VendorBetter(price, unit, self:_Vendor(entry))
    end
    if vendor then
        lines[#lines + 1] = "Sells for more at a vendor: " .. money(vendor) .. " (net on the AH: " .. money(net) .. ")."
    end
    return lines, unit
end

-- Show the warning box. The post runs in the click of the yes button, so it keeps its hardware event.
function Tab:_AskWarning(entry, price, lines, unit, all)
    local text = string.format("Post %d x %s at %s each?", unit and unit.quantity or 0,
        self:_ItemLink(entry) or self:_Name(entry), money(price))
    text = text .. "\n\n" .. table.concat(lines, "\n")
    self.deps.warn("Post anyway?", text, "Post anyway", function()
        if self.awaiting or self:_Focus(all) ~= entry then
            return
        end
        entry.warned = true
        self:_PostStep(all)
    end)
end

-- Post the next unit of the first ready entry. Call it only from the click of the post button.
-- One call makes one protected post. Returns true, or false and a text.
function Tab:PostNext()
    return self:_PostStep(false)
end

-- The same for the button "Post all": the queue of the selection, with no entry that the rule skips.
function Tab:PostAll()
    return self:_PostStep(true)
end

function Tab:_PostStep(all)
    if self.awaiting then
        self:_ShowConfirm()
        return true
    end
    local entry = self:_Focus(all)
    if not entry then
        self:_Say("nothing to post")
        return false, "nothing to post"
    end
    local price, why = self:_PostPrice(entry)
    if not price then
        self:_Say(why)
        return false, why
    end
    if not self.dryRun and not entry.warned then
        local lines, unit = self:_Warnings(entry, price, all)
        if #lines > 0 then
            self:_AskWarning(entry, price, lines, unit, all)
            return true
        end
    end
    if entry.status ~= "ready" then
        self:_ForcePlan(entry, price)
    end
    local unit = entry.units[entry.next]
    local decision = entry.decision
    if self.dryRun then
        self:_Record(entry, unit.quantity, "dry run", price)
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
            return client.PostCommodity(unit.bag, unit.slot, decision.duration, quantity, price)
        end
        confirm = function()
            return client.ConfirmPostCommodity(unit.bag, unit.slot, decision.duration, quantity, price)
        end
    else
        local buyout = price * quantity
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
        self.awaiting = { entry = entry, unit = unit, quantity = quantity, confirm = confirm, price = price }
        self:_ShowConfirm()
        self:_Update()
        return true
    end
    entry.real = true
    self:_Record(entry, quantity, "post", price)
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

local function paint(label, color)
    label:SetTextColor(color[1], color[2], color[3])
end

-- The cells of one item row: the price, operation, lowest, net and info texts and the colour of the net.
function SellingTab.Cells(entry, vendorPrice)
    local candidate, decision = entry.candidate, entry.decision
    local cells = { price = "-", operation = candidate and candidate.operationName or "-", lowest = "-", net = "-",
        info = SellingTab.InfoText(entry) }
    local ready = entry.status == "ready"
    if ready and decision then
        cells.price = money(decision.price)
        cells.lowest = decision.competitor and money(decision.competitor) or "none"
        local profit = SellingTab.EntryProfit(entry, vendorPrice)
        if profit then
            cells.net = money(profit.net)
            cells.netNegative = profit.net < 0
        end
    elseif entry.status == "waiting" and candidate and candidate.normalPrice then
        cells.price = "~" .. money(candidate.normalPrice)
    elseif decision and decision.action == "skip" and decision.competitor then
        cells.lowest = money(decision.competitor)
    end
    return cells
end

-- Draw one tree row: a group (toggle and name) or a bag item (icon, name and the columns).
function Tab:_InitTreeRow(row, node, depth, isCollapsed, hasChildren)
    local Kit = ns.Kit
    local parts = row.sellParts
    if not parts then
        parts = { icon = row:CreateTexture(nil, "ARTWORK") }
        parts.icon:SetSize(18, 18)
        parts.cells = Kit.CreateColumnCells(row, COLUMNS, COLUMN_OPTIONS)
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
    row.label:SetWidth(math.max(20, ITEM_WIDTH - (depth - 1) * TREE_INDENT - ITEM_LEAD
        - (node.kind == "group" and 0 or ICON_LEAD)))
    row.label:SetJustifyH("LEFT")
    if row.label.SetWordWrap then
        row.label:SetWordWrap(false)
    end
    if node.kind == "group" then
        parts.icon:Hide()
        for _, cell in pairs(parts.cells) do
            cell:SetText("")
        end
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
    row.label:SetText(self:_Name(entry) .. " x" .. tostring(entry.item.count))
    local cells = SellingTab.Cells(entry, self:_Vendor(entry))
    local grey = entry.status ~= "ready"
    Kit.SetColumnCells(parts.cells, COLUMNS, cells)
    for _, cell in pairs(parts.cells) do
        paint(cell, grey and GREY or WHITE)
    end
    if cells.netNegative then
        paint(parts.cells.net, RED)
    end
    local dim = entry.status == "noop" or entry.status == "done" or entry.status == "skipped"
        or entry.status == "failed"
    paint(row.label, dim and GREY or WHITE)
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
    if self.awaiting then
        return "Confirm post"
    end
    return "Post"
end

-- The progress text: "Posting 3 of 60" while a post is left, else empty.
function Tab:ProgressText()
    local total, done = self:_Progress()
    if total > 0 and (self.awaiting or self:_Current()) then
        return string.format("Posting %d of %d", math.min(done + 1, total), total)
    end
    return ""
end

-- The label of the post all button from the state: "Post all (3/12)" is the done count and the total of the queue.
function Tab:PostAllLabel()
    local total, done = self:_Progress()
    if total > 0 and self:_Current() and not self.awaiting then
        return string.format("Post all (%d/%d)", done, total)
    end
    return "Post all"
end

-- Put a suggested price in the price box. The box belongs to the entry until another entry shows.
function Tab:_FillPrice(entry, copper)
    self.priceEntry = entry
    self.filling = true
    self.ui.details.priceInput:SetText(copper and SellingTab.PriceText(copper) or "")
    self.filling = false
end

local function clearDetails(d)
    d.icon:SetTexture(nil)
    d.operation:SetText("")
    d.price:SetText("")
    d.stack:SetText("")
    d.deposit:SetText("")
    d.lowest:SetText("")
    d.net:SetText("")
    d.vs:SetText("")
    d.warn:SetText("")
end

-- Fill the details pane from the next post of the queue (or the one item that the rule skips).
function Tab:_UpdateDetails()
    local d = self.ui.details
    local entry = self.awaiting and self.awaiting.entry or self:_Focus(false)
    if not entry then
        clearDetails(d)
        d.name:SetText(#self.selection == 0 and "Pick a group or an item" or "Nothing to post")
        if self.priceEntry ~= nil then
            self.priceEntry = nil
            self.filling = true
            d.priceInput:SetText("")
            self.filling = false
        end
        d.priceInput:SetEnabled(false)
        return
    end
    local decision = entry.decision
    local ready = entry.status == "ready"
    if self.priceEntry ~= entry then
        self:_FillPrice(entry, ready and decision.price or decision.suggested)
    end
    d.priceInput:SetEnabled(true)
    local typed, why = SellingTab.ParsePrice(d.priceInput:GetText())
    local _, icon = self.deps.itemInfo(entry.item.itemID or 0)
    d.icon:SetTexture(icon)
    d.name:SetText(self:_Name(entry))
    d.operation:SetText("Operation: " .. tostring(entry.candidate and entry.candidate.operationName or "-"))
    local values = ready and SellingTab.Details(entry, self:_Vendor(entry), typed)
    if not values then
        clearDetails(d)
        d.icon:SetTexture(icon)
        d.operation:SetText("Operation: " .. tostring(entry.candidate and entry.candidate.operationName or "-"))
        local reason = decision.reason or "no decision"
        d.warn:SetText("The rule skips this item: " .. (SKIP_TEXT[reason] or reason) .. ". Post asks you first.")
        paint(d.warn, ORANGE)
        return
    end
    d.price:SetText("Buyout " .. money(values.buyout) .. " per auction")
    d.stack:SetText(string.format("%d x %d", values.auctions, values.stackSize))
    d.deposit:SetText("Deposit: " .. money(values.deposit))
    d.lowest:SetText("Lowest on AH: " .. (values.lowest and money(values.lowest) or "none"))
    local netText, netColor = SellingTab.NetStyle(values.net)
    d.net:SetText(netText)
    paint(d.net, netColor)
    if values.vs == nil then
        d.vs:SetText("vs vendor: -")
        paint(d.vs, WHITE)
    else
        d.vs:SetText("vs vendor: " .. money(values.vs))
        paint(d.vs, values.vs < 0 and RED or (values.vs > 0 and GREEN or WHITE))
    end
    -- One line for a problem: a bad price first, then the vendor warning for the next post.
    if not typed then
        d.warn:SetText("Invalid price: " .. why)
        paint(d.warn, RED)
        return
    end
    local vendor, net = SellingTab.VendorBetter(typed, entry.units[entry.next], self:_Vendor(entry))
    if vendor then
        d.warn:SetText("Sells for more at a vendor: " .. money(vendor) .. " (net on the AH: " .. money(net) .. ")")
        paint(d.warn, ORANGE)
    else
        d.warn:SetText("")
    end
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
    ui.headers.frame:SetShown(not self.showLog)
    ui.logList.frame:SetShown(self.showLog == true)
    local current = self:_Current()
    ui.postNext:SetText(self:PostLabel())
    ui.postNext:SetEnabled(client.CanPost() and (self.awaiting ~= nil or self:_Focus(false) ~= nil))
    ui.postAll:SetText(self:PostAllLabel())
    ui.postAll:SetEnabled(client.CanPost() and self.awaiting == nil and current ~= nil)
    ui.skip:SetEnabled(self.awaiting ~= nil or current ~= nil)
    ui.progress:SetText(self:ProgressText())
    local _, _, deposit = self:_Progress()
    ui.deposit:SetText(deposit and ("Deposit: " .. money(deposit)) or "")
    local queue = self:QueueProfit()
    if queue then
        ui.net:SetText("Queue net: " .. money(queue.net))
        paint(ui.net, queue.net < 0 and RED or WHITE)
        ui.vs:SetText(queue.vs ~= nil and ("vs vendor: " .. money(queue.vs)) or "vs vendor: -")
        paint(ui.vs, queue.vs ~= nil and queue.vs < 0 and RED or WHITE)
    else
        ui.net:SetText("")
        ui.vs:SetText("")
    end
    self:_UpdateDetails()
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
    ui.dryRun = Kit.Check(content, "Dry run (log only)", function(checked)
        self:SetDryRun(checked)
    end)
    ui.dryRun:SetPoint("TOPRIGHT", content, "TOPRIGHT", -198, 1)
    ui.message = Kit.Label(content, "", "small")
    ui.message:SetPoint("TOPLEFT", content, "TOPLEFT", 172, -6)
    ui.message:SetJustifyH("LEFT")
    ui.message:SetWidth(380)
    if ui.message.SetWordWrap then
        ui.message:SetWordWrap(false)
    end

    -- The details pane: the next post of the queue.
    local pane = Kit.Inset(content)
    pane:SetPoint("TOPLEFT", content, "TOPLEFT", 0, DETAILS_TOP)
    pane:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, DETAILS_TOP)
    pane:SetHeight(DETAILS_HEIGHT)
    local d = { frame = pane }
    d.icon = pane:CreateTexture(nil, "ARTWORK")
    d.icon:SetSize(40, 40)
    d.icon:SetPoint("TOPLEFT", pane, "TOPLEFT", 8, -8)
    local function line(role, x, y, width)
        local label = Kit.Label(pane, "", role)
        label:SetPoint("TOPLEFT", pane, "TOPLEFT", x, -y)
        label:SetWidth(width)
        label:SetJustifyH("LEFT")
        if label.SetWordWrap then
            label:SetWordWrap(false)
        end
        return label
    end
    d.name = line("highlight", 56, 6, 400)
    d.operation = line("small", 56, 22, 190)
    d.stack = line("small", 250, 22, 150)
    -- The price box: the user can type the price for each item, for example 1g 20s 5c.
    d.priceLabel = line("small", 56, 40, 66)
    d.priceLabel:SetText("Price each:")
    d.priceInput = Kit.Input(pane, 110, function()
        self:_UpdateDetails()
    end, function()
        self:_UpdateDetails()
    end)
    d.priceInput:SetPoint("TOPLEFT", pane, "TOPLEFT", 126, -36)
    if d.priceInput.SetMaxLetters then
        d.priceInput:SetMaxLetters(24)
    end
    d.priceInput:HookScript("OnTextChanged", function()
        if not self.filling then
            self:_UpdateDetails()
        end
    end)
    Kit.Tooltip(d.priceInput, "Price for each item", { "Type gold, silver and copper, for example 1g 20s 5c or 120s.",
        "A plain number is copper. Post uses this price." })
    d.price = line("small", 246, 40, 210)
    d.warn = line("small", 56, 56, 400)
    d.deposit = line("small", 470, 6, 290)
    d.lowest = line("small", 470, 22, 290)
    d.net = line("small", 470, 38, 290)
    d.vs = line("small", 470, 54, 290)
    -- A hit frame over the lowest line shows what the number means.
    d.lowestHit = CreateFrame("Frame", nil, pane)
    d.lowestHit:SetPoint("TOPLEFT", pane, "TOPLEFT", 470, -20)
    d.lowestHit:SetSize(290, 16)
    d.lowestHit:EnableMouse(true)
    Kit.Tooltip(d.lowestHit, "Lowest on AH", { LOWEST_TIP })
    ui.details = d



    ui.tree = Kit.CreateTree(content, { rowHeight = ROW_HEIGHT, inset = true,
        initRow = function(row, node, depth, isCollapsed, hasChildren)
            self:_InitTreeRow(row, node, depth, isCollapsed, hasChildren)
        end,
        onSelect = function(node)
            self:SelectNode(node)
        end })
    ui.tree.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, TREE_TOP)
    ui.tree.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, BAR_HEIGHT)
    -- The column titles over the tree.
    local edge = ui.tree.contentInsets
    local headers = Kit.CreateColumnHeader(content, COLUMNS,
        { gap = COLUMN_GAP, left = edge.left, right = edge.right })
    headers.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, DETAILS_TOP - DETAILS_HEIGHT - 4)
    headers.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, DETAILS_TOP - DETAILS_HEIGHT - 4)
    headers.frame:SetHeight(HEADER_HEIGHT)
    ui.headers = headers
    ui.logList = Kit.CreateList(content, { rowHeight = 18, inset = true, initRow = function(row, data)
        self:_InitLogRow(row, data)
    end })
    ui.logList.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, DETAILS_TOP)
    ui.logList.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, BAR_HEIGHT)

    -- The bottom bar. The post button posts in its own click handler: the protected call needs the click.
    ui.postNext = Kit.Button(content, "Post", 100, nil)
    ui.postNext:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    ui.postNext:SetScript("OnClick", function()
        self:PostNext()
    end)
    -- Post all is a queue: each click posts one auction, the next one of the selection. The post needs the click.
    ui.postAll = Kit.Button(content, "Post all", 120, nil)
    ui.postAll:SetPoint("LEFT", ui.postNext, "RIGHT", 6, 0)
    ui.postAll:SetScript("OnClick", function()
        self:PostAll()
    end)
    ui.skip = Kit.Button(content, "Skip", 60, function()
        self:Skip()
    end)
    ui.skip:SetPoint("LEFT", ui.postAll, "RIGHT", 6, 0)
    local function bottom(previous, gap, width)
        local label = Kit.Label(content, "", "small")
        label:SetPoint("LEFT", previous, "RIGHT", gap, 0)
        label:SetWidth(width)
        label:SetJustifyH("LEFT")
        if label.SetWordWrap then
            label:SetWordWrap(false)
        end
        return label
    end
    ui.progress = bottom(ui.skip, 8, 100)
    ui.deposit = bottom(ui.progress, 4, 110)
    ui.net = bottom(ui.deposit, 4, 150)
    ui.vs = bottom(ui.net, 4, 150)
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
    -- The bags change after a post: read them again so that a posted item leaves the list.
    bus:Subscribe("BAG_UPDATE_DELAYED", OWNER, function()
        self:_OnBags()
    end)
    self.events[#self.events + 1] = "BAG_UPDATE_DELAYED"
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
-- itemInfo, maxStack(itemID), vendorPrice(itemID) (copper for one item, or nil), confirm(name, text, onAccept),
-- getRecord(key), now(), itemLink(itemID) (link, quality), warn(title, text, yesLabel, onYes).
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
        vendorPrice = deps.vendorPrice or defaultVendorPrice,
        maxStack = deps.maxStack or defaultMaxStack,
        confirm = deps.confirm or function(...)
            return ns.Kit.Confirm(...)
        end,
        itemLink = deps.itemLink or defaultItemLink,
        warn = deps.warn or openWarning,
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
