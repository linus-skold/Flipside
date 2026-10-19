local _, ns = ...

-- The craft profit panel. It docks to the right side of the profession window of the client.
-- It shows the reagent cost, the AH value and the profit of the selected recipe.
-- The panel adds no hook. It reads the selected recipe on the game events and on a throttled OnUpdate of its own frame.
local CraftPanel = {}
ns.CraftPanel = CraftPanel

CraftPanel.DEFAULT_REAGENT_FORMULA = "min(vendorbuy, scanmin)"
CraftPanel.DEFAULT_ITEM_FORMULA = "scanmin"
CraftPanel.REAGENT_KEY = "crafting.reagentFormula"
CraftPanel.ITEM_KEY = "crafting.itemFormula"
CraftPanel.INTERVAL = 0.2
CraftPanel.PRICE_EVENTS = { "Flipside.ScanFinished", "Flipside.PriceCaptured" }

local OWNER = "Flipside.CraftPanel"
local GREEN, RED = "|cff20ff20", "|cffff4040"

-- Return a function that gives the copper price of an item from a formula, or nil for no price.
-- run is a FormulaRun object. getText() gives the formula text.
function CraftPanel.PriceFunction(run, getText)
    return function(itemID)
        if not run then
            return nil
        end
        local ok, copper = pcall(run.Evaluate, run, getText(), itemID)
        if ok and type(copper) == "number" and copper > 0 then
            return copper
        end
        return nil
    end
end

