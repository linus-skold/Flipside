local _, ns = ...

-- The "Open all" run of the Flipside mailbox window (Forever, SPEC 5.5). It takes the money and the attachments of
-- every mail in the inbox, one mail at a time, with the client function AutoLootMailItem (api.autoLoot). It has no
-- frame code: the window calls Start and Stop and shows Status().
-- Order: from the last mail to the first. A take removes no mail below the one that the run works on, so the index
-- of a mail that is still to do never shifts.
-- Wait rule: after a take the run waits for MailTake.EVENT_ENDED (a quiet time after the last mail or bag event).
-- The run never pays a COD mail and never opens a GM mail (the client Open All button does the same).
local MailOpenAll = {}
ns.MailOpenAll = MailOpenAll

local OWNER = "Flipside.MailOpenAll"
-- The default of the client error text if the global ERR_INV_FULL is missing.
MailOpenAll.FULL_FALLBACK = "Inventory is full."
-- While a client mail command is in flight, the run asks again after PENDING_WAIT seconds, at most PENDING_MAX times
-- in a row (3 s); then it goes on, so that the run cannot hang.
local PENDING_WAIT = 0.15
local PENDING_MAX = 20
-- The red of the client error messages (UIErrorsFrame calls in the client source).
local ERROR_COLOR = { 1, 0.1, 0.1, 1 }

local function log(level, text)
    if ns.Log and ns.Log.Write then
        ns.Log.Write("mail", level, text)
    end
end

-- Reads one mail. api.header(index) is GetInboxHeaderInfo (money 5, COD 6, item count 8, is GM 13).
local function readMail(api, index)
    local _, _, sender, _, money, cod, _, itemCount, _, _, _, _, isGM = api.header(index)
    return {
        index = index,
        sender = sender or "",
        money = money or 0,
        cod = cod or 0,
        items = itemCount or 0,
        gm = isGM and true or false,
    }
end

-- Returns nil if the run can take the mail, or why it does not: "gm", "cod" or "empty".
local function skipReason(mail)
    if mail.gm then
        return "gm"
    end
    if mail.cod > 0 then
        return "cod"
    end
    if mail.items == 0 and mail.money == 0 then
        return "empty"
    end
    return nil
end

-- Shows a red message in the client error frame (UIErrorsFrame). frame is the frame or nil. Forever has
-- AddExternalErrorMessage (red); the other clients get AddMessage with the red of the client. Returns true if shown.
function MailOpenAll.ShowError(frame, text)
    if not frame then
        return false
    end
    if frame.AddExternalErrorMessage then
        frame:AddExternalErrorMessage(text)
    else
        frame:AddMessage(text, ERROR_COLOR[1], ERROR_COLOR[2], ERROR_COLOR[3], ERROR_COLOR[4])
    end
    return true
end

local function plural(count, one, many)
    return count == 1 and one or many
end

