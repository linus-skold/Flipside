local _, ns = ...

-- The "take in progress" state of the mailbox. A take (take all, auto-loot, shift-click) makes many MAIL_INBOX_UPDATE
-- and BAG_UPDATE_DELAYED events. While the state is on, the readers of the bags and of the mail holdings wait. When
-- the burst ends, this module emits EVENT_ENDED once and each reader runs its skipped read once.
-- The burst ends after QUIET_SECONDS with no event, or on MAIL_CLOSED.
local MailTake = {}
ns.MailTake = MailTake

local OWNER = "Flipside.MailTake"
MailTake.EVENT_ENDED = "Flipside.MailTakeEnded"
MailTake.QUIET_SECONDS = 0.5

-- deps: bus, after(seconds, fn). Returns { Begin(), IsActive() }.
function MailTake.New(deps)
    local take = { active = false }
    local token = 0

    local function finish()
        if not take.active then
            return
        end
        take.active = false
        deps.bus:Emit(MailTake.EVENT_ENDED)
    end

    -- Start a quiet timer. An older timer does nothing when it fires.
    local function touch()
        token = token + 1
        local mine = token
        deps.after(MailTake.QUIET_SECONDS, function()
            if mine == token then
                finish()
            end
        end)
    end

    function take.Begin()
        take.active = true
        touch()
    end

    function take.IsActive()
        return take.active
    end

    local function onActivity()
        if take.active then
            touch()
        end
    end
    deps.bus:Subscribe("MAIL_INBOX_UPDATE", OWNER, onActivity)
    deps.bus:Subscribe("BAG_UPDATE_DELAYED", OWNER, onActivity)
    deps.bus:Subscribe("MAIL_CLOSED", OWNER, finish)
    return take
end
