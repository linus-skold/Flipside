local _, ns = ...

-- The Selling tab of the Auction House: it reads the bags, searches each item, decides the post and posts it.
-- The post calls are protected (D26): only a click handler calls them, one post for each click.
-- The Buy button buys the selected level, or the cheapest level that is not yours, after the same confirm as the
-- Buying tab (ns.BuyFlow). Its protected calls run in a click handler too, one for each click (D26).
-- A host (ns.AuctionTabHost) owns the Blizzard frame and the tab button.
local SellingTab = {}
ns.SellingTab = SellingTab

local BuyFlow = ns.BuyFlow -- the parts of a buy that the Buying tab shares
local BuyDialog = ns.BuyDialog -- the confirm box of a buy

local OWNER = "Flipside.SellingTab"
local DIALOG = "FLIPSIDE_CONFIRM_POST"
local SEARCH_TIMEOUT = 10
local RETRY_SECONDS = 5
local MULTI_TIMEOUT = 15
local MULTI_TIMEOUT_PER_STACK = 3
local SECONDS_PER_HOUR = 3600
local POST_TIMEOUT = 5 -- seconds after which the post lock ends, with or without a result
local BUSY_TEXT = "The auction house is busy. Wait a moment."
local GATE_POLL_SECONDS =0.25 -- seconds between two checks of the throttle gate while it is closed
local NAME_REFRESH_DELAY = 0.2 -- seconds that item name events wait before one redraw
local QUOTE_WAIT = 10 -- seconds that a commodity buy waits for its quote
local CONFIRM_WAIT = 15 -- seconds that a buy waits for the result of the server
local DEAL_PERCENT = 30 -- a lowest price this many percent under the market value shows as a deal
local CONFIRM_BOX = "FlipsideBuyConfirm" -- the box of the Buying tab: one buy box for both tabs
local BUY_TEXT = "Buy"
local ROWS_TRIES = 3 -- most retries of the search for the rows of the pane while the AH is not ready
-- Seconds that a click waits before the search for the rows of the pane starts (debounce). It is not GATE_POLL_SECONDS:
-- the gate poll timers and these timers must stay apart.
local ROWS_DELAY = 0.3
local DOT_SECONDS = 0.4 -- seconds between two steps of the dots of the loading text
local INFO_TRIES = 3 -- failed tries (an event or a timeout with no data) before an entry is skipped
local INFO_TIMEOUT = 10 -- seconds that an entry waits for item data before it tries again

-- Write a line to the log. The logger can be missing.
local function log(level, text)
    if ns.Log and ns.Log.Write then
        ns.Log.Write("selling", level, text)
    end
end

local NONE_ID = "none"
local BASE_GROUP = 1
local ROW_HEIGHT = 22
local TREE_INDENT = 14
local ITEM_WIDTH = 190
local ITEM_LEAD = 18
local ICON_LEAD = 22
local COLUMN_GAP = 6
local DETAILS_TOP = -28
local DETAILS_HEIGHT = 100
-- Left offsets in the details pane: the stack count box, and the stack size or quantity box.
local STACKS_X = 320
local QTY_X = 414
local SINGLE_QTY_X = 392
local HEADER_HEIGHT = 18
local TOP_ROOM = 28 -- height that the lower part gains when the Stop button is hidden
local TREE_TOP = DETAILS_TOP - DETAILS_HEIGHT - 4 - HEADER_HEIGHT
local RED = { 1, 0.3, 0.3 }
local VALUE_GREEN = "|cff66ff66" -- green, as a client colour code
local VENDOR_SKIP = "vendor pays more than the AH"
local WHITE = { 1, 1, 1 }
local GREY = { 0.5, 0.5, 0.5 }
local ORANGE = { 1, 0.6, 0.2 }
local GREEN = { 0.4, 1, 0.4 }
local YELLOW = { 1, 0.82, 0.1 } -- the rows of your own auctions in the level list
local MAX_PRICE = 100000000000

local function paint(label, color)
    label:SetTextColor(color[1], color[2], color[3])
end
local SYNC_INTERVAL = 1

-- The columns of the item list (Kit.ColumnLayout): the header and every row share them.
-- The item cell (icon and name) is drawn by the row itself. The Info column fills the rest.
-- The tree is compact because the level pane is always at its right: the Operation and Info columns are hidden (the
-- reason of an entry shows in the warning line of the details pane) and there is no Lowest column (the pane shows it).
local COLUMNS = {
    { key = "item", title = "Item", width = ITEM_WIDTH, owned = true },
    { key = "price", title = "Your price", width = 78, number = true },
    { key = "operation", title = "Operation", width = 80, hidden = true },
    { key = "net", title = "Net", width = 78, number = true },
    { key = "info", title = "Info", hidden = true },
}
local COLUMN_OPTIONS = { gap = COLUMN_GAP }
SellingTab.COLUMNS = COLUMNS

-- The level pane: one row for each price level of the shown item, always at the right of the item tree. A Buy button
-- with an amount box sits under it.
local LEVEL_GAP = 6 -- space between the tree and the level pane
local WIDE_CONTENT = 760 -- content width from which the pane is wide (Forever and TBC); narrower is a fallback
local LEVEL_WIDTH = { wide = 320, tight = 220 }
local LEVEL_MAX = 40 -- most rows of the level pane
local BUY_ROW = 30 -- height of the row of the Buy button under the pane
local JUMP_PERCENT = 10 -- a quote this many percent above the list estimate shows as a price jump
local AMOUNT_TEXT = "the amount must be a whole number above 0"
local LEVEL_COLUMNS = {
    { key = "price", title = "Unit price", width = 150, number = true },
    { key = "available", title = "Available", width = 110, number = true },
}
-- The widths of the level columns for a wide and a tight pane, and the gap between the columns.
local LEVEL_WIDTHS = { wide = { 150, 110, gap = 6 }, tight = { 100, 76, gap = 4 } }
local LEVEL_OPTIONS = { gap = LEVEL_WIDTHS.wide.gap }
SellingTab.LEVEL_COLUMNS = LEVEL_COLUMNS

local function money(copper)
    if ns.TooltipLines and ns.TooltipLines.FormatMoney then
        return ns.TooltipLines.FormatMoney(copper)
    end
    return GetMoneyString(math.floor((copper or 0) + 0.5))
end

-- Check a price from the money input. Returns the copper, or nil and a reason.
function SellingTab.CheckPrice(copper)
    if type(copper) ~= "number" or copper < 1 then
        return nil, "the price must be at least 1c"
    end
    if copper > MAX_PRICE then
        return nil, "the price is too large"
    end
    return copper
end

-- Build the tree nodes from the entries. A group node shows only if it holds a bag item, directly or deeper.
-- Items first (bag order), then the subgroups. The roots are the top-level groups (the children of the hidden
-- Base group). Items of no group go to the last root node "[No group]".
-- Group node: { id = "g<ID>", kind = "group", groupID, text, children }.
-- Item node: { id = "i<key>", kind = "item", entry, text }.
function SellingTab.BuildNodes(rules, entries)
    local byGroup = {}
    for _, entry in ipairs(entries) do
        -- An item that is posted for real is on the AH now, so the list does not show it.
        if not (entry.status == "done" and entry.real) then
            -- Ask for the group each time: a group change moves the item.
            entry.groupID = rules:GroupOf(entry.key)
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

-- The bag stack for a post of need items: the first stack that holds that many, else the biggest stack.
function SellingTab.StackFor(candidate, need)
    local best
    for _, stack in ipairs(candidate.stacks or {}) do
        if stack.count >= need then
            return stack
        end
        if not best or stack.count > best.count then
            best = stack
        end
    end
    return best
end

-- Units for a client that posts several stacks in one call: one unit with all the full stacks, then one unit with
-- the smaller rest (decision.remainder). A unit is { bag, slot, quantity (of one stack), stacks }.
local function multisellUnits(candidate, decision)
    local units = {}
    local size = math.max(1, decision.quantity)
    local first = SellingTab.StackFor(candidate, size)
    units[1] = { bag = first.bag, slot = first.slot, quantity = size, stacks = math.max(1, decision.auctions or 1) }
    local rest = tonumber(decision.remainder) or 0
    if rest > 0 then
        local stack = SellingTab.StackFor(candidate, rest)
        units[2] = { bag = stack.bag, slot = stack.slot, quantity = rest, stacks = 1 }
    end
    return units
end

-- Split a post decision into units. A unit is one protected post: { bag, slot, quantity }.
-- A commodity is one unit. An item gives one unit for each auction, taken from the stacks in bag order.
-- On TBC an item gives one unit for all the full stacks and one for the rest (stacks is the stack count of a unit).
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
    if ns.SellingPlan.Multisell() then
        return multisellUnits(candidate, decision)
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
        if decision.remainder then
            parts = parts .. string.format(" + 1 x %d", decision.remainder)
        end
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
    if entry.postText then
        return entry.postText
    elseif status == "noop" then
        return "no operation"
    elseif status == "waiting" then
        return entry.waitText or candidate and candidate.reason or "not searched yet"
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
    profit.auctions = 0
    for _, unit in ipairs(left) do
        profit.auctions = profit.auctions + (unit.stacks or 1)
    end
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
        nextStacks = unit.stacks or 1,
        stackSize = unit.quantity,
        duration = decision.duration,
        deposit = profit.depositKnown and profit.deposit or nil,
        lowest = decision.competitor,
        net = profit.net,
        vs = profit.vs,
    }
end

-- The deposit as text: "unknown" if the deposit is nil (never 0).
function SellingTab.DepositValue(deposit)
    return deposit and money(deposit) or "unknown"
end

-- The text of the deposit line of a warning: "unknown" if the deposit is nil.
function SellingTab.DepositText(deposit)
    return "Deposit: " .. SellingTab.DepositValue(deposit)
end

-- The price of one item from the price of one stack. The result is rounded down to whole copper:
-- a stack price of 1005c for 10 items gives 100c each. A stack size under 1 counts as 1.
function SellingTab.UnitFromStack(stackPrice, size)
    size = math.max(1, math.floor(tonumber(size) or 1))
    return math.floor(math.max(0, tonumber(stackPrice) or 0) / size)
end

-- The price of one stack from the price of one item: the price of one item times the stack size.
function SellingTab.StackFromUnit(unitPrice, size)
    return math.max(0, tonumber(unitPrice) or 0) * math.max(1, math.floor(tonumber(size) or 1))
end

-- The total price of one post: the price of one item times the items of one stack times the stacks of the unit.
function SellingTab.TotalPrice(unitPrice, unit)
    return math.max(0, tonumber(unitPrice) or 0) * unit.quantity * (unit.stacks or 1)
end

-- Tell if the vendor pays more than the AH for the next post. Returns the vendor total and the net, or nil.
-- unit is { quantity, deposit }; price is per item; vendorPrice is per item or nil.
function SellingTab.VendorBetter(price, unit, vendorPrice)
    if not vendorPrice or not unit or not price then
        return nil
    end
    local profit = ns.SellingPlan.Profit(price, { unit }, vendorPrice)
    if profit.vendor and profit.vendor > profit.net then
        return profit.vendor, profit.net, profit
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
local function defaultRequestItem(itemID)
    if C_Item and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(itemID)
    end
end

-- The item name inside the brackets of a link; nil if the link is missing or its brackets are empty.
local function linkName(link)
    local name = type(link) == "string" and link:match("|h%[(.-)%]|h") or nil
    return name ~= "" and name or nil
end

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

-- The max stack size of an item, or nil while the item data is not loaded. The tab never guesses 1: it waits for the
-- data (see Tab:_WaitInfo). A client with no item API (a spec) gives 1.
local function defaultMaxStack(itemID)
    if not (C_Item and C_Item.GetItemMaxStackSizeByID) then
        return 1
    end
    if C_Item.IsItemDataCachedByID and not C_Item.IsItemDataCachedByID(itemID) then
        if C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(itemID)
        end
        return nil
    end
    local size = C_Item.GetItemMaxStackSizeByID(itemID)
    return type(size) == "number" and size >= 1 and size or nil
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

-- The warning box: a square Kit window with a text and the buttons Post, Skip and Cancel.
-- onPost runs in the click of the Post button, so the post keeps its hardware event.
-- options is optional: { post = text, skip = text or false, cancel = text } sets the button texts. skip = false
-- hides the Skip button.
local function openWarning(title, text, onPost, onSkip, onCancel, options)
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
        -- Run the callback of the button that was clicked, then close the box. The callback runs first and in the
        -- click, so the protected post is the first action of the click. A callback that opens the box again keeps it.
        local function answer(key)
            return function()
                local callback = dialog[key]
                dialog.onPost, dialog.onSkip, dialog.onCancel = nil, nil, nil
                local ok, err = true, nil
                if callback then
                    ok, err = pcall(callback)
                end
                if not (dialog.onPost or dialog.onSkip or dialog.onCancel) then
                    dialog:Hide()
                end
                if not ok then
                    error(err, 0)
                end
            end
        end
        dialog.yesButton = Kit.Button(dialog, "Post", 90, answer("onPost"))
        dialog.yesButton:SetPoint("BOTTOM", dialog, "BOTTOM", -100, pad + 4)
        dialog.skipButton = Kit.Button(dialog, "Skip", 90, answer("onSkip"))
        dialog.skipButton:SetPoint("BOTTOM", dialog, "BOTTOM", 0, pad + 4)
        dialog.noButton = Kit.Button(dialog, "Cancel", 90, answer("onCancel"))
        dialog.noButton:SetPoint("BOTTOM", dialog, "BOTTOM", 100, pad + 4)
    end
    local dialog = warnDialog
    dialog.onPost, dialog.onSkip, dialog.onCancel = onPost, onSkip, onCancel
    options = options or {}
    dialog.yesButton:SetText(options.post or "Post")
    dialog.skipButton:SetText(options.skip or "Skip")
    dialog.skipButton:SetShown(options.skip ~= false)
    dialog.noButton:SetText(options.cancel or "Cancel")
    if dialog.SetTitle then
        dialog:SetTitle(title or "")
    end
    dialog.text:SetText(text or "")
    local textHeight = dialog.text.GetStringHeight and dialog.text:GetStringHeight() or 14
    dialog.textFrame:SetHeight(textHeight)
    dialog:SetHeight(math.max(150, 40 + textHeight + 20 + 22 + Kit.Theme.padding + 8))
    dialog.text:SetTextColor(ORANGE[1], ORANGE[2], ORANGE[3])
    dialog:Show()
    dialog:Raise()
end

local Tab = {}
Tab.__index = Tab

-- Move the details pane and the list up when the Stop button is hidden. The list bottom stays.
-- A host with a band (api.band) holds the Stop button outside the content, so the pane never moves.
function Tab:_Layout()
    local ui = self.ui
    if not (ui and ui.postNext) then
        return
    end
    local up = (not self.api.band and ui.stop:IsShown()) and 0 or TOP_ROOM
    local content = self.content
    local headerTop = DETAILS_TOP - DETAILS_HEIGHT - 4 + up
    -- The room that the level pane takes at the right of the tree.
    local room = self:_LevelWidth() + LEVEL_GAP
    ui.details.frame:ClearAllPoints()
    ui.details.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, DETAILS_TOP + up)
    ui.details.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, DETAILS_TOP + up)
    ui.headers.frame:ClearAllPoints()
    ui.headers.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, headerTop)
    ui.headers.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", -room, headerTop)
    ui.tree.frame:ClearAllPoints()
    ui.tree.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, headerTop - HEADER_HEIGHT)
    ui.tree.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -room, 0)
    if ui.levelList then
        local width = self:_LevelWidth()
        ui.levelHeader.frame:ClearAllPoints()
        ui.levelHeader.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, headerTop)
        ui.levelHeader.frame:SetWidth(width)
        ui.levelList.frame:ClearAllPoints()
        ui.levelList.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, headerTop - HEADER_HEIGHT)
        ui.levelList.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, BUY_ROW)
        ui.levelList.frame:SetWidth(width)
        -- The Buy row under the pane: the Buy button at the right, the amount box left of it, the info text next.
        ui.buyRow:ClearAllPoints()
        ui.buyRow:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
        ui.buyRow:SetSize(width, BUY_ROW)
    end
