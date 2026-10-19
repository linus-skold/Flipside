local _, ns = ...

-- Adds up the money that the player takes from mails while the mailbox is open. At MAIL_CLOSED it waits until
-- the ledger has no pending mail money (at most MAX_WAIT seconds), then it prints one chat line with the total
-- and the number of mails, and resets. If the mailbox opens again during the wait, it prints the old total at once.
-- Only money from mails counts: postage, sent money and COD that the player pays do not come from a mail. The
-- source is the event of LedgerMail, which fires once for each mail whose money the player took.
local MailTotal = {}
ns.MailTotal = MailTotal

local OWNER = "Flipside.MailTotal"

-- The longest wait after the close, and the time between two checks (seconds).
MailTotal.MAX_WAIT = 2
MailTotal.POLL = 0.25

-- deps: bus, event (the LedgerMail event name), print(text), format(copper) -> text, after(seconds, fn),
-- pending() (optional, true while the ledger waits for mail money), enabled() (optional, false turns the line
-- off) and log(fmt, ...) (optional). Returns { Total, Count }.
function MailTotal.Attach(deps)
    local total, count = 0, 0
    local waiting = false
    local generation = 0
    local state = {}

    function state.Total()
        return total
    end

    function state.Count()
        return count
    end

    local function isPending()
        return deps.pending ~= nil and deps.pending() == true
    end

    local function finish()
        waiting = false
        generation = generation + 1
        local sum, mails = total, count
        total, count = 0, 0
        if sum <= 0 then
            return
        end
        if deps.log then
            deps.log("mail money total %d copper from %d mails", sum, mails)
        end
        if deps.enabled and deps.enabled() == false then
            return
        end
        deps.print(string.format("You collected %s from %d %s.", deps.format(sum), mails,
            mails == 1 and "mail" or "mails"))
    end

    local function poll(mine, waited)
        if mine ~= generation or not waiting then
            return
        end
        if not isPending() or waited >= MailTotal.MAX_WAIT then
            finish()
            return
        end
        deps.after(MailTotal.POLL, function()
            poll(mine, waited + MailTotal.POLL)
        end)
    end

    deps.bus:Subscribe(deps.event, OWNER, function(_, amount)
        if type(amount) == "number" and amount > 0 then
            total = total + amount
            count = count + 1
        end
    end)
    deps.bus:Subscribe("MAIL_CLOSED", OWNER, function()
        if waiting then
            return
        end
        waiting = true
        generation = generation + 1
        poll(generation, 0)
    end)
    deps.bus:Subscribe("MAIL_SHOW", OWNER, function()
        if waiting then
            finish()
        end
    end)
    return state
end
