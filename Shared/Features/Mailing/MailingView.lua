local _, ns = ...

-- The mailing view (SPEC 5.5). It lists the mailing rules (the mailing operations) as compact rows. A rule knows
-- its groups, so the user selects none. Run plans and sends the mails of one rule, Run all those of every rule in
-- order, each after one confirm. It takes a parent frame and knows nothing about its place: a host (MailHost)
-- anchors view.frame.
local MailingView = {}
ns.MailingView = MailingView

local Kit = ns.Kit
-- The row height of the Ledger list (LedgerPage).
local ROW_HEIGHT = 18
local SIDE = 6
local TOP = -30
-- Space under the list, from the bottom edge: the buttons and the status line.
local LIST_BOTTOM = 64
local STATUS_BOTTOM = 40
local RUN_WIDTH = 34
local RUN_HEIGHT = 16
-- The columns of a rule row: the x offset and the width of each text.
local COLUMNS = {
    name = { 4, 68 },
    recipient = { 76, 56 },
    groups = { 136, 44 },
    filter = { 184, 70 },
}
local GROUP_TIP_LINES = 12
local GREY = { 0.5, 0.5, 0.5 }
local GOLD = { 1, 0.82, 0 }
local RED = { 1, 0.4, 0.4 }
local WHITE = { 1, 1, 1 }
local MAX_QUALITY = 4
local RARITY_NAMES = { [0] = "Poor", "Common", "Uncommon", "Rare", "Epic" }
local RARITY_SHORT = { [0] = "Poor", "Com", "Unc", "Rare", "Epic" }
local ESCAPES = { "|c%x%x%x%x%x%x%x%x", "|r" }

local function log(level, text)
    if ns.Log and ns.Log.Write then
        ns.Log.Write("mail", level, text)
    end
end

-- Returns true if the recipient is a known own character. Names match without regard to case; a name without a
-- realm matches the name part.
function MailingView.IsKnownCharacter(recipient, characters)
    local wanted = recipient:lower()
    local wantedName, wantedRealm = wanted:match("^([^%-]+)%-(.+)$")
    for _, character in ipairs(characters or {}) do
        local lower = character:lower()
        local name, realm = lower:match("^([^%-]+)%-(.+)$")
        if lower == wanted then
            return true
        end
        if not wantedRealm and (name or lower) == wanted then
            return true
        end
        if wantedRealm and not realm and lower == wantedName then
            return true
        end
    end
    return false
end

local function mailsText(count)
    return count .. (count == 1 and " mail" or " mails")
end

local function unitsOf(mails)
    local units = 0
    for _, mail in ipairs(mails) do
        for _, attachment in ipairs(mail.attachments) do
            units = units + attachment.count
        end
    end
    return units
end

