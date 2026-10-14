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
    return status == "later" and "not available yet" or "available"
end

-- Build the page in the content frame. deps: formulaRun, formulaSources, itemCache, itemNameIndex (optional).
-- Shift-click on an item link fills the item box while it has focus (ChatEdit_InsertLink hook).
function FormulaPage.Build(content, deps)
    local Kit = ns.Kit
    local run, sources, index = deps.formulaRun, deps.formulaSources, deps.itemNameIndex
    local page = {}

    local formulaLabel = Kit.Label(content, "Formula", "highlight")
    formulaLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    local itemLabel = Kit.Label(content, index and "Item (name, link or id)" or "Item (link or id)", "highlight")
    local money = Kit.Money(content)
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
        initRow = function(row, data)
            if not row.nameText then
                row.nameText = Kit.Label(row, "", "normal")
                row.nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
                row.statusText = Kit.Label(row, "", "small")
                row.statusText:SetPoint("LEFT", row, "LEFT", 200, 0)
            end
            row.nameText:SetText(data.name)
            row.statusText:SetText(statusLabel(data.status))
            row:SetScript("OnClick", function()
                appendName(page.formulaInput, data.name)
            end)
        end,
    })
    list.frame:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -gap * 3)
    list.frame:SetPoint("BOTTOMRIGHT", help, "TOPRIGHT", 0, gap)
    page.list = list
    list:SetData(sources and sources:List() or {})

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
