local _, ns = ...

-- Adds up the money that the player takes from mails while the mailbox is open. At MAIL_CLOSED it prints one chat
-- line with the total and the number of mails, then it resets. Only money from mails counts: postage, sent
-- money and COD that the player pays do not come from a mail. The source is the event of LedgerMail,
-- which fires once for each mail whose money the player took, whatever way the player used.
local MailTotal = {}
ns.MailTotal = MailTotal

local OWNER = "Flipside.MailTotal"

-- deps: bus, event (the LedgerMail event name), print(text), format(copper) -> text, enabled() (optional, false
-- turns the line off) and log(fmt, ...) (optional). Returns { Total, Count }.
function MailTotal.Attach(deps)
    local total, count = 0, 0
    local state = {}

    function state.Total()
        return total
    end

    function state.Count()
        return count
    end

    deps.bus:Subscribe(deps.event, OWNER, function(amount)
        if type(amount) == "number" and amount > 0 then
            total = total + amount
            count = count + 1
        end
    end)
    deps.bus:Subscribe("MAIL_CLOSED", OWNER, function()
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
    end)
    return state
end
