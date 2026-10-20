local _, ns = ...

-- Prints the money that the player gained while the mailbox was open. At MAIL_SHOW it stores the money of the
-- player. At MAIL_CLOSED it waits a short time, because the server can send the money late. Then it reads the
-- money again. If the money is higher, it prints one chat line with the difference. If the mailbox opens again
-- during the wait, it prints the old result at once. It does not use the ledger.
local MailTotal = {}
ns.MailTotal = MailTotal

local OWNER = "Flipside.MailTotal"

-- The wait after the close (seconds).
MailTotal.WAIT = 0.5

-- deps: bus, money() -> copper, print(text), format(copper) -> text, after(seconds, fn),
-- enabled() (optional, false turns the line off) and log(fmt, ...) (optional). Returns { Start }.
function MailTotal.Attach(deps)
    local start = nil
    local waiting = false
    local generation = 0
    local state = {}

    function state.Start()
        return start
    end

    local function finish()
        waiting = false
        generation = generation + 1
        local before = start
        start = nil
        local now = deps.money()
        if type(before) ~= "number" or type(now) ~= "number" or now <= before then
            return
        end
        local delta = now - before
        if deps.log then
            deps.log("mail money gain %d copper", delta)
        end
        if deps.enabled and deps.enabled() == false then
            return
        end
        deps.print(string.format("You collected %s from the mailbox.", deps.format(delta)))
    end

    deps.bus:Subscribe("MAIL_SHOW", OWNER, function()
        if waiting then
            finish()
        end
        if start == nil then
            start = deps.money()
        end
    end)
    deps.bus:Subscribe("MAIL_CLOSED", OWNER, function()
        if start == nil or waiting then
            return
        end
        waiting = true
        generation = generation + 1
        local mine = generation
        deps.after(MailTotal.WAIT, function()
            if mine == generation and waiting then
                finish()
            end
        end)
    end)
    return state
end
