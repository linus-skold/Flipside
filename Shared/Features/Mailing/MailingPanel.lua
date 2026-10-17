local _, ns = ...

-- The mailing panel beside the MailFrame (SPEC 5.5). It lists the groups that have a mailing operation, shows the
-- planned mails of the groups that the user ticks, asks for one confirm and then starts the send run.
local MailingPanel = {}
ns.MailingPanel = MailingPanel

local Kit = ns.Kit
local WIDTH, HEIGHT = 290, 420
local ROW_HEIGHT = 34
local RESULT_ROW_HEIGHT = 16
local WARNING = "|cffffd200not one of your characters|r"

-- Returns true if the recipient is a known own character. Names match without regard to case; a name without a
-- realm matches the name part.
function MailingPanel.IsKnownCharacter(recipient, characters)
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
function MailingPanel.ConfirmText(mails)
    return string.format("Send %s to %s? The client charges the postage for each mail.", mailsText(#mails),
        table.concat(recipientsOf(mails), ", "))
end

-- The lines of the result list. result is a MailingRun result.
function MailingPanel.ResultLines(result, itemName, formatMoney)
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

-- deps: rules (RulesStore), client (MailClient object), newRun(callbacks) (returns a MailingRun), characters()
-- (own characters), selfName(), itemName(key), formatMoney(copper), confirm(text, onAccept).
function MailingPanel.Create(parent, deps)
    local panel = { selected = {}, groups = {}, deps = deps }
    local frame = CreateFrame("Frame", "FlipsideMailingPanel", parent, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    panel.frame = frame

    local title = Kit.Label(frame, "Flipside mailing", "title")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -12)

    panel.list = Kit.CreateList(frame, {
        rowHeight = ROW_HEIGHT,
        inset = true,
        initRow = function(row, data)
            if not row.check then
                row.check = Kit.Check(row, "", function(checked)
                    panel:SetSelected(row.groupID, checked)
                end)
                row.check:SetPoint("LEFT", row, "LEFT", 2, 0)
                row.name = Kit.Label(row, "", "normal")
                row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 30, -3)
                row.detail = Kit.Label(row, "", "small")
                row.detail:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 30, 3)
            end
            row.groupID = data.id
            row.check:SetChecked(panel.selected[data.id] == true)
            row.name:SetText(data.name .. " > " .. data.recipient)
            row.detail:SetText(data.detail)
        end,
    })
    panel.list.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -34)
    panel.list.frame:SetSize(WIDTH - 16, 150)

    panel.summary = Kit.Label(frame, "", "normal")
    panel.summary:SetPoint("TOPLEFT", panel.list.frame, "BOTTOMLEFT", 4, -8)

    panel.send = Kit.Button(frame, "Send", 80, function()
        panel:Send()
    end)
    panel.send:SetPoint("TOPLEFT", panel.summary, "BOTTOMLEFT", 0, -6)
    panel.stop = Kit.Button(frame, "Stop", 80, function()
        panel.run:Stop()
    end)
    panel.stop:SetPoint("LEFT", panel.send, "RIGHT", 8, 0)
    panel.stop:Disable()

    panel.progress = Kit.Label(frame, "", "small")
    panel.progress:SetPoint("TOPLEFT", panel.send, "BOTTOMLEFT", 0, -6)

    panel.results = Kit.CreateList(frame, {
        rowHeight = RESULT_ROW_HEIGHT,
        inset = true,
        initRow = function(row, data)
            if not row.text then
                row.text = Kit.Label(row, "", "small")
                row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            end
            row.text:SetText(data)
        end,
    })
    panel.results.frame:SetPoint("TOPLEFT", panel.progress, "BOTTOMLEFT", -4, -6)
    panel.results.frame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 8)

    panel.run = deps.newRun({
        onProgress = function(status)
            panel:ShowProgress(status)
        end,
        onDone = function(result)
            panel:ShowResult(result)
        end,
    })
    return setmetatable(panel, { __index = MailingPanel })
end

-- Lists the groups that have a mailing operation of their own, with the planned mails of each.
function MailingPanel:Refresh()
    local deps = self.deps
    self.groups = {}
    if not deps.rules then
        self.list:SetData(self.groups)
        return
    end
    local slots = deps.client.ReadSlots()
    local characters = deps.characters and deps.characters() or {}
    deps.rules:Walk(function(id)
        local opID, from = deps.rules:EffectiveOperation(id, "mailing")
        local operation = opID and from == id and deps.rules:GetOperation(opID)
        if not operation then
            return
        end
        local plan = ns.MailingPlan.Build({
            groups = ns.MailingPlan.GroupsFor(deps.rules, { id }), slots = slots, self = deps.selfName(),
        })
        local recipient = tostring(operation.settings.recipient or "")
        local detail = string.format("%s, %d items", mailsText(#plan.mails), unitsOf(plan.mails))
        if recipient == "" then
            detail = "no recipient set"
        elseif not MailingPanel.IsKnownCharacter(recipient, characters) then
            detail = detail .. ", " .. WARNING
        end
        self.groups[#self.groups + 1] = {
            id = id, name = deps.rules:Name(id), recipient = recipient == "" and "?" or recipient,
            detail = detail, mails = #plan.mails, items = unitsOf(plan.mails),
        }
    end)
    self.list:SetData(self.groups)
    self:_ShowSummary()
end

-- Returns the planned mails of the ticked groups, and the skipped slots.
function MailingPanel:Plan()
    local ids = {}
    for _, group in ipairs(self.groups) do
        if self.selected[group.id] then
            ids[#ids + 1] = group.id
        end
    end
    if #ids == 0 then
        return { mails = {}, skipped = {} }
    end
    return ns.MailingPlan.Build({
        groups = ns.MailingPlan.GroupsFor(self.deps.rules, ids), slots = self.deps.client.ReadSlots(),
        self = self.deps.selfName(),
    })
end

function MailingPanel:_ShowSummary()
    local plan = self:Plan()
    self.summaryText = string.format("%s, %d items", mailsText(#plan.mails), unitsOf(plan.mails))
    self.summary:SetText(self.summaryText)
    self.send:SetEnabled(#plan.mails > 0 and not self.run:IsRunning())
end

function MailingPanel:SetSelected(id, selected)
    self.selected[id] = selected or nil
    self:_ShowSummary()
end

-- Asks for one confirm, then starts the run.
function MailingPanel:Send()
    if self.run:IsRunning() then
        return
    end
    local plan = self:Plan()
    if #plan.mails == 0 then
        return
    end
    self.confirmText = MailingPanel.ConfirmText(plan.mails)
    self.deps.confirm(self.confirmText, function()
        self.results:SetData({})
        local ok, message = self.run:Start(plan)
        if not ok then
            self.progress:SetText(message)
        end
    end)
end

function MailingPanel:ShowProgress(status)
    local running = status.state ~= "idle"
    self.send:SetEnabled(not running)
    self.stop:SetEnabled(running)
    if running then
        self.progressText = string.format("Mail %d of %d (%d sent)", math.max(status.index, 1), status.total,
            status.sent)
    else
        self.progressText = ""
    end
    self.progress:SetText(self.progressText)
end

function MailingPanel:ShowResult(result)
    self.resultLines = MailingPanel.ResultLines(result, self.deps.itemName, self.deps.formatMoney)
    self.results:SetData(self.resultLines)
    self:Refresh()
end

function MailingPanel:Show()
    self.frame:Show()
end

function MailingPanel:Hide()
    self.frame:Hide()
end
