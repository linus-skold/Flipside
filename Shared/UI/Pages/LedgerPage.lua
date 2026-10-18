local _, ns = ...

-- The Ledger page of the Flipside window (SPEC 5.8 point 9). It reads the ledger store. Its only write is the edit
-- of one record (right-click menu, SPEC 5.8 edit).

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
local KEY_REALM = "ledger.view.realm"
local UNKNOWN_REALM = "?"
local DEFAULT_RANGE = "30"
local FILTER_HEIGHT = 28
local GRAPH_HEIGHT = 130
local NOTE_HEIGHT = 14
local GRAPH_EMPTY_TEXT = "No balance to show."
local HEADER_HEIGHT = 18
local TOTALS_HEIGHT = 22
local ROW_HEIGHT = 18

LedgerPage.TABS = {
    { key = "overview", title = "Overview" },
    { key = "sales", title = "Sales" },
    { key = "purchases", title = "Purchases" },
    { key = "auctions", title = "Auctions" },
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
    ahOutbidRefund = "Outbid refund",
    ahExpired = "Auction expired",
    ahCancelled = "Auction cancelled",
    loot = "Loot",
    vendorSale = "Vendor sale",
    vendorPurchase = "Vendor purchase",
    repair = "Repair",
    mailMoney = "Mail money",
    mailPostage = "Mail postage",
    mailMoneySent = "Mail money sent",
    mailSent = "Mail sent",
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

-- The short label of the Type column of the Overview, by source. A log record has no source.
local TYPE_LABELS = {
    ahSale = "AH sale",
    ahPurchase = "AH purchase",
    ahPost = "AH post",
    ahDeposit = "Deposit",
    ahDepositRefund = "Deposit refund",
    ahOutbidRefund = "Outbid refund",
    ahExpired = "AH expired",
    ahCancelled = "AH cancelled",
    loot = "Loot",
    vendorSale = "Vendor sale",
    vendorPurchase = "Vendor purchase",
    repair = "Repair",
    mailMoney = "Mail money",
    mailPostage = "Mail postage",
    mailMoneySent = "Mail money sent",
    mailSent = "Mail sent",
    trade = "Trade",
    quest = "Quest",
    unknown = "Unknown",
}
LedgerPage.TYPE_LABELS = TYPE_LABELS

function LedgerPage.TypeLabel(source, dryRun)
    if source == nil then
        return dryRun and "Dry run" or "Log"
    end
    return TYPE_LABELS[source] or tostring(source)
end

local MINUS = "\226\136\146"
local GREEN, RED = "|cff40ff40", "|cffff4040"

local function money(copper)
    if copper < 0 then
        return "-" .. GetMoneyString(-copper)
    end
    return GetMoneyString(copper)
end

local function direction(recordType)
    return ns.LedgerRecord and ns.LedgerRecord.Direction(recordType) or nil
end

-- The text of a signed money flow: a green plus for money in, a red minus for money out. Zero is empty.
function LedgerPage.FlowText(flow)
    if flow > 0 then
        return GREEN .. "+" .. money(flow) .. "|r"
    elseif flow < 0 then
        return RED .. MINUS .. money(-flow) .. "|r"
    end
    return ""
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
    if tab == "overview" then
        return true
    end
    if tab == "auctions" then
        local t = record.type
        return t == "post" or t == "expired" or t == "cancelled" or t == "log"
            or (t == "purchase" and record.source == "ahPurchase")
    end
    return TAB_TYPES[tab] ~= nil and TAB_TYPES[tab][record.type] == true
end

-- Which tab shows a daily sum. A sum has a source but no type.
local function sumInTab(tab, sum)
    if tab == "overview" then
        return true
    end
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
    if tab == "overview" then
        if record.type == "post" then
            local parts = {}
            if (record.buyout or 0) > 0 then
                parts[1] = "Buyout " .. money(record.buyout)
            end
            if (record.deposit or 0) > 0 then
                parts[#parts + 1] = "deposit " .. money(record.deposit)
            end
            if #parts > 0 then
                parts[1] = parts[1]:sub(1, 1):upper() .. parts[1]:sub(2)
                return table.concat(parts, ", ")
            end
        end
        return record.counterparty or record.mob or ""
    elseif tab == "sales" or tab == "purchases" then
        return record.counterparty or (tab == "purchases" and LedgerPage.SourceLabel(record.source)) or ""
    elseif tab == "loot" then
        return record.mob or ""
    elseif tab == "expenses" then
        local label = LedgerPage.SourceLabel(record.source)
        return record.counterparty and (label .. ", " .. record.counterparty) or label
    end
    return auctionDetail(record, log)
end

local dryRunRow

-- The detail text of a record row: the tab detail, then the note. An edited record starts with "*".
local function withMarks(detail, record)
    if record.note then
        detail = detail == "" and record.note or (detail .. ", " .. record.note)
    end
    if record.edited then
        detail = detail == "" and "*" or ("* " .. detail)
    end
    return detail
end

-- Returns the title and the lines of the row tooltip of a record, or nil if there is nothing to show.
-- It shows the note and, for an edited record, the first values.
function LedgerPage.TooltipLines(record)
    if type(record) ~= "table" or not (record.note or record.edited) then
        return nil
    end
    local lines = {}
    if record.note then
        lines[#lines + 1] = "Note: " .. record.note
    end
    local orig = record.orig
    if record.edited and type(orig) == "table" then
        lines[#lines + 1] = "Edited. First values:"
        lines[#lines + 1] = "Source: " .. LedgerPage.SourceLabel(orig.source)
        local item = (orig.item or "") ~= "" and orig.item or orig.itemName or "-"
        lines[#lines + 1] = "Item: " .. item .. ", quantity " .. (orig.qty or 0)
        lines[#lines + 1] = "Amount: " .. money(orig.money or 0)
        if orig.note then
            lines[#lines + 1] = "Note: " .. orig.note
        end
    end
    return record.edited and "Edited entry" or "Note", lines
end

-- Builds the row of a full record. Money in or out follows the record type.
local function recordRow(tab, record, log)
    local dir = direction(record.type)
    local qty = record.qty or 0
    return {
        record = record,
        edited = record.edited == true,
        time = record.time,
        char = record.char,
        item = (record.item or "") ~= "" and record.item or record.itemName or "",
        qty = qty,
        money = (record.money or 0) > 0 and record.money or nil,
        moneyIn = dir == "in" and (record.money or 0) or 0,
        moneyOut = dir == "out" and (record.money or 0) or 0,
        value = tab == "loot" and record.value and record.value * math.max(qty, 1) or nil,
        detail = withMarks(detailOf(tab, record, log), record),
        source = record.source,
        kind = tab == "overview" and LedgerPage.TypeLabel(record.source) or nil,
        flow = tab == "overview" and (dir == "in" and (record.money or 0) or dir == "out" and -(record.money or 0)
            or 0) or nil,
    }
end

-- The Overview row of a decision log record (dry run or not).
local function logRow(log)
    local row = dryRunRow(log)
    row.kind = LedgerPage.TypeLabel(nil, log.dryRun)
    row.flow = 0
    if not log.dryRun then
        local parts = {}
        for _, part in ipairs({ log.action, log.reason }) do
            if part then
                parts[#parts + 1] = tostring(part)
            end
        end
        row.detail = table.concat(parts, ", ")
    end
    return row
end

function dryRunRow(log)
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
        kind = tab == "overview" and LedgerPage.TypeLabel(sum.source) or nil,
        flow = tab == "overview" and (sum.moneyIn - sum.moneyOut) or nil,
    }
end

-- Returns the realm part of a "Name-Realm" key, or UNKNOWN_REALM if the key has no realm (an old record).
function LedgerPage.RealmOf(char)
    return type(char) == "string" and char:match("^[^-]+%-(.+)$") or UNKNOWN_REALM
end

-- Returns the name part of a "Name-Realm" key. A key with no realm is returned as it is.
function LedgerPage.NameOf(char)
    return type(char) == "string" and char:match("^([^-]+)%-") or tostring(char)
end

-- True if the filter has no realm, or the character is on the realm of the filter.
local function inRealm(filter, char)
    return filter.realm == nil or LedgerPage.RealmOf(char) == filter.realm
end

-- The store options of a filter: { char = name or nil, fromTime = number or nil }.
local function storeOptions(filter, now)
    local char = filter.char
    if char == ALL then
        char = nil
    end
    return { char = char, fromTime = LedgerPage.RangeStart(filter.range, now), toTime = nil }
end

-- Returns the rows of a record tab, newest first. filter: { char, range, realm }. char "all" means every character.
-- If realm is set (TBC), "all" means every character of that realm.
function LedgerPage.Rows(store, tab, filter, now)
    local options = storeOptions(filter, now)
    local records = store:Records(options)
    if filter.realm ~= nil and options.char == nil then
        local kept = {}
        for _, record in ipairs(records) do
            if inRealm(filter, record.char) then
                kept[#kept + 1] = record
            end
        end
        records = kept
    end
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
                if tab == "overview" then
                    rows[#rows + 1] = logRow(record)
                elseif record.dryRun then
                    rows[#rows + 1] = dryRunRow(record)
                end
            else
                rows[#rows + 1] = recordRow(tab, record, record.ctx and logs[record.ctx] or nil)
            end
        end
    end
    local chars = options.char and { options.char } or store:Characters()
    for _, char in ipairs(chars) do
        if options.char or inRealm(filter, char) then
            local sums = store:Sums({ char = char, fromTime = options.fromTime })
            for _, sum in ipairs(sums) do
                if sumInTab(tab, sum) then
                    rows[#rows + 1] = sumRow(tab, sum, char)
                end
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
    if tab == "overview" then
        return {
            { key = "time", title = "Date", width = 104, format = formatters.time },
            { key = "char", title = "Character", width = 110, hidden = not showChar },
            { key = "kind", title = "Type", width = 100 },
            { key = "item", title = "Item", format = formatters.item },
            { key = "qty", title = "Qty", width = 36, number = true, format = function(v)
                return v and v > 0 and tostring(v) or ""
            end },
            { key = "flow", title = "Money", width = 110, number = true, owned = true },
            { key = "detail", title = "Detail", width = 150 },
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
    -- With the realm filter (TBC) the default is the current server and All characters.
    local realmFilter = (ns.Flavour or {}).ledgerRealmFilter == true
    local currentRealm = deps.character and LedgerPage.RealmOf(deps.character) or nil
    page.filter = {
        char = readSetting(KEY_CHAR, realmFilter and ALL or deps.character or ALL),
        range = tostring(readSetting(KEY_RANGE, DEFAULT_RANGE)),
        realm = realmFilter and readSetting(KEY_REALM, currentRealm or UNKNOWN_REALM) or nil,
    }

    local function logFilter()
        if ns.Log then
            ns.Log.Write("ledger", "debug", "filter realm=" .. tostring(page.filter.realm) .. " char="
                .. tostring(page.filter.char) .. " range=" .. tostring(page.filter.range))
        end
    end

    local function store()
        return loader and loader:Store() or nil
    end

    -- Item text: a quality-coloured link if the client knows the item, else a name or the key.
    local function itemText(key, tab)
        if key == nil or key == "" then
            if tab == "overview" then
            return ""
        end
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

    if realmFilter then
        page.realmDropdown = Kit.Dropdown(content, 150, {
            items = {},
            value = page.filter.realm,
            onChange = function(value)
                page.filter.realm = value
                page.filter.char = ALL
                if deps.db then
                    deps.db:Set("character", KEY_REALM, value)
                    deps.db:Set("character", KEY_CHAR, ALL)
                end
                logFilter()
                page.Draw()
            end,
        })
        page.realmDropdown:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    end
    page.charDropdown = Kit.Dropdown(content, realmFilter and 150 or 190, {
        items = { { value = ALL, text = realmFilter and "All" or "All characters" } },
        value = page.filter.char,
        onChange = function(value)
            page.filter.char = value
            if deps.db then
                deps.db:Set("character", KEY_CHAR, value)
            end
            if realmFilter then
                logFilter()
            end
            page.Draw()
        end,
    })
    if realmFilter then
        page.charDropdown:SetPoint("LEFT", page.realmDropdown, "RIGHT", 8, 0)
    else
        page.charDropdown:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    end
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
            if realmFilter then
                logFilter()
            end
            page.Draw()
        end,
    })
    page.rangeDropdown:SetPoint("LEFT", page.charDropdown, "RIGHT", 8, 0)
    page.status = Kit.Label(content, LOADING_TEXT, "normal")
    page.status:SetPoint("LEFT", page.rangeDropdown, "RIGHT", 12, 0)
    page.status:SetJustifyH("LEFT")

    -- The character list: all, the current character first, then the others.
    -- The server and character lists of the realm filter. A saved choice with no records falls back to the defaults.
    local function refreshRealmLists()
        local current = store()
        local byRealm, realms = {}, {}
        local function addRealm(realm)
            if not byRealm[realm] then
                byRealm[realm] = {}
                realms[#realms + 1] = realm
            end
            return byRealm[realm]
        end
        if currentRealm then
            addRealm(currentRealm)
        end
        for _, name in ipairs(current and current:Characters() or {}) do
            local list = addRealm(LedgerPage.RealmOf(name))
            list[#list + 1] = name
        end
        table.sort(realms, function(a, b)
            if (a == currentRealm) ~= (b == currentRealm) then
                return a == currentRealm
            end
            if (a == UNKNOWN_REALM) ~= (b == UNKNOWN_REALM) then
                return b == UNKNOWN_REALM
            end
            return a < b
        end)
        if not byRealm[page.filter.realm] then
            page.filter.realm = currentRealm or realms[1] or UNKNOWN_REALM
            page.filter.char = ALL
        end
        local realmItems = {}
        for _, realm in ipairs(realms) do
            local text = realm
            if realm == UNKNOWN_REALM then
                text = "Unknown"
            elseif realm == currentRealm and type(_G.GetRealmName) == "function" then
                text = _G.GetRealmName() or realm
            end
            realmItems[#realmItems + 1] = { value = realm, text = text }
        end
        local list = byRealm[page.filter.realm] or {}
        local charItems = { { value = ALL, text = "All" } }
        local found = page.filter.char == ALL
        for _, name in ipairs(list) do
            found = found or name == page.filter.char
            charItems[#charItems + 1] = { value = name, text = LedgerPage.NameOf(name) }
        end
        if not found then
            page.filter.char = ALL
        end
        page.realmDropdown:SetItems(realmItems)
        page.realmDropdown:SetValue(page.filter.realm)
        page.charDropdown:SetItems(charItems)
        page.charDropdown:SetValue(page.filter.char)
    end

    local function refreshCharacters()
        if realmFilter then
            refreshRealmLists()
            return
        end
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
    local flavour = ns.Flavour or {}
    page.topTabs = Kit.CreateTopTabs(body, LedgerPage.TABS, {
        template = flavour.topTabTemplate,
        tabPadding = flavour.topTabPadding,
        minTabWidth = flavour.topTabMinWidth,
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
                        row.money[key] = Kit.Money(row, key == "flow" and LedgerPage.FlowText or money)
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
                        if value == nil and tab == "overview" then
                            cell:SetText("")
                        end
                    elseif cell then
                        cell:SetText(Kit.ColumnText(column, data))
                    end
                end
                row.data = data
                if not row.ledgerHooked then
                    row.ledgerHooked = true
                    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                    row:SetScript("OnClick", function(self, button)
                        if button == "RightButton" and self.data then
                            page.OpenRowMenu(self, self.data)
                        end
                    end)
                    row:HookScript("OnEnter", function(self)
                        local title, lines = LedgerPage.TooltipLines(self.data and self.data.record)
                        if title then
                            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                            GameTooltip:SetText(title)
                            for _, line in ipairs(lines) do
                                GameTooltip:AddLine(line, 1, 1, 1, true)
                            end
                            GameTooltip:Show()
                        end
                    end)
                    row:HookScript("OnLeave", function()
                        GameTooltip:Hide()
                    end)
                end
            end,
        })
        -- The rows sit inside the list, so only the header takes the list insets.
        local edge = view.list.contentInsets
        view.headerOptions = { gap = view.options.gap, left = edge.left, right = edge.right }
        view.header = Kit.CreateColumnHeader(panel, view.columns, view.headerOptions)
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
        Kit.LayoutColumnLabels(view.header.labels, view.header.frame, view.columns, view.headerOptions)
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
        if page.filter.realm ~= nil then
            local kept = {}
            for _, name in ipairs(names) do
                if inRealm(page.filter, name) then
                    kept[#kept + 1] = name
                end
            end
            names = kept
        end
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
            page.filter.char, page.filter.realm or "-", page.filter.range, current:Revision(),
            buffer and buffer:Count() or 0, copper or "-", math.floor(at / 60),
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
        local rows = LedgerPage.Rows(current, tab, page.filter, at)
        view.rows = rows
        view.list:SetData(rows)
        view.empty:SetShown(#rows == 0)
        local totals = LedgerPage.Totals(rows)
        view.totals.moneyIn:SetCopper(totals.moneyIn)
        view.totals.moneyOut:SetCopper(totals.moneyOut)
        view.totals.net:SetCopper(totals.net)
        if totals.net > 0 then
            view.totals.net:SetTextColor(0.25, 1, 0.25)
        elseif totals.net < 0 then
            view.totals.net:SetTextColor(1, 0.25, 0.25)
        else
            view.totals.net:SetTextColor(1, 1, 1)
        end
        view.totals.count:SetText(totals.count .. (totals.count == 1 and " row" or " rows"))
        page.DrawGraph()
        showStatus("")
    end

    -- Edit (SPEC 5.8). Only a full record in the loaded store can be edited; a daily sum cannot.

    local function logEdit(text)
        if ns.Log then
            ns.Log.Write("ledger", "info", text)
        end
    end

    -- Returns the store, the record id and the record of a row, or nil if the row cannot be edited.
    local function editTarget(data)
        local current = store()
        if not (current and data and data.record) or current:IsReadOnly() then
            return nil
        end
        local id = current:IdOf(data.char, data.record)
        if not id then
            return nil
        end
        return current, id, data.record
    end

    -- Saves the changes of one row. Returns nil, or a message for the edit window.
    function page.SaveEdit(data, changes)
        local current, id, record = editTarget(data)
        if not current then
            return "The ledger is not available."
        end
        local names = {}
        for name, value in pairs(changes) do
            if value ~= record[name] then
                names[#names + 1] = name
            end
        end
        table.sort(names)
        local ok, message = current:UpdateRecord(data.char, id, changes)
        if not ok then
            return message
        end
        if #names > 0 then
            logEdit("edit " .. data.char .. " " .. id .. ": " .. table.concat(names, ", "))
        end
        page.Draw()
        return nil
    end

    function page.RevertRow(data)
        local current, id = editTarget(data)
        if not current then
            return false
        end
        local ok = current:RevertRecord(data.char, id)
        if ok then
            logEdit("revert " .. data.char .. " " .. id)
            page.Draw()
        end
        return ok
    end

    function page.EditRow(data)
        local _, _, record = editTarget(data)
        if not (record and ns.LedgerEdit) then
            return nil
        end
        return ns.LedgerEdit.Open({
            record = record,
            sourceLabel = LedgerPage.SourceLabel,
            itemIndex = deps.itemNameIndex,
            onSave = function(changes)
                return page.SaveEdit(data, changes)
            end,
        })
    end

    -- The entries of the row menu: Edit, and Revert for an edited record. Empty for a row that cannot be edited.
    function page.RowMenuEntries(data)
        if not (data and data.record and store() and not store():IsReadOnly()) then
            return {}
        end
        local entries = { { text = "Edit...", onClick = function()
            page.EditRow(data)
        end } }
        if data.record.edited then
            entries[#entries + 1] = { text = "Revert", onClick = function()
                page.RevertRow(data)
            end }
        end
        return entries
    end

    function page.OpenRowMenu(row, data)
        local entries = page.RowMenuEntries(data)
        if #entries > 0 then
            page.menu = Kit.ContextMenu(row, entries, { title = "Ledger entry" })
        end
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