-- The names of the recipients of a mail list, in order, with no repeat.
local function recipientsOf(mails)
    local names, seen = {}, {}
    for _, mail in ipairs(mails) do
        local id = mail.recipient:lower()
        if not seen[id] then
            seen[id] = true
            names[#names + 1] = mail.recipient
        end
    end
    return names
end

-- The confirm text, for example "Send 3 mails to Alt, Bank? The client charges the postage."
function MailingView.ConfirmText(mails)
    return string.format("Send %s to %s? The client charges the postage for each mail.", mailsText(#mails),
        table.concat(recipientsOf(mails), ", "))
end

-- The lines of a run result. result is a MailingRun result.
function MailingView.ResultLines(result, itemName, formatMoney)
    local lines = {}
    lines[#lines + 1] = string.format("Sent %s, postage %s", mailsText(result.sent), formatMoney(result.postage))
    for _, entry in ipairs(result.recipients) do
        lines[#lines + 1] = string.format("  %s: %s, %d items", entry.name, mailsText(entry.mails), entry.units)
    end
    if result.stopped then
        lines[#lines + 1] = "|cffff6060Stopped: " .. result.stopped .. "|r"
    end
    for _, skip in ipairs(result.skipped) do
        local name = skip.name or (skip.key and itemName(skip.key)) or "item"
        lines[#lines + 1] = string.format("Skipped %s x%d: %s", name, skip.count or 0, skip.reason)
    end
    return lines
end

-- The one status line of a run result, for example "Sent 2 mails, postage 60c, stopped: mailbox closed, 3 skipped".
function MailingView.ResultSummary(result, formatMoney)
    local text = string.format("Sent %s, postage %s", mailsText(result.sent), formatMoney(result.postage))
    if result.stopped then
        text = text .. ", stopped: " .. result.stopped
    end
    if #result.skipped > 0 then
        text = text .. ", " .. #result.skipped .. " skipped"
    end
    return text
end

-- Returns the short and the long text of the item filter of a mailing operation.
function MailingView.FilterText(settings)
    local min = math.max(0, math.min(tonumber(settings.minQuality) or 0, MAX_QUALITY))
    local max = math.max(min, math.min(tonumber(settings.maxQuality) or MAX_QUALITY, MAX_QUALITY))
    local classes = 0
    for _ in pairs(ns.MailingPlan.ParseClasses(settings.itemClasses)) do
        classes = classes + 1
    end
    local short, long = {}, {}
    if min > 0 or max < MAX_QUALITY then
        short[#short + 1] = min == max and RARITY_SHORT[min] or (RARITY_SHORT[min] .. "-" .. RARITY_SHORT[max])
        long[#long + 1] = min == max and ("Rarity: " .. RARITY_NAMES[min])
            or string.format("Rarity: %s to %s", RARITY_NAMES[min], RARITY_NAMES[max])
    end
    if classes > 0 then
        short[#short + 1] = classes .. (classes == 1 and " type" or " types")
        long[#long + 1] = "Item types: " .. classes
    end
    if #short == 0 then
        return "any item", "No item filter"
    end
    return table.concat(short, ", "), table.concat(long, "\n")
end

local function trim(text)
    return (text:match("^%s*(.-)%s*$"))
end

local function setNoWrap(label)
    if label.SetWordWrap then
        label:SetWordWrap(false)
    end
end

local function setColor(label, color)
    label:SetTextColor(color[1], color[2], color[3])
end

local function showTooltip(row, rule)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText(rule.name)
    if rule.reason then
        GameTooltip:AddLine("Cannot run: " .. rule.reason, RED[1], RED[2], RED[3])
    end
    GameTooltip:AddLine("Recipient: " .. (rule.recipient ~= "" and rule.recipient or "none"), 1, 1, 1)
    if rule.unknown then
        GameTooltip:AddLine("Not one of your characters", GOLD[1], GOLD[2], GOLD[3])
    end
    if #rule.groupNames == 0 then
        GameTooltip:AddLine("No groups use this rule", GREY[1], GREY[2], GREY[3])
    else
        GameTooltip:AddLine("Groups:", GOLD[1], GOLD[2], GOLD[3])
        for index, name in ipairs(rule.groupNames) do
            if index > GROUP_TIP_LINES then
                GameTooltip:AddLine(string.format("+ %d more", #rule.groupNames - GROUP_TIP_LINES), 1, 1, 1)
                break
            end
            GameTooltip:AddLine(name, 1, 1, 1)
        end
    end
    GameTooltip:AddLine(rule.filterLong, 1, 1, 1)
    if not rule.reason then
        GameTooltip:AddLine(string.format("Ready: %s, %d items", mailsText(rule.mails), rule.items), 1, 1, 1)
    end
    GameTooltip:Show()
end

local function placeText(row, label, column)
    label:SetPoint("LEFT", row, "LEFT", column[1], 0)
    label:SetWidth(column[2])
    label:SetJustifyH("LEFT")
    setNoWrap(label)
end

-- Builds the fields of a rule row once.
local function buildRow(view, row)
    row.nameText = Kit.Label(row, "", "small")
    placeText(row, row.nameText, COLUMNS.name)
    row.recipientText = Kit.Label(row, "", "small")
    placeText(row, row.recipientText, COLUMNS.recipient)
    row.groupsText = Kit.Label(row, "", "small")
    placeText(row, row.groupsText, COLUMNS.groups)
    row.filterText = Kit.Label(row, "", "small")
    placeText(row, row.filterText, COLUMNS.filter)
    row.run = Kit.Button(row, "Run", RUN_WIDTH, function()
        view:RunRule(row.rule.id)
    end)
    row.run:SetHeight(RUN_HEIGHT)
    row.run:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row:SetScript("OnEnter", function(self)
        showTooltip(self, self.rule)
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

-- Draw one rule row. A rule that cannot run shows grey, with the reason in the filter column.
local function initRow(view, row, rule)
    if not row.run then
        buildRow(view, row)
    end
    row.rule = rule
    local color = rule.reason and GREY or GOLD
    row.nameText:SetText(rule.name)
    setColor(row.nameText, color)
    row.recipientText:SetText(rule.recipient)
    setColor(row.recipientText, rule.unknown and RED or color)
    row.groupsText:SetText(rule.groupsShort)
    setColor(row.groupsText, color)
    row.filterText:SetText(rule.reason or rule.filterShort)
    setColor(row.filterText, rule.reason and RED or WHITE)
    row.run:SetEnabled(not rule.reason and not view.run:IsRunning())
end

-- deps: rules (RulesStore), client (MailClient object), newRun(callbacks) (returns a MailingRun), characters()
-- (own characters), selfName(), itemName(key), formatMoney(copper), confirm(text, onAccept), skin (optional, the
-- list skin of the Auction House tabs).
-- size (optional) is { width, height }. A host can instead anchor view.frame at two corners.
function MailingView.Create(parent, deps, size)
    local view = { rules = {}, byId = {}, deps = deps, statusText = "" }
    local frame = CreateFrame("Frame", nil, parent)
    if size then
        frame:SetSize(size.width, size.height)
    end
    view.frame = frame

    local title = Kit.Label(frame, "Flipside mailing", "title")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE + 2, -8)

    view.list = Kit.CreateList(frame, {
        rowHeight = ROW_HEIGHT,
        inset = true,
        skin = deps.skin,
        retainScroll = true,
        initRow = function(row, rule)
            initRow(view, row, rule)
        end,
    })
    view.list.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE, TOP)
    view.list.frame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -SIDE, LIST_BOTTOM)

    view.status = Kit.Label(frame, "", "small")
    view.status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", SIDE + 4, STATUS_BOTTOM)
    view.status:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -SIDE - 4, STATUS_BOTTOM)
    view.status:SetJustifyH("LEFT")
    setNoWrap(view.status)

    view.runAll = Kit.Button(frame, "Run all", 80, function()
        view:RunAll()
    end)
    view.runAll:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", SIDE, SIDE + 2)
    view.stop = Kit.Button(frame, "Stop", 80, function()
        view.run:Stop()
    end)
    view.stop:SetPoint("LEFT", view.runAll, "RIGHT", 8, 0)
    view.stop:Disable()

    view.run = deps.newRun({
        onProgress = function(status)
            view:ShowProgress(status)
        end,
        onDone = function(result)
            view:ShowResult(result)
        end,
    })
    return setmetatable(view, { __index = MailingView })
end

-- Builds the row data of one mailing operation, with its groups and its planned mails.
function MailingView:_BuildRule(entry, slots, characters)
    local deps = self.deps
    local settings = deps.rules:GetOperation(entry.id).settings
    local groups = ns.MailingPlan.GroupsForOperation(deps.rules, entry.id)
    local rule = { id = entry.id, name = entry.name, groupNames = {}, mails = 0, items = 0 }
    rule.recipient = trim(tostring(settings.recipient or ""))
    for _, group in ipairs(groups) do
        rule.groupNames[#rule.groupNames + 1] = tostring(deps.rules:Name(group.id))
    end
    local count = #groups
    rule.groupsShort = count .. (count == 1 and " group" or " groups")
    rule.filterShort, rule.filterLong = MailingView.FilterText(settings)
    if rule.recipient == "" then
        rule.reason = "no recipient"
    elseif count == 0 then
        rule.reason = "no groups"
    else
        local plan = ns.MailingPlan.Build({ groups = groups, slots = slots, self = deps.selfName() })
        rule.mails, rule.items = #plan.mails, unitsOf(plan.mails)
        rule.unknown = not MailingView.IsKnownCharacter(rule.recipient, characters)
    end
    return rule
end

-- Reads the mailing operations and the bags again and shows one row for each rule, sorted by name.
function MailingView:Refresh()
    local deps = self.deps
    local rules, byId = {}, {}
    if deps.rules then
        local slots = deps.client.ReadSlots()
        local characters = deps.characters and deps.characters() or {}
        for _, entry in ipairs(deps.rules:ListOperations("mailing")) do
            local rule = self:_BuildRule(entry, slots, characters)
            rules[#rules + 1] = rule
            byId[rule.id] = rule
        end
    end
    self.rules, self.byId = rules, byId
    self.list:SetData(rules)
    self:_ShowIdle()
end

-- The rules that can run, in order.
function MailingView:_Runnable()
    local list = {}
    for _, rule in ipairs(self.rules) do
        if not rule.reason then
            list[#list + 1] = rule
        end
    end
    return list
end

-- The status line and the Run all button when no run is active.
function MailingView:_ShowIdle()
    local runnable = self:_Runnable()
    if not self.run:IsRunning() then
        local mails = 0
        for _, rule in ipairs(runnable) do
            mails = mails + rule.mails
        end
        if not self.resultText then
            self.statusText = string.format("%d rules, %s ready", #self.rules, mailsText(mails))
            self.status:SetText(self.statusText)
        end
    end
    self.runAll:SetEnabled(#runnable > 0 and not self.run:IsRunning())
end

-- Returns the planned mails of the given rules, joined in order, and the skipped slots.
function MailingView:Plan(chosen)
    local deps = self.deps
    local plan = { mails = {}, skipped = {} }
    if #chosen == 0 then
        return plan
    end
    local slots = deps.client.ReadSlots()
    for _, rule in ipairs(chosen) do
        local part = ns.MailingPlan.Build({
            groups = ns.MailingPlan.GroupsForOperation(deps.rules, rule.id), slots = slots, self = deps.selfName(),
        })
        for _, mail in ipairs(part.mails) do
            plan.mails[#plan.mails + 1] = mail
        end
        for _, skip in ipairs(part.skipped) do
            plan.skipped[#plan.skipped + 1] = skip
        end
    end
    return plan
end

-- Runs one rule after one confirm.
function MailingView:RunRule(id)
    local rule = self.byId[id]
    if rule and not rule.reason then
        self:_Start({ rule })
    end
end

-- Runs every rule that can run, in order, after one confirm.
function MailingView:RunAll()
    self:_Start(self:_Runnable())
end

function MailingView:_Start(chosen)
    if self.run:IsRunning() or #chosen == 0 then
        return
    end
    local names = {}
    for _, rule in ipairs(chosen) do
        names[#names + 1] = rule.name
    end
    local plan = self:Plan(chosen)
    if #plan.mails == 0 then
        self.resultText = "Nothing to send for " .. table.concat(names, ", ")
        self.statusText = self.resultText
        self.status:SetText(self.statusText)
        log("info", self.resultText .. " (" .. #plan.skipped .. " skipped)")
        return
    end
    self.confirmText = MailingView.ConfirmText(plan.mails)
    self.deps.confirm(self.confirmText, function()
        self.resultText = nil
        log("info", string.format("run %s: %s, %d items", table.concat(names, ", "), mailsText(#plan.mails),
            unitsOf(plan.mails)))
        local ok, message = self.run:Start(plan)
        if not ok then
            self.statusText = tostring(message)
            self.status:SetText(self.statusText)
            log("warn", "run did not start: " .. tostring(message))
        end
    end)
end

function MailingView:ShowProgress(status)
    local running = status.state ~= "idle"
    self.runAll:SetEnabled(not running and #self:_Runnable() > 0)
    self.stop:SetEnabled(running)
    if running then
        self.statusText = string.format("Mail %d of %d (%d sent)", math.max(status.index, 1), status.total,
            status.sent)
        self.status:SetText(self.statusText)
    end
    self.list:SetData(self.rules)
end

-- Shows the result as one status line and writes the detail lines to the log.
function MailingView:ShowResult(result)
    local deps = self.deps
    self.resultLines = MailingView.ResultLines(result, deps.itemName, deps.formatMoney)
    for _, line in ipairs(self.resultLines) do
        for _, pattern in ipairs(ESCAPES) do
            line = line:gsub(pattern, "")
        end
        log("info", line)
    end
    self.resultText = MailingView.ResultSummary(result, deps.formatMoney)
    self.statusText = self.resultText
    self.status:SetText(self.statusText)
    self:Refresh()
end

function MailingView:Show()
    self.frame:Show()
end

function MailingView:Hide()
    self.frame:Hide()
end
