local _, ns = ...

-- Prints the money that the player gains from the mail. At MAIL_SHOW it stores the money of the player. When
-- the money changes while the mailbox is open (PLAYER_MONEY), it waits a short time, then it reads the money
-- again and prints one chat line with the gain of the batch. At MAIL_CLOSED it does the same for the rest.
-- The wait lets the server send late money and joins many takes into one line. It does not use the ledger.
local MailTotal = {}
ns.MailTotal = MailTotal

local OWNER = "Flipside.MailTotal"

-- The wait after the last change or after the close (seconds).
MailTotal.WAIT = 0.5

-- deps: bus, money() -> copper, print(text), format(copper) -> text, after(seconds, fn),
-- enabled() (optional, false turns the line off) and log(fmt, ...) (optional). Returns { Start }.
function MailTotal.Attach(deps)
    local start = nil
    local open = false
    local closing = false
    local pending = false
    local generation = 0
    local state = {}

    function state.Start()
        return start
    end

    -- Print the gain since the stored money, then store the money again. After a close the count ends.
    local function report()
        pending = false
        generation = generation + 1
        local before = start
        local now = deps.money()
        if closing then
            open, closing, start = false, false, nil
        elseif type(now) == "number" then
            start = now
        end
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
        deps.print(string.format("Gold collected: %s", deps.format(delta)))
    end

    local function schedule()
        pending = true
        generation = generation + 1
        local mine = generation
        deps.after(MailTotal.WAIT, function()
            if mine == generation and pending then
                report()
            end
        end)
    end

    deps.bus:Subscribe("MAIL_SHOW", OWNER, function()
        if closing and pending then
            report()
        end
        if not open then
            open = true
            closing = false
            start = deps.money()
        end
    end)
    deps.bus:Subscribe("PLAYER_MONEY", OWNER, function()
        if open and not closing then
            schedule()
        end
    end)
    deps.bus:Subscribe("MAIL_CLOSED", OWNER, function()
        if not open or closing then
            return
        end
        closing = true
        schedule()
    end)
    return state
end
