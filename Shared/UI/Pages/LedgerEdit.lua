local _, ns = ...

-- The edit window of one ledger record (SPEC 5.8, edit). It reads a record and gives back a table of changes.
-- The page saves the changes through the ledger store.
local LedgerEdit = {}
ns.LedgerEdit = LedgerEdit

local WINDOW_NAME = "FlipsideLedgerEdit"
local WIDTH = 340
local ROW_HEIGHT = 52
local TOP = 36

-- The fields of the form, in order. key is a field of LedgerRecord.EDIT_FIELDS. kind picks the control:
-- "source" (drop-down), "item" (name, link or id), "count" (whole number), "money" and "text".
-- To edit one more field, add its name to LedgerRecord.EDIT_FIELDS and one line here.
LedgerEdit.FIELDS = {
    { key = "source", kind = "source", label = "Source" },
    { key = "item", kind = "item", label = "Item (name, link or id; empty for none)" },
    { key = "qty", kind = "count", label = "Quantity" },
    { key = "money", kind = "money", label = "Amount" },
    { key = "note", kind = "text", label = "Note" },
}

local function trim(text)
    return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

-- Returns the item key for the text of the item box: "" for empty text, a key for a link, an id or a key,
-- or an item name that the name index knows. Else returns nil and a message.
function LedgerEdit.ResolveItem(text, index)
    text = trim(text)
    if text == "" then
        return ""
    end
    local key = ns.ItemString.ToExactKey(text)
    if key then
        return key
    end
    if ns.ItemString.ParseKey(text) then
        return text
    end
    if not index then
        return nil, "Type an item link or an item id."
    end
    local result = index:Resolve(text)
    if result.kind == "error" then
        return nil, "Item: " .. result.message .. "."
    end
    local matches = result.matches or {}
    if #matches == 1 then
        return matches[1].key
    end
    for _, match in ipairs(matches) do
        if tostring(match.name):lower() == text:lower() then
            return match.key
        end
    end
    if #matches == 0 then
        return nil, "No item found for \"" .. text .. "\"."
    end
    return nil, "Several items match \"" .. text .. "\". Type more of the name, or use a link."
end

-- The text that the item box shows for a record.
local function itemTextOf(record)
    if (record.item or "") ~= "" then
        return record.item
    end
    return record.itemName or ""
end

-- Reads the controls. Returns the table of changes, or nil and a message.
local function collect(window, config)
    local record = config.record
    local changes = {}
    for _, field in ipairs(LedgerEdit.FIELDS) do
        local control = window.controls[field.key]
        local value
        if field.kind == "source" then
            value = window.sourceValue
        elseif field.kind == "item" then
            local text = trim(control:GetText())
            if text ~= window.itemStart then
                local key, message = LedgerEdit.ResolveItem(text, config.itemIndex)
                if not key then
                    return nil, message
                end
                changes[field.key] = key
            end
        elseif field.kind == "count" then
            local text = trim(control:GetText())
            value = text == "" and 0 or tonumber(text)
            if not (value and value >= 0 and value % 1 == 0) then
                return nil, field.label .. " must be a whole number, 0 or more."
            end
        elseif field.kind == "money" then
            value = control:GetCopper()
        else
            value = trim(control:GetText())
        end
        if value ~= nil and value ~= record[field.key] and not (value == "" and record[field.key] == nil) then
            changes[field.key] = value
        end
    end
    return changes
end

local function build()
    local Kit = ns.Kit
    local pad = Kit.Theme.padding
    local window = Kit.CreateWindow(WINDOW_NAME, { width = WIDTH, height = 300 })
    window:SetFrameStrata("DIALOG")
    window:SetToplevel(true)
    window.controls = {}
    window.labels = {}
    for _, field in ipairs(LedgerEdit.FIELDS) do
        window.labels[field.key] = Kit.Label(window, field.label, "highlight")
        local control
        if field.kind == "source" then
            control = Kit.Dropdown(window, 220, {
                items = {},
                onChange = function(value)
                    window.sourceValue = value
                end,
            })
        elseif field.kind == "money" then
            control = Kit.MoneyInput(window, {})
        else
            control = Kit.Input(window, field.kind == "count" and 80 or WIDTH - 2 * pad - 24)
            if field.kind == "count" then
                control:SetNumeric(true)
            end
        end
        window.controls[field.key] = control
    end
    window.error = Kit.Label(window, "", "bad")
    window.error:SetWidth(WIDTH - 2 * pad - 16)

    -- The user can drop an item from the cursor on the item box (no hook).
    local box = window.controls.item
    local function drop()
        local getInfo = _G.GetCursorInfo
        local kind, itemID, link = nil, nil, nil
        if getInfo then
            kind, itemID, link = getInfo()
        end
        if kind == "item" then
            box:SetText(type(link) == "string" and link or tostring(itemID))
            if _G.ClearCursor then
                _G.ClearCursor()
            end
        end
    end
    window.DropItem = drop
    box:SetScript("OnReceiveDrag", drop)
    box:SetScript("OnMouseDown", drop)

    local function save()
        local config = window.config
        if not config then
            return
        end
        local changes, message = collect(window, config)
        if changes then
            message = config.onSave(changes)
        end
        if message then
            window.error:SetText(message)
            return
        end
        window.config = nil
        window:Hide()
    end
    window.Save = save

    window.okButton = Kit.Button(window, "Save", 100, save)
    window.okButton:SetPoint("BOTTOM", window, "BOTTOM", -55, pad + 4)
    window.cancelButton = Kit.Button(window, "Cancel", 100, function()
        window.config = nil
        window:Hide()
    end)
    window.cancelButton:SetPoint("BOTTOM", window, "BOTTOM", 55, pad + 4)
    window:HookScript("OnHide", function()
        window.config = nil
    end)
    return window
end

local window

-- Opens the window for a record. config: record, sourceLabel(source), itemIndex (optional name index),
-- onSave(changes) (gives nil when the save works, else a message that stays in the window).
-- Returns the window.
function LedgerEdit.Open(config)
    local Kit = ns.Kit
    window = window or build()
    local pad = Kit.Theme.padding
    local record = config.record
    window.config = config
    window.itemStart = itemTextOf(record)
    local y = TOP
    for _, field in ipairs(LedgerEdit.FIELDS) do
        local label, control = window.labels[field.key], window.controls[field.key]
        label:ClearAllPoints()
        label:SetPoint("TOPLEFT", window, "TOPLEFT", pad + 8, -y)
        control:ClearAllPoints()
        control:SetPoint("TOPLEFT", window, "TOPLEFT", pad + 8, -(y + 16))
        if field.kind == "source" then
            local items = {}
            for _, source in ipairs(ns.LedgerRecord.SOURCES) do
                items[#items + 1] = { value = source, text = config.sourceLabel and config.sourceLabel(source)
                    or source }
            end
            control:SetItems(items)
            window.sourceValue = record.source
            control:SetValue(record.source)
        elseif field.kind == "item" then
            control:SetText(window.itemStart)
        elseif field.kind == "count" then
            control:SetText(tostring(record[field.key] or 0))
        elseif field.kind == "money" then
            control:SetCopper(record[field.key] or 0)
        else
            control:SetText(record[field.key] or "")
        end
        y = y + ROW_HEIGHT
    end
    window.error:ClearAllPoints()
    window.error:SetPoint("TOPLEFT", window, "TOPLEFT", pad + 8, -y)
    window.error:SetText("")
    window:SetHeight(y + 20 + 40)
    if window.SetTitle then
        window:SetTitle("Edit ledger entry")
    end
    window:Show()
    window:Raise()
    return window
end
