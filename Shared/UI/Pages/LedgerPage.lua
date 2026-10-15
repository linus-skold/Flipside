local _, ns = ...

-- The Ledger page of the Flipside window (SPEC 5.8 point 9). It reads the ledger store and writes nothing to it.

local LedgerPage = {}
ns.LedgerPage = LedgerPage

local SECONDS_PER_DAY = 86400
local ALL = "all"
local EMPTY_TEXT = "No records yet. The ledger records money from loot, vendors, mail, trades, quests and the "
    .. "Auction House."
local LOADING_TEXT = "Loading ledger..."
local COMBAT_TEXT = "Loading ledger... It loads when combat ends."
local OWNER = "Flipside.LedgerPage"
local KEY_CHAR, KEY_RANGE, KEY_GRAPH = "ledger.view.char", "ledger.view.range", "ledger.view.graph"
local DEFAULT_RANGE = "30"
local FILTER_HEIGHT = 28
local GRAPH_HEIGHT = 130
local NOTE_HEIGHT = 14
local GRAPH_EMPTY_TEXT = "No balance to show."
local HEADER_HEIGHT = 18
local TOTALS_HEIGHT = 22
local ROW_HEIGHT = 18

LedgerPage.TABS = {
    { key = "sales", title = "Sales" },
    { key = "purchases", title = "Purchases" },
    { key = "auctions", title = "Auctions" },
    { key = "income", title = "Income by source" },
    { key = "loot", title = "Loot" },
    { key = "expenses", title = "Expenses" },
}

-- The date range presets. days is the number of ledger days (UTC) that end today; nil means no start.
LedgerPage.RANGES = {
    { value = "today", text = "Today", days = 1 },
    { value = "7", text = "7 days", days = 7 },
    { value = "30", text = "30 days", days = 30 },
    { value = "180", text = "180 days", days = 180 },
    { value = "all", text = "All" },
}

local SOURCE_LABELS = {
    ahSale = "Auction sale",
    ahPurchase = "Auction purchase",
    ahPost = "Auction post",
    ahDeposit = "Auction deposit",
    ahDepositRefund = "Deposit refund",
    ahExpired = "Auction expired",
    ahCancelled = "Auction cancelled",
    loot = "Loot",
    vendorSale = "Vendor sale",
    vendorPurchase = "Vendor purchase",
    repair = "Repair",
    mailMoney = "Mail money",
    trade = "Trade",
    quest = "Quest",
    unknown = "Unknown",
}

-- Source -> the record types it can have. ahPost is listed here until the record module knows it.
local function typesOf(source)
    local known = ns.LedgerRecord and ns.LedgerRecord.SOURCE_TYPES and ns.LedgerRecord.SOURCE_TYPES[source]
    if known then
        return known
    end
    if source == "ahPost" then
        return { post = true }
    end
    return {}
end

function LedgerPage.SourceLabel(source)
    return SOURCE_LABELS[source] or tostring(source)
end

local function money(copper)
    if copper < 0 then
        return "-" .. GetMoneyString(-copper)
    end
    return GetMoneyString(copper)
end

local function direction(recordType)
    return ns.LedgerRecord and ns.LedgerRecord.Direction(recordType) or nil
end

-- Returns the first second of the range, or nil for no start. now is the server time.
function LedgerPage.RangeStart(rangeKey, now)
    for _, range in ipairs(LedgerPage.RANGES) do
        if range.value == rangeKey and range.days then
            return (math.floor(now / SECONDS_PER_DAY) - range.days + 1) * SECONDS_PER_DAY
        end
    end
    return nil
end

-- Which tab shows a full record. Returns true or false.
local TAB_TYPES = {
    sales = { sale = true },
    purchases = { purchase = true },
    loot = { loot = true },
    expenses = { expense = true },
}

local function recordInTab(tab, record)
    if tab == "auctions" then
        local t = record.type
        return t == "post" or t == "expired" or t == "cancelled" or t == "log"
            or (t == "purchase" and record.source == "ahPurchase")
    end
    return TAB_TYPES[tab] ~= nil and TAB_TYPES[tab][record.type] == true
end

