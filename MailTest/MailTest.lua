-- MailTest: throwaway probe. Can an addon send several mails in a row from one click, or from a timer?
-- It does not depend on Flipside. See README.md for the test steps.
-- Slash: /mailtest target <Name> | item <itemID> | click N | timer N | direct | status

local ADDON_NAME = "MailTest"
local STEP_TIMEOUT = 10

local frame = CreateFrame("Frame")
local target, itemID
local mailOpen = false
local run -- the active run, nil when idle
local blocked = 0
local panel

local function out(msg)
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff66ccff%s|r %.3f %s", ADDON_NAME, GetTime(), msg))
end

local function tabState()
    local send = SendMailFrame and SendMailFrame:IsShown() and true or false
    local inbox = InboxFrame and InboxFrame:IsShown() and true or false
    return string.format("sendTabShown=%s inboxTabShown=%s", tostring(send), tostring(inbox))
end

local function findSlot()
    for bag = 0, 4 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemID and not info.isLocked then
                return bag, slot
            end
        end
    end
end

local function finish(reason)
    if not run then
        return
    end
    local r = run
    run = nil
    local gaps, total = {}, 0
    for i = 2, #r.sendTimes do
        local g = r.sendTimes[i] - r.sendTimes[i - 1]
        gaps[#gaps + 1] = string.format("%.2f", g)
        total = total + g
    end
    out("SUMMARY (" .. r.mode .. ", " .. tabState() .. ", end: " .. reason .. ")")
    out(string.format("  sends tried=%d success=%d failed=%d blocked(total)=%d pcallErrors=%d",
        r.tried, r.success, r.failed, blocked, r.errors))
    out("  seconds between sends: " .. (#gaps > 0 and table.concat(gaps, ", ") or "n/a"))
end

local function sendOne()
    if not run then
        return
    end
    if run.tried >= run.n then
        finish("all mails done")
        return
    end
    if not mailOpen then
        finish("mailbox closed")
        return
    end
    local bag, slot = findSlot()
    if not bag then
        finish("no more slots with item " .. tostring(itemID))
        return
    end
    run.tried = run.tried + 1
    local idx = run.tried
    C_Container.PickupContainerItem(bag, slot)
    local okClick, errClick = pcall(ClickSendMailItemButton, 1)
    local attached = GetSendMailItem and GetSendMailItem(1)
    out(string.format("#%d attach: bag %d slot %d, click pcall=%s%s, attachedName=%s", idx, bag, slot,
        tostring(okClick), okClick and "" or (" err=" .. tostring(errClick)), tostring(attached)))
    if not attached then
        ClearCursor()
        run.errors = run.errors + 1
        finish("attach failed")
        return
    end
    out(string.format("#%d postage copper=%s", idx, tostring(GetSendMailPrice())))
    run.sendTimes[#run.sendTimes + 1] = GetTime()
    run.waiting = idx
    local ok, err = pcall(SendMail, target, "MailTest " .. idx, "MailTest probe " .. idx)
    out(string.format("#%d SendMail called, pcall=%s err=%s", idx, tostring(ok), tostring(err)))
    if not ok then
        run.errors = run.errors + 1
        finish("SendMail raised an error")
        return
    end
    C_Timer.After(STEP_TIMEOUT, function()
        if run and run.waiting == idx then
            out(string.format("#%d no event after %ds", idx, STEP_TIMEOUT))
            run.waiting = nil
            finish("timeout")
        end
    end)
end

local function startRun(mode, n)
    if not target or not itemID then
        out("set /mailtest target <Name> and /mailtest item <itemID> first")
        return
    end
    if not mailOpen then
        out("open a mailbox first")
        return
    end
    n = tonumber(n) or 1
    run = { mode = mode, n = n, tried = 0, success = 0, failed = 0, errors = 0, sendTimes = {} }
    out(string.format("run %s n=%d to %s item %d; %s", mode, n, target, itemID, tabState()))
    sendOne()
end

local function onEvent(_, event, ...)
    if event == "MAIL_SHOW" then
        mailOpen = true
        out("MAIL_SHOW")
    elseif event == "MAIL_CLOSED" then
        mailOpen = false
        out("MAIL_CLOSED")
    elseif event == "MAIL_SEND_SUCCESS" or event == "MAIL_FAILED" then
        out(event .. " " .. tostring((...)))
        if run and run.waiting then
            run.waiting = nil
            if event == "MAIL_SEND_SUCCESS" then
                run.success = run.success + 1
            else
                run.failed = run.failed + 1
            end
            -- The next mail starts here, from the event handler, not from a new click.
            sendOne()
        end
    elseif event == "UI_ERROR_MESSAGE" then
        local errType, msg = ...
        out("UI_ERROR_MESSAGE " .. tostring(errType) .. " " .. tostring(msg))
    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        blocked = blocked + 1
        out(event .. " " .. table.concat({ tostring((...)), tostring(select(2, ...)) }, " "))
    else
        out(event .. " " .. tostring((...)))
    end
end

for _, e in ipairs({ "MAIL_SHOW", "MAIL_CLOSED", "MAIL_SEND_SUCCESS", "MAIL_FAILED", "MAIL_SEND_INFO_UPDATE",
    "MAIL_LOCK_SEND_ITEMS", "UI_ERROR_MESSAGE", "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
    frame:RegisterEvent(e)
end
frame:SetScript("OnEvent", onEvent)

local function showPanel(n)
    if not panel then
        panel = CreateFrame("Frame", "MailTestPanel", UIParent, "BackdropTemplate")
        panel:SetSize(140, 50)
        panel:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
        panel:SetMovable(true)
        panel:EnableMouse(true)
        panel:RegisterForDrag("LeftButton")
        panel:SetScript("OnDragStart", panel.StartMoving)
        panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
        local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        button:SetSize(110, 26)
        button:SetPoint("CENTER")
        button:SetScript("OnClick", function()
            startRun("click", panel.n)
        end)
        panel.button = button
    end
    panel.n = n
    panel.button:SetText("Send " .. n)
    panel:Show()
end

SLASH_MAILTEST1 = "/mailtest"
SlashCmdList["MAILTEST"] = function(msg)
    local cmd, arg = (msg or ""):match("^(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "target" and arg ~= "" then
        target = arg
        out("target = " .. target)
    elseif cmd == "item" and tonumber(arg) then
        itemID = tonumber(arg)
        out("item = " .. itemID)
    elseif cmd == "click" and tonumber(arg) then
        showPanel(tonumber(arg))
        out("click the button to start; " .. tabState())
    elseif cmd == "timer" and tonumber(arg) then
        out("timer run starts in 1 second, no click; " .. tabState())
        C_Timer.After(1, function()
            startRun("timer", arg)
        end)
    elseif cmd == "direct" then
        -- One SendMail from the slash command itself.
        if not target or not itemID then
            out("set target and item first")
            return
        end
        run = { mode = "direct", n = 1, tried = 0, success = 0, failed = 0, errors = 0, sendTimes = {} }
        sendOne()
    elseif cmd == "status" then
        out(string.format("target=%s item=%s mailOpen=%s blocked=%d %s", tostring(target), tostring(itemID),
            tostring(mailOpen), blocked, tabState()))
    else
        out("usage: /mailtest target <Name> | item <itemID> | click N | timer N | direct | status")
    end
end
