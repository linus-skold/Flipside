local _, ns = ...

-- The Lists page of the Flipside window: manage the AH buying lists (search lists and craft lists) with no AH open.
-- It reads and writes through ns.SearchLists and prices a craft list with ns.CraftListMargin (SPEC 5.3 point 24c).
-- It buys nothing (D26): buying happens in the Buying tab of the Auction House.

local ListsPage = {}
ns.ListsPage = ListsPage

local OWNER = "Flipside.ListsPage"
local EVENT = "Flipside.SearchListsChanged"
local NEW_PROMPT = "FlipsideListsNewPrompt"
local RENAME_PROMPT = "FlipsideListsRenamePrompt"
local DELETE_DIALOG = "FLIPSIDE_DELETE_SEARCH_LIST"
local LEFT_WIDTH = 190
local EDIT_X = LEFT_WIDTH + 8
local EDIT_WIDTH = 270
local MARGIN_X = EDIT_X + EDIT_WIDTH + 8
local ROW = 18
local ITEMS_HEIGHT = 118
local RESULTS_HEIGHT = 84
local MAX_MATCHES = 8
local YIELDS = { "min", "avg", "max" }
local TABLE_ROW = 16
local TABLE_ROWS = 5
local TABLE_HEIGHT = (TABLE_ROWS + 1) * TABLE_ROW
local TABLE_LABEL = 52
local TABLE_COLUMN = 82

local function trim(text)
    return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

local function money(copper)
    return GetMoneyString(math.floor((copper or 0) + 0.5))
end

local function signedMoney(copper)
    return copper < 0 and ("-" .. money(-copper)) or money(copper)
end

local function rangeText(min, max)
    return min == max and tostring(min) or (min .. "-" .. max)
end

-- Read a yield text: "2" (min and max are 2) or "1-2". Returns min and max, or nil and a text.
-- The store checks that max is not below min.
function ListsPage.ParseYield(text)
    text = trim(text)
    local low, high = text:match("^(%d+)%s*%-%s*(%d+)$")
    if not low then
        low = text:match("^(%d+)$")
        high = low
    end
    if not low then
        return nil, "enter an amount such as 2 or 1-2"
    end
    return tonumber(low), tonumber(high)
end

