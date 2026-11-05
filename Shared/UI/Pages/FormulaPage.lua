local _, ns = ...

-- The formula preview page of the Flipside window.

local FormulaPage = {}
ns.FormulaPage = FormulaPage

local MAX_CHOICES = 8
local HELP ="Money: 10g 5s 2c. Functions: min max avg first check ifgt iflt ifeq round. "
    .. "Missing prices are invalid, never 0."

local function trim(text)
    return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

-- About 10 characters of the formula around the error position.
local function nearText(formula, pos)
    local first = math.max(1, pos - 5)
    local last = math.min(#formula, first + 9)
    return (first > 1 and "..." or "") .. formula:sub(first, last) .. (last < #formula and "..." or "")
end

local function listText(names)
    return table.concat(names or {}, ", ")
end

-- Build the status lines. info.kind is "ok", "invalid", "error" or "compiled".
-- err is a compile error { message, pos }. formula (optional) gives the nearby text of an error.
function FormulaPage.Describe(copper, info, err, formula)
    info = info or {}
    err = err or (info.kind == "error" and info) or nil
    local lines = {}
    if err then
        if err.pos then
            lines[#lines + 1] = string.format("error at %d: %s", err.pos, tostring(err.message))
            if formula and formula ~= "" then
                lines[#lines + 1] = string.format('near "%s"', nearText(formula, err.pos))
            end
        else
            lines[#lines + 1] = tostring(err.message)
        end
    elseif info.kind == "compiled" then
        local names = info.names or {}
        lines[#lines + 1] = "formula ok (sources: " .. (#names > 0 and listText(names) or "none") .. ")"
    elseif info.kind == "ok" and copper ~= nil then
        lines[#lines + 1] = "valid"
    else
        local missing = info.missing or {}
        lines[#lines + 1] = #missing > 0 and ("invalid: missing " .. listText(missing)) or "invalid"
    end
    if not err and info.later and #info.later > 0 then
        lines[#lines + 1] = "not available yet: " .. listText(info.later)
    end
    return lines
end

local function isItem(text)
    return text:match("^%d+$") or (text:match("^|[cH]") and text:find("|Hitem:", 1, true))
end

local function appendName(input, name)
    local text = input:GetText() or ""
    if text ~= "" and text:sub(-1):match("[%w_]") then
        text = text .. " "
    end
    input:SetText(text .. name)
end

local function statusLabel(status)
    if status == "custom" then
        return "custom"
    end
    return status == "later" and "not available yet" or "available"
end

local DELETE_DIALOG = "FLIPSIDE_DELETE_CUSTOM_SOURCE"
local CUSTOM_HEIGHT = 190
local CUSTOM_WINDOW = "FlipsideCustomSourceWindow"
local CUSTOM_BUTTON_ROW = 48 -- space below the list for the buttons and the message

local function firstSentence(text)
    return text:match("^.-%.") or text
end

local function sortedNames(map)
    local names = {}
    for name in pairs(map) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

-- Rows of the reference list: a header row, then one row for each entry of the section.
function FormulaPage.ReferenceRows(sources, custom)
    local rows = {}
    local functions = ns.FormulaFunctions and ns.FormulaFunctions.DOCS or {}
    local docs = ns.FormulaSources and ns.FormulaSources.DOCS or {}

    rows[#rows + 1] = { header = "Functions" }
    for _, name in ipairs(sortedNames(functions)) do
        local doc = functions[name]
        rows[#rows + 1] = {
            name = name, insert = name .. "(", short = firstSentence(doc.text),
            title = doc.usage, text = doc.text, example = doc.example,
        }
    end

    rows[#rows + 1] = { header = "Sources" }
    local entries = {}
    for _, entry in ipairs(sources and sources:List() or {}) do
        local doc = docs[entry.name]
        entries[#entries + 1] = {
            name = entry.name, insert = entry.name, status = entry.status,
            text = doc and doc.text or "",
        }
    end
    for _, entry in ipairs(custom and custom:List() or {}) do
        entries[#entries + 1] = {
            name = entry.name, insert = entry.name, status = "custom",
            text = entry.text, custom = true,
        }
    end
    table.sort(entries, function(a, b)
        return a.name < b.name
    end)
    for _, entry in ipairs(entries) do
        entry.title = entry.name
        entry.short = entry.custom and entry.text or firstSentence(entry.text)
        rows[#rows + 1] = entry
    end

    rows[#rows + 1] = { header = "Syntax" }
    for _, name in ipairs({ "invalid", "10g 5s 2c", "150%" }) do
        local doc = docs[name]
        local text = doc and doc.text or ""
        rows[#rows + 1] = {
            name = name, insert = name:match("^%S+"), title = name, text = text, short = firstSentence(text),
        }
    end
    return rows
end

-- Build the custom sources section: a list, and the Add, Edit and Delete buttons.
-- Add and Edit open one popup window with a name box and a formula box.
function FormulaPage.BuildCustom(page, frame, deps)
    local Kit, custom, run = ns.Kit, deps.customSources, deps.formulaRun
    local gap, pad = Kit.Theme.gap, Kit.Theme.padding
    local selected

    local title = Kit.Label(frame, "Save as custom source", "highlight")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    local helpLine = Kit.Label(
        frame, "Give the formula a name, for example mymin. Then use mymin in any formula or operation.", "small"
    )
    helpLine:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    local message = Kit.Label(frame, "", "bad")
    message:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    message:SetWidth(760)
    message:SetJustifyH("LEFT")
    page.customMessage = message

    -- The popup window.
    local edge = pad + 8
    local dialog = Kit.CreateWindow(CUSTOM_WINDOW, { width = 520, height = 220, title = "Custom source" })
    dialog:SetFrameStrata("DIALOG")
    dialog:SetToplevel(true)
    page.customDialog = dialog
    local save

    local nameLabel = Kit.Label(dialog, "Name", "highlight")
    nameLabel:SetPoint("TOPLEFT", dialog, "TOPLEFT", edge, -36)
    dialog.nameInput = Kit.Input(dialog, 200, function()
        save()
    end)
    dialog.nameInput:SetPoint("TOPLEFT", dialog, "TOPLEFT", edge, -52)
    local textLabel = Kit.Label(dialog, "Formula", "highlight")
    textLabel:SetPoint("TOPLEFT", dialog, "TOPLEFT", edge, -84)
    dialog.textInput = Kit.Input(dialog, 520 - 2 * edge - 8, function()
        save()
    end)
    dialog.textInput:SetPoint("TOPLEFT", dialog, "TOPLEFT", edge, -100)
    dialog.error = Kit.Label(dialog, "", "bad")
    dialog.error:SetPoint("TOPLEFT", dialog, "TOPLEFT", edge, -132)
    dialog.error:SetWidth(520 - 2 * edge)
    dialog.error:SetJustifyH("LEFT")

    local function compile(text)
        return run:Compile(text)
    end
    function save()
        local name, text = trim(dialog.nameInput:GetText()), trim(dialog.textInput:GetText())
        local ok, err = custom:Set(name, text, run and compile or nil)
        if ok then
            selected = name:lower()
            message:SetText("")
            dialog:Hide()
        else
            dialog.error:SetText(tostring(err))
        end
    end
    dialog.saveButton = Kit.Button(dialog, SAVE, 100, save)
    dialog.saveButton:SetPoint("BOTTOM", dialog, "BOTTOM", -55, pad + 4)
    dialog.cancelButton = Kit.Button(dialog, CANCEL, 100, function()
        dialog:Hide()
    end)
    dialog.cancelButton:SetPoint("BOTTOM", dialog, "BOTTOM", 55, pad + 4)

    -- Show the popup. name is nil for a new source. A saved source keeps its name; only the formula changes.
    local function openDialog(name, text)
        dialog.nameInput:SetText(name or "")
        dialog.nameInput:SetEnabled(name == nil)
        dialog.textInput:SetText(text or "")
        dialog.error:SetText("")
        dialog:Show()
        dialog:Raise()
        local box = name == nil and dialog.nameInput or dialog.textInput
        if box.SetFocus then
            box:SetFocus()
        end
    end

    local function findSelected()
        for _, entry in ipairs(custom:List()) do
            if entry.name:lower() == tostring(selected):lower() then
                return entry
            end
        end
    end

    local function edit(entry)
        selected = entry.name
        message:SetText("")
        openDialog(entry.name, entry.text)
    end

    page.customList = Kit.CreateList(frame, {
        inset = true,
        initRow = function(row, data)
            if not row.nameText then
                row.nameText = Kit.Label(row, "", "normal")
                row.nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
            end
            row.nameText:SetText(data.name .. " = " .. data.text)
            row:SetScript("OnClick", function()
                selected = data.name
                message:SetText("")
            end)
            row:SetScript("OnDoubleClick", function()
                edit(data)
            end)
        end,
    })
    page.customList.frame:SetPoint("TOPLEFT", helpLine, "BOTTOMLEFT", 0, -gap)
    page.customList.frame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, CUSTOM_BUTTON_ROW)

    page.customAdd = Kit.Button(frame, "Add", 70, function()
        message:SetText("")
        openDialog(nil, "")
    end)
    page.customAdd:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 18)
    page.customEdit = Kit.Button(frame, "Edit", 70, function()
        local entry = selected and findSelected()
        if not entry then
            message:SetText("Select a custom source first.")
            return
        end
        edit(entry)
    end)
    page.customEdit:SetPoint("LEFT", page.customAdd, "RIGHT", gap, 0)
    page.customDelete = Kit.Button(frame, "Delete", 70, function()
        local name = selected
        if not name then
            message:SetText("Select a custom source first.")
            return
        end
        Kit.Confirm(DELETE_DIALOG, 'Delete the custom source "' .. name .. '"?', function()
            local ok, err = custom:Delete(name)
            if ok then
                selected = nil
                message:SetText("")
            else
                message:SetText(tostring(err))
            end
        end)
    end)
    page.customDelete:SetPoint("LEFT", page.customEdit, "RIGHT", gap, 0)
    page.customFrom = Kit.Button(frame, "Save current formula as...", 170, function()
        message:SetText("")
        openDialog(nil, trim(page.formulaInput:GetText()))
    end)
    page.customFrom:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    page.customList:SetData(custom:List())
end
-- Build the page in the content frame. deps: formulaRun, formulaSources, itemCache, itemNameIndex (optional),
-- customSources and subscribe (optional).
-- Shift-click on an item link fills the item box while it has focus (ChatEdit_InsertLink hook).
function FormulaPage.Build(content, deps)
    local Kit = ns.Kit
    local run, sources, index = deps.formulaRun, deps.formulaSources, deps.itemNameIndex
    local custom = deps.customSources
    local page = {}

    local formulaLabel = Kit.Label(content, "Formula", "highlight")
    formulaLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    local itemLabel = Kit.Label(content, index and "Item (name, link or id)" or "Item (link or id)", "highlight")
    local money = Kit.Money(content, ns.TooltipLines and ns.TooltipLines.FormatMoney)
    local status = Kit.Label(content, "", "normal")
    local check

    local choices = {}
    page.choices = choices

    local function hideChoices()
        for _, button in ipairs(choices) do
            button:Hide()
        end
        if page.list then
            page.list.frame:Show()
            page.customFrame:SetShown(custom ~= nil)
        end
    end

    local function evaluate(formula, input)
        local copper, info = run:Evaluate(formula, input)
        money:SetCopper(copper)
        status:SetText(table.concat(FormulaPage.Describe(copper, info, nil, formula), "\n"))
    end

    local function showChoices(formula, matches, pending)
        local text = #matches .. " items match, pick one"
        if pending > 0 then
            text = text .. "\n" .. pending .. " item names are still loading"
        end
        status:SetText(text)
        page.list.frame:Hide()
        page.customFrame:Hide()
        for position, button in ipairs(choices) do
            local match = matches[position]
            if match then
                button:SetText(ns.ItemNameIndex.Describe(match))
                button:SetScript("OnClick", function()
                    hideChoices()
                    evaluate(formula, ns.ItemNameIndex.ToInput(match.key))
                end)
                button:Show()
            else
                button:Hide()
            end
        end
    end

    local function evaluateName(formula, item)
        local result = index:Resolve(item)
        if result.kind == "error" then
            status:SetText(result.message)
            return
        end
        if result.kind == "item" then
            evaluate(formula, item)
            return
        end
        local matches, pending = result.matches, result.pendingCount
        if #matches > 1 then
            showChoices(formula, matches, pending)
            return
        end
        if #matches == 0 then
            status:SetText('no item named "' .. item .. '" in the scan data')
        else
            evaluate(formula, ns.ItemNameIndex.ToInput(matches[1].key))
        end
        if pending > 0 then
            status:SetText(status:GetText() .. "\n" .. pending .. " item names are still loading")
        end
    end

    local function runCheck()
        local formula = trim(page.formulaInput:GetText())
        local item = trim(page.itemInput:GetText())
        money:SetCopper(nil)
        hideChoices()
        if not run then
            status:SetText("formulas are not available this session")
        elseif formula == "" then
            status:SetText("enter a formula")
        elseif item == "" then
            local compiled, err = run:Compile(formula)
            local info = compiled and { kind = "compiled", names = compiled.names, later = compiled.later }
            status:SetText(table.concat(FormulaPage.Describe(nil, info, err, formula), "\n"))
        elseif isItem(item) then
            evaluate(formula, item)
        elseif index then
            evaluateName(formula, item)
        else
            status:SetText("not an item: " .. item)
        end
    end
    page.Check = runCheck

    local gap = Kit.Theme.gap
    page.formulaInput = Kit.Input(content, 740, runCheck)
    page.formulaInput:SetPoint("TOPLEFT", formulaLabel, "BOTTOMLEFT", 6, -gap)
    itemLabel:SetPoint("TOPLEFT", page.formulaInput, "BOTTOMLEFT", -6, -gap * 2)
    page.itemInput = Kit.Input(content, 260, runCheck)
    page.itemInput:SetPoint("TOPLEFT", itemLabel, "BOTTOMLEFT", 6, -gap)
    check = Kit.Button(content, "Check", 80, runCheck)
    check:SetPoint("LEFT", page.itemInput, "RIGHT", gap * 2, 0)
    page.checkButton = check
    money:SetPoint("LEFT", check, "RIGHT", gap * 2, 0)
    status:SetPoint("TOPLEFT", page.itemInput, "BOTTOMLEFT", -6, -gap * 2)
    status:SetWidth(740)
    status:SetJustifyH("LEFT")
    page.money, page.status = money, status
    for position = 1, MAX_CHOICES do
        local button = Kit.Button(content, "", 360, nil)
        button:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -gap * 3 - (position - 1) * 24)
        button:Hide()
        choices[position] = button
    end

    local help = Kit.Label(content, HELP, "small")
    help:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    help:SetWidth(760)
    help:SetJustifyH("LEFT")
    page.help = help

    local list = Kit.CreateList(content, {
        inset = true,
        initRow = function(row, data)
            if not row.nameText then
                row.nameText = Kit.Label(row, "", "normal")
                row.nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
                row.statusText = Kit.Label(row, "", "small")
                row.statusText:SetPoint("LEFT", row, "LEFT", 120, 0)
                row.descText = Kit.Label(row, "", "small")
                row.descText:SetPoint("LEFT", row, "LEFT", 240, 0)
                row.descText:SetWidth(480)
                row.descText:SetJustifyH("LEFT")
            end
            if data.header then
                row.nameText:SetText(data.header)
                row.statusText:SetText("")
                row.descText:SetText("")
                row:SetScript("OnClick", nil)
                row:SetScript("OnEnter", nil)
                row:SetScript("OnLeave", nil)
                return
            end
            row.nameText:SetText(data.name)
            row.statusText:SetText(data.status and statusLabel(data.status) or "")
            row.descText:SetText(data.short or "")
            row:SetScript("OnClick", function()
                appendName(page.formulaInput, data.insert)
            end)
            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(data.title or data.name)
                if data.text ~= "" then
                    GameTooltip:AddLine(data.text, 1, 1, 1, true)
                end
                if data.example then
                    GameTooltip:AddLine("Example: " .. data.example, 0.7, 0.7, 0.7, true)
                end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
        end,
    })
    list.frame:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -gap * 3)
    page.list = list

    local customFrame = CreateFrame("Frame", nil, content)
    customFrame:SetHeight(CUSTOM_HEIGHT)
    customFrame:SetPoint("BOTTOMLEFT", help, "TOPLEFT", 0, gap)
    customFrame:SetPoint("BOTTOMRIGHT", help, "TOPRIGHT", 0, gap)
    page.customFrame = customFrame
    list.frame:SetPoint("BOTTOMRIGHT", customFrame, "TOPRIGHT", 0, gap)
    if custom then
        FormulaPage.BuildCustom(page, customFrame, deps)
    else
        customFrame:Hide()
    end

    local function refreshSources()
        list:SetData(FormulaPage.ReferenceRows(sources, custom))
    end
    refreshSources()
    if deps.subscribe and custom then
        deps.subscribe(function()
            refreshSources()
            page.customList:SetData(custom:List())
        end)
    end

    local hook, insertLink = _G.hooksecurefunc, _G.ChatEdit_InsertLink
    if hook and insertLink then
        hook("ChatEdit_InsertLink", function(link)
            if type(link) == "string" and page.itemInput:HasFocus() then
                page.itemInput:SetText(link)
            end
        end)
    end
    return page
end
