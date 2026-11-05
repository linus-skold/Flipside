local _, ns = ...

-- The craft profit block. It is a plain child frame inside the profession window of the client, under the reagents.
-- It shows the material cost and the profit of the selected recipe. The tooltip of the block has the detail.
-- The block adds no hook. It reads the selected recipe on the game events and on a throttled OnUpdate of its own frame.
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
-- Two lines only: the material cost and the profit or loss. A gain has the tone "good" and a loss has "bad".
-- A partial cost (a reagent has no price) makes the profit an upper limit and a loss a lower limit.
function CraftPanel.SummaryLines(result, format)
    local lines = {}
    lines[1] = { (result.partial and "Materials: at least " or "Materials: ") .. format(result.cost) }
    if not result.hasItem then
        lines[2] = { "No item to sell" }
        return lines
    end
    if result.value == nil then
        lines[2] = { "No sell price" }
        return lines
    end
    local percent = result.percent and string.format(" (%.0f%%)", math.abs(result.percent)) or ""
    if result.profit > 0 then
        lines[2] = { (result.partial and "Profit: at most +" or "Profit: +") .. format(result.profit) .. percent, "good" }
    elseif result.profit < 0 then
        lines[2] = { (result.partial and "Loss: at least " or "Loss: ") .. format(-result.profit) .. percent, "bad" }
    else
        lines[2] = { "Profit: " .. format(0) .. percent }
    end
    return lines
end

-- Return the tooltip lines of the block: item value, AH cut and the two formulas. result may be nil.
function CraftPanel.DetailLines(result, format, reagentFormula, itemFormula)
    local lines = {}
    if result and result.hasItem and result.value ~= nil then
        local made = result.made == 1 and "" or (" (" .. result.made .. " made)")
        lines[#lines + 1] = "Item value: " .. format(result.value) .. made
        lines[#lines + 1] = "AH cut: -" .. format(result.cutAmount)
    end
    lines[#lines + 1] = "Reagent price formula: " .. tostring(reagentFormula)
    lines[#lines + 1] = "Item value formula: " .. tostring(itemFormula)
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
    elseif self.view.Place then
        -- The client lays out its reagents after the selection changes, so the anchor can change.
        self.view:Place()
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

local PAD = 4
local WIDTH = 290
local LINE = 16
local EDITOR_HEIGHT = 110

-- Create the block. deps: kit, client, format(copper), getFormulas(), setFormula(which, text) -> ok, message,
-- onFormulaChanged(). The result has the view methods and a frame field. The frame is a child of the profession
-- window, so it hides with that window. The client gives the parent and the anchor (CraftClient:Mount).
local function buildView(deps, mount)
    local Kit = deps.kit
    local frame = CreateFrame("Frame", nil, mount.parent)
    frame:SetSize(WIDTH, 2 * LINE + 2 * PAD)
    frame:EnableMouse(true)
    local view = { frame = frame, mount = mount, usedLines = 0, summary = {} }

    for index = 1, 2 do
        local label = Kit.Label(frame, "", "normal")
        label:SetJustifyH("LEFT")
        label:SetWidth(index == 1 and WIDTH - 70 or WIDTH)
        label:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -PAD - (index - 1) * LINE)
        view.summary[index] = label
    end

    -- The formula editor: two text boxes, hidden until the player opens them.
    view.editor = CreateFrame("Frame", nil, frame)
    view.editor:SetSize(WIDTH, EDITOR_HEIGHT)
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
    view.reagentInput = Kit.Input(view.editor, WIDTH - 8, saver("reagent"))
    view.reagentInput:SetPoint("TOPLEFT", reagentLabel, "BOTTOMLEFT", 4, -2)
    local itemLabel = Kit.Label(view.editor, "Item value formula", "small")
    itemLabel:SetPoint("TOPLEFT", view.reagentInput, "BOTTOMLEFT", -4, -6)
    view.itemInput = Kit.Input(view.editor, WIDTH - 8, saver("item"))
    view.itemInput:SetPoint("TOPLEFT", itemLabel, "BOTTOMLEFT", 4, -2)
    view.formulaMessage = Kit.Label(view.editor, "", "bad")
    view.formulaMessage:SetPoint("TOPLEFT", view.itemInput, "BOTTOMLEFT", -4, -4)
    view.formulaMessage:SetWidth(WIDTH)
    view.formulaMessage:SetJustifyH("LEFT")

    -- The Formulas button sits at the right end of the first line.
    view.toggle = Kit.Button(frame, "Formulas", 66, function()
        view.editor:SetShown(not view.editor:IsShown())
        local reagent, item = deps.getFormulas()
        view.reagentInput:SetText(reagent)
        view.itemInput:SetText(item)
        view:Layout()
    end)
    view.toggle:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -PAD + 3)

    frame:SetScript("OnEnter", function(self)
        if not view.result then
            return
        end
        local reagent, item = deps.getFormulas()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Flipside crafting")
        for _, text in ipairs(CraftPanel.DetailLines(view.result, deps.format, reagent, item)) do
            GameTooltip:AddLine(text, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Set the block height. On TBC the scroll child of the detail area grows by the same height, so that the
    -- block stays inside the scroll range.
    function view:Layout()
        local height = self.usedLines * LINE + 2 * PAD
        if self.usedLines > 0 and self.editor:IsShown() then
            self.editor:ClearAllPoints()
            self.editor:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -height)
            height = height + EDITOR_HEIGHT
        end
        frame:SetHeight(math.max(1, height))
        self:Grow()
    end

    function view:Grow()
        local child = self.mount.scrollChild
        if not child then
            return
        end
        self.baseHeight = self.baseHeight or child:GetHeight()
        child:SetHeight(self.baseHeight + frame:GetHeight() + 8)
        if self.mount.scrollFrame and self.mount.scrollFrame.UpdateScrollChildRect then
            self.mount.scrollFrame:UpdateScrollChildRect()
        end
    end

    -- Read the mount again and anchor the block under the reagents. Cheap when nothing changed.
    function view:Place()
        local current = deps.client:Mount()
        if not current then
            return
        end
        local old = self.mount
        self.mount = current
        if current.parent ~= frame:GetParent() then
            frame:SetParent(current.parent)
        end
        if current.anchor ~= old.anchor or current.x ~= old.x or current.y ~= old.y or not self.placed then
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", current.anchor, current.relativePoint, current.x, current.y)
            self.placed = true
            self:Grow()
        end
    end

    function view:Show()
        self:Place()
        frame:Show()
        self:Grow()
    end

    function view:Hide()
        frame:Hide()
        local child = self.mount.scrollChild
        if child and self.baseHeight then
            child:SetHeight(self.baseHeight)
            self.baseHeight = nil
        end
    end

    function view:IsShown()
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
        view.usedLines = #lines
        view.toggle:SetShown(#lines > 0)
    end

    function view:Render(state)
        self.result = state.result
        if state.unsupported then
            setSummary({ { ns.CraftClient.UNSUPPORTED } })
        elseif state.empty then
            setSummary({})
            self.editor:Hide()
        else
            setSummary(CraftPanel.SummaryLines(state.result, deps.format))
        end
        self:Place()
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
-- Returns the driver. The frame is built on the first TRADE_SKILL_SHOW, when the client gives a parent for it.
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