-- Which tab shows a daily sum. A sum has a source but no type.
local function sumInTab(tab, sum)
    local types = typesOf(sum.source)
    if tab == "auctions" then
        return types.post or types.expired or types.cancelled or (types.purchase and true) or false
    end
    local wanted = TAB_TYPES[tab]
    if not wanted then
        return false
    end
    for name in pairs(types) do
        if wanted[name] then
            -- A source with both directions (trade, unknown) belongs to Expenses only when money went out.
            return tab ~= "expenses" or not types.income or sum.moneyOut > 0
        end
    end
    return false
end

local AUCTION_KINDS = { post = "Posted", purchase = "Bought", expired = "Expired", cancelled = "Cancelled" }

local function auctionDetail(record, log)
    local parts = { AUCTION_KINDS[record.type] or LedgerPage.SourceLabel(record.source) }
    if record.type == "post" then
        if (record.buyout or 0) > 0 then
            parts[#parts + 1] = "buyout " .. money(record.buyout)
        end
        if (record.deposit or 0) > 0 then
            parts[#parts + 1] = "deposit " .. money(record.deposit)
        end
    end
    local text = table.concat(parts, ", ")
    if log and log.reason then
        text = text .. ": " .. tostring(log.reason)
    end
    return text
end

local function dryRunDetail(log)
    local parts = { "dry run" }
    if log.action then
        parts[#parts + 1] = tostring(log.action)
    end
    if log.reason then
        parts[#parts + 1] = tostring(log.reason)
    end
    return table.concat(parts, ", ")
end

-- The detail text of a full record for a tab.
local function detailOf(tab, record, log)
    if tab == "sales" or tab == "purchases" then
        return record.counterparty or (tab == "purchases" and LedgerPage.SourceLabel(record.source)) or ""
    elseif tab == "loot" then
        return record.mob or ""
    elseif tab == "expenses" then
        local label = LedgerPage.SourceLabel(record.source)
        return record.counterparty and (label .. ", " .. record.counterparty) or label
    end
    return auctionDetail(record, log)
end

-- Builds the row of a full record. Money in or out follows the record type.
local function recordRow(tab, record, log)
    local dir = direction(record.type)
    local qty = record.qty or 0
    return {
        time = record.time,
        char = record.char,
        item = record.item or "",
        qty = qty,
        money = (record.money or 0) > 0 and record.money or nil,
        moneyIn = dir == "in" and (record.money or 0) or 0,
        moneyOut = dir == "out" and (record.money or 0) or 0,
        value = tab == "loot" and record.value and record.value * math.max(qty, 1) or nil,
        detail = detailOf(tab, record, log),
        source = record.source,
    }
end

local function dryRunRow(log)
    return {
        time = log.time,
        char = log.char,
        item = log.item or "",
        qty = log.qty or 0,
        money = (log.money or 0) > 0 and log.money or nil,
        moneyIn = 0,
        moneyOut = 0,
        detail = dryRunDetail(log),
        dryRun = true,
    }
end

local function sumRow(tab, sum, char)
    local count = sum.count
    local detail = "daily total (" .. count .. ")"
    if tab == "auctions" then
        detail = LedgerPage.SourceLabel(sum.source) .. ", " .. detail
    end
    local total = sum.moneyIn + sum.moneyOut
    return {
        time = sum.day * SECONDS_PER_DAY,
        char = char,
        item = sum.item or "",
        qty = sum.qty,
        money = total > 0 and total or nil,
        moneyIn = sum.moneyIn,
        moneyOut = sum.moneyOut,
        detail = detail,
        source = sum.source,
        daily = true,
    }
end

-- The store options of a filter: { char = name or nil, fromTime = number or nil }.
local function storeOptions(filter, now)
    local char = filter.char
    if char == ALL then
        char = nil
    end
    return { char = char, fromTime = LedgerPage.RangeStart(filter.range, now), toTime = nil }
end

-- Returns the rows of a record tab, newest first. filter: { char, range }. char "all" means every character.
function LedgerPage.Rows(store, tab, filter, now)
    local options = storeOptions(filter, now)
    local records = store:Records(options)
    local logs = {}
    if tab == "auctions" then
        for _, record in ipairs(records) do
            if record.type == "log" and record.ctx and not record.dryRun then
                logs[record.ctx] = record
            end
        end
    end
    local rows = {}
    for _, record in ipairs(records) do
        if recordInTab(tab, record) then
            if record.type == "log" then
                if record.dryRun then
                    rows[#rows + 1] = dryRunRow(record)
                end
            else
                rows[#rows + 1] = recordRow(tab, record, record.ctx and logs[record.ctx] or nil)
            end
        end
    end
    local chars = options.char and { options.char } or store:Characters()
    for _, char in ipairs(chars) do
        local sums = store:Sums({ char = char, fromTime = options.fromTime })
        for _, sum in ipairs(sums) do
            if sumInTab(tab, sum) then
                rows[#rows + 1] = sumRow(tab, sum, char)
            end
        end
    end
    for index, row in ipairs(rows) do
        row.order = index
    end
    table.sort(rows, function(a, b)
        if a.time ~= b.time then
            return a.time > b.time
        end
        return a.order > b.order
    end)
    return rows
end

-- Returns one row for each source with money flow: { source, count, qty, moneyIn, moneyOut, net }.
function LedgerPage.IncomeRows(store, filter, now)
    local rows = {}
    for source, entry in pairs(store:SumsBySource(storeOptions(filter, now))) do
        if entry.moneyIn > 0 or entry.moneyOut > 0 then
            rows[#rows + 1] = {
                source = source,
                label = LedgerPage.SourceLabel(source),
                count = entry.count,
                qty = entry.qty,
                moneyIn = entry.moneyIn,
                moneyOut = entry.moneyOut,
                net = entry.moneyIn - entry.moneyOut,
            }
        end
    end
    table.sort(rows, function(a, b)
        local sa, sb = a.moneyIn + a.moneyOut, b.moneyIn + b.moneyOut
        if sa ~= sb then
            return sa > sb
        end
        return a.source < b.source
    end)
    return rows
end

-- Returns money in, money out and net of rows.
function LedgerPage.Totals(rows)
    local totalIn, totalOut = 0, 0
    for _, row in ipairs(rows) do
        totalIn = totalIn + row.moneyIn
        totalOut = totalOut + row.moneyOut
    end
    return { moneyIn = totalIn, moneyOut = totalOut, net = totalIn - totalOut, count = #rows }
end

-- The column list of a tab. showChar is false when one character is selected.
-- The Money columns are owned: the page draws them with the Kit money widget.
function LedgerPage.Columns(tab, showChar, formatters)
    formatters = formatters or {}
    if tab == "income" then
        return {
            { key = "label", title = "Source" },
            { key = "count", title = "Count", width = 60, number = true },
            { key = "moneyIn", title = "Money in", width = 120, number = true, owned = true },
            { key = "moneyOut", title = "Money out", width = 120, number = true, owned = true },
            { key = "net", title = "Net", width = 120, number = true, owned = true },
        }
    end
    local detailTitle = ({ sales = "Buyer", purchases = "Seller", loot = "Mob", expenses = "Type" })[tab] or "Detail"
    return {
        { key = "time", title = "Date", width = 104, format = formatters.time },
        { key = "char", title = "Character", width = 110, hidden = not showChar },
        { key = "item", title = "Item", format = formatters.item },
        { key = "qty", title = "Qty", width = 36, number = true, format = function(v)
            return v and v > 0 and tostring(v) or ""
        end },
        { key = "money", title = "Money", width = 100, number = true, owned = true },
        { key = "value", title = "Value", width = 90, number = true, owned = true, hidden = tab ~= "loot" },
        { key = "detail", title = detailTitle, width = 150 },
    }
end

-- Page --------------------------------------------------------------------------------------------------

local function now(deps)
    return (deps.now or GetServerTime)()
end

local function placeAcross(frame, parent, top, bottom)
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, top)
    frame:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, top)
    if bottom then
        frame:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, bottom)
        frame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, bottom)
    end
end

-- Build the page in the content frame.
-- deps: ledgerLoader (Ensure, Store), bus (Subscribe), db (settings), character (Name-Realm), itemCache (optional),
-- now (optional), after(seconds, fn) (optional).
function LedgerPage.Build(content, deps)
    local Kit = ns.Kit
    local LedgerBalance = ns.LedgerBalance
    local page = { views = {}, tab = LedgerPage.TABS[1].key }
    local loader = deps.ledgerLoader
    local requested = {}
    local failure

    -- Saved choices. The default is the current character and 30 days.
    local function readSetting(key, default)
        local value = deps.db and deps.db:Get("character", key)
        if value == nil or value == "" then
            return default
        end
        return value
    end
    page.filter = {
        char = readSetting(KEY_CHAR, deps.character or ALL),
        range = tostring(readSetting(KEY_RANGE, DEFAULT_RANGE)),
    }

    local function store()
        return loader and loader:Store() or nil
    end

    -- Item text: a quality-coloured link if the client knows the item, else a name or the key.
    local function itemText(key, tab)
        if key == nil or key == "" then
            return tab == "loot" and "Money" or "-"
        end
        local parsed = ns.ItemString and ns.ItemString.ParseKey(key)
        if not (parsed and deps.itemCache) then
            return key
        end
        local info = deps.itemCache:Get(parsed.itemID)
        if info then
            if info.link then
                return info.link
            end
            local _, _, _, hex = Kit.QualityColor(info.quality)
            return "|c" .. hex .. tostring(info.name) .. "|r"
        end
        if not requested[parsed.itemID] then
            requested[parsed.itemID] = true
            deps.itemCache:Request(parsed.itemID, function()
                if deps.after then
                    deps.after(0, page.Draw)
                end
            end)
        end
        return "Item " .. parsed.itemID
    end

    local function timeText(value, row)
        local format = _G.date
        if row and row.daily then
            return format("!%Y-%m-%d", value)
        end
        return format("%Y-%m-%d %H:%M", value)
    end

    -- Filters.

    page.charDropdown = Kit.Dropdown(content, 190, {
        items = { { value = ALL, text = "All characters" } },
        value = page.filter.char,
        onChange = function(value)
            page.filter.char = value
            if deps.db then
                deps.db:Set("character", KEY_CHAR, value)
            end
            page.Draw()
        end,
    })
    page.charDropdown:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    local rangeItems = {}
    for _, range in ipairs(LedgerPage.RANGES) do
        rangeItems[#rangeItems + 1] = { value = range.value, text = range.text }
    end
    page.rangeDropdown = Kit.Dropdown(content, 110, {
        items = rangeItems,
        value = page.filter.range,
        onChange = function(value)
            page.filter.range = value
            if deps.db then
                deps.db:Set("character", KEY_RANGE, value)
            end
            page.Draw()
        end,
    })
    page.rangeDropdown:SetPoint("LEFT", page.charDropdown, "RIGHT", 8, 0)
    page.status = Kit.Label(content, LOADING_TEXT, "normal")
    page.status:SetPoint("LEFT", page.rangeDropdown, "RIGHT", 12, 0)
    page.status:SetJustifyH("LEFT")

    -- The character list: all, the current character first, then the others.
    local function refreshCharacters()
        local items = { { value = ALL, text = "All characters" } }
        local seen = { [ALL] = true }
        local function add(name)
            if name and not seen[name] then
                seen[name] = true
                items[#items + 1] = { value = name, text = name }
            end
        end
        add(deps.character)
        local current = store()
        if current then
            for _, name in ipairs(current:Characters()) do
                add(name)
            end
        end
        add(page.filter.char)
        page.charDropdown:SetItems(items)
        page.charDropdown:SetValue(page.filter.char)
    end

    -- The balance graph. It follows the character and range filters. The button hides it to give the list room.

    page.graphMode = "days"
    page.graph = Kit.LineGraph(content, {
        height = GRAPH_HEIGHT,
        emptyText = GRAPH_EMPTY_TEXT,
        formatY = money,
        formatX = function(x)
            return LedgerBalance.AxisText(x, page.graphMode, _G.date)
        end,
        onHover = function(point)
            return LedgerBalance.HoverLines(point, page.graphMode, _G.date, money)
        end,
    })
    page.graph:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -FILTER_HEIGHT - 2)
    page.graph:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -FILTER_HEIGHT - 2)
    page.graphNote = Kit.Label(content, "", "small")
    page.graphNote:SetPoint("TOPLEFT", page.graph, "BOTTOMLEFT", 4, -2)
    page.graphNote:SetJustifyH("LEFT")
    page.graphShown = readSetting(KEY_GRAPH, true) ~= false

    -- Tabs.

    local body = CreateFrame("Frame", nil, content)
    body:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
    local function layoutBody()
        local top = -FILTER_HEIGHT - 4
        if page.graphShown then
            top = top - GRAPH_HEIGHT - NOTE_HEIGHT
        end
        body:ClearAllPoints()
        body:SetPoint("TOPLEFT", content, "TOPLEFT", 0, top)
        body:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
        page.graph:SetShown(page.graphShown)
        page.graphNote:SetShown(page.graphShown)
        page.graphToggle:SetText(page.graphShown and "Hide graph" or "Show graph")
    end
    page.graphToggle = Kit.Button(content, "", 100, function()
        page.graphShown = not page.graphShown
        if deps.db then
            deps.db:Set("character", KEY_GRAPH, page.graphShown)
        end
        layoutBody()
        page.DrawGraph()
    end)
    page.graphToggle:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    layoutBody()
    page.topTabs = Kit.CreateTopTabs(body, LedgerPage.TABS, {
        onSelect = function(key)
            page.tab = key
            page.Draw()
        end,
    })

    -- A view: the header, the list and the totals row of one tab. It is built when the tab first shows.
    local function buildView(tab)
        local panel = page.topTabs:GetContent(tab)
        local view = { tab = tab }
        view.columns = LedgerPage.Columns(tab, page.filter.char == ALL, { time = timeText, item = function(v)
            return itemText(v, tab)
        end })
        view.options = { gap = 6 }
        view.moneyKeys = {}
        for _, column in ipairs(view.columns) do
            if column.owned then
                view.moneyKeys[#view.moneyKeys + 1] = column.key
            end
        end
        view.list = Kit.CreateList(panel, {
            rowHeight = ROW_HEIGHT,
            inset = true,
            initRow = function(row, data)
                if not row.cells then
                    row.cells = Kit.CreateColumnCells(row, view.columns, view.options)
                    row.money = {}
                    for _, key in ipairs(view.moneyKeys) do
                        row.money[key] = Kit.Money(row, money)
                        row.cells[key] = row.money[key]
                    end
                end
                Kit.LayoutColumnLabels(row.cells, row, view.columns, view.options)
                for _, column in ipairs(view.columns) do
                    local cell = row.cells[column.key]
                    if column.owned then
                        local value = data[column.key]
                        if value == 0 and column.key ~= "net" then
                            value = nil
                        end
                        cell:SetCopper(value)
                    elseif cell then
                        cell:SetText(Kit.ColumnText(column, data))
                    end
                end
                row.data = data
            end,
        })
        local edge = view.list.contentInsets
        view.options.left, view.options.right = edge.left, edge.right
        view.header = Kit.CreateColumnHeader(panel, view.columns, view.options)
        placeAcross(view.header.frame, panel, 0)
        view.header.frame:SetHeight(HEADER_HEIGHT)
        view.list.frame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -HEADER_HEIGHT - 2)
        view.list.frame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, TOTALS_HEIGHT + 4)
        view.empty = Kit.Label(panel, EMPTY_TEXT, "disabled")
        view.empty:SetPoint("CENTER", view.list.frame, "CENTER", 0, 0)
        view.empty:SetWidth(460)
        view.empty:SetJustifyH("CENTER")
        view.empty:Hide()

        -- The totals row.
        local totals = CreateFrame("Frame", nil, panel)
        totals:SetHeight(TOTALS_HEIGHT)
        totals:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
        totals:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
        view.totals = { frame = totals }
        view.totals.caption = Kit.Label(totals, "Totals", "highlight")
        view.totals.caption:SetPoint("LEFT", totals, "LEFT", 4, 0)
        local previous = view.totals.caption
        for _, name in ipairs({ "moneyIn", "moneyOut", "net" }) do
            local title = ({ moneyIn = "Money in", moneyOut = "Money out", net = "Net" })[name]
            local caption = Kit.Label(totals, title, "small")
            caption:SetPoint("LEFT", previous, "RIGHT", 24, 0)
            local value = Kit.Money(totals, money)
            value:SetPoint("LEFT", caption, "RIGHT", 6, 0)
            view.totals[name] = value
            previous = value
        end
        view.totals.count = Kit.Label(totals, "", "small")
        view.totals.count:SetPoint("RIGHT", totals, "RIGHT", -4, 0)
        return view
    end

    local function ensureView(tab)
        if not page.views[tab] then
            page.views[tab] = buildView(tab)
        end
        return page.views[tab]
    end

    -- Show or hide the character column: change the flag and place the labels again.
    local function applyColumns(view)
        local show = page.filter.char == ALL
        for _, column in ipairs(view.columns) do
            if column.key == "char" then
                column.hidden = not show
            end
        end
        Kit.LayoutColumnLabels(view.header.labels, view.header.frame, view.columns, view.options)
    end

    local function showStatus(text)
        page.status:SetText(text or "")
    end

    -- The names that the graph covers: the chosen character, or every known character for "All characters".
    -- A character from the settings counts only if it has a saved balance.
    local function graphCharacters(current)
        if page.filter.char ~= ALL then
            return { page.filter.char }
        end
        local names, seen = {}, {}
        local function add(name)
            if name and not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
        for _, name in ipairs(current:Characters()) do
            add(name)
        end
        add(deps.character)
        if deps.db then
            for _, name in ipairs(deps.db:ListCharacters()) do
                if LedgerBalance.ReadSnapshot(deps.db, name) then
                    add(name)
                end
            end
        end
        table.sort(names)
        return names
    end

    -- Draw the balance graph. It computes the points only when the filter, the records or the balance change.
    function page.DrawGraph()
        local current = store()
        if not (current and page.graphShown) then
            return
        end
        local at = now(deps)
        local getMoney = deps.getMoney or GetMoney
        local copper = getMoney and getMoney() or nil
        if type(copper) ~= "number" then
            copper = nil
        end
        local buffer = deps.ledgerBuffer
        local signature = table.concat({
            page.filter.char, page.filter.range, current:Revision(), buffer and buffer:Count() or 0,
            copper or "-", math.floor(at / 60),
        }, "|")
        if page.graphSignature == signature then
            return
        end
        page.graphSignature = signature
        local range = page.filter.range
        local series = LedgerBalance.Series({
            store = current,
            characters = graphCharacters(current),
            live = deps.character and copper and { char = deps.character, copper = copper } or nil,
            snapshot = function(name)
                return deps.db and LedgerBalance.ReadSnapshot(deps.db, name) or nil
            end,
            buffered = buffer and buffer:Peek() or nil,
            now = at,
            rangeKey = range,
            rangeStart = LedgerPage.RangeStart(range, at),
        })
        page.series = series
        page.graphMode = series.mode
        local maxY = 0
        for _, point in ipairs(series.points) do
            maxY = math.max(maxY, point.y)
        end
        local scale = LedgerBalance.MoneyScale(maxY)
        page.graphScale = scale
        page.graph:SetPoints(series.points, { yMin = 0, yMax = scale.max, yTicks = scale.ticks })
        if #series.omitted > 0 then
            page.graphNote:SetText("Not in the graph, no balance known yet: " .. table.concat(series.omitted, ", ")
                .. ". Log in with the character once.")
        else
            page.graphNote:SetText("")
        end
    end

    -- Draw the visible tab. Only the rows of this tab and range are built.
    function page.Draw()
        local current = store()
        if not current then
            return
        end
        refreshCharacters()
        local tab = page.tab
        local view = ensureView(tab)
        applyColumns(view)
        local at = now(deps)
        local rows
        if tab == "income" then
            rows = LedgerPage.IncomeRows(current, page.filter, at)
        else
            rows = LedgerPage.Rows(current, tab, page.filter, at)
        end
        view.rows = rows
        view.list:SetData(rows)
        view.empty:SetShown(#rows == 0)
        local totals = LedgerPage.Totals(rows)
        view.totals.moneyIn:SetCopper(totals.moneyIn)
        view.totals.moneyOut:SetCopper(totals.moneyOut)
        view.totals.net:SetCopper(totals.net)
        view.totals.count:SetText(totals.count .. (totals.count == 1 and " row" or " rows"))
        page.DrawGraph()
        showStatus("")
    end

    -- Load the ledger and draw. It never loads in combat: the loader waits for the end of combat.
    function page.Open()
        failure = nil
        if not store() then
            showStatus(LOADING_TEXT)
        end
        if loader then
            local ok, reason = loader:Ensure()
            if not ok and not store() then
                if reason == "combat" then
                    showStatus(COMBAT_TEXT)
                elseif reason ~= "busy" and reason ~= nil then
                    failure = tostring(reason)
                    showStatus(failure)
                end
            end
        else
            failure = "The ledger is not available this session."
            showStatus(failure)
        end
        if store() then
            page.Draw()
        end
    end

    if deps.bus and ns.LedgerLoader then
        deps.bus:Subscribe(ns.LedgerLoader.EVENT_LOADED, OWNER, function()
            failure = nil
            page.Draw()
        end)
        deps.bus:Subscribe(ns.LedgerLoader.EVENT_FAILED, OWNER, function(_, reason)
            failure = tostring(reason)
            if not store() then
                showStatus(failure)
            end
        end)
    end

    page.Open()
    return page
end