-- Find one item for a name with the name index. Returns an item, or nil and a text.
local function resolveName(text, index)
    local ok, matches = pcall(index.Find, index, text, MAX_MATCHES)
    if not ok or type(matches) ~= "table" or #matches == 0 then
        return nil, "no item named " .. text .. "; type an item link, ID or key"
    end
    local exact = {}
    for _, match in ipairs(matches) do
        if tostring(match.name):lower() == text:lower() then
            exact[#exact + 1] = match
        end
    end
    local pick = #matches == 1 and matches[1] or (#exact == 1 and exact[1]) or nil
    if not pick then
        return nil, #matches .. " items match; type more of the name, or an item link, ID or key"
    end
    return { itemID = pick.itemID, key = pick.key, name = pick.name }
end

-- Read the text of the add box: an item link, an item ID, a Flipside key or (with an item name index) a name.
-- Returns { itemID, key, name }, or nil and a text. deps: keyFor(link) and itemNameIndex (both optional).
function ListsPage.ResolveItem(input, deps)
    local text = trim(input)
    local ItemString = ns.ItemString
    if text == "" then
        return nil, "enter an item link, ID or key"
    end
    if text:match("^%d+$") then
        local itemID = tonumber(text)
        if itemID < 1 then
            return nil, "not an item: " .. text
        end
        return { itemID = itemID, key = string.format("%d", itemID) }
    end
    local parsed = ItemString.ParseKey(text)
    if parsed then
        return { itemID = parsed.itemID, key = text }
    end
    if ItemString.IsItemLink(text) then
        local fields = ItemString.ParseLink(text)
        if not fields then
            return nil, "not an item link"
        end
        local key = deps.keyFor and deps.keyFor(text) or ItemString.ToExactKey(text)
        return { itemID = fields.itemID, key = key or string.format("%d", fields.itemID),
            name = text:match("|h%[(.-)%]|h") }
    end
    if deps.itemNameIndex then
        return resolveName(text, deps.itemNameIndex)
    end
    return nil, "type an item link, ID or key"
end

-- The rows of the margin breakdown for a CraftListMargin result: one row for each material and one for each
-- result. saved is the list (its items and results are in the order of the margin). nameOf(entry) gives a name.
-- Returns { { kind = "head" | "item", left, right } }.
function ListsPage.MarginRows(margin, saved, nameOf)
    local rows = {}
    local function add(kind, left, right)
        rows[#rows + 1] = { kind = kind, left = left, right = right or "" }
    end
    add("head", "Materials for " .. margin.crafts .. (margin.crafts == 1 and " craft" or " crafts"))
    for index, line in ipairs(margin.materials) do
        local right = "no price"
        if line.total then
            right = money(line.total) .. (line.estimate and " (est.)" or "")
        end
        add("item", line.needed .. "× " .. nameOf(saved.items[index]), right)
    end
    if #margin.materials == 0 then
        add("item", "No materials yet")
    end
    local oneOf = margin.resultMode == "oneOf"
    add("head", (oneOf and "One of these results" or "Results") .. " (value after the 5% cut)")
    if #margin.results == 0 then
        add("item", "Add a result to see the margin")
        return rows
    end
    for index, line in ipairs(margin.results) do
        add("item", rangeText(line.min, line.max) .. "× " .. nameOf(saved.results[index]),
            line.net and ("avg " .. money(line.net.avg)) or "no price")
    end
    return rows
end

-- The table under the breakdown: the cost once, then the columns Min, Avg and Max. Returns
-- { cost = text, rows = { { label, cells = { min, avg, max }, tones = { min, avg, max } } } }; rows is empty with no
-- result. A row is the header, "Yield" (mode "oneOf" only: the result that sets the min and the max), "Value",
-- "Profit" (a tone "good" or "bad" for each cell) and the percent of the profit (if the cost is above 0).
function ListsPage.MarginTable(margin, saved, nameOf)
    local cost = margin.costKnown and money(margin.cost) or ("? (" .. money(margin.cost) .. " priced)")
    local out = { cost = cost .. (margin.estimate and " (est.)" or ""), rows = {} }
    if #margin.results == 0 then
        return out
    end
    local function add(label, cells, tones)
        out.rows[#out.rows + 1] = { label = label, cells = cells, tones = tones or {} }
    end
    add("", { "Min", "Avg", "Max" })
    if margin.resultMode == "oneOf" then
        local cells = { "?", "mean", "?" }
        if margin.valueKnown then
            for index, name in ipairs(YIELDS) do
                local pick = name ~= "avg" and margin.results[margin.pick[name]] or nil
                if pick then
                    cells[index] = pick[name] .. "× " .. nameOf(saved.results[margin.pick[name]])
                end
            end
        end
        add("Yield", cells)
    end
    local value, profit, percent, tones = {}, {}, {}, {}
    for index, name in ipairs(YIELDS) do
        value[index] = margin.valueKnown and money(margin.value[name]) or "?"
        profit[index] = margin.margin and signedMoney(margin.margin[name]) or "?"
        if margin.margin then
            tones[index] = margin.margin[name] > 0 and "good" or (margin.margin[name] < 0 and "bad" or nil)
            percent[index] = margin.percent and string.format("(%.0f%%)", margin.percent[name]) or nil
        end
    end
    add("Value", value)
    add("Profit", profit, tones)
    if margin.percent then
        add("", percent, tones)
    end
    return out
end

-- Build the page in the content frame.
-- deps: searchLists, bus (optional), itemCache, itemNameIndex, keyFor(link), getRecord(key) with now() (scan prices)
-- and livePrice(key, needed) (a live AH cost from this session; default ns.BuyingTab.LivePrice), all optional.
-- Returns the page: Refresh(), Select(id), New(name, kind), Rename(name), Delete(), AddItem(text),
-- SetCount(index, text), RemoveItem(index), AddResult(text, amount), SetResult(index, text), RemoveResult(index),
-- SetCrafts(text), SetResultMode(mode) and Margin().
function ListsPage.Build(content, deps)
    local Kit = ns.Kit
    local store = deps.searchLists
    local page = { crafts = 1 }
    local asked = {}
    local craftOnly = {}

    local function place(widget, x, y)
        widget:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
        return widget
    end

    local function craftWidget(widget)
        craftOnly[#craftOnly + 1] = widget
        return widget
    end

    local function say(text)
        page.status:SetText(text or "")
    end

    -- Show the text of a failed store call. Returns true when the call worked.
    local function report(ok, err)
        if ok then
            say("")
            return true
        end
        say(tostring(err or ""))
        return false, err
    end

    local function current()
        return page.selected and store:Get(page.selected) or nil
    end

    local function nameOf(entry)
        local cache = deps.itemCache
        local info = cache and cache.Get and cache:Get(entry.itemID)
        local name = info and info.name or entry.name
        if not name and cache and cache.Request and not asked[entry.itemID] then
            asked[entry.itemID] = true
            cache:Request(entry.itemID, function(_, loaded)
                if loaded then
                    page.Refresh()
                end
            end)
        end
        name = name or ("item " .. entry.itemID)
        if entry.key and entry.key ~= string.format("%d", entry.itemID) then
            name = name .. " (" .. entry.key .. ")"
        end
        return name
    end

    local function scanValues(key)
        local record = deps.getRecord and key and deps.getRecord(key)
        local now = deps.now and deps.now() or nil
        if type(record) ~= "table" or not ns.ScanSources or type(now) ~= "number" then
            return nil
        end
        return ns.ScanSources.Compute(record, now)
    end

    -- A material costs the live price of this session if the Buying tab has it, else ScanMarket x units (an estimate).
    local function materialPrice(material, needed)
        local live = deps.livePrice or (ns.BuyingTab and ns.BuyingTab.LivePrice)
        local total = live and live(material.key, needed)
        if total then
            return total, false
        end
        return ns.CraftListMargin.ScanMaterialPrice(scanValues(material.key), needed)
    end

    local function resultPrice(result)
        return ns.CraftListMargin.ScanResultPrice(scanValues(result.key))
    end

    -- The margin of the selected craft list, or nil.
    function page.Margin()
        local saved = current()
        if not (saved and saved.kind == "craft") then
            return nil
        end
        return ns.CraftListMargin.Compute({ materials = saved.items, results = saved.results,
            resultMode = saved.resultMode }, {
            crafts = page.crafts, materialPrice = materialPrice, resultPrice = resultPrice,
        }), saved
    end

    -- Rows.

    local function initRow(row, data, selected, onClick)
        if not row.text then
            row.tag = Kit.Label(row, "", "disabled")
            row.tag:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row.text = Kit.Label(row, "", "small")
            row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            row.text:SetPoint("RIGHT", row.tag, "LEFT", -4, 0)
            row.text:SetJustifyH("LEFT")
            row.selection = Kit.SelectionTexture(row, nil)
        end
        row.text:SetText(data.text)
        row.tag:SetText(data.tag or "")
        row.selection:SetShown(selected)
        row:SetScript("OnClick", onClick)
    end

    page.listsLabel = place(Kit.Label(content, "Lists", "highlight"), 0, 0)
    page.lists = Kit.CreateList(content, { rowHeight = ROW, inset = true,
        initRow = function(row, data)
            initRow(row, data, page.selected == data.id, function()
                page.Select(data.id)
            end)
        end })
    page.lists.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -18)
    page.lists.frame:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 30)
    page.lists.frame:SetWidth(LEFT_WIDTH)

    page.title = place(Kit.Label(content, "", "highlight"), EDIT_X, 0)
    page.addInput = place(Kit.Input(content, EDIT_WIDTH - 8, function(text)
        page.AddItem(text)
    end, nil, { placeholder = "Item link, ID, key or name" }), EDIT_X + 6, 18)
    page.addItem = place(Kit.Button(content, "Add item", 70, function()
        page.AddItem(page.addInput:GetText())
    end), EDIT_X, 44)
    page.addResult = craftWidget(place(Kit.Button(content, "Add result", 80, function()
        page.AddResult(page.addInput:GetText(), page.amountInput:GetText())
    end), EDIT_X + 74, 44))
    page.amountLabel = craftWidget(place(Kit.Label(content, "Made", "small"), EDIT_X + 160, 49))
    page.amountInput = craftWidget(place(Kit.Input(content, 44, nil, nil), EDIT_X + 192, 46))
    page.amountInput:SetText("1")

    page.itemsLabel = place(Kit.Label(content, "Items", "small"), EDIT_X, 74)
    page.items = Kit.CreateList(content, { rowHeight = ROW, inset = true,
        initRow = function(row, data)
            initRow(row, data, page.itemSel == data.index, function()
                page.itemSel = page.itemSel ~= data.index and data.index or nil
                page.Refresh()
            end)
        end })
    place(page.items.frame, EDIT_X, 90)
    page.items.frame:SetSize(EDIT_WIDTH, ITEMS_HEIGHT)
    place(Kit.Label(content, "Count", "small"), EDIT_X, 216)
    page.countInput = place(Kit.Input(content, 44, function(text)
        page.SetCount(page.itemSel, text)
    end), EDIT_X + 38, 212)
    page.countSet = place(Kit.Button(content, "Set", 40, function()
        page.SetCount(page.itemSel, page.countInput:GetText())
    end), EDIT_X + 88, 212)
    page.itemRemove = place(Kit.Button(content, "Remove", 64, function()
        page.RemoveItem(page.itemSel)
    end), EDIT_X + 132, 212)

    page.resultsLabel = craftWidget(place(Kit.Label(content, "Results (amount made for each craft)", "small"),
        EDIT_X, 246))
    page.results = Kit.CreateList(content, { rowHeight = ROW, inset = true,
        initRow = function(row, data)
            initRow(row, data, page.resultSel == data.index, function()
                page.resultSel = page.resultSel ~= data.index and data.index or nil
                page.Refresh()
            end)
        end })
    place(page.results.frame, EDIT_X, 262)
    page.results.frame:SetSize(EDIT_WIDTH, RESULTS_HEIGHT)
    craftWidget(page.results.frame)
    page.resultLabel = craftWidget(place(Kit.Label(content, "Min-max", "small"), EDIT_X, 352))
    page.resultInput = craftWidget(place(Kit.Input(content, 56, function(text)
        page.SetResult(page.resultSel, text)
    end), EDIT_X + 50, 348))
    page.resultSet = craftWidget(place(Kit.Button(content, "Set", 40, function()
        page.SetResult(page.resultSel, page.resultInput:GetText())
    end), EDIT_X + 112, 348))
    page.resultRemove = craftWidget(place(Kit.Button(content, "Remove", 64, function()
        page.RemoveResult(page.resultSel)
    end), EDIT_X + 156, 348))

    page.oneOfCheck = craftWidget(place(Kit.Check(content, "Only one result drops", function(checked)
        page.SetResultMode(checked and "oneOf" or "all")
    end), EDIT_X - 4, 372))
    Kit.Tooltip(page.oneOfCheck, "Only one result drops", {
        "Use this if a craft gives exactly one of the results, not all of them.",
        "The min value is the lowest value that one result gives at its min amount.",
        "The max value is the highest value that one result gives at its max amount.",
        "The avg value is the mean of the avg values of the results.",
    })

    page.status = Kit.Label(content, "", "small")
    page.status:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", EDIT_X, 4)
    page.status:SetWidth(EDIT_WIDTH)
    page.status:SetJustifyH("LEFT")

    -- The margin breakdown of a craft list, on the right.
    craftWidget(place(Kit.Label(content, "Margin", "highlight"), MARGIN_X, 0))
    craftWidget(place(Kit.Label(content, "Crafts", "small"), MARGIN_X, 24))
    local function setCrafts(text)
        page.SetCrafts(text)
    end
    page.craftsInput = craftWidget(place(Kit.Input(content, 40, setCrafts, setCrafts), MARGIN_X + 40, 20))
    page.margin = Kit.CreateList(content, { rowHeight = ROW, inset = true,
        initRow = function(row, data)
            if not row.left then
                row.right = Kit.Label(row, "", "small")
                row.right:SetPoint("RIGHT", row, "RIGHT", -4, 0)
                row.left = Kit.Label(row, "", "small")
                row.left:SetPoint("LEFT", row, "LEFT", 4, 0)
                row.left:SetJustifyH("LEFT")
            end
            row.left:SetText(data.left)
            row.right:SetText(data.right)
        end })
    page.margin.frame:SetPoint("TOPLEFT", content, "TOPLEFT", MARGIN_X, -44)
    page.margin.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 26 + TABLE_HEIGHT + 4)
    craftWidget(page.margin.frame)

    -- The table: the cost once, then the rows Min/Avg/Max (header), Yield, Value, Profit and the percent. The slots
    -- are in this order from the top. A row that the list does not need is hidden. Each cell has a fixed width.
    local function slotCell(slot, x, width, justify)
        local cell = craftWidget(Kit.Label(content, "", "small"))
        cell:SetWidth(width)
        cell:SetJustifyH(justify)
        if cell.SetWordWrap then
            cell:SetWordWrap(false)
        end
        cell:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", MARGIN_X + x, 26 + (TABLE_ROWS - slot) * TABLE_ROW)
        return cell
    end
    page.tableCost = { label = slotCell(0, 0, TABLE_LABEL, "LEFT"), text = slotCell(0, TABLE_LABEL, 240, "LEFT") }
    page.tableCost.label:SetText("Cost")
    page.tableRows = {}
    for slot = 1, TABLE_ROWS do
        local row = { label = slotCell(slot, 0, TABLE_LABEL, "LEFT") }
        for column = 1, 3 do
            row[column] = slotCell(slot, TABLE_LABEL + (column - 1) * TABLE_COLUMN, TABLE_COLUMN, "RIGHT")
        end
        page.tableRows[slot] = row
    end
    page.marginNote = Kit.Label(content,
        "(est.) = scan market value. No live search of this session.", "small")
    page.marginNote:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", MARGIN_X, 6)

    -- Actions. Each one changes the store; the change event (or the Refresh at the end) draws the page again.

    function page.Select(id)
        if not (id and store:Get(id)) then
            return false
        end
        page.selected, page.itemSel, page.resultSel = id, nil, nil
        say("")
        page.Refresh()
        return true
    end

    -- Set how the results of the selected craft list drop: "all" or "oneOf". Returns true, or false and a text.
    function page.SetResultMode(mode)
        local saved = current()
        if not saved then
            return report(false, "pick a list first")
        end
        local ok, err = store:SetResultMode(saved.id, mode)
        page.Refresh()
        return report(ok, err)
    end

    -- Make a list. kind is "craft" for a craft list, else a search list. Returns true, or false and a text.
    function page.New(name, kind)
        local id, err = store:Create(name, {}, kind)
        if not id then
            say(tostring(err))
            return false, err
        end
        page.Select(id)
        return true
    end

    -- Rename a list: the list with this id, or the selected list.
    function page.Rename(name, id)
        id = id or page.selected
        if not id then
            return report(nil, "pick a list first")
        end
        local ok, err = report(store:Rename(id, name))
        page.Refresh()
        return ok, err
    end

    -- Delete a list: the list with this id, or the selected list.
    function page.Delete(id)
        id = id or page.selected
        if not id then
            return report(nil, "pick a list first")
        end
        local ok, err = report(store:Delete(id))
        if ok and id == page.selected then
            page.selected, page.itemSel, page.resultSel = nil, nil, nil
        end
        page.Refresh()
        return ok, err
    end

    function page.PromptNew()
        Kit.Prompt(NEW_PROMPT):Open({
            title = "New list",
            choiceLabel = "Kind",
            choices = { { value = "search", text = "Search list" }, { value = "craft", text = "Craft list" } },
            label = "Name",
            onOK = function(name, kind)
                local ok, err = page.New(name, kind)
                return not ok and err or nil
            end,
        })
    end

    function page.PromptRename()
        local saved = current()
        if not saved then
            say("pick a list first")
            return
        end
        Kit.Prompt(RENAME_PROMPT):Open({
            title = "Rename list",
            label = "New name",
            text = saved.name,
            onOK = function(name)
                local ok, err = page.Rename(name, saved.id)
                return not ok and err or nil
            end,
        })
    end

    function page.ConfirmDelete()
        local saved = current()
        if not saved then
            say("pick a list first")
            return
        end
        Kit.Confirm(DELETE_DIALOG, "Delete the list " .. saved.name .. "?", function()
            page.Delete(saved.id)
        end)
    end

    -- Add an item (a link, an ID, a key or a name) to the items of the selected list.
    function page.AddItem(text)
        if not page.selected then
            return report(nil, "pick a list first")
        end
        local item, err = ListsPage.ResolveItem(text, deps)
        if not item then
            return report(nil, err)
        end
        local ok, storeErr = report(store:AddItem(page.selected, item))
        if ok then
            page.addInput:SetText("")
            page.itemSel = #current().items
            say("added " .. nameOf(item))
        end
        page.Refresh()
        return ok, storeErr
    end

    -- Set the count of the item at a place. An empty text clears the count.
    function page.SetCount(index, text)
        if not (page.selected and index) then
            return report(nil, "pick an item first")
        end
        text = trim(text)
        local count = text ~= "" and tonumber(text) or nil
        if text ~= "" and not (count and count >= 1 and count % 1 == 0) then
            return report(nil, "the count must be a whole number above 0")
        end
        local ok, err = report(store:SetCount(page.selected, index, count))
        page.Refresh()
        return ok, err
    end

    function page.RemoveItem(index)
        if not (page.selected and index) then
            return report(nil, "pick an item first")
        end
        local ok, err = report(store:RemoveItem(page.selected, index))
        if ok then
            page.itemSel = nil
        end
        page.Refresh()
        return ok, err
    end

    -- Add a result to the selected craft list. amount is "2" or "1-2" (default 1).
    function page.AddResult(text, amount)
        if not page.selected then
            return report(nil, "pick a list first")
        end
        local item, err = ListsPage.ResolveItem(text, deps)
        if not item then
            return report(nil, err)
        end
        local min, max = ListsPage.ParseYield(trim(amount) ~= "" and amount or "1")
        if not min then
            return report(nil, max)
        end
        item.min, item.max = min, max
        local ok, storeErr = report(store:AddResult(page.selected, item))
        if ok then
            page.addInput:SetText("")
            page.resultSel = #current().results
        end
        page.Refresh()
        return ok, storeErr
    end

    function page.SetResult(index, text)
        if not (page.selected and index) then
            return report(nil, "pick a result first")
        end
        local min, max = ListsPage.ParseYield(text)
        if not min then
            return report(nil, max)
        end
        local ok, err = report(store:SetResult(page.selected, index, min, max))
        page.Refresh()
        return ok, err
    end

    function page.RemoveResult(index)
        if not (page.selected and index) then
            return report(nil, "pick a result first")
        end
        local ok, err = report(store:RemoveResult(page.selected, index))
        if ok then
            page.resultSel = nil
        end
        page.Refresh()
        return ok, err
    end

    -- Set the number of crafts that the margin counts for (a whole number above 0, not saved).
    function page.SetCrafts(text)
        text = trim(text)
        local number = text:match("^%d+$") and tonumber(text) or nil
        if not number or number < 1 then
            say("crafts must be a whole number above 0")
            page.Refresh()
            return false
        end
        page.crafts = number
        page.Refresh()
        return true
    end

    -- Draw the page again from the store.
    function page.Refresh()
        local all = store:List()
        if page.selected and not store:Get(page.selected) then
            page.selected, page.itemSel, page.resultSel = nil, nil, nil
        end
        if not page.selected and all[1] then
            page.selected = all[1].id
        end
        local data = {}
        for index, entry in ipairs(all) do
            data[index] = { id = entry.id, kind = entry.kind, text = entry.name .. " (" .. entry.count .. ")",
                tag = entry.kind == "craft" and "craft" or "search" }
        end
        page.lists:SetData(data)
        local saved = current()
        local craft = saved ~= nil and saved.kind == "craft"
        for _, widget in ipairs(craftOnly) do
            widget:SetShown(craft)
        end
        page.title:SetText(saved and (saved.name .. (craft and " (craft list)" or " (search list)"))
            or "Pick a list, or click New.")
        page.itemsLabel:SetText(craft and "Materials (count for one craft)" or "Items (count to buy)")
        local enabled = saved ~= nil
        page.rename:SetEnabled(enabled)
        page.delete:SetEnabled(enabled)
        page.addInput:SetEnabled(enabled)
        page.addItem:SetEnabled(enabled)
        page.addResult:SetEnabled(enabled and craft)
        local oneOf = craft and saved.resultMode == "oneOf"
        page.oneOfCheck:SetChecked(oneOf)
        page.resultsLabel:SetText(oneOf and "One of these results" or "Results (amount made for each craft)")
        local items, results = {}, {}
        for index, item in ipairs(saved and saved.items or {}) do
            items[index] = { index = index, text = (item.count and (item.count .. "× ") or "") .. nameOf(item) }
        end
        for index, result in ipairs(saved and saved.results or {}) do
            results[index] = { index = index, text = rangeText(result.min, result.max) .. "× " .. nameOf(result) }
        end
        if page.itemSel and not items[page.itemSel] then
            page.itemSel = nil
        end
        if page.resultSel and not results[page.resultSel] then
            page.resultSel = nil
        end
        page.items:SetData(items)
        page.results:SetData(results)
        local item = page.itemSel and saved.items[page.itemSel] or nil
        local result = page.resultSel and saved.results[page.resultSel] or nil
        page.countSet:SetEnabled(item ~= nil)
        page.itemRemove:SetEnabled(item ~= nil)
        page.resultSet:SetEnabled(result ~= nil)
        page.resultRemove:SetEnabled(result ~= nil)
        if item and not page.countInput:HasFocus() then
            page.countInput:SetText(item.count and tostring(item.count) or "")
        end
        if result and not page.resultInput:HasFocus() then
            page.resultInput:SetText(rangeText(result.min, result.max))
        end
        local margin = page.Margin()
        page.marginNote:SetShown(margin ~= nil and margin.estimate == true)
        page.margin:SetData(margin and ListsPage.MarginRows(margin, saved, nameOf) or {})
        local grid = margin and ListsPage.MarginTable(margin, saved, nameOf) or { cost = "", rows = {} }
        page.tableCost.text:SetText(grid.cost)
        for slot, row in ipairs(page.tableRows) do
            local data = grid.rows[slot]
            row.label:SetText(data and data.label or "")
            for column = 1, 3 do
                local cell = row[column]
                cell:SetText(data and data.cells[column] or "")
                cell:SetFontObject(Kit.Font(data and data.tones[column] or "small"))
            end
        end
        if margin and not page.craftsInput:HasFocus() then
            page.craftsInput:SetText(tostring(page.crafts))
        end
    end

    page.new = Kit.Button(content, "New", 60, function()
        page.PromptNew()
    end)
    page.new:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 4)
    page.rename = Kit.Button(content, "Rename", 64, function()
        page.PromptRename()
    end)
    page.rename:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 64, 4)
    page.delete = Kit.Button(content, "Delete", 58, function()
        page.ConfirmDelete()
    end)
    page.delete:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 132, 4)

    if deps.bus then
        deps.bus:Subscribe(EVENT, OWNER, function()
            page.Refresh()
        end)
    end

    -- Shift-click on an item link puts the link in the add box while it has focus. WoW: Forever calls
    -- ChatFrameUtil.InsertLink; ChatEdit_InsertLink is the call of TBC and of old callers, so each name gets a hook.
    local function onLink(text)
        if type(text) == "string" and page.addInput:HasFocus() then
            page.addInput:Insert(text)
        end
    end
    if _G.hooksecurefunc then
        local frameUtil = _G.ChatFrameUtil
        if type(frameUtil) == "table" and type(frameUtil.InsertLink) == "function" then
            _G.hooksecurefunc(frameUtil, "InsertLink", onLink)
        end
        if type(_G.ChatEdit_InsertLink) == "function" then
            _G.hooksecurefunc("ChatEdit_InsertLink", onLink)
        end
    end

    page.Refresh()
    return page
end
