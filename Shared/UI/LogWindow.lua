local _, ns = ...

-- The log window: the entries of the diagnostics log with filters, Copy and Clear.
local LogWindow = {}
ns.LogWindow = LogWindow

local instance

local PAD = 20
local ROW_HEIGHT = 16
local HEADER_HEIGHT = 18
local REFRESH_DELAY = 0.5
local ALL = ""

local LEVEL_COLOURS = { debug = "ff9d9d9d", info = "ffffffff", warn = "ffffd100", error = "ffff4040" }
local LEVEL_ITEMS = {
    { value = "debug", text = "Debug and up" },
    { value = "info", text = "Info and up" },
    { value = "warn", text = "Warnings and up" },
    { value = "error", text = "Errors only" },
}

local function levelText(value)
    return "|c" .. (LEVEL_COLOURS[value] or LEVEL_COLOURS.info) .. tostring(value) .. "|r"
end

local function plainText(value)
    return (tostring(value):gsub("|", "||"))
end

local COLUMNS = {
    { key = "clock", title = "Time", width = 92 },
    { key = "level", title = "Level", width = 46, format = levelText },
    { key = "category", title = "Category", width = 70, format = plainText },
    { key = "text", title = "Text", format = plainText },
}

-- Create the window once. deps: log (the ns.Log API), after (C_Timer.After, optional).
-- Returns a view: frame, Toggle(), Refresh(), SetMinLevel(level), SetCategory(name or nil),
-- SetSearch(text), SetNewestFirst(flag), GetRows(), GetText(), Copy(), Clear(), and the filter values.
-- The controls are view.debugCheck, view.traceCheck, view.clearButton and view.copyButton.
function LogWindow.Create(deps)
    if instance then
        return instance
    end
    local Kit = ns.Kit
    local log = deps.log
    local frame = Kit.CreateWindow("FlipsideLogWindow", {
        width = 760,
        height = 460,
        title = "Flipside log",
        square = true,
        resize = { minWidth = 600, minHeight = 320 },
    })
    local view = {
        frame = frame,
        minLevel = "debug",
        category = nil,
        search = "",
        newestFirst = true,
        rows = {},
    }
    instance = view

    local categoryKey = ""
    local pending = false

    -- Row 1: filters.
    local levelDrop = Kit.Dropdown(frame, 130, {
        items = LEVEL_ITEMS,
        value = view.minLevel,
        onChange = function(value)
            view:SetMinLevel(value)
        end,
    })
    levelDrop:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -34)
    local categoryDrop = Kit.Dropdown(frame, 130, {
        items = { { value = ALL, text = "All categories" } },
        value = ALL,
        onChange = function(value)
            view:SetCategory(value ~= ALL and value or nil)
        end,
    })
    categoryDrop:SetPoint("LEFT", levelDrop, "RIGHT", 6, 0)
    local searchInput = Kit.Input(frame, 170, nil, nil, { placeholder = "Search text" })
    searchInput:SetPoint("LEFT", categoryDrop, "RIGHT", 14, 0)
    searchInput:HookScript("OnTextChanged", function(self)
        view:SetSearch(self:GetText())
    end)
    local orderButton = Kit.Button(frame, "Newest first", 100, function()
        view:SetNewestFirst(not view.newestFirst)
    end)
    orderButton:SetPoint("LEFT", searchInput, "RIGHT", 10, 0)

    -- Row 2: switches and actions.
    local debugCheck = Kit.Check(frame, "Debug entries", function(on)
        log.SetDebug(on)
    end)
    debugCheck:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD - 4, -62)
    local traceCheck = Kit.Check(frame, "Event trace", function(on)
        log.SetTrace(on)
    end)
    traceCheck:SetPoint("LEFT", debugCheck, "RIGHT", 100, 0)
    local clearButton = Kit.Button(frame, "Clear", 80, function()
        Kit.Confirm("FLIPSIDE_LOG_CLEAR", "Remove all entries from the Flipside log?", function()
            view:Clear()
        end)
    end)
    clearButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -64)
    local copyButton = Kit.Button(frame, "Copy", 80, function()
        view:Copy()
    end)
    copyButton:SetPoint("RIGHT", clearButton, "LEFT", -6, 0)
    local refreshButton = Kit.Button(frame, "Refresh", 80, function()
        view:Refresh()
    end)
    refreshButton:SetPoint("RIGHT", copyButton, "LEFT", -6, 0)

    -- The header and the list.
    local list = Kit.CreateList(frame, {
        rowHeight = ROW_HEIGHT,
        inset = true,
        initRow = function(row, data)
            if not row.cells then
                row.cells = Kit.CreateColumnCells(row, COLUMNS, { gap = 6 })
                if row.cells.text and row.cells.text.SetWordWrap then
                    row.cells.text:SetWordWrap(false)
                end
            end
            Kit.SetColumnCells(row.cells, COLUMNS, data)
        end,
    })
    local edge = list.contentInsets
    local header = Kit.CreateColumnHeader(frame, COLUMNS, { gap = 6, left = edge.left, right = edge.right })
    header.frame:SetHeight(HEADER_HEIGHT)
    header.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -94)
    header.frame:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -94)
    list.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -94 - HEADER_HEIGHT - 2)
    list.frame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, 34)
    local status = Kit.Label(frame, "", "small")
    status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, 14)
    view.list, view.status = list, status
    view.debugCheck, view.traceCheck = debugCheck, traceCheck
    view.clearButton, view.copyButton = clearButton, copyButton

    local function updateCategories()
        local names = log.Categories()
        local key = table.concat(names, ",")
        if key == categoryKey then
            return
        end
        categoryKey = key
        local items = { { value = ALL, text = "All categories" } }
        for _, name in ipairs(names) do
            items[#items + 1] = { value = name, text = name }
        end
        categoryDrop:SetItems(items)
        categoryDrop:SetValue(view.category or ALL)
    end

    -- Fill the list from the log with the current filters.
    function view:Refresh()
        updateCategories()
        local entries = log.Query({ minLevel = self.minLevel, category = self.category, search = self.search })
        local rows = {}
        local count = #entries
        for index = 1, count do
            local entry = self.newestFirst and entries[count - index + 1] or entries[index]
            rows[index] = {
                clock = log.FormatTime(entry),
                level = entry.level,
                category = entry.category,
                text = entry.text,
            }
        end
        self.rows = rows
        list:SetData(rows)
        status:SetText(string.format("%d of %d entries shown", count, log.Count()))
        debugCheck:SetChecked(log.IsDebug())
        traceCheck:SetChecked(log.IsTrace())
    end

    function view:SetMinLevel(level)
        self.minLevel = level
        levelDrop:SetValue(level)
        self:Refresh()
    end

    function view:SetCategory(name)
        self.category = name
        self:Refresh()
    end

    function view:SetSearch(text)
        self.search = text or ""
        self:Refresh()
    end

    function view:SetNewestFirst(flag)
        self.newestFirst = flag and true or false
        orderButton:SetText(self.newestFirst and "Newest first" or "Oldest first")
        self:Refresh()
    end

    function view:GetRows()
        return self.rows
    end

    -- The filtered entries as plain text, oldest first.
    function view:GetText()
        return log.ToText(log.Query({ minLevel = self.minLevel, category = self.category, search = self.search }))
    end

    -- Open a dialog with the text selected, so that Ctrl+C copies it.
    function view:Copy()
        local dialog = Kit.EditorDialog("FlipsideLogCopy", {
            width = 640,
            height = 440,
            readOnly = true,
            help = "Press Ctrl+C to copy the text. Then paste it where you share it.",
        })
        dialog:Open("Flipside log (copy)", self:GetText())
        return dialog
    end

    function view:Clear()
        log.Clear()
        self:Refresh()
    end

    function view.Toggle()
        frame:Toggle()
    end

    -- Refresh at most twice a second while new entries arrive.
    local function onNewEntry()
        if pending or not frame:IsShown() or not deps.after then
            return
        end
        pending = true
        deps.after(REFRESH_DELAY, function()
            pending = false
            if frame:IsShown() then
                view:Refresh()
            end
        end)
    end
    frame:HookScript("OnShow", function()
        log.SetListener(onNewEntry)
        view:Refresh()
    end)
    frame:HookScript("OnHide", function()
        log.SetListener(nil)
    end)
    return view
end