end

-- The width of the level pane: wide when the content is 760 px or more (Forever and TBC), else tight (a fallback).
function Tab:_LevelWidth()
    local content = self.content
    local width = content and content.GetWidth and content:GetWidth() or 0
    return (type(width) == "number" and width >= WIDE_CONTENT) and LEVEL_WIDTH.wide or LEVEL_WIDTH.tight
end

-- Set the columns of the level pane for its width and draw them again.
function Tab:_ApplyColumns()
    local set = LEVEL_WIDTHS[self:_LevelWidth() == LEVEL_WIDTH.wide and "wide" or "tight"]
    for index, column in ipairs(LEVEL_COLUMNS) do
        column.width = set[index]
    end
    LEVEL_OPTIONS.gap = set.gap
    self.colVersion = (self.colVersion or 0) + 1
    self.appliedWidth = self:_LevelWidth()
    local ui = self.ui
    if ui and ui.levelHeader then
        ui.levelHeaderOptions.gap = set.gap
        ns.Kit.LayoutColumnLabels(ui.levelHeader.labels, ui.levelHeader.frame, LEVEL_COLUMNS, ui.levelHeaderOptions)
    end
    self.levelShown = nil
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

function Tab:_Name(entry)
    local item = entry.item
    if item.name and item.name ~= "" then
        return item.name
    end
    local fromLink = linkName(item.link)
    if fromLink then
        return fromLink
    end
    local name = self.deps.itemInfo(item.itemID or 0)
    if not name or name:match("^item %d+$") then
        self:_RequestName(item.itemID)
    end
    return name
end

-- Ask the client to load the data of an item once. The redraw comes with ITEM_DATA_LOAD_RESULT.
function Tab:_RequestName(itemID)
    if type(itemID) ~= "number" or self.requested[itemID] then
        return
    end
    self.requested[itemID], self.waiting[itemID] = true, true
    log("debug", "name requested for item " .. itemID)
    pcall(self.deps.requestItem, itemID)
end

-- Item data arrived. If a row waits for it, draw the rows again (one redraw for a burst of events).
function Tab:_OnItemLoaded(itemID)
    if type(itemID) == "number" then
        self:_RetryInfo(itemID)
    end
    if not (type(itemID) == "number" and self.waiting[itemID]) then
        return
    end
    self.waiting[itemID] = nil
    log("debug", "name received for item " .. itemID)
    if self.refreshQueued then
        return
    end
    self.refreshQueued = true
    self.deps.after(NAME_REFRESH_DELAY, function()
        self.refreshQueued = false
        if self.active and self.ui then
            self.ui.tree:Refresh()
            self:_UpdateDetails()
        end
    end)
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
            unit.quantity, decision.commodity == true, nil, nil, unit.stacks)
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
    local commodity, maxStack = self:_StackInfo(itemID)
    -- The max stack size is not known yet and the item is not a commodity: do not guess 1. Wait for the data.
    if not candidate.reason and commodity ~= true and maxStack == nil then
        self:_WaitInfo(entry)
        return
    end
    entry.waitText, entry.infoFails = nil, nil
    local decision = deps.plan.Decide(candidate, rows, {
        isCommodity = commodity == true or nil,
        maxStack = maxStack,
    })
    entry.decision = decision
    entry.marketValue = self:_Market(entry)
    -- single: an item that has no stack price: a Forever item auction (no stacks) or a TBC item of max stack 1.
    entry.market = { commodity = commodity == true, maxStack = maxStack,
        single = commodity ~= true and (not ns.SellingPlan.Multisell() or (maxStack or 1) <= 1) }
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

-- The commodity flag and the max stack size of an item. The flag is true, false or nil (not known). With no answer
-- on a client that has a commodity market (Forever), a max stack size above 1 means a commodity (SPEC 5.1 point 5).
-- A client with no commodity market (TBC) has no commodity. The max stack size is nil while the item data loads.
function Tab:_StackInfo(itemID)
    local deps = self.deps
    if type(itemID) ~= "number" then
        return nil, nil
    end
    local ok, commodity = pcall(deps.client.ItemIsCommodity, itemID)
    commodity = ok and commodity or nil
    local maxStack = deps.maxStack(itemID)
    if commodity == nil and ns.Flavour and ns.Flavour.hasCommodityMarket == true and maxStack and maxStack > 1 then
        commodity = true
    elseif commodity == nil and ns.Flavour and ns.Flavour.hasCommodityMarket == false then
        commodity = false
    end
    return commodity, maxStack
end