-- Return the text to show for a result. Each entry is { text, tone } with tone "good", "bad" or nil.
-- format(copper) gives the money text.
function CraftPanel.SummaryLines(result, format)
    local lines = {}
    lines[#lines + 1] = { (result.partial and "Craft cost: at least " or "Craft cost: ") .. format(result.cost) }
    if not result.hasItem then
        lines[#lines + 1] = { "No item to sell" }
        return lines
    end
    if result.value == nil then
        lines[#lines + 1] = { "Item value: no price" }
        return lines
    end
    local made = result.made == 1 and "" or (" (" .. result.made .. " made)")
    lines[#lines + 1] = { "Item value: " .. format(result.value) .. made }
    lines[#lines + 1] = { "AH cut: -" .. format(result.cutAmount) }
    local tone = result.profit > 0 and "good" or (result.profit < 0 and "bad" or nil)
    local profit = result.partial and "Profit: at most " or "Profit: "
    lines[#lines + 1] = { profit .. format(result.profit), tone }
    if result.percent then
        lines[#lines + 1] = { string.format("Profit of cost: %.0f%%", result.percent), tone }
    end
    return lines
end

-- The driver holds the refresh logic and no frame code. deps:
--   client: a CraftClient object. view: { Show, Hide, IsShown, Render(state) }.
--   compute(recipe): gives the CraftCost result. bus: the event bus.
-- Render gets { unsupported = true }, { empty = true } or { recipe, result }.
local Driver = {}
Driver.__index = Driver

function CraftPanel.NewDriver(deps)
    return setmetatable({
        client = deps.client,
        view = deps.view,
        compute = deps.compute,
        bus = deps.bus,
        interval = deps.interval or CraftPanel.INTERVAL,
        elapsed = 0,
        lastKey = nil,
    }, Driver)
end

-- Read the selected recipe again and draw it.
function Driver:Refresh()
    local client = self.client
    if not client:Supported() then
        self.lastKey = nil
        self.view:Render({ unsupported = true })
        return
    end
    local recipe = client:Read()
    if not recipe then
        self.lastKey = nil
        self.view:Render({ empty = true })
        return
    end
    self.lastKey = recipe.key
    self.view:Render({ recipe = recipe, result = self.compute(recipe) })
end

function Driver:Show()
    self.elapsed = 0
    self.view:Show()
    self:Refresh()
end

function Driver:Hide()
    self.view:Hide()
end

-- Called from the OnUpdate of the panel frame. It checks the selection at most once in each interval.
function Driver:Tick(seconds)
    self.elapsed = self.elapsed + seconds
    if self.elapsed < self.interval then
        return
    end
    self.elapsed = 0
    if not self.view:IsShown() then
        return
    end
    local host = self.client:Host()
    if host and host.IsShown and not host:IsShown() then
        self.view:Hide()
        return
    end
    if self.client:SelectionKey() ~= self.lastKey then
        self:Refresh()
    end
end

-- Subscribe to the game events and the price events.
function Driver:Start()
    local bus = self.bus
    for _, event in ipairs(self.client:Events()) do
        if event == "TRADE_SKILL_SHOW" then
            bus:Subscribe(event, OWNER, function()
                self:Show()
            end)
        elseif event == "TRADE_SKILL_CLOSE" then
            bus:Subscribe(event, OWNER, function()
                self:Hide()
            end)
        else
            bus:Subscribe(event, OWNER, function()
                if self.view:IsShown() then
                    self:Refresh()
                end
            end)
        end
    end
    for _, event in ipairs(CraftPanel.PRICE_EVENTS) do
        bus:Subscribe(event, OWNER, function()
            if self.view:IsShown() then
                self:Refresh()
            end
        end)
    end
end

local MAX_ROWS = 12
local ROW_HEIGHT = 28
local PAD = 12
local WIDTH = 280

-- Create the frame view. deps: kit, client, format(copper), getFormulas(), setFormula(which, text) -> ok, message,
-- onFormulaChanged(). The result has the view methods and a frame field.
local function buildView(deps)
    local Kit = deps.kit
    local frame = Kit.CreateWindow("FlipsideCraftPanel", { width = WIDTH, height = 200, title = "Flipside Crafting",
        square = true })
    -- The panel stays when Escape is pressed: the profession window decides when it hides.
    for index = #UISpecialFrames, 1, -1 do
        if UISpecialFrames[index] == "FlipsideCraftPanel" then
            table.remove(UISpecialFrames, index)
        end
    end
    local view = { frame = frame, rows = {} }

    local message = Kit.Label(frame, "", "normal")
    message:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -36)
    message:SetWidth(WIDTH - 2 * PAD)
    message:SetJustifyH("LEFT")
    view.message = message

    for index = 1, MAX_ROWS do
        local row = {}
        row.icon = frame:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(24, 24)
        row.name = Kit.Label(frame, "", "normal")
        row.name:SetJustifyH("LEFT")
        row.name:SetWidth(130)
        row.total = Kit.Label(frame, "", "highlight")
        row.total:SetJustifyH("RIGHT")
        row.unit = Kit.Label(frame, "", "small")
        row.unit:SetJustifyH("LEFT")
        row.icon:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -36 - (index - 1) * ROW_HEIGHT)
        row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, 0)
        row.unit:SetPoint("TOPLEFT", row.icon, "RIGHT", 6, -1)
        row.total:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -38 - (index - 1) * ROW_HEIGHT)
        view.rows[index] = row
    end

    view.summary = {}
    for index = 1, 6 do
        local label = Kit.Label(frame, "", "normal")
        label:SetJustifyH("LEFT")
        label:SetWidth(WIDTH - 2 * PAD)
        view.summary[index] = label
    end

    -- The formula editor: two text boxes, hidden until the player opens them.
    view.editor = CreateFrame("Frame", nil, frame)
    view.editor:SetSize(WIDTH - 2 * PAD, 110)
    view.editor:Hide()
    local reagentLabel = Kit.Label(view.editor, "Reagent price formula", "small")
    reagentLabel:SetPoint("TOPLEFT", view.editor, "TOPLEFT", 0, 0)
    local function saver(which)
        return function(text)
            local ok, err = deps.setFormula(which, text)
            view.formulaMessage:SetText(ok and "" or (err or "Formula not saved."))
            if ok then
                deps.onFormulaChanged()
            end
        end
    end
    view.reagentInput = Kit.Input(view.editor, WIDTH - 2 * PAD - 8, saver("reagent"))
    view.reagentInput:SetPoint("TOPLEFT", reagentLabel, "BOTTOMLEFT", 4, -2)
    local itemLabel = Kit.Label(view.editor, "Item value formula", "small")
    itemLabel:SetPoint("TOPLEFT", view.reagentInput, "BOTTOMLEFT", -4, -6)
    view.itemInput = Kit.Input(view.editor, WIDTH - 2 * PAD - 8, saver("item"))
    view.itemInput:SetPoint("TOPLEFT", itemLabel, "BOTTOMLEFT", 4, -2)
    view.formulaMessage = Kit.Label(view.editor, "", "bad")
    view.formulaMessage:SetPoint("TOPLEFT", view.itemInput, "BOTTOMLEFT", -4, -4)
    view.formulaMessage:SetWidth(WIDTH - 2 * PAD)
    view.formulaMessage:SetJustifyH("LEFT")

    view.toggle = Kit.Button(frame, "Formulas", 90, function()
        view.editor:SetShown(not view.editor:IsShown())
        local reagent, item = deps.getFormulas()
        view.reagentInput:SetText(reagent)
        view.itemInput:SetText(item)
        view:Layout()
    end)

    -- Place the summary, the button and the editor below the last used row, and set the frame height.
    function view:Layout()
        local top = -40 - self.usedRows * ROW_HEIGHT - 6
        for index, label in ipairs(self.summary) do
            label:ClearAllPoints()
            label:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, top - (index - 1) * 16)
        end
        top = top - self.usedSummary * 16 - 8
        self.toggle:ClearAllPoints()
        self.toggle:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, top)
        top = top - 28
        local height = -top + PAD
        if self.editor:IsShown() then
            self.editor:ClearAllPoints()
            self.editor:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, top)
            height = height + 110
        end
        frame:SetHeight(height)
    end

    view.usedRows, view.usedSummary = 0, 0

    function view.Show()
        local host = deps.client:Host()
        frame:ClearAllPoints()
        if host then
            frame:SetPoint("TOPLEFT", host, "TOPRIGHT", 0, 0)
        else
            frame:SetPoint("CENTER")
        end
        frame:Show()
    end

    function view.Hide()
        frame:Hide()
    end

    function view.IsShown()
        return frame:IsShown()
    end

    local function setSummary(lines)
        for index, label in ipairs(view.summary) do
            local line = lines[index]
            if line then
                local colour = line[2] == "good" and GREEN or (line[2] == "bad" and RED or "")
                label:SetText(colour == "" and line[1] or (colour .. line[1] .. "|r"))
            end
            label:SetShown(line ~= nil)
        end
        view.usedSummary = #lines
    end

    local function setRows(result)
        local used = result and math.min(#result.lines, MAX_ROWS) or 0
        for index, row in ipairs(view.rows) do
            local line = result and result.lines[index]
            local shown = index <= used and line ~= nil
            row.icon:SetShown(shown)
            row.name:SetShown(shown)
            row.unit:SetShown(shown)
            row.total:SetShown(shown)
            if shown then
                row.icon:SetTexture(line.icon)
                row.name:SetText((line.name or ("Item " .. line.itemID)) .. " x" .. line.count)
                if line.unit then
                    row.unit:SetText(deps.format(line.unit) .. " each")
                    row.total:SetText(deps.format(line.total))
                else
                    row.unit:SetText(RED .. "no price|r")
                    row.total:SetText("-")
                end
            end
        end
        view.usedRows = used
    end

    function view:Render(state)
        if state.unsupported or state.empty then
            message:SetText(state.unsupported and ns.CraftClient.UNSUPPORTED or "Select a recipe.")
            message:Show()
            setRows(nil)
            setSummary({})
        else
            message:Hide()
            setRows(state.result)
            setSummary(CraftPanel.SummaryLines(state.result, deps.format))
        end
        self:Layout()
    end

    frame:SetScript("OnUpdate", function(_, seconds)
        if view.driver then
            view.driver:Tick(seconds)
        end
    end)
    return view
end

-- Create the panel and start it. deps:
--   kit, client (a CraftClient object), bus, format(copper), run (a FormulaRun object), cut(gross),
--   getFormulas() -> reagent text, item text; setFormula(which, text) -> ok, message.
-- Returns the driver. The frame is built on the first TRADE_SKILL_SHOW.
function CraftPanel.Attach(deps)
    local view
    local driver
    local function reagentText()
        return (deps.getFormulas())
    end
    local function itemText()
        return (select(2, deps.getFormulas()))
    end
    local reagentPrice = CraftPanel.PriceFunction(deps.run, reagentText)
    local itemPrice = CraftPanel.PriceFunction(deps.run, itemText)
    local proxy = {}
    local function ensure()
        if not view then
            view = buildView({
                kit = deps.kit,
                client = deps.client,
                format = deps.format,
                getFormulas = deps.getFormulas,
                setFormula = deps.setFormula,
                onFormulaChanged = function()
                    driver:Refresh()
                end,
            })
            view.driver = driver
        end
        return view
    end
    function proxy.Show()
        ensure():Show()
    end
    function proxy.Hide()
        if view then
            view:Hide()
        end
    end
    function proxy.IsShown()
        return view ~= nil and view:IsShown()
    end
    function proxy.Render(_, state)
        ensure():Render(state)
    end
    driver = CraftPanel.NewDriver({
        client = deps.client,
        view = proxy,
        compute = function(recipe)
            return ns.CraftCost.Compute(recipe, {
                reagentPrice = reagentPrice,
                itemPrice = itemPrice,
                cut = deps.cut,
            })
        end,
        bus = deps.bus,
    })
    driver:Start()
    return driver
end