-- deps: api = { numItems(), header(index), autoLoot(index), freeSlots() (optional), commandPending() (optional,
-- C_Mail.IsCommandPending) }, bus, after(seconds, fn),
-- take (a MailTake: Begin(), IsActive()), formatMoney(copper), fullText (the client text of the full bags error,
-- ERR_INV_FULL), showError(text) (shows the red client message), say(text) (one chat line), blocked() (optional;
-- gives a text if the run must not start now, for example while a mailing run goes), onChange() (optional; called
-- when the status or the state changed).
-- Returns an object with Start(), Stop(), IsRunning() and Status().
function MailOpenAll.New(deps)
    local self = { running = false, stopping = false, status = "" }
    local api = deps.api
    local run

    local function setStatus(text)
        self.status = text
        if deps.onChange then
            deps.onChange()
        end
    end

    local function summary(prefix)
        local opened = run.opened
        local text = string.format("%sOpened %d %s, took %s", prefix, opened, plural(opened, "mail", "mails"),
            deps.formatMoney(run.money))
        if run.skipped > 0 then
            text = text .. string.format(", skipped %d", run.skipped)
        end
        if run.failed > 0 then
            text = text .. string.format(", not taken %d", run.failed)
        end
        return text
    end

    local function stopListening()
        deps.bus:Unsubscribe("Flipside.MailTakeEnded", OWNER)
        deps.bus:Unsubscribe("MAIL_CLOSED", OWNER)
        deps.bus:Unsubscribe("UI_ERROR_MESSAGE", OWNER)
    end

    -- reason: "done", "stopped", "closed" or "full". For "full" the error shows, and run.fullSkipped is the number
    -- of item mails that stay.
    local function finish(reason)
        self.running, self.stopping, run.pending = false, false, nil
        stopListening()
        local prefix = ""
        if reason == "stopped" then
            prefix = "Stopped. "
        elseif reason == "closed" then
            prefix = "Mailbox closed. "
        elseif reason == "full" then
            prefix = "Bags are full. "
        end
        local text = summary(prefix)
        log(reason == "full" and "warn" or "info", "open all ended (" .. reason .. "): " .. text)
        if reason == "full" then
            local count = run.fullSkipped
            deps.showError(deps.fullText)
            deps.say(string.format("%s %d %s left to open", deps.fullText, count, plural(count, "mail", "mails")))
        end
        setStatus(text)
    end

    -- The run ended by itself: with the full bags error if item mails stayed, else normally.
    local function finishDone()
        finish(run.fullSkipped > 0 and "full" or "done")
    end

    -- Takes the next mail, or ends the run. Works from run.index down to 1. While the client has a mail command in
    -- flight (api.commandPending), it waits, up to PENDING_MAX times.
    local function step()
        while true do
            if self.stopping then
                return finish("stopped")
            end
            run.index = math.min(run.index, api.numItems() or 0)
            if run.index < 1 then
                return finishDone()
            end
            local index = run.index
            local mail = readMail(api, index)
            local why = skipReason(mail)
            if why == "cod" or why == "gm" then
                run.skipped = run.skipped + 1
                log("info", string.format("open all skipped mail %d from %s: %s", index, mail.sender, why))
            end
            if not why and mail.items > 0 and api.freeSlots and api.freeSlots() == 0 then
                -- No free slot: the item mail stays; a mail with only money is still taken.
                run.fullSkipped = run.fullSkipped + 1
                log("warn", string.format("open all left mail %d from %s: bags are full", index, mail.sender))
                why = "full"
            end
            if not why then
                if api.commandPending and api.commandPending() and run.waits < PENDING_MAX then
                    run.waits = run.waits + 1
                    deps.after(PENDING_WAIT, function()
                        if self.running then
                            step()
                        end
                    end)
                    return
                end
                run.waits = 0
                log("info", string.format("open all takes mail %d from %s: %d items, money %d", index, mail.sender,
                    mail.items, mail.money))
                run.pending = mail
                setStatus(string.format("Opening mails: %d opened", run.opened))
                deps.take.Begin()
                api.autoLoot(index)
                return
            end
            run.index = index - 1
        end
    end

    -- Counts the taken mail. A mail that is still at its index with the same money and items was not taken.
    local function settle(mail)
        local now = mail.index <= (api.numItems() or 0) and readMail(api, mail.index) or nil
        local money = mail.money
        if now and now.sender == mail.sender then
            money = math.max(0, mail.money - now.money)
            if money == 0 and now.items >= mail.items then
                run.failed = run.failed + 1
                log("warn", string.format("open all: mail %d from %s was not taken", mail.index, mail.sender))
                return
            end
        end
        run.opened = run.opened + 1
        run.money = run.money + money
    end

    -- The take of the pending mail ended. The next step runs after a short delay, so that MAIL_CLOSED, which also
    -- ends the take, can end the run first.
    local function onTakeEnded()
        local mail = run and run.pending
        if not (self.running and mail) then
            return
        end
        run.pending = nil
        if mail.bagsFull then
            run.fullSkipped = run.fullSkipped + 1
        else
            settle(mail)
        end
        run.index = mail.index - 1
        deps.after(0, function()
            if self.running then
                step()
            end
        end)
    end

    -- The client error for full bags during a take: the mail stays, the run goes on with the money-only mails.
    local function onError(_, _, message)
        if self.running and run.pending and deps.fullText and message == deps.fullText then
            run.pending.bagsFull = true
        end
    end

    local function onClosed()
        if self.running then
            finish("closed")
        end
    end

    -- Starts the run. Returns true, or false and the reason as a text.
    function self.Start()
        if self.running then
            return false, "Open all is running"
        end
        local blocked = deps.blocked and deps.blocked()
        if not blocked and deps.take.IsActive() then
            blocked = "Wait for the mail take to end"
        end
        if blocked then
            setStatus(blocked)
            return false, blocked
        end
        if (api.numItems() or 0) == 0 then
            return false, "The inbox is empty"
        end
        run = { opened = 0, money = 0, skipped = 0, failed = 0, fullSkipped = 0, waits = 0, index = api.numItems() }
        self.running, self.stopping = true, false
        deps.bus:Subscribe("Flipside.MailTakeEnded", OWNER, onTakeEnded)
        deps.bus:Subscribe("MAIL_CLOSED", OWNER, onClosed)
        deps.bus:Subscribe("UI_ERROR_MESSAGE", OWNER, onError)
        log("info", string.format("open all started: %d mails", run.index))
        step()
        return true
    end

    -- Stops after the mail that is in progress.
    function self.Stop()
        if not self.running then
            return
        end
        self.stopping = true
        if run.pending then
            setStatus("Stopping after this mail")
        else
            finish("stopped")
        end
    end

    function self.IsRunning()
        return self.running
    end

    function self.Status()
        return self.status
    end

    return self
end