-- Put an entry in the waiting state until the item data is loaded. It asks the client for the data once and has one
-- record in self.infoWait. Two things end the wait: ITEM_DATA_LOAD_RESULT and a timeout (INFO_TIMEOUT seconds). Both
-- search the entry again (_RetryEntries). A search that still finds no data counts as a failed try. After INFO_TRIES
-- failed tries the entry is skipped. A new click on a waiting entry changes nothing and uses no try.
function Tab:_WaitInfo(entry)
    local itemID = entry.candidate.itemID
    local retry = entry.infoRetry
    entry.infoRetry = nil
    if retry then
        entry.infoFails = (entry.infoFails or 0) + 1
        if entry.infoFails >= INFO_TRIES then
            entry.status, entry.waitText = "skip", nil
            entry.decision = { action = "skip", reason = "item data is not available", key = entry.candidate.key }
            entry.units, entry.next = {}, 1
            self.deps.log:Add(entry.candidate, entry.decision)
            self:_Update()
            return "skipped"
        end
    end
    entry.status, entry.decision, entry.waitText = "waiting", nil, "item data is loading"
    entry.units, entry.next = {}, 1
    self.infoWait = self.infoWait or {}
    local list = self.infoWait[itemID]
    if not list then
        list = {}
        self.infoWait[itemID] = list
    end
    for _, each in ipairs(list) do
        if each == entry then
            return "skipped"
        end
    end
    list[#list + 1] = entry
    entry.infoToken = (entry.infoToken or 0) + 1
    local token = entry.infoToken
    pcall(self.deps.requestItem, itemID)
    self.deps.after(INFO_TIMEOUT, function()
        if entry.infoToken == token and self.infoWait and entry.status == "waiting" then
            self:_InfoTimeout(entry)
        end
    end)
    self:_Update()
    return "skipped"
end

-- The wait of an entry ran out with no event: search it again, as for an event.
function Tab:_InfoTimeout(entry)
    local itemID = entry.candidate.itemID
    local list = self.infoWait and self.infoWait[itemID]
    if not list then
        return
    end
    for index, each in ipairs(list) do
        if each == entry then
            table.remove(list, index)
            break
        end
    end
    if #list == 0 then
        self.infoWait[itemID] = nil
    end
    self:_RetryEntries({ entry })
end

-- The item data of an item arrived: search the entries again that waited for it.
function Tab:_RetryInfo(itemID)
    local list = self.infoWait and self.infoWait[itemID]
    if not list then
        return
    end
    self.infoWait[itemID] = nil
    self:_RetryEntries(list)
end

-- Search entries again after a wait. Only an entry that is still waiting, is in the selection and belongs to an open
-- tab goes in the queue. Another entry stays "waiting" and is searched when it is selected.
function Tab:_RetryEntries(entries)
    for _, entry in ipairs(entries) do
        entry.infoToken = (entry.infoToken or 0) + 1
        local selected = false
        for _, each in ipairs(self.selection) do
            selected = selected or each == entry
        end
        if entry.status == "waiting" and selected and self.active then
            entry.infoRetry = true
            if self.queue then
                self.queue.list[#self.queue.list + 1] = entry
            else
                self.queue = { list = { entry }, pos = 0 }
            end
        end
    end
    self:_Next()
end

-- Forget the entries that wait for item data (Stop, AH close, a new bag read). Their timers do nothing. An entry that
-- waited stays "waiting" and is searched when it is selected again.
function Tab:_ClearInfoWait()
    for _, list in pairs(self.infoWait or {}) do
        for _, entry in ipairs(list) do
            entry.infoToken = (entry.infoToken or 0) + 1
        end
    end
    self.infoWait = nil
end
-- Start the live search of one entry. Returns "started", "skipped" or "wait" with a text.
function Tab:_Start(entry)
    local candidate = entry.candidate
    if candidate.reason or not candidate.itemID then
        self:_Decide(entry, {})
        return "skipped"
    end
    -- Search only when the item data is known: the rows and the post depend on the commodity flag and the stack size.
    local commodity, maxStack = self:_StackInfo(candidate.itemID)
    if commodity ~= true and maxStack == nil then
        return self:_WaitInfo(entry)
    end
    entry.infoRetry = nil
    return self:_Launch(entry, false)
end

-- Send the live search of an entry. Only one search is in flight (self.pending). rowsOnly is true for a search that
-- only brings the rows for the level pane: the decision of the entry stays as it is. Returns "started", or "wait"
-- and a text.
function Tab:_Launch(entry, rowsOnly)
    local client = self.deps.client
    local candidate = entry.candidate
    if not client.IsReady() then
        return "wait", "waiting for the Auction House to be ready"
    end
    local ok, text = client.LiveSearch(candidate.itemID)
    if not ok then
        return "wait", text or "the search was refused"
    end
    self.token = self.token + 1
    local token = self.token
    self.live, self.levelSel, self.amount, self.amountBad = nil, nil, nil, false -- the client list is new now
    if not rowsOnly then
        entry.status = "searching"
    end
    self.pending = { entry = entry, itemID = candidate.itemID, token = token, rowsOnly = rowsOnly }
    -- A search that gets no result ends with the timeout, so that the next search can start.
    self.deps.after(SEARCH_TIMEOUT, function()
        local pending = self.pending
        if pending and pending.token == token then
            self.pending = nil
            if rowsOnly then
                self.rowsFailed = candidate.itemID
            elseif self:_InSelection(entry) then
                entry.status = "skip"
                entry.decision = { action = "skip", reason = "no response", key = candidate.key }
                self.deps.log:Add(candidate, entry.decision)
                -- No second search at once: a new click searches again.
                self.rowsFailed = candidate.itemID
            else
                entry.status = "waiting" -- not wanted any more: no mark, it is searched when it is selected again
            end
            self:_Update()
            self:_AfterSearch()
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
        self:_StartWantedRows()
    end)
end

-- True if the entry is in the current selection.
function Tab:_InSelection(entry)
    for _, each in ipairs(self.selection) do
        if each == entry then
            return true
        end
    end
    return false
end

-- True if the rows of the last search are the rows of this entry.
function Tab:_HasRows(entry)
    return self.live ~= nil and self.live.itemID == entry.item.itemID
end

-- After a search ended (result, drop or timeout): go on with the queue, else with the rows that the pane wants.
function Tab:_AfterSearch()
    self:_Next()
    self:_StartWantedRows()
end

-- Latest selection wins. A click on one item sets self.wanted. The rows of that item are searched when no search is
-- in flight, else when the search that runs has ended. A result for an entry that is not selected any more is
-- dropped. Only the last click counts: the debounce below lets a fast run of clicks end in one search.
function Tab:_WantRows()
    self.rowsToken = (self.rowsToken or 0) + 1
    local token = self.rowsToken
    self.rowsScheduled = true
    self.deps.after(ROWS_DELAY, function()
        if self.rowsToken ~= token then
            return
        end
        self.rowsScheduled = false
        self:_StartWantedRows()
        self:_Update()
    end)
end

-- Start the search for the rows of the wanted item if the pane lacks them and nothing else is searching.
function Tab:_StartWantedRows()
    local entry = self.wanted
    if not entry or self.pending or self.queue or self.rowsScheduled then
        return
    end
    -- No search for the pane during a post, a multisell or a buy, or while the tab is hidden.
    if self.awaiting or self.multi or self.buy or self.lock or not self.active then
        return
    end
    if not self:_InSelection(entry) or self:_HasRows(entry) or self.rowsFailed == entry.item.itemID then
        return
    end
    local candidate = entry.candidate
    if not candidate or candidate.reason or not candidate.itemID or entry.status == "waiting"
        or entry.status == "searching" or entry.next > 1 then
        return
    end
    local commodity, maxStack = self:_StackInfo(candidate.itemID)
    if commodity ~= true and maxStack == nil then
        return
    end
    if self:_Launch(entry, true) == "wait" then
        -- The AH is not ready: try again, but not for ever.
        self.rowsTries = (self.rowsTries or 0) + 1
        if self.rowsTries > ROWS_TRIES then
            self.rowsFailed, self.rowsTries = candidate.itemID, nil
            self:_Update()
            self:_ShowBusy("The prices could not be loaded. Click the item again.")
            return
        end
        self:_ScheduleRetry()
    else
        self.rowsTries = nil
        self:_Update()
    end
end

-- True if something will search the entry: it is the search that runs, it is in the queue or it waits for item data.
function Tab:_Searching(entry)
    if self.pending and self.pending.entry == entry then
        return true
    end
    for _, each in ipairs(self.queue and self.queue.list or {}) do
        if each == entry then
            return true
        end
    end
    for _, list in pairs(self.infoWait or {}) do
        for _, each in ipairs(list) do
            if each == entry then
                return true
            end
        end
    end
    return false
end

-- True while the pane waits for the rows of its item: a search is on its way or will start.
function Tab:_PaneLoading()
    local entry = self.wanted
    if not entry or not self:_InSelection(entry) or self:_HasRows(entry) then
        return false
    end
    -- An entry that waits or searches is loading only while something searches it (Stop and the AH close end it).
    if entry.status == "waiting" or entry.status == "searching" then
        return self:_Searching(entry)
    end
    return self.rowsFailed ~= entry.item.itemID and (self.pending ~= nil or self.rowsScheduled == true
        or self.queue ~= nil or self.retrying == true)
end

-- Animate the dots of the loading text. The ticker stops when the pane has its rows.
function Tab:_TickLoading()
    if self.ticking then
        return
    end
    self.ticking = true
    self.deps.after(DOT_SECONDS, function()
        self.ticking = false
        if self.ui and self.active and self:_PaneLoading() then
            self.dots = (self.dots or 0) % 3 + 1
            self.ui.levelLoading:SetText("Loading prices" .. string.rep(".", self.dots))
            self:_TickLoading()
        end
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
            self:_Update()
            return
        end
        local status = self:_Start(entry)
        if status == "wait" then
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
    if self.multi then
        return false, "wait for the post to end first"
    end
    if self.awaiting then
        return false, "confirm or skip the open post first"
    end
    if self.buy then
        return false, "end the open buy first"
    end
    local deps = self.deps
    self.queue, self.wanted = nil, nil
    self:_ClearInfoWait()
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
    local fresh
    if not decision.commodity and ns.SellingPlan.Multisell() then
        -- Keep the size and the stack count of each unit that is left; only the bag slot is new.
        fresh = {}
        for _, unit in ipairs(old) do
            local stack = SellingTab.StackFor(candidate, unit.quantity)
            if stack then
                fresh[#fresh + 1] = { bag = stack.bag, slot = stack.slot, quantity = unit.quantity,
                    stacks = unit.stacks }
            end
        end
    else
        fresh = SellingTab.BuildUnits(candidate, { quantity = decision.quantity, auctions = left,
            commodity = decision.commodity })
    end
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
    if self.awaiting or self.multi or self.buy or not self.ui or not self.loaded then
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

-- The kept sale slot (TBC). The client gives the deposit only for the item in the sale slot. A select click puts the
-- item of the pane in the slot (client.HoldSlot, a protected step) and the tab keeps it there. self.held is
-- { entry = the entry that owns the slot, or nil when no entry owns it now }. While the entry owns the slot, every
-- redraw of the pane reads the deposit again (client.Deposit, a plain read). The slot is released (client.ReleaseSlot,
-- a protected step, so only in a click) on a new select click, a Skip click, a tab leave and an AH close.

-- The entry whose item the slot should hold: the entry that the pane shows or Post posts next, else the first entry of
-- the selection that waits for its decision (its bag stack goes in the slot now, the decision comes later).
function Tab:_HoldTarget()
    local focus = self:_Focus()
    if focus then
        return focus
    end
    for _, entry in ipairs(self.selection) do
        local candidate = entry.candidate
        if (entry.status == "waiting" or entry.status == "searching") and candidate and candidate.stacks
            and candidate.stacks[1] then
            return entry
        end
    end
    return nil
end

-- The bag slot, the stack size and the number of stacks to put in the sale slot for an entry, or nil.
function Tab._HoldArgs(_, entry)
    local unit = entry.status == "ready" and entry.units[entry.next]
    if unit and entry.decision and not entry.decision.commodity then
        return unit.bag, unit.slot, unit.quantity, unit.stacks or 1
    end
    local stack = entry.candidate and entry.candidate.stacks and entry.candidate.stacks[1]
    if stack and not (entry.decision and entry.decision.commodity) then
        return stack.bag, stack.slot, 1, 1
    end
    return nil
end

-- Put the item of the target entry in the sale slot and keep it there. A slot that fails to fill (cursor busy, locked
-- item, combat, AH hidden) leaves the deposit unknown. Call it only inside a click handler.
function Tab:_Hold()
    local hold = self.deps.client.HoldSlot
    if type(hold) ~= "function" then
        return
    end
    local entry = self:_HoldTarget()
    local bag, slot, quantity, stacks
    if entry then
        bag, slot, quantity, stacks = self:_HoldArgs(entry)
    end
    if not bag then
        self:_Release()
        return
    end
    local plannedID = entry.item and entry.item.itemID or entry.candidate and entry.candidate.itemID
    local ok, placed = pcall(hold, bag, slot, quantity, plannedID, stacks > 1 and stacks or nil)
    if ok and placed then
        self.held = { entry = entry }
    else
        self:_Release()
    end
end

-- Put the kept item back in its bag slot. Call it only inside a click handler, or when the AH closes or the tab leaves.
function Tab:_Release()
    local held = self.held
    self.held = nil
    local release = self.deps.client.ReleaseSlot
    if held and type(release) == "function" then
        pcall(release)
    end
end

-- No entry owns the slot after a change that is not a click: the deposit reads stop, and the next click, the tab leave
-- or the AH close releases the slot.
function Tab:_CheckHeld()
    local held = self.held
    if not held or not held.entry then
        return
    end
    local status = held.entry.status
    local kept = false
    for _, entry in ipairs(self.selection) do
        kept = kept or entry == held.entry
    end
    if not kept or status == "done" or status == "skipped" or status == "failed" or status == "noop" then
        held.entry = nil
    end
end

-- With the item in the sale slot, read the real deposit of the next post and of the units behind it. A plain read:
-- no fill, no protected call. price is the price of one item. nextUnit is the unit that the pane shows. A read that
-- gives nothing leaves the deposit as it was.
function Tab:_ReadHeld(entry, price, decision, nextUnit)
    local held = self.held
    local read = self.deps.client.Deposit
    if not (held and held.entry == entry and decision and nextUnit and not decision.commodity
        and type(price) == "number" and price >= 1) then
        return
    end
    local ready = entry.status == "ready"
    for index = entry.next, ready and #entry.units or entry.next do
        local unit = index == entry.next and nextUnit or entry.units[index]
        local buyout = price * unit.quantity
        local ok, deposit = pcall(read, unit.bag, unit.slot, decision.duration, unit.quantity, false, buyout, buyout,
            unit.stacks)
        if ok and type(deposit) == "number" then
            unit.deposit, unit.depositRead = deposit, true
            entry.depositPrice = price
        end
    end
    local total
    for _, unit in ipairs(entry.units) do
        if unit.deposit then
            total = (total or 0) + unit.deposit
        end
    end
    entry.deposit = total
end

-- The price changed after the deposit read: the stored real deposits are stale, so they become unknown.
function Tab._ForgetDeposits(_, entry)
    local total
    for _, unit in ipairs(entry.units) do
        if unit.depositRead then
            unit.deposit, unit.depositRead = nil, nil
        end
        if unit.deposit then
            total = (total or 0) + unit.deposit
        end
    end
    entry.deposit, entry.depositPrice = total, nil
end

-- A selected item that the user skipped is a normal item again. It gets its first post back and the vendor and
-- price answers of the old run are forgotten, so the checks of the Post click run again. An item that the rule
-- skipped (or that was forced) goes back to the rule skip: Post still asks first.
function Tab:_Revive(entry)
    if entry.status ~= "skipped" and entry.status ~= "failed" then
        return
    end
    entry.note = nil
    entry.vendorForce, entry.warned, entry.manual = nil, nil, nil
    entry.manualQty, entry.manualHours, entry.manualStacks = nil, nil, nil
    entry.next = 1
    if entry.skipDecision then
        entry.decision, entry.skipDecision, entry.units = entry.skipDecision, nil, {}
    end
    local decision = entry.decision
    if decision and decision.action == "post" and #entry.units > 0 then
        entry.status = "ready"
        self:_Restack(entry, entry.item)
    else
        entry.status = "skip"
    end
end

-- Select a tree node: the group and its subgroups, or one item. Start the live searches of the entries that
-- have no result yet. fromClick is true when a mouse click selects the node: then the item of the pane goes in the
-- sale slot and stays there (a protected step), and the slot item of the old selection goes back. Other calls make no
-- protected call.
function Tab:SelectNode(node, fromClick)
    if self.awaiting or self.multi or self.buy then
        if self.ui then
            self.ui.tree.selected = self.selectedId
            self.ui.tree:Refresh()
        end
        return false
    end
    self.selectedId = node.id
    self.levelSel, self.amount, self.amountBad = nil, nil, false
    self.selection = SellingTab.CollectEntries(node, {})
    self.postedCount = 0
    self.priceEntry = nil
    -- Latest selection wins: this click is the item that the pane wants. An older wish is dropped.
    local only = #self.selection == 1 and node.id:sub(1, 1) == "i" and self.selection[1] or nil
    self.wanted, self.rowsFailed, self.rowsTries = only, nil, nil
    self.rowsToken, self.rowsScheduled = (self.rowsToken or 0) + 1, false
    if fromClick and #self.selection == 1 and node.id:sub(1, 1) == "i" then
        self:_Revive(self.selection[1])
    end
    if fromClick then
        self:_Hold()
    else
        self:_CheckHeld()
    end
    local list = {}
    for _, entry in ipairs(self.selection) do
        if entry.status == "waiting" then
            list[#list + 1] = entry
        end
    end
    if #list == 0 then
        self.queue = nil
        -- A decided item has no rows in the pane unless it was the last search: ask for them (after a short delay).
        if only and not self:_HasRows(only) then
            self:_WantRows()
        end
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
    self:_ClearInfoWait()
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
    local entry = pending.entry
    if not self:_InSelection(entry) then
        -- Latest selection wins: the user selected something else while this search ran. Drop the result, give the
        -- entry its wait state back and start the search for the wanted item at once.
        if not pending.rowsOnly and entry.status == "searching" then
            entry.status = "waiting"
        end
        self:_Update()
        self:_AfterSearch()
        return
    end
    local rows = self.deps.client.LiveRows(pending.itemID)
    -- The rows stay for the Buy button. The client list belongs to this item until the next search.
    self.live = { itemID = pending.itemID, rows = rows }
    self.rowsFailed = nil
    if pending.rowsOnly then
        self:_Update()
    else
        self:_Decide(entry, rows)
    end
    self:_AfterSearch()
end

function Tab:_OnReady()
    if self.queue and not self.pending then
        self:_Next()
    end
    self:_StartWantedRows()
end

-- The client made an auction. It ends a one-stack post that waits for it (_EndMulti). A multi-stack post
-- counts its stacks from the multisell events.
function Tab:_OnPosted()
    self.live = nil -- a post changes the AH list
    local m = self.multi
    if m and m.stacks == 1 and m.created < 1 then
        m.created = 1
        if m.armed then
            self:_CheckMulti()
        end
    end
    self:_QueueSync()
end

function Tab:_OnBags()
    self:_QueueSync()
end

-- Read the bags again for a bag event. At most one read in each SYNC_INTERVAL: a read that comes too soon
-- waits for the end of the interval. Events that come while a read waits join it.
function Tab:_QueueSync()
    if self.syncWaiting then
        return
    end
    local deps = self.deps
    local wait = self.lastSync and (self.lastSync + deps.syncInterval - deps.time()) or 0
    if wait <= 0 then
        self:_RunSync()
        return
    end
    self.syncWaiting = true
    deps.after(wait, function()
        self.syncWaiting = false
        self:_RunSync()
    end)
end

function Tab:_RunSync()
    self.lastSync = self.deps.time()
    if not self:SyncBags() and (self.awaiting or self.multi or self.buy) then
        self.syncAgain = true
    end
end

-- The groups or the rules changed: read the operation, the min and the max price of every item again and build
-- the tree again, as a full read of the bags does. The tab keeps the selected node and searches it again.
-- A hidden tab waits until it shows. An open server confirm waits until the confirm ends.
function Tab:_OnRules()
    if not self.loaded then
        return
    end
    if not self.active then
        self.stale = true
    elseif self.awaiting or self.multi or self.buy then
        self.reloadAgain = true
    else
        self:_Reload()
    end
end

function Tab:_Reload()
    self.stale, self.reloadAgain = false, false
    local keep = self.selectedId
    if not self:RefreshBags() then
        return
    end
    local node = keep and findNode(self.nodes, keep)
    if node then
        if self.ui then
            self.ui.tree.selected = node.id
            self.ui.tree:Refresh()
        end
        self:SelectNode(node)
    end
end

-- Log one post of a unit.
function Tab:_Record(entry, quantity, kind, price, duration)
    local decision = entry.decision
    self.deps.log:Add(entry.candidate, {
        action = kind, reason = decision.reason, price = price or decision.price, quantity = quantity, auctions = 1,
        duration = duration or decision.duration,
    })
end

function Tab:_Fail(entry, text)
    entry.status = "failed"
    entry.note = text
    self.awaiting = nil
    local price = entry.decision and entry.decision.price
    self.deps.log:Add(entry.candidate, { action = "failed", reason = text, price = price })
    self:_AfterStep()
    return false, text
end

-- Update the view. If the selection has no post left and no search runs, say so and read the bags again.
function Tab:_AfterStep()
    if not (self.awaiting or self.multi or self.buy) then
        if self.reloadAgain then
            self:_Reload()
            return
        elseif self.syncAgain then
            self.syncAgain = false
            self:SyncBags()
        end
    end
    self:_Update()
    if self:_Focus() or self.pending or self.queue then
        return
    end
    -- A failed post stays in the list with its reason until the user selects the item again.
    for _, entry in ipairs(self.selection) do
        if entry.status == "failed" then
            return
        end
    end
    self:RefreshBags()
end

-- Count one finished unit (a post or a skip). After the last unit of an entry, ask for a fresh owned list.
-- count is the number of auctions that the unit made (default 1).
function Tab:_Advance(entry, posted, count)
    entry.next = entry.next + 1
    entry.manualQty, entry.manualHours, entry.manualStacks = nil, nil, nil
    if posted then
        entry.posted = entry.posted + (count or 1)
        self.postedCount = self.postedCount + (count or 1)
    end
    local following
    if entry.next > #entry.units then
        entry.status = entry.posted > 0 and "done" or "skipped"
        local client = self.deps.client
        if entry.posted > 0 and client.IsReady() then
            pcall(client.RefreshOwned)
        end
        following = self.selectedId == "i" .. entry.key and self:_EntriesAfter(entry) or nil
        -- Find the next group before the rebuild drops the current group.
        local nextGroupId = self:_NextGroupId()
        -- A real post puts the item on the AH: the list drops it now.
        if entry.status == "done" and entry.real then
            self:_RebuildNodes()
        end
        local nextGroup = nextGroupId and findNode(self.nodes, nextGroupId)
        if nextGroup then
            self:_SelectGroup(nextGroup)
        end
    end
    if following then
        self:_MoveOn(following)
    end
    self:_AfterStep()
end

-- True if the entry can still be worked on.
local function isWorkable(entry)
    local status = entry.status
    return status == "waiting" or status == "searching" or status == "ready" or status == "skip"
end

-- Add the group nodes of a node list to out, in tree order.
local function flattenGroups(nodes, out)
    for _, node in ipairs(nodes) do
        if node.kind == "group" then
            out[#out + 1] = node
            flattenGroups(node.children or {}, out)
        end
    end
    return out
end

-- The id of the next group to select. The selection is a group with no work left: the answer is the first group
-- after its subtree that has work. Returns nil in all other cases.
function Tab:_NextGroupId()
    local current = self.selectedId and findNode(self.nodes, self.selectedId)
    if not current or current.kind ~= "group" or self.awaiting or self.multi then
        return nil
    end
    for _, each in ipairs(SellingTab.CollectEntries(current, {})) do
        if isWorkable(each) then
            return nil
        end
    end
    local groups = flattenGroups(self.nodes, {})
    local first
    for index, node in ipairs(groups) do
        if node == current then
            first = index + #flattenGroups(current.children or {}, {}) + 1
            break
        end
    end
    for index = first or (#groups + 1), #groups do
        for _, each in ipairs(SellingTab.CollectEntries(groups[index], {})) do
            if isWorkable(each) then
                return groups[index].id
            end
        end
    end
    return nil
end

-- Select a group node as _MoveOn does for an item: no click, so no protected call.
function Tab:_SelectGroup(node)
    if self.ui then
        self.ui.tree.selected = node.id
        self.ui.tree:Refresh()
    end
    self:SelectNode(node)
end

-- The entries below an entry in tree order.
function Tab:_EntriesAfter(entry)
    local all, after, seen = SellingTab.CollectEntries({ children = self.nodes }, {}), {}, false
    for _, each in ipairs(all) do
        if seen then
            after[#after + 1] = each
        elseif each == entry then
            seen = true
        end
    end
    return after
end

-- One item is finished and it was the selection: select the next item in the list that can still be worked on.
function Tab:_MoveOn(following)
    for _, entry in ipairs(following) do
        local status = entry.status
        local node = (status == "waiting" or status == "searching" or status == "ready" or status == "skip")
            and findNode(self.nodes, "i" .. entry.key)
        if node then
            if self.ui then
                self.ui.tree.selected = node.id
                self.ui.tree:Refresh()
            end
            self:SelectNode(node)
            return
        end
    end
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
    local stacks = awaiting.stacks or 1
    self:_StartMulti(awaiting.entry, awaiting.quantity, stacks, awaiting.price, awaiting.duration)
    local ok, err = pcall(awaiting.confirm)
    self.awaiting = nil
    if not ok then
        self:_DropMulti()
        return self:_Fail(awaiting.entry, tostring(err))
    end
    awaiting.entry.real = true
    self:_ArmMulti()
end

-- The item as a link in the quality colour; nil while the client has no link yet.
function Tab:_ItemLink(entry)
    local link, quality = entry.item.link, nil
    -- A bag link of an item that is not loaded has empty brackets: do not use it.
    if not linkName(link) then
        link = nil
    end
    if not (link and link:find("^|c")) then
        local found, foundQuality = self.deps.itemLink(entry.item.itemID or 0)
        link, quality = link or found, foundQuality
    end
    if not link then
        self:_RequestName(entry.item.itemID)
        return nil
    end
    if link:find("^|c") then
        return link
    end
    local _, _, _, hex = ns.Kit.QualityColor(quality)
    return "|c" .. hex .. link .. "|r"
end

-- The entry that a click on Post works on: the first ready entry of the selection.
-- Post can also work on one selected item that the rule skips, after a warning.
function Tab:_Focus()
    local current = self:_Current()
    if current then
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

-- The most units that a manual post can hold: the count in the bags minus the keep quantity, at least 1.
function SellingTab.MaxQuantity(candidate)
    local stacks = candidate.stacks or {}
    local count = candidate.count or (stacks[1] and stacks[1].count) or 1
    return math.max(1, count - (tonumber(candidate.settings and candidate.settings.keepInBags) or 0))
end

-- Limit a typed quantity to a whole number from 1 to maxQuantity. Returns nil if the value is not a number.
function SellingTab.ClampQuantity(value, maxQuantity)
    local number = tonumber(value)
    if not number or number ~= number then
        return nil
    end
    return math.max(1, math.min(math.floor(number), math.max(1, maxQuantity)))
end

-- Limit a typed stack count to a whole number from 1 to the stacks of size items that fit in maxQuantity.
-- Returns nil if the value is not a number.
function SellingTab.ClampStacks(value, size, maxQuantity)
    local number = tonumber(value)
    if not number or number ~= number then
        return nil
    end
    local fit = math.max(1, math.floor(math.max(1, maxQuantity) / math.max(1, size)))
    return math.max(1, math.min(math.floor(number), fit))
end

-- The most items in one stack of a manual post: the count above the keep quantity. On TBC an item stack
-- also stays under the item maximum stack.
function SellingTab.StackLimit(entry)
    local limit = SellingTab.MaxQuantity(entry.candidate)
    local market = entry.market or {}
    if ns.SellingPlan.Multisell() and not market.commodity and market.maxStack then
        limit = math.max(1, math.min(limit, market.maxStack))
    end
    return limit
end

-- True if hours is one of the post durations (SellingPlan.DURATIONS).
function SellingTab.IsDuration(hours)
    for _, valid in ipairs(ns.SellingPlan.DURATIONS) do
        if valid == hours then
            return true
        end
    end
    return false
end

local function copyTable(source)
    local copy = {}
    for key, value in pairs(source) do
        copy[key] = value
    end
    return copy
end

-- The decision and the units of a manual post of an item that the rule skips: one auction.
-- It follows the keep quantity and the max stack size of the rule. The quantity and the duration that the
-- user chose (entry.manualQty, entry.manualHours) replace the calculated ones, unless raw is true.
function Tab._ManualPlan(_, entry, price, raw)
    local candidate, market = entry.candidate, entry.market or {}
    local stacks = candidate.stacks
    local commodity = market.commodity == true
    local settings = candidate.settings or {}
    local available = SellingTab.MaxQuantity(candidate)
    local multisell = ns.SellingPlan.Multisell() and not commodity
    local quantity
    local auctions = 1
    if commodity then
        quantity = available
    else
        local size = math.max(1, market.maxStack or 1)
        local limit = tonumber(settings.stackSize) or 0
        if limit > 0 then
            size = math.min(size, limit)
        end
        quantity = math.min(size, multisell and available or stacks[1].count, available)
    end
    local duration = ns.SellingPlan.NormalizeDuration(settings.duration)
    if not raw then
        quantity = SellingTab.ClampQuantity(entry.manualQty, SellingTab.StackLimit(entry)) or quantity
        duration = entry.manualHours or duration
    end
    if multisell and not raw then
        auctions = SellingTab.ClampStacks(entry.manualStacks, quantity, available) or 1
    end
    local decision = { action = "post", price = price, quantity = quantity, auctions = auctions, commodity = commodity,
        reason = "manual post", key = candidate.key, duration = duration }
    return decision, SellingTab.BuildUnits(candidate, decision)
end

-- The decision and the unit of the next post of an entry. The quantity and the duration that the user chose
-- apply, with a new deposit quote. With raw the plan is used as it is.
function Tab:_NextPost(entry, price, raw)
    local ready = entry.status == "ready"
    if ready and (raw or not (entry.manualQty or entry.manualHours or entry.manualStacks)) then
        return entry.decision, entry.units[entry.next]
    end
    local decision, unit
    if ready then
        decision, unit = copyTable(entry.decision), copyTable(entry.units[entry.next])
        decision.duration = entry.manualHours or decision.duration
        unit.quantity = SellingTab.ClampQuantity(entry.manualQty, SellingTab.StackLimit(entry)) or unit.quantity
        if unit.stacks then
            local room = SellingTab.MaxQuantity(entry.candidate)
            unit.stacks = SellingTab.ClampStacks(entry.manualStacks or unit.stacks, unit.quantity, room) or unit.stacks
        end
    else
        local units
        decision, units = self:_ManualPlan(entry, price, raw)
        unit = units[1]
    end
    if not raw then
        local ok, deposit = pcall(self.deps.client.Deposit, unit.bag, unit.slot, decision.duration, unit.quantity,
            decision.commodity == true, nil, nil, unit.stacks)
        unit.deposit = ok and type(deposit) == "number" and deposit or nil
        if unit.deposit == nil then
            self:_ReadHeld(entry, price, decision, unit)
        end
    end
    return decision, unit
end

-- Set the quantity of the next manual post. The value is limited to 1 to the available count. nil clears it.
function Tab:SetManualQuantity(value)
    local entry = not self.awaiting and not self.multi and self:_Focus()
    if not entry then
        return false
    end
    entry.manualQty = SellingTab.ClampQuantity(value, SellingTab.StackLimit(entry))
    -- A bigger stack size leaves room for fewer stacks: the typed stack count follows.
    local stacksBox = self.ui and self.ui.details.stacks
    if entry.manualStacks and entry.manualQty then
        entry.manualStacks = SellingTab.ClampStacks(entry.manualStacks, entry.manualQty,
            SellingTab.MaxQuantity(entry.candidate))
        if stacksBox and stacksBox.GetNumber() ~= entry.manualStacks then
            self.syncing = true
            stacksBox:SetNumber(entry.manualStacks)
            self.syncing = false
        end
    end
    self:_UpdateDetails()
    return true, entry.manualQty
end

-- Set the number of stacks of the next manual post (TBC). The value is limited to the stacks that the bags hold
-- at the stack size of the post. nil clears it.
function Tab:SetManualStacks(value)
    local entry = not self.awaiting and not self.multi and self:_Focus()
    if not entry or not ns.SellingPlan.Multisell() then
        return false
    end
    local _, unit = self:_NextPost(entry, 1, true)
    entry.manualStacks = unit and SellingTab.ClampStacks(value, entry.manualQty or unit.quantity,
        SellingTab.MaxQuantity(entry.candidate)) or nil
    self:_UpdateDetails()
    return true, entry.manualStacks
end

-- Set the duration in hours of the next manual post (SellingPlan.DURATIONS). Another value or nil clears it.
function Tab:SetManualDuration(hours)
    local entry = not self.awaiting and not self.multi and self:_Focus()
    if not entry then
        return false
    end
    entry.manualHours = SellingTab.IsDuration(hours) and hours or nil
    -- The stored deposits were read for the old duration.
    self:_ForgetDeposits(entry)
    self:_UpdateDetails()
    return true
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
        local price, why = SellingTab.CheckPrice(self.ui.details.priceInput:GetCopper())
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
-- A line shows if the rule skips the item, if the price is under the minimum price or over the maximum price,
-- The vendor case has no line here: _PostStep checks it with the real deposit.
function Tab:_Warnings(entry, price)
    local lines = {}
    local skipReason
    if entry.status ~= "ready" then
        skipReason = entry.decision and entry.decision.reason or "no decision"
        -- The vendor case is checked at the post with the real deposit (_VendorHold), so it has no line here.
        if skipReason ~= VENDOR_SKIP then
            lines[1] = "The rule skips this item: " .. (SKIP_TEXT[skipReason] or skipReason) .. "."
        end
    end
    local unit = select(2, self:_NextPost(entry, price))
    local candidate = entry.candidate or {}
    if candidate.minPrice and price < candidate.minPrice and skipReason ~= "below minimum" then
        lines[#lines + 1] = "The price is below the minimum price: " .. money(candidate.minPrice) .. "."
    end
    if candidate.maxPrice and price > candidate.maxPrice then
        lines[#lines + 1] = "The price is above the maximum price: " .. money(candidate.maxPrice) .. "."
    end
    return lines, unit
end

-- Show the warning box with Post, Skip and Cancel. The post runs in the click of the Post button, so it keeps
-- its hardware event. Skip leaves the whole item. Cancel makes no post.
function Tab:_AskWarning(entry, price, lines, unit)
    local text = string.format("Post %d x %s at %s each?", unit and unit.quantity or 0,
        self:_ItemLink(entry) or self:_Name(entry), money(price))
    text = text .. "\n\n" .. table.concat(lines, "\n")
    local function stale()
        return self.awaiting ~= nil or self:_Focus() ~= entry
    end
    self.deps.warn("Check the price", text, function()
        if stale() then
            return
        end
        entry.warned = true
        self:_PostStep()
    end, function()
        if stale() then
            return
        end
        self:SkipItem(entry)
    end, function() end)
end

-- The two lines of the vendor box. The larger value is green: the vendor price N, or the AH net profit S.
function SellingTab.VendorText(vendor, net)
    local function show(value, green)
        return green and (VALUE_GREEN .. money(value) .. "|r") or money(value)
    end
    return "Sell to vendor for: " .. show(vendor, vendor > net) .. "\nAH net profit: " .. show(net, net > vendor)
end

-- The vendor rule for one post: the held table { deposit, vendor, net, profit } if the vendor pays more than the
-- net of the post, else nil. It needs the vendor price and a real deposit. One rule: SellingTab.VendorBetter.
function Tab:_VendorHold(entry, price, unit)
    local vendor = self:_Vendor(entry)
    if not vendor or type(unit.deposit) ~= "number" then
        return nil
    end
    local better, net, profit = SellingTab.VendorBetter(price, unit, vendor)
    if better then
        return { deposit = unit.deposit, vendor = better, net = net, profit = profit }
    end
    return nil
end

-- The backend held a post: with the real deposit the vendor pays more than the net. The item is back in the bag.
-- Show the box. "Post anyway" posts once in its own click. "Cancel" posts nothing and skips the item.
function Tab:_AskVendor(entry, held)
    local function stale()
        return self.awaiting ~= nil or self:_Focus() ~= entry
    end
    local text = SellingTab.VendorText(held.vendor, held.net)
    -- The title names the item (item link in the quality colour), so the body is only the two lines.
    local title = "Check the deposit: " .. (self:_ItemLink(entry) or self:_Name(entry))
    self.deps.warn(title, text, function()
        if stale() then
            return
        end
        entry.vendorForce = true
        self:_PostStep()
    end, function()
        if stale() then
            return
        end
        self:SkipItem(entry)
    end, function()
        if stale() then
            return
        end
        self:SkipItem(entry, "vendor pays more than the AH")
    end, { post = "Post anyway", skip = false, cancel = "Cancel" })
end

-- Post the next unit of the first ready entry. Call it only from the click of the post button.
-- One call makes one protected post. Returns true, or false and a text.
function Tab:PostNext()
    return self:_PostStep()
end

-- True while the scan of the selection runs: a search in flight, or a queue that waits for the next search.
-- The queue ends at its last item, at Stop, at a new selection, at a bag read and when the AH closes.
function Tab:_Scanning()
    return self.pending ~= nil or self.queue ~= nil
end

function Tab:_DropMulti()
    local m = self.multi
    if m then
        m.entry.postText = nil
    end
    self.multi = nil
end
function Tab:_PostStep()
    if self.multi then
        return false, "posting"
    end
    if self:_Scanning() then
        return false, "Wait for the scan to finish."
    end
    if self.lock then
        return false, "wait for the last post to end"
    end
    if not self:_GateOpen() then
        log("warn", "post refused: the Auction House is busy")
        self:_ShowBusy(BUSY_TEXT)
        return false, BUSY_TEXT
    end
    if self.awaiting then
        self:_ShowConfirm()
        return true
    end
    local entry = self:_Focus()
    if not entry then
        return false, "nothing to post"
    end
    local price, why = self:_PostPrice(entry)
    if not price then
        return false, why
    end
    -- After "Post anyway" the user knows the real deposit, so the price warnings do not come back.
    if not entry.warned and not entry.vendorForce then
        local lines, unit = self:_Warnings(entry, price)
        if #lines > 0 then
            self:_AskWarning(entry, price, lines, unit)
            return true
        end
    end
    if entry.status ~= "ready" then
        self:_ForcePlan(entry, price)
    end
    local decision, unit = self:_NextPost(entry, price)
    local client = self.deps.client
    local okValid, valid = pcall(client.IsSellItemValid, unit.bag, unit.slot)
    if okValid and valid == false then
        return self:_Fail(entry, "the item cannot be posted")
    end
    local quantity = unit.quantity
    local stacks = not decision.commodity and unit.stacks or 1
    local okCount, available = pcall(client.AvailablePostCount, unit.bag, unit.slot)
    -- Several stacks may come from several bag slots, so the slot count limits one stack only.
    if okCount and type(available) == "number" and stacks == 1 then
        quantity = math.min(quantity, available)
    end
    if quantity < 1 then
        return self:_Fail(entry, "no item left to post")
    end
    -- The planned item. A backend that posts from the sale slot refuses a bag slot that holds another item.
    local plannedID = entry.item and entry.item.itemID or entry.candidate and entry.candidate.itemID
    local call, confirm, held
    -- The vendor rule at the post click. A deposit that the pane already shows is used at once. The user
    -- decides in one box. "Post anyway" sets entry.vendorForce for the rest of the item, so the box does not
    -- come again. An unknown deposit is read by the backend guard.
    local forced = entry.vendorForce
    if not forced and unit.deposit and quantity == unit.quantity then
        held = self:_VendorHold(entry, price, { quantity = quantity, stacks = stacks, deposit = unit.deposit })
        if held then
            self:_AskVendor(entry, held)
            return true
        end
    end
    if decision.commodity then
        call = function()
            return client.PostCommodity(unit.bag, unit.slot, decision.duration, quantity, price)
        end
        confirm = function()
            return client.ConfirmPostCommodity(unit.bag, unit.slot, decision.duration, quantity, price)
        end
    else
        -- TBC: the buyout is for the stack (price of one item times the stack size). Forever has no stacks: the client
        -- takes the price of one item (PostItem: the item sell frame posts its per-item price box).
        local buyout = ns.SellingPlan.Multisell() and price * quantity or price
        -- With no known deposit the backend reads it from the sale slot (TBC). If the vendor pays more than the
        -- net after that deposit, the backend holds the post and the user decides.
        local guard
        if self:_Vendor(entry) and not forced then
            guard = function(deposit)
                if type(deposit) ~= "number" then
                    return true
                end
                unit.deposit = deposit
                held = self:_VendorHold(entry, price, { quantity = quantity, stacks = stacks, deposit = deposit })
                return held == nil
            end
        end
        call = function()
            return client.PostItem(unit.bag, unit.slot, decision.duration, quantity, nil, buyout, plannedID, guard,
                stacks > 1 and stacks or nil)
        end
        confirm = function()
            return client.ConfirmPostItem(unit.bag, unit.slot, decision.duration, quantity, nil, buyout, plannedID,
                nil, stacks > 1 and stacks or nil)
        end
    end
    -- The post call reuses the kept slot when it holds the right item, else it fills the slot. After the call the
    -- post owns the slot: the tab does not release it, and the slot is empty after the post.
    self.held = nil
    log("info", string.format("post click: %s, size %d, stacks %d, price %d, %d h", self:_Name(entry), quantity,
        stacks, price, decision.duration))
    -- The events of the client can come while the call runs. The state exists before the call. The row stays in the
    -- list until the client confirms the post (_EndMulti).
    self:_StartMulti(entry, quantity, stacks, price, decision.duration)
    local ok, needsConfirmation = pcall(call)
    if not ok then
        self:_DropMulti()
        return self:_Fail(entry, tostring(needsConfirmation))
    end
    if needsConfirmation == "held" or needsConfirmation then
        self:_DropMulti()
    end
    if needsConfirmation == "held" then
        if not held then
            return self:_Fail(entry, "the post was held")
        end
        self:_AskVendor(entry, held)
        return true
    end
    if needsConfirmation then
        self.awaiting = { entry = entry, unit = unit, quantity = quantity, confirm = confirm, price = price,
            duration = decision.duration, stacks = stacks }
        self:_ShowConfirm()
        self:_Update()
        return true
    end
    entry.real = true
    self:_ArmMulti()
    return true
end

-- The state of a post that waits for the client (one stack or several, TBC). It blocks Post and Skip until the
-- client confirms the post or fails it.
function Tab:_StartMulti(entry, quantity, stacks, price, duration)
    self.multiToken = (self.multiToken or 0) + 1
    self.multi = { entry = entry, quantity = quantity, stacks = stacks, price = price, duration = duration,
        created = 0, total = stacks, token = self.multiToken }
    entry.postText = self:_MultiText()
end

-- The text of the Info column of the entry that posts.
function Tab:_MultiText()
    local m = self.multi
    if m.stacks == 1 then
        return "posting"
    end
    return string.format("posting %d of %d stacks", m.created, m.total)
end

-- The call returned: wait for the events. A timer ends a post that gets no answer.
function Tab:_ArmMulti()
    local m = self.multi
    if not m then
        return
    end
    m.armed = true
    local token = m.token
    self:_LockPost(token)
    self.deps.after(MULTI_TIMEOUT + MULTI_TIMEOUT_PER_STACK * m.stacks, function()
        if self.multi and self.multi.token == token then
            log("warn", "no answer from the Auction House")
            self:_EndMulti("no answer from the Auction House")
        end
    end)
    self:_CheckMulti()
end

-- Keep Post off after a post call until the result came and postDelay seconds passed. A timeout ends the lock too.
-- With a delay of 0 the result alone ends it. The lock starts no post by itself (D26).
function Tab:_LockPost(token)
    local deps = self.deps
    local lock = { token = token, resulted = false, delayed = deps.postDelay <= 0 }
    self.lock = lock
    if deps.postDelay <= 0 then
        return
    end
    deps.after(deps.postDelay, function()
        if self.lock == lock then
            lock.delayed = true
            self:_TryUnlock()
        end
    end)
    deps.after(deps.postTimeout, function()
        if self.lock == lock then
            log("warn", "post delay timeout, Post is on again")
            self.lock = nil
            self:_Update()
        end
    end)
end

-- End the lock if the result came and the delay passed.
function Tab:_TryUnlock()
    local lock = self.lock
    if lock and lock.resulted and lock.delayed then
        self.lock = nil
        self:_Update()
    end
end

-- A multisell event of the client: kind is "start", "update" or "failure".
function Tab:_OnMultisell(kind, created, total, text)
    local m = self.multi
    if not m then
        return
    end
    log("debug", string.format("multisell %s %s of %s", tostring(kind), tostring(created), tostring(total)))
    if type(created) == "number" then
        m.created = math.max(m.created, created)
    end
    if type(total) == "number" and total > 0 then
        m.total = total
    end
    if kind == "failure" then
        m.failure = text or "the Auction House stopped the post"
    end
    if m.armed then
        self:_CheckMulti()
    end
end

function Tab:_CheckMulti()
    local m = self.multi
    if m.failure then
        self:_EndMulti(m.failure)
    elseif m.created >= m.total then
        self:_EndMulti()
    else
        m.entry.postText = self:_MultiText()
        self:_Update()
    end
end

-- End a multi-stack post: log each stack that the client made. A failure marks the entry failed with the count.
function Tab:_EndMulti(failure)
    local m = self.multi
    self.multi, self.live = nil, nil
    local entry = m.entry
    entry.postText = nil
    local created = math.min(m.created, m.stacks)
    for _ = 1, created do
        self:_Record(entry, m.quantity, "post", m.price, m.duration)
    end
    if self.lock then
        self.lock.resulted = true
    end
    if failure then
        entry.posted = entry.posted + created
        self.postedCount = self.postedCount + created
        log("error", string.format("post failed: %s (%d of %d stacks made)", failure, created, m.stacks))
        local ok, text = self:_Fail(entry, string.format("%s (%d of %d stacks made)", failure, created, m.stacks))
        self:_TryUnlock()
        return ok, text
    end
    log("info", string.format("post ok: %d x %d", created, m.quantity))
    self:_Advance(entry, true, created)
    self:_TryUnlock()
end

-- Leave the next auction of the queue without a post. Makes no protected call.
function Tab:Skip()
    if self.multi then
        return false, "posting"
    end
    local entry = self.awaiting and self.awaiting.entry or self:_Focus()
    if not entry then
        return false, "nothing to skip"
    end
    self.awaiting = nil
    if self.held and self.held.entry == entry and entry.next >= #entry.units then
        self:_Release()
    end
    self.deps.log:Add(entry.candidate, { action = "skip", reason = "skipped by user" })
    self:_Advance(entry, false)
    return true
end


-- Leave all the auctions that are left of one item (the Skip button of the warning box). No protected call.
function Tab:SkipItem(entry, reason)
    if self.held and self.held.entry == entry then
        self:_Release()
    end
    self.deps.log:Add(entry.candidate, { action = "skip", reason = reason or "skipped by user" })
    entry.next = #entry.units
    self:_Advance(entry, false)
end

-- Buy. The state of a buy is self.buy, as in the Buying tab (see BuyFlow): phase quoting (a commodity waits for
-- the quote), quoted (the box shows the price), confirming (the buy call went out).

-- The market value of an entry (ScanMarket, from the scan record), or nil.
function Tab:_Market(entry)
    local deps = self.deps
    local record = deps.getRecord and entry.key and deps.getRecord(entry.key)
    local now = deps.now and deps.now()
    if type(record) ~= "table" or type(now) ~= "number" or not (ns.ScanSources and ns.ScanSources.Compute) then
        return nil
    end
    local ok, values = pcall(ns.ScanSources.Compute, record, now)
    return ok and type(values) == "table" and values.scanMarket or nil
end

-- The buy that the Buy button would make for the item that the pane shows: the selected level, else the lowest level
-- that is not yours. Returns entry, cover, reason, stale, info.
-- cover is the cover plan (BuyFlow.CoverPlan) or nil with a reason. stale is true if the client list is for another
-- item: a click then reads the prices again and buys nothing. info describes the amount box: { item = true, text } for
-- an item auction (one auction for each click, the amount is fixed at 1), or { amount, default } for a commodity.
-- A commodity buy takes the cheapest units first, so the amount counts from the cheapest level. The default amount is
-- the units up to and including the target level. A level of yours in the units that the amount covers refuses the buy.
function Tab:_BuyTarget()
    local entry = self:_Focus()
    if not entry then
        return nil, nil, "pick an item first"
    end
    local client = self.deps.client
    if type(client.CanBuy) ~= "function" or client.CanBuy() ~= true then
        return entry, nil, "buying is not available"
    elseif self.buy or BuyFlow.OtherOpen("selling") then
        return entry, nil, "a buy is open"
    elseif self.awaiting or self.multi or self.lock then
        return entry, nil, "a post is open"
    elseif self:_PaneLoading() then
        return entry, nil, "loading prices"
    elseif self.pending or self.queue then
        return entry, nil, "a search is running"
    elseif not client.IsReady() then
        return entry, nil, "waiting for the Auction House"
    end
    local live = self.live
    if not (live and live.itemID == entry.item.itemID) then
        if entry.next > 1 then
            return entry, nil, "finish the post first"
        end
        return entry, nil, "search first", true
    end
    local levels = ns.BuyingPlan.PriceLevels(live.rows)
    -- The selected level, or the lowest level that is not yours. A selected level of yours cannot be bought.
    local level = self:_SelectedLevel(levels)
    if level and level.own then
        return entry, nil, ns.BuyingPlan.REASON.own
    end
    level = level or BuyFlow.CheapestFree(levels)
    if not level then
        return entry, nil, #levels > 0 and ns.BuyingPlan.REASON.own or ns.BuyingPlan.REASON.none
    end
    if live.rows[1].isCommodity == false then
        -- An item auction: one auction for each click.
        local text = level.perItem and "1 item" or string.format("1 stack of %d", level.stackSize or 1)
        return entry, BuyFlow.CoverPlan(levels, level, level, nil, true), nil, nil, { item = true, text = text }
    end
    local default = 0
    for _, each in ipairs(levels) do
        default = default + each.quantity
        if each == level then
            break
        end
    end
    local amount = self.amount or default
    local info = { amount = amount, default = default }
    if self.amountBad then
        return entry, nil, AMOUNT_TEXT, nil, info
    end
    local cover = BuyFlow.CoverPlan(levels, levels[1], levels[#levels], amount, false)
    if cover.own then
        -- The API cannot skip own units: a purchase takes the cheapest units of the market.
        return entry, nil, ns.BuyingPlan.REASON.ownBelow, nil, info
    elseif cover.quantity < amount then
        return entry, nil, string.format("only %d units are for sale", cover.quantity), nil, info
    end
    return entry, cover, nil, nil, info
end

-- Set the amount box. The box calls SetAmount only for a text that the user typed (the OnTextChanged hook checks it).
function Tab:_FillAmount(number)
    local box = self.ui.amount
    if box.GetNumber() ~= number then
        box:SetNumber(number)
    end
end

-- The user typed an amount (a whole number above 0, or nil for an empty or bad text). The amount counts for the
-- selected level until the selection or the rows change. Only a commodity buy has an amount. quiet is true while the
-- box is empty (the user is still typing): the amount is bad and the button is off, but there is no error text.
function Tab:SetAmount(number, quiet)
    self.amount, self.amountBad = nil, false
    if number ~= nil then
        if type(number) == "number" and number >= 1 and number == math.floor(number) then
            self.amount = number
        else
            self.amountBad = true
        end
    else
        -- An empty box is a bad amount. The text of the box is not used for a number that the box cannot read.
        self.amountBad = true
    end
    self:_Update()
    if self.amountBad and not quiet then
        self:_ShowBusy(AMOUNT_TEXT)
    end
    return not self.amountBad
end

-- Set the Buy button and the amount box. The button is on only when a click can buy or read the prices. The amount box
-- is on for a commodity only; an item auction or a stack shows its fixed amount of 1 and the stack size.
function Tab:_RefreshBuy()
    local ui = self.ui
    if not (ui and ui.buy) then
        return
    end
    local target = { self:_BuyTarget() } -- entry, cover, reason, stale, info
    local cover, stale, info = target[2], target[4], target[5]
    ui.buy:SetEnabled(cover ~= nil or stale == true)
    if info and info.item then
        self:_FillAmount(1)
        ui.amount:SetEnabled(false)
        ui.buyInfo:SetText(info.text)
    elseif info then
        if not self.amountBad then
            self:_FillAmount(info.amount)
        end
        ui.amount:SetEnabled(true)
        ui.buyInfo:SetText("")
    else
        -- No target now. A buy that is open keeps the amount that it started with.
        if not self.buy then
            self:_FillAmount(nil)
            ui.buyInfo:SetText("")
        end
        ui.amount:SetEnabled(false)
    end
end

-- The level that the user selected in the level list, from the levels of the shown item, or nil.
function Tab:_SelectedLevel(levels)
    if self.levelSel == nil then
        return nil
    end
    for _, level in ipairs(levels or {}) do
        if BuyFlow.LevelId(level) == self.levelSel then
            return level
        end
    end
    return nil
end

-- The entry whose levels the list shows: the entry of the open post, or the entry of the pane.
function Tab:_LevelEntry()
    return self.awaiting and self.awaiting.entry or self:_Focus()
end

-- The levels of the shown item, from the rows of the last search. Empty if the rows are for another item.
function Tab:_LevelsOf(entry)
    local live = self.live
    if entry and live and live.itemID == entry.item.itemID then
        return ns.BuyingPlan.PriceLevels(live.rows)
    end
    return {}
end

-- Draw one row of the level list. The click selects the level; a level of yours cannot be selected.
function Tab:_InitLevelRow(row, data)
    local Kit = ns.Kit
    local parts = row.levelParts
    if not parts then
        -- The mark is a gold tint under the row of your own auction. It is not the selection highlight.
        local mark = row:CreateTexture(nil, "BACKGROUND")
        mark:SetAllPoints(row)
        mark:SetColorTexture(YELLOW[1], YELLOW[2], YELLOW[3], 0.18)
        parts = { cells = Kit.CreateColumnCells(row, LEVEL_COLUMNS, LEVEL_OPTIONS), mark = mark,
            select = Kit.SelectionTexture(row, ns.AuctionTabs and ns.AuctionTabs.Skin) }
        row.levelParts = parts
    end
    if parts.version ~= self.colVersion then
        parts.version = self.colVersion
        Kit.LayoutColumnLabels(parts.cells, row, LEVEL_COLUMNS, LEVEL_OPTIONS)
    end
    Kit.SetColumnCells(parts.cells, LEVEL_COLUMNS, data)
    -- Your own row is yellow. The price of a deal (30% or more under the market value) is green.
    for _, cell in pairs(parts.cells) do
        paint(cell, data.mine and YELLOW or WHITE)
    end
    if data.deal and not data.mine then
        paint(parts.cells.price, GREEN)
    end
    parts.mark:SetShown(data.mine == true)
    parts.select:SetShown(self.levelSel ~= nil and self.levelSel == data.id)
    row:SetScript("OnClick", function()
        self:SelectLevel(data.id)
    end)
end

-- Select a level of the list, or clear the selection with a second click. The selection never starts a buy.
-- Returns true, or false and a reason.
function Tab:SelectLevel(id)
    if self.buy then
        return false, "a buy is open"
    end
    local level
    for _, each in ipairs(self:_LevelsOf(self:_LevelEntry())) do
        if BuyFlow.LevelId(each) == id then
            level = each
        end
    end
    if not level then
        return false, "no such level"
    end
    if level.own then
        self:_ShowBusy(ns.BuyingPlan.REASON.own)
        return false, ns.BuyingPlan.REASON.own
    end
    self.levelSel = self.levelSel ~= id and id or nil
    self.amount, self.amountBad = nil, false -- the default amount follows the selected level
    self.levelShown = nil
    self:_Update()
    return true
end

-- Fill the level pane from the rows of the last search of the shown item. It is empty when no item shows or when
-- the rows are for another item. It draws again only when the data changed.
function Tab:_RefreshLevels()
    local ui = self.ui
    if not (ui and ui.levelList) then
        return
    end
    local entry = self:_LevelEntry()
    local levels = entry and self:_LevelsOf(entry) or {}
    -- While the pane waits for its rows it shows the loading text and no rows (not the rows of an older item).
    local loading = self:_PaneLoading()
    if loading ~= ui.levelLoading:IsShown() then
        ui.levelLoading:SetShown(loading)
        if loading then
            self.dots = 1
            ui.levelLoading:SetText("Loading prices.")
        end
    end
    if loading then
        levels = {}
        self:_TickLoading()
    end
    -- A single item has a price, not a unit price.
    local title = entry and entry.market and entry.market.single and "Price" or "Unit price"
    if ui.levelHeader.labels.price.GetText and ui.levelHeader.labels.price:GetText() ~= title then
        ui.levelHeader.labels.price:SetText(title)
    end
    if self.levelSel ~= nil and not self:_SelectedLevel(levels) then
        self.levelSel, self.amount, self.amountBad = nil, nil, false
    end
    local live = self.live
    local shown = self.levelShown
    if shown and shown.live == live and shown.entry == entry and shown.sel == self.levelSel then
        return
    end
    self.levelShown = { live = live, entry = entry, sel = self.levelSel }
    ui.levelList:SetData(SellingTab.LevelRows(levels, entry and entry.marketValue))
end

-- Search the item of an entry again, so that its decision and its post price use the new lowest price.
-- Nothing happens while a search runs or after a part of the post.
function Tab:_Research(entry)
    if self.pending or entry.next > 1 or not entry.candidate then
        return
    end
    local listed = false
    for _, each in ipairs(self.entries) do
        listed = listed or each == entry
    end
    local status = entry.status
    if not listed or (status ~= "ready" and status ~= "skip" and status ~= "waiting") then
        return
    end
    entry.status = "waiting"
    self.queue = { list = { entry }, pos = 0 }
    self:_Next()
end

-- The click on Buy. A commodity asks for the quote now (a protected call). An item opens the confirm box.
-- Each case makes at most one protected call (D26). Returns true, or false and a reason.
function Tab:Buy()
    local entry, cover, reason, stale = self:_BuyTarget()
    if stale then
        -- The list is for another item: this click only reads the prices. The next click buys.
        self:_Research(entry)
        self:_ShowBusy("Prices are read. Click " .. BUY_TEXT .. " again.")
        return false, reason
    end
    if not cover then
        self:_ShowBusy(reason or "")
        return false, reason
    end
    return self:_StartBuy(entry, cover)
end

function Tab:_StartBuy(entry, cover)
    local candidate, level = entry.candidate or {}, cover.last
    local itemID = entry.item.itemID
    local buyEntry = { key = entry.key, itemID = itemID, groupPath = candidate.groupPath,
        operationName = candidate.operationName, noMax = true }
    if level.rows[1].isCommodity == false then
        local row = BuyFlow.FirstFree(level)
        self.buy = {
            entry = buyEntry, source = entry, level = level, row = row, isItem = true, phase = "quoted",
            itemID = itemID, auctionID = row.auctionID, quantity = BuyFlow.BuyQuantity(row), unit = row.unitPrice,
            total = BuyFlow.BuyoutOf(row), stacks = level.stacks,
        }
        self:_ShowBuyConfirm()
        self:_Update()
        return true
    end
    local buy = { entry = buyEntry, source = entry, level = level, row = level.rows[1], phase = "quoting",
        itemID = itemID, quantity = cover.quantity, complete = cover.complete, estimate = cover.cost }
    local ok, err = pcall(self.deps.client.StartCommodityPurchase, itemID, buy.quantity)
    if not ok then
        self.deps.buyLog:Add(buyEntry, "buy failed", tostring(err))
        self:_ShowBusy("the quote was refused")
        return false, "the quote was refused"
    end
    self.buy = buy
    self.deps.after(QUOTE_WAIT, function()
        if self.buy == buy and buy.phase == "quoting" then
            self:_CancelBuy("no quote came")
        end
    end)
    self:_Update()
    self:_ShowBusy("waiting for the quote of " .. tostring(self:_Name(entry)))
    return true
end

-- Show the confirm box with the price of the quote (a commodity) or the buyout (an item).
function Tab:_ShowBuyConfirm()
    local buy = self.buy
    if not buy then
        return
    end
    local source = buy.source
    local text, over, jumped = BuyFlow.QuoteText(buy, self:_ItemLink(source) or tostring(self:_Name(source)))
    local options = BuyFlow.ConfirmOptions(buy, over, jumped, false)
    BuyDialog.Get(CONFIRM_BOX):Open(options.title, text, {
        yes = options.yes, no = options.no, red = options.red, keep = options.keep,
        onYes = function()
            self:_ConfirmBuy()
        end,
        onNo = function()
            self:_CancelBuy("cancelled")
        end,
    })
end

-- Close the confirm box. It stays open if the Buying tab has a buy open: the box is theirs then.
local function closeBuyBox()
    local box = BuyDialog.Find(CONFIRM_BOX)
    if box and not BuyFlow.OtherOpen("selling") then
        box:Close()
    end
end

-- Show the seconds that the quote has left, each second, until the quote ends.
function Tab:_TickQuote(buy)
    self.deps.after(1, function()
        if self.buy ~= buy or buy.phase ~= "quoted" then
            return
        end
        local left = self.deps.client.QuoteSecondsLeft()
        if left == 0 then
            self:_CancelBuy("the quote ended")
            return
        end
        buy.left = left
        self:_ShowBuyConfirm()
        self:_TickQuote(buy)
    end)
end

-- The server quote came: show it in the confirm box.
function Tab:_OnBuyQuote(unit, total)
    local buy = self.buy
    if not BuyFlow.QuoteApplies(buy) then
        return
    end
    local first = buy.phase == "quoting"
    buy.phase = "quoted"
    buy.unit, buy.total = unit, total
    -- A quote more than 10% above the estimate from the list shows as a price jump (the box turns red).
    buy.jump = nil
    if buy.estimate and buy.estimate > 0 and total > buy.estimate * (1 + JUMP_PERCENT / 100) then
        buy.jump = { prev = buy.estimate / buy.quantity, percent = (total / buy.estimate - 1) * 100 }
    end
    buy.left = self.deps.client.QuoteSecondsLeft()
    self:_ShowBuyConfirm()
    if first then
        self:_TickQuote(buy)
    end
    self:_Update()
end

function Tab:_OnBuyQuoteUnavailable()
    local buy = self.buy
    if BuyFlow.QuoteApplies(buy) then
        self:_CancelBuy("the price is not available")
        self:_Research(buy.source)
    end
end

-- Click 2: buy at the quote or at the buyout. Call it only from a click.
function Tab:_ConfirmBuy()
    local buy = self.buy
    if not buy or buy.phase ~= "quoted" then
        return
    end
    local client = self.deps.client
    buy.phase = "confirming"
    log("info", string.format("buy click: item %s, quantity %s, total %s, %s", buy.itemID, buy.quantity, buy.total,
        buy.isItem and "item auction" or "commodity"))
    local ok, err
    if buy.isItem then
        -- The list indexes can shift. Find an identical auction in the list again before the call.
        local index = BuyFlow.Refind(client.LiveRows(buy.itemID), buy)
        if not index then
            self:_BuyFail(buy, "the auction is gone")
            return
        end
        buy.auctionID = index
        ok, err = pcall(client.BuyItemAuction, buy.auctionID, buy.total)
    else
        ok, err = pcall(client.ConfirmCommodityPurchase, buy.itemID, buy.quantity)
    end
    if not ok then
        self:_BuyFail(buy, tostring(err))
        return
    end
    self:_Update()
    self:_ShowBusy("buying " .. tostring(self:_Name(buy.source)))
    self.deps.after(CONFIRM_WAIT, function()
        if self.buy == buy and buy.phase == "confirming" then
            self:_BuyFail(buy, "no response")
        end
    end)
end

-- End a buy that has not gone out: close the box, drop the quote and log it. It starts no search.
function Tab:_AbortBuy(buy, why)
    self.buy = nil
    closeBuyBox()
    if not buy.isItem then
        pcall(self.deps.client.CancelCommodityPurchase)
    end
    self.deps.buyLog:Add(buy.entry, "buy cancelled", why)
end

-- Cancel an open quote or confirm box. A buy that went out stays; its box closes.
function Tab:_CancelBuy(why)
    local buy = self.buy
    if not buy then
        return
    end
    if buy.phase == "confirming" then
        closeBuyBox()
        return
    end
    self:_AbortBuy(buy, why)
    if self.active then
        self:_AfterStep()
    end
    self:_Update()
    self:_ShowBusy(why)
end

-- The buy worked. The item is searched again, so that the post price uses the new lowest price.
function Tab:_BuySucceed(buy)
    self.buy, self.live, self.levelSel, self.amount, self.amountBad = nil, nil, nil, nil, false
    log("info", string.format("bought %s of item %s, total %s", buy.quantity, buy.itemID, buy.total))
    -- The price is the unit price of the server quote (a commodity buy can cover many levels), or the auction price.
    local unit = buy.unit or buy.level.unitPrice
    self.deps.buyLog:Add(buy.entry, string.format("bought %d at %s", buy.quantity, BuyFlow.Money(unit)),
        "total " .. BuyFlow.Money(buy.total))
    closeBuyBox()
    self:_AfterStep()
    self:_Research(buy.source)
    self:_Update()
    self:_ShowBusy("bought " .. buy.quantity .. " x " .. tostring(self:_Name(buy.source)))
end

-- The buy failed. The list is stale, so the item is searched again.
function Tab:_BuyFail(buy, reason)
    self.buy, self.live, self.levelSel, self.amount, self.amountBad = nil, nil, nil, nil, false
    closeBuyBox()
    log("warn", string.format("buy of item %s failed: %s", buy.itemID, reason))
    self.deps.buyLog:Add(buy.entry, "buy failed", reason)
    self:_AfterStep()
    self:_Research(buy.source)
    self:_Update()
    self:_ShowBusy("buy failed: " .. reason)
end

function Tab:_OnBuyCommodityResult(ok)
    local buy = self.buy
    if BuyFlow.CommodityResultApplies(buy) then
        if ok then
            self:_BuySucceed(buy)
        else
            self:_BuyFail(buy, "the server refused the purchase")
        end
    end
end

function Tab:_OnBuyItemDone(auctionID)
    local buy = self.buy
    if BuyFlow.ItemDoneApplies(buy, auctionID) then
        self:_BuySucceed(buy)
    end
end

function Tab:_OnBuyItemError(code)
    local buy = self.buy
    if BuyFlow.ItemErrorApplies(buy) then
        self:_BuyFail(buy, "error " .. tostring(code))
    end
end

-- The deal mark of a price: "-70%" when the price is DEAL_PERCENT or more under the market value (ScanMarket).
-- Nil if the price is not that low or if there is no market value.
function SellingTab.DealText(price, market)
    if type(price) ~= "number" or type(market) ~= "number" or market <= 0 then
        return nil
    end
    local below = math.floor((1 - price / market) * 100 + 0.5)
    if below < DEAL_PERCENT then
        return nil
    end
    return "-" .. below .. "%"
end

-- The rows of the level pane from price levels (BuyingPlan.PriceLevels), cheapest first, at most LEVEL_MAX.
-- Row: { id, unitPrice, price, available, mine, deal }. A commodity level shows its quantity. An item level
-- (a stack group) shows "stacks x size" for a stack above 1, else the count. mine is true for your own level (the row
-- is yellow). deal is true if the price is a deal (see SellingTab.DealText); the price is green.
function SellingTab.LevelRows(levels, market)
    local rows = {}
    for _, level in ipairs(levels or {}) do
        if #rows >= LEVEL_MAX then
            break
        end
        -- Available is the count of items. Only a real stack (a size above 1) is "stacks x size": a level of one-item
        -- auctions (a Forever row, a TBC level of stacks of 1) is just the count.
        local available = tostring(level.quantity or 0)
        if level.stackSize and level.stackSize > 1 then
            available = (level.stacks or 1) > 1 and string.format("%d x %d", level.stacks, level.stackSize)
                or tostring(level.stackSize)
        end
        rows[#rows + 1] = {
            id = level.id or level.unitPrice, unitPrice = level.unitPrice, price = money(level.unitPrice),
            available = available, mine = level.own == true,
            deal = SellingTab.DealText(level.unitPrice, market) ~= nil,
        }
    end
    return rows
end
-- The cells of one item row: the price, operation, net and info texts and the colour of the net.
function SellingTab.Cells(entry, vendorPrice)
    local candidate, decision = entry.candidate, entry.decision
    local cells = { price = "-", operation = candidate and candidate.operationName or "-", net = "-",
        info = SellingTab.InfoText(entry) }
    local ready = entry.status == "ready"
    if ready and decision then
        cells.price = money(decision.price)
        local profit = SellingTab.EntryProfit(entry, vendorPrice)
        if profit then
            cells.net = money(profit.net)
            cells.netNegative = profit.net < 0
        end
    elseif entry.status == "waiting" and candidate and candidate.normalPrice then
        cells.price = "~" .. money(candidate.normalPrice)
    end
    return cells
end

-- Make an item row a link: the mouse shows the item tooltip, a shift-click puts the link in the chat box.
-- A row without a link (a group row) loses both. The tree sets the OnClick script again each time it draws a row.
function Tab._LinkRow(_, row, link)
    local payload = link and link:match("|H(.-)|h")
    if not payload then
        row:SetScript("OnEnter", nil)
        row:SetScript("OnLeave", nil)
        return
    end
    row:SetScript("OnEnter", function(frame)
        GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(payload)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    local onSelect = row:GetScript("OnClick")
    row:SetScript("OnClick", function(frame, button, ...)
        local insert, modified = ChatEdit_InsertLink, _G.IsModifiedClick
        if button ~= "RightButton" and insert and modified and modified("CHATLINK") and insert(link) then
            return
        end
        if onSelect then
            onSelect(frame, button, ...)
        end
    end)
end

-- Draw one tree row: a group (toggle and name) or a bag item (icon, name and the columns).
function Tab:_InitTreeRow(row, node, depth, isCollapsed, hasChildren)
    local Kit = ns.Kit
    local parts = row.sellParts
    if not parts then
        parts = { icon = row:CreateTexture(nil, "ARTWORK"), shift = 0 }
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
    row.label:SetWidth(math.max(20, COLUMNS[1].width - (depth - 1) * TREE_INDENT - ITEM_LEAD
        - (node.kind == "group" and 0 or ICON_LEAD)))
    row.label:SetJustifyH("LEFT")
    if row.label.SetWordWrap then
        row.label:SetWordWrap(false)
    end
    -- The view indents a row, so the cells shift back: they line up with the header at every depth.
    local shift = tree.box and (depth - 1) * TREE_INDENT or 0
    if parts.shift ~= shift or parts.version ~= self.colVersion then
        parts.shift, parts.version = shift, self.colVersion
        Kit.LayoutColumnLabels(parts.cells, row, COLUMNS, { gap = COLUMN_GAP, left = -shift })
    end
    if node.kind == "group" then
        self:_LinkRow(row, nil)
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
    local link = self:_ItemLink(entry)
    row.label:SetText((link or self:_Name(entry)) .. " x" .. tostring(entry.item.count))
    self:_LinkRow(row, link)
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

-- Count the auctions of the selection: total to post and done (posted or skipped). Also the deposit still to pay.
-- A unit with several stacks (TBC) counts each stack.
function Tab:_Progress()
    local total, done, deposit = 0, 0, nil
    for _, entry in ipairs(self.selection) do
        if entry.decision and entry.decision.action == "post" then
            local count, before = 0, 0
            for index, unit in ipairs(entry.units) do
                count = count + (unit.stacks or 1)
                if index < entry.next then
                    before = before + (unit.stacks or 1)
                end
            end
            done = done + before
            if entry.status == "ready" or entry.status == "done" then
                total = total + count
            else
                total = total + before
            end
            if entry.status == "ready" and entry.deposit and count > 0 then
                deposit = (deposit or 0) + entry.deposit * (count - before) / count
            end
        end
    end
    return total, done, deposit
end

-- The label of the post button from the state.
function Tab:PostLabel()
    -- PostWait is a read of the wait time, not a post call. The local name keeps it out of the call-site guard test.
    local api = self.deps.client
    local wait = self.multi == nil and api.PostWait and api.PostWait() or 0
    local suffix = wait > 0 and (" (" .. math.ceil(wait) .. " s)") or ""
    if self.awaiting then
        return "Confirm post" .. suffix
    end
    if self:_Scanning() then
        return "Scanning..."
    end
    if self.lock then
        return "Wait..."
    end
    return "Post" .. suffix
end

-- The number of items of the selection that wait for their price (not searched yet, or searching now).
function Tab:_WaitingCount()
    local count = 0
    for _, entry in ipairs(self.selection) do
        if entry.status == "waiting" or entry.status == "searching" then
            count = count + 1
        end
    end
    return count
end

-- The progress text: "Posting 3 of 60" while a post is left, else empty. The total counts the items that have a price.
-- With nothing ready and items waiting for a price, it says "2 waiting".
function Tab:ProgressText()
    if self.multi then
        return string.format("Posting %d of %d stacks", self.multi.created, self.multi.total)
    end
    local total, done = self:_Progress()
    local waiting = self:_WaitingCount()
    if total > 0 and (self.awaiting or self:_Current()) then
        return string.format("Posting %d of %d", math.min(done + 1, total), total)
    end
    if waiting > 0 then
        return string.format("%d waiting", waiting)
    end
    return ""
end


-- Put a suggested price in the price box. The box belongs to the entry until another entry shows.
function Tab:_FillPrice(entry, copper)
    self.priceEntry = entry
    self.ui.details.priceInput:SetCopper(copper)
end

local function clearDetails(d)
    d.icon:SetTexture(nil)
    d.operation:SetText("")
    d.deposit:SetText("")
    d.total:SetText("")
    d.warn:SetText("")
end

-- A view of an entry in which the next unit is the shown unit and the decision is the shown decision.
local function shadowEntry(entry, decision, unit)
    local units = {}
    for index, each in ipairs(entry.units) do
        units[index] = each
    end
    units[entry.next] = unit
    return setmetatable({ decision = decision, units = units, status = "ready" }, { __index = entry })
end

-- Put the calculated quantity and duration in the controls when the shown post changes.
function Tab:_SyncManual(entry, price)
    local d = self.ui.details
    local decision, unit = self:_NextPost(entry, price, true)
    local shown = self.manualShown
    local stacks = unit.stacks or 1
    local size = SellingTab.ClampQuantity(entry.manualQty, SellingTab.StackLimit(entry)) or unit.quantity
    self:_Shape(SellingTab.ShapeOf(entry.market))
    d.stacksMax:SetText("Max: " .. math.max(1, math.floor(SellingTab.MaxQuantity(entry.candidate) / size)))
    d.qtyMax:SetText("Max: " .. SellingTab.StackLimit(entry))
    if not (shown and shown.entry == entry and shown.next == entry.next and shown.qty == unit.quantity
        and shown.hours == decision.duration and shown.stacks == stacks) then
        self.manualShown = { entry = entry, next = entry.next, qty = unit.quantity, hours = decision.duration,
            stacks = stacks }
        self.syncing = true
        d.stacks:SetNumber(entry.manualStacks or stacks)
        d.qty:SetNumber(entry.manualQty or unit.quantity)
        d.duration:SetValue(entry.manualHours or decision.duration)
        self.syncing = false
    end
    d.qty:SetEnabled(true)
    d.stacks:SetEnabled(true)
    d.duration:SetEnabled(true)
    return size
end

-- The shape of the post boxes for the market of an entry (entry.market, or nil before the first decision):
--   "commodity": a quantity and a unit price (no stacks).
--   "plain": a Forever item auction: a price for one item and a quantity. Forever has no stacks.
--   "single": a TBC item of max stack 1: a price for one item and the number of stacks. No stack size.
--   "multi": a TBC stackable item: stacks of a size, a unit price and a stack price.
function SellingTab.ShapeOf(market)
    if market and market.commodity then
        return "commodity"
    elseif ns.SellingPlan.Multisell() then
        return market and market.single and "single" or "multi"
    end
    return "plain"
end

-- Show the boxes of the post size that fit the item (see SellingTab.ShapeOf). Only a stacked item has a stack
-- price and a stack size. The price box reads "Unit Price" for a commodity and a stack, else "Price".
function Tab:_Shape(mode)
    local d = self.ui.details
    if d.mode == mode then
        return
    end
    d.mode = mode
    local multi = mode == "multi"
    local counted = multi or mode == "single" -- the number of stacks is a box
    d.stacks:SetShown(counted)
    d.stackOf:SetShown(multi)
    d.stacksMax:SetShown(counted)
    d.qtyLabel:SetShown(mode == "commodity" or mode == "plain")
    d.qtyLabel:SetText("Quantity:")
    d.qty:SetShown(mode ~= "single")
    d.qtyMax:SetShown(mode ~= "single")
    d.stackLabel:SetShown(multi)
    d.stackInput:SetShown(multi)
    d.priceLabel:SetText((mode == "commodity" or multi) and "Unit Price" or "Price")
    local x = multi and QTY_X or SINGLE_QTY_X
    d.qty:ClearAllPoints()
    d.qty:SetPoint("TOPLEFT", d.frame, "TOPLEFT", x, -38)
    d.qtyMax:ClearAllPoints()
    d.qtyMax:SetPoint("TOPLEFT", d.frame, "TOPLEFT", x, -60)
end

-- The user typed a stack price: the unit price is the stack price divided by the stack size, rounded down.
-- The stack price box keeps the typed text.
function Tab:_OnStackPrice(copper)
    local entry = self.awaiting and self.awaiting.entry or self:_Focus()
    if not entry then
        return
    end
    local _, unit = self:_NextPost(entry, 1, true)
    local size = SellingTab.ClampQuantity(entry.manualQty, SellingTab.StackLimit(entry)) or unit.quantity
    self.ui.details.priceInput:SetCopper(SellingTab.UnitFromStack(copper, size))
    self.stackEdit = true
    self:_UpdateDetails()
    self.stackEdit = false
end

-- Fill the details pane from the next post of the queue (or the one item that the rule skips).
function Tab:_DrawDetails()
    local d = self.ui.details
    local entry = self.awaiting and self.awaiting.entry or self:_Focus()
    -- An edit of the stack size, the stack count or the duration holds until another item shows.
    local old = self.shownEntry
    if old ~= entry then
        if old then
            old.manualQty, old.manualHours, old.manualStacks = nil, nil, nil
        end
        self.shownEntry = entry
    end
    if not entry then
        clearDetails(d)
        local waiting = self:_WaitingCount()
        d.name:SetText(#self.selection == 0 and "Pick a group or an item" or waiting > 0
            and string.format("Waiting for the price of %d %s", waiting, waiting == 1 and "item" or "items")
            or "Nothing to post")
        -- A failed post stays in the list with its reason: the pane shows the same text.
        for _, failed in ipairs(self.selection) do
            if failed.status == "failed" then
                d.warn:SetText(self:_Name(failed) .. ": " .. tostring(failed.note))
                paint(d.warn, RED)
                break
            end
        end
        if self.priceEntry ~= nil then
            self.priceEntry = nil
            d.priceInput:SetCopper(nil)
        end
        d.priceInput:SetEnabled(false)
        d.stackInput:SetCopper(nil)
        d.stackInput:SetEnabled(false)
        d.stacksMax:SetText("")
        d.qtyMax:SetText("")
        self.manualShown = nil
        d.qty:SetNumber(nil)
        d.qty:SetEnabled(false)
        d.stacks:SetNumber(nil)
        d.stacks:SetEnabled(false)
        d.duration:SetValue(nil)
        d.duration:SetEnabled(false)
        return
    end
    local decision = entry.decision
    local ready = entry.status == "ready"
    if self.priceEntry ~= entry then
        self:_FillPrice(entry, ready and decision.price or decision.suggested)
    end
    d.priceInput:SetEnabled(true)
    d.stackInput:SetEnabled(true)
    local typed, why = SellingTab.CheckPrice(d.priceInput:GetCopper())
    local _, icon = self.deps.itemInfo(entry.item.itemID or 0)
    d.icon:SetTexture(icon)
    d.name:SetText(self:_Name(entry))
    d.operation:SetText("Operation: " .. tostring(entry.candidate and entry.candidate.operationName or "-"))
    if entry.depositPrice and typed ~= entry.depositPrice then
        self:_ForgetDeposits(entry)
    end
    local shown = typed or decision.price or decision.suggested or 0
    local size = self:_SyncManual(entry, shown)
    -- The stack price follows the unit price, unless the user types in the stack price box.
    if not self.stackEdit then
        d.stackInput:SetCopper(typed and SellingTab.StackFromUnit(typed, size) or nil)
    end
    local nextDecision, nextUnit = self:_NextPost(entry, shown)
    self:_ReadHeld(entry, typed, nextDecision, nextUnit)
    local values = nextUnit and SellingTab.Details(shadowEntry(entry, nextDecision, nextUnit),
        self:_Vendor(entry), typed)
    if not ready or not values then
        clearDetails(d)
        d.icon:SetTexture(icon)
        d.operation:SetText("Operation: " .. tostring(entry.candidate and entry.candidate.operationName or "-"))
        local reason = decision.reason or "no decision"
        d.warn:SetText("The rule skips this item: " .. (SKIP_TEXT[reason] or reason) .. ". Post asks you first.")
        paint(d.warn, ORANGE)
        if values then
            d.deposit:SetText(SellingTab.DepositValue(nextUnit.deposit))
            d.total:SetText(money(SellingTab.TotalPrice(values.unitPrice, nextUnit)))
        end
        return
    end
    d.deposit:SetText(SellingTab.DepositValue(nextUnit.deposit))
    d.total:SetText(money(SellingTab.TotalPrice(values.unitPrice, nextUnit)))
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

-- Draw the details pane. The Info column of the tree is hidden, so the reason of the shown entry goes to the warning
-- line when that line has no problem text.
function Tab:_UpdateDetails()
    self:_DrawDetails()
    local d = self.ui.details
    local entry = self.awaiting and self.awaiting.entry or self:_Focus()
    local alone = not entry and #self.selection == 1 and self.selectedId and self.selectedId:sub(1, 1) == "i"
    entry = entry or (alone and self.selection[1] or nil)
    if entry and (d.warn:GetText() or "") == "" then
        local info = SellingTab.InfoText(entry)
        d.warn:SetText(alone and (tostring(self:_Name(entry)) .. ": " .. info) or info)
        paint(d.warn, GREY)
    end
end
-- Show a refusal text in the warning line of the details pane. The next redraw of the pane replaces it.
function Tab:_ShowBusy(text)
    local d = self.ui and self.ui.details
    if d and d.warn then
        d.warn:SetText(text)
        paint(d.warn, ORANGE)
    end
end

-- True when the client takes a post now (the throttle gate). A client with no gate is always open.
function Tab:_GateOpen()
    local gate = self.deps.client.CanSendPost
    return gate == nil or gate() == true
end

-- Set the Post button from all gates: capability, post state, scan lock, post lock, throttle and an item to post.
-- With a closed gate and a client with no gate events, a short timer on this tab checks the gate again. The timer
-- changes the button only. It never posts (D26).
function Tab:_RefreshPost()
    local ui = self.ui
    if not ui then
        return
    end
    local open = self:_GateOpen()
    ui.postNext:SetText(self:PostLabel())
    ui.postNext:SetEnabled(self.deps.client.CanPost() and self.multi == nil and self.lock == nil and self.buy == nil
        and not self:_Scanning() and open and (self.awaiting ~= nil or self:_Focus() ~= nil))
    local events = self.deps.client.ThrottleEvents
    if open or not self.active or self.gateWatch or (events and events()) then
        return
    end
    self.gateWatch = true
    self.deps.after(GATE_POLL_SECONDS, function()
        self.gateWatch = false
        if self.active then
            self:_RefreshPost()
        end
    end)
end

function Tab:_Update()
    local ui = self.ui
    if not ui then
        return
    end
    self:_CheckHeld()
    ui.stop:SetShown(self.queue ~= nil)
    self:_Layout()
    ui.tree:Refresh()
    ui.postNext:SetText(self:PostLabel())
    local busy = self.multi ~= nil or self.buy ~= nil
    self:_RefreshPost()

    self:_RefreshLevels()
    self:_RefreshBuy()
    ui.skip:SetEnabled(not busy and (self.awaiting ~= nil or self:_Focus() ~= nil))
    ui.progress:SetText(self:ProgressText())
    self:_UpdateDetails()
end

function Tab:IsActive()
    return self.active
end

-- Hide the panel; the host or Blizzard's own code takes over.
function Tab:Deselect()
    self.active = false
    -- A quote or a confirm box that is open ends with the tab.
    self:_CancelBuy("the tab was left")
    -- A Blizzard tab or a hide takes over: its sale slot must not hold our item.
    self:_Release()
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
    elseif self.stale then
        self:_Reload()
    else
        -- Every later select reads the bags at once. An open post or a running queue stays.
        self:_RunSync()
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
    ui.stop = Kit.Button(content, "Stop", 60, function()
        self:Stop()
    end)
    -- A host with a free band over the content (TBC) gives its place; else the row sits at the top of the content.
    local band = api.band
    ui.stop:SetPoint("TOPLEFT", content, "TOPLEFT", band and band.left or 0, band and band.top or 0)

    -- The details pane: the next post of the queue.
    local skin = ns.AuctionTabs and ns.AuctionTabs.Skin
    local pane = Kit.Inset(content, skin)
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
    -- A line at the right edge of the pane: fromRight is the distance of its left edge from the right edge.
    local function rline(role, fromRight, y, width)
        local label = Kit.Label(pane, "", role)
        label:SetPoint("TOPLEFT", pane, "TOPRIGHT", -fromRight, -y)
        label:SetWidth(width)
        label:SetJustifyH("LEFT")
        if label.SetWordWrap then
            label:SetWordWrap(false)
        end
        return label
    end
    d.name = line("highlight", 56, 6, 400)
    d.operation = line("small", 56, 22, 290)
    -- The price of one item and the price of one stack. Each follows the other (see SellingTab.UnitFromStack).
    d.priceLabel = line("small", 56, 43, 64)
    d.priceLabel:SetText("Unit Price")
    d.priceInput = Kit.MoneyInput(pane, { onChange = function()
        self:_UpdateDetails()
    end })
    d.priceInput:SetPoint("TOPLEFT", pane, "TOPLEFT", 120, -38)
    for _, key in ipairs({ "gold", "silver", "copper" }) do
        Kit.Tooltip(d.priceInput[key], "Unit price", { "Type the gold, silver and copper of one item.",
            "An empty box counts as 0. Post uses this price." })
    end
    d.stackLabel = line("small", 56, 65, 64)
    d.stackLabel:SetText("Stack Price")
    d.stackInput = Kit.MoneyInput(pane, { onChange = function(copper)
        self:_OnStackPrice(copper)
    end })
    d.stackInput:SetPoint("TOPLEFT", pane, "TOPLEFT", 120, -60)
    for _, key in ipairs({ "gold", "silver", "copper" }) do
        Kit.Tooltip(d.stackInput[key], "Stack price", { "The price of one full stack.",
            "The unit price is this price divided by the stack size, rounded down to whole copper." })
    end
    d.warn = line("small", 56, 84, 410)
    -- The stack count and the stack size (or the quantity) of a manual post. The calculated values show until
    -- the user changes them. The labels under the boxes tell the most that the bags allow.
    d.stacks = Kit.NumberInput(pane, 40, { min = 1, hint = "1+", onChange = function(number)
        local ok, clamped = self:SetManualStacks(number)
        if ok and clamped then
            d.stacks:SetNumber(clamped)
        end
    end })
    d.stacks:SetPoint("TOPLEFT", pane, "TOPLEFT", STACKS_X, -38)
    if d.stacks.HookScript then
        d.stacks:HookScript("OnTextChanged", function()
            if not self.syncing then
                self:SetManualStacks(d.stacks.GetNumber())
            end
        end)
    end
    Kit.Tooltip(d.stacks, "Stacks", { "How many stacks one Post click makes.",
        "The most is what your bags hold at this stack size." })
    d.stackOf = line("small", STACKS_X + 44, 43, 46)
    d.stackOf:SetText("stack of")
    d.qtyLabel = line("small", STACKS_X, 43, 68)
    d.qty = Kit.NumberInput(pane, 40, { min = 1, hint = "1+", onChange = function(number)
        local ok, clamped = self:SetManualQuantity(number)
        if ok and clamped then
            d.qty:SetNumber(clamped)
        end
    end })
    d.qty:SetPoint("TOPLEFT", pane, "TOPLEFT", QTY_X, -38)
    if d.qty.HookScript then
        d.qty:HookScript("OnTextChanged", function()
            if not self.syncing then
                self:SetManualQuantity(d.qty.GetNumber())
            end
        end)
    end
    Kit.Tooltip(d.qty, "Stack size", { "How many items one stack of the next post holds.",
        "The most is your count minus the keep quantity, and the stack size of the item." })
    d.stacksMax = line("small", STACKS_X, 61, 70)
    d.qtyMax = line("small", QTY_X, 61, 70)
    -- The progress text of a run: in the band when the host has one, else under the operation name.
    if band then
        ui.progress = Kit.Label(content, "", "small")
        ui.progress:SetPoint("TOPLEFT", content, "TOPLEFT", band.left + 68, band.top - 5)
        ui.progress:SetJustifyH("LEFT")
        ui.progress:SetWidth(300)
    else
        ui.progress = line("small", 350, 22, 110)
    end
    -- The duration, the buttons, and the deposit and total price block, along the right edge of the pane.
    local durationLabel = rline("small", 312, 6, 100)
    durationLabel:SetText("Duration (hours)")
    local items = {}
    for _, hours in ipairs(ns.SellingPlan.DURATIONS) do
        items[#items + 1] = { value = hours, text = tostring(hours) }
    end
    d.duration = Kit.RadioGroup(pane, { items = items, width = 46, onChange = function(hours)
        self:SetManualDuration(hours)
    end })
    d.duration:SetPoint("TOPLEFT", pane, "TOPRIGHT", -312, -20)
    -- The post button posts in its own click handler: the protected call needs the click.
    ui.postNext = Kit.Button(pane, "Post", 140, nil)
    ui.postNext:SetPoint("TOPLEFT", pane, "TOPRIGHT", -312, -46)
    ui.postNext:SetScript("OnClick", function()
        self:PostNext()
    end)
    ui.skip = Kit.Button(pane, "Skip", 140, function()
        self:Skip()
    end)
    ui.skip:SetPoint("TOPLEFT", pane, "TOPRIGHT", -312, -72)
    local depositLabel = rline("small", 164, 6, 156)
    depositLabel:SetText("Deposit:")
    d.deposit = rline("highlight", 164, 22, 156)
    local totalLabel = rline("small", 164, 44, 156)
    totalLabel:SetText("Total Price:")
    d.total = rline("highlight", 164, 60, 156)
    ui.details = d
    self:_Shape(SellingTab.ShapeOf(nil))

    ui.tree = Kit.CreateTree(content, { rowHeight = ROW_HEIGHT, inset = true, skin = skin,
        initRow = function(row, node, depth, isCollapsed, hasChildren)
            self:_InitTreeRow(row, node, depth, isCollapsed, hasChildren)
        end,
        onSelect = function(node)
            self:SelectNode(node, true)
        end })
    ui.tree.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, TREE_TOP)
    ui.tree.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
    -- The column titles over the tree.
    local edge = ui.tree.contentInsets
    ui.headerOptions = { gap = COLUMN_GAP, left = edge.left, right = edge.right }
    local headers = Kit.CreateColumnHeader(content, COLUMNS, ui.headerOptions)
    headers.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, DETAILS_TOP - DETAILS_HEIGHT - 4)
    headers.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, DETAILS_TOP - DETAILS_HEIGHT - 4)
    headers.frame:SetHeight(HEADER_HEIGHT)
    ui.headers = headers

    -- The level pane at the right of the tree, always shown, with the Buy row under it.
    ui.levelList = Kit.CreateList(content, { rowHeight = ROW_HEIGHT, inset = true, skin = skin,
        initRow = function(row, data)
            self:_InitLevelRow(row, data)
        end })
    local levelEdge = ui.levelList.contentInsets
    ui.levelHeaderOptions = { gap = LEVEL_OPTIONS.gap, left = levelEdge.left, right = levelEdge.right }
    ui.levelHeader = Kit.CreateColumnHeader(content, LEVEL_COLUMNS, ui.levelHeaderOptions)
    ui.levelHeader.frame:SetHeight(HEADER_HEIGHT)
    -- The loading text of the pane: shown while the pane waits for the rows of its item.
    ui.levelLoading = Kit.Label(ui.levelList.frame, "", "highlight")
    ui.levelLoading:SetPoint("CENTER", ui.levelList.frame, "CENTER", 0, 0)
    ui.levelLoading:Hide()
    -- The Buy row: the info text, the amount box and the Buy button. The click on Buy starts the buy (D26).
    ui.buyRow = CreateFrame("Frame", nil, content)
    ui.buyRow:SetSize(LEVEL_WIDTH.wide, BUY_ROW)
    ui.buy = Kit.Button(ui.buyRow, BUY_TEXT, 80, nil)
    ui.buy:SetPoint("RIGHT", ui.buyRow, "RIGHT", 0, 0)
    ui.buy:SetScript("OnClick", function()
        self:Buy()
    end)
    ui.amount = Kit.NumberInput(ui.buyRow, 56, { min = 1, hint = "1+" })
    ui.amount:SetPoint("RIGHT", ui.buy, "LEFT", -6, 0)
    -- The hint of a bad number sits above the box, so that it does not cover the Buy button.
    ui.amount.hint:ClearAllPoints()
    ui.amount.hint:SetPoint("BOTTOM", ui.amount, "TOP", 0, 2)
    -- Only a text that the user typed is an amount. The client calls the hook with userInput true for a typed text and
    -- false for SetText (the default amount and the fixed 1 that the tab puts in the box). An empty box is quiet.
    ui.amount:HookScript("OnTextChanged", function(_, userInput)
        if userInput == true then
            self:SetAmount(ui.amount.GetNumber(), (ui.amount:GetText() or "") == "")
        end
    end)
    ui.buyInfo = Kit.Label(ui.buyRow, "", "small")
    ui.buyInfo:SetPoint("RIGHT", ui.amount, "LEFT", -6, 0)
    ui.buyInfo:SetJustifyH("RIGHT")
    Kit.Tooltip(ui.buy, BUY_TEXT, {
        "Buys the selected level, or the cheapest level that is not yours.",
        "A commodity buy takes the amount in the box, the cheapest units first.",
        "An item auction or a stack is one buy for each click.",
        "A box asks you to confirm the final price first." })
    if content.HookScript then
        content:HookScript("OnSizeChanged", function()
            -- Only a change of the wide or tight choice needs new columns; the anchors follow the size.
            if self:_LevelWidth() ~= self.appliedWidth then
                self:_ApplyColumns()
                self:_Layout()
                self:_Update()
            end
        end)
    end
    ui.stop:Hide()
    self:_Layout()
end

-- Build the panel in the parent frame and listen for the search events.
-- api: Enter(wasActive), Leave(tabIndex) and optional insets.
function Tab:Mount(parent, api)
    self.parent, self.api = parent, api
    self:_BuildContent()
    self:_ApplyColumns()
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
    -- The buy events reach the Buying tab too. Each tab acts only on the buy that it started (see BuyFlow).
    local buyEvents = client.BuyEvents and client.BuyEvents()
    if buyEvents then
        local function listen(event, fn)
            bus:Subscribe(event, OWNER, fn)
            self.events[#self.events + 1] = event
        end
        listen(buyEvents.priceUpdated, function(_, unit, total)
            self:_OnBuyQuote(unit, total)
        end)
        listen(buyEvents.priceUnavailable, function()
            self:_OnBuyQuoteUnavailable()
        end)
        listen(buyEvents.commoditySucceeded, function()
            self:_OnBuyCommodityResult(true)
        end)
        listen(buyEvents.commodityFailed, function()
            self:_OnBuyCommodityResult(false)
        end)
        listen(buyEvents.itemCompleted, function(_, auctionID)
            self:_OnBuyItemDone(auctionID)
        end)
        listen(buyEvents.itemError, function(_, code)
            self:_OnBuyItemError(code)
        end)
    end
    local posted = client.PostedEvent()
    if posted then
        bus:Subscribe(posted, OWNER, function()
            self:_OnPosted()
        end)
        self.events[#self.events + 1] = posted
    end
    local multisell = client.MultisellEvent and client.MultisellEvent()
    if multisell then
        bus:Subscribe(multisell, OWNER, function(_, kind, created, total, text)
            self:_OnMultisell(kind, created, total, text)
        end)
        self.events[#self.events + 1] = multisell
    end
    -- The throttle gate can change after these events: set the Post button again. This starts no post.
    local gateEvents = client.ThrottleEvents and client.ThrottleEvents()
    for _, event in ipairs(gateEvents or {}) do
        bus:Subscribe(event, OWNER, function()
            self:_RefreshPost()
        end)
        self.events[#self.events + 1] = event
    end
    -- The AH closes: the client gives the sale slot item back; the tab drops its hold and asks for the release too.
    local closeEvent = client.CloseEvent and client.CloseEvent()
    if closeEvent then
        bus:Subscribe(closeEvent, OWNER, function()
            -- A scan cannot go on without the AH: end it so that Post is not locked for ever.
            self.queue, self.pending = nil, nil
            -- A search that was in flight gets no result now: its entry waits again (it would stay "searching").
            for _, entry in ipairs(self.entries) do
                if entry.status == "searching" then
                    entry.status = "waiting"
                end
            end
            self.wanted, self.rowsFailed = nil, nil
            self:_ClearInfoWait()
            -- An open buy ends with no retry and no search: the AH is closed. The wait timers see no buy.
            if self.buy then
                self:_AbortBuy(self.buy, "the Auction House closed")
            end
            self.live, self.levelSel, self.amount, self.amountBad = nil, nil, nil, false
            self:_Release()
            self:_Update()
        end)
        self.events[#self.events + 1] = closeEvent
    end
    -- The bags change after a post: read them again so that a posted item leaves the list.
    bus:Subscribe("BAG_UPDATE_DELAYED", OWNER, function()
        self:_OnBags()
    end)
    self.events[#self.events + 1] = "BAG_UPDATE_DELAYED"
    -- Item data that loads late: draw the rows again. This makes no bag read.
    bus:Subscribe("ITEM_DATA_LOAD_RESULT", OWNER, function(_, itemID)
        self:_OnItemLoaded(itemID)
    end)
    self.events[#self.events + 1] = "ITEM_DATA_LOAD_RESULT"
    -- A group or rule change moves items to other groups: build the tree again.
    bus:Subscribe("Flipside.RulesChanged", OWNER, function()
        self:_OnRules()
    end)
    self.events[#self.events + 1] = "Flipside.RulesChanged"
    -- A scan changed the prices and the data age: build the candidates again.
    bus:Subscribe("Flipside.ScanFinished", OWNER, function()
        self:_OnRules()
    end)
    self.events[#self.events + 1] = "Flipside.ScanFinished"
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
-- itemInfo, maxStack(itemID), vendorPrice(itemID)
-- (copper for one item, or nil), confirm(name, text, onAccept), getRecord(key), now(),
-- itemLink(itemID) (link, quality), warn(title, text, onPost, onSkip, onCancel),
-- time() (seconds, default GetTime) and syncInterval (seconds between two automatic bag reads, default 1),
-- requestItem(itemID) (asks the client to load item data), postDelay (seconds that Post stays off after a post
-- result, default ns.Flavour.postDelay) and postTimeout (seconds after which Post comes back with no result).
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
        requestItem = deps.requestItem or defaultRequestItem,
        postDelay = deps.postDelay or ns.Flavour and ns.Flavour.postDelay or 0,
        postTimeout = deps.postTimeout or ns.Flavour and ns.Flavour.postTimeout or POST_TIMEOUT,
        warn = deps.warn or openWarning,
        time = deps.time or GetTime,
        syncInterval = deps.syncInterval or SYNC_INTERVAL,
    }
    resolved.log = deps.log or resolved.plan.Log
    -- The buy lines go to the log of the Buying tab: same lines as a purchase there.
    resolved.buyLog = deps.buyLog or ns.BuyingPlan.Log
    local tab = setmetatable({
        deps = resolved, entries = {}, selection = {}, events = {}, active = false, token = 0, postedCount = 0,
        requested = {}, waiting = {},
    }, Tab)
    BuyFlow.Register("selling", function()
        return tab.buy ~= nil
    end)
    return tab
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
