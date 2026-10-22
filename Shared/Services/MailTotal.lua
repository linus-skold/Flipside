local _, ns = ...

-- Prints the money that the player gained from the mail between MAIL_SHOW and MAIL_CLOSED, as one chat line
-- after the close. At MAIL_SHOW it stores the money of the player (a second MAIL_SHOW while the mailbox is open
-- keeps the first value). At MAIL_CLOSED it waits a short time, because the server can send the money late.
-- A PLAYER_MONEY event during the wait starts the wait again, up to MAX_EXTENSIONS times. Then it reads the money
-- again and prints the difference. A second MAIL_CLOSED does nothing. It does not use the ledger.
local MailTotal = {}
ns.MailTotal = MailTotal

local OWNER = "Flipside.MailTotal"

-- The wait after the close (seconds).
MailTotal.WAIT = 0.5

-- The most times that late money can start the wait again.
MailTotal.MAX_EXTENSIONS = 10

-- deps: bus, money() -> copper, print(text), format(copper) -> text, after(seconds, fn),
-- enabled() (optional, false turns the line off) and log(fmt, ...) (optional). Returns { Start }.
function MailTotal.Attach(deps)
    local start = nil
    local closing = false
    local extensions = 0
    local generation = 0
    local state = {}

    function state.Start()
        return start
    end

    -- Print the gain since MAIL_SHOW and end the count.
    local function finish()
        closing = false
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
        deps.print(string.format("Gold collected: %s", deps.format(delta)))
    end

    local function wait()
        generation = generation + 1
        local mine = generation
        deps.after(MailTotal.WAIT, function()
            if mine == generation and closing then
                finish()
            end
        end)
    end

    deps.bus:Subscribe("MAIL_SHOW", OWNER, function()
        if closing then
            finish()
        end
        if start == nil then
            start = deps.money()
        end
    end)
    deps.bus:Subscribe("PLAYER_MONEY", OWNER, function()
        if closing and extensions < MailTotal.MAX_EXTENSIONS then
            extensions = extensions + 1
            wait()
        end
    end)
    deps.bus:Subscribe("MAIL_CLOSED", OWNER, function()
        if start == nil or closing then
            return
        end
        closing = true
        extensions = 0
        wait()
    end)
    return state
end
