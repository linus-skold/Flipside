local _, ns = ...

-- Writes the postage of each sent mail to the ledger as an expense (SPEC 5.5). The ledger has no record type for the
-- items of a mail, so only the postage is recorded. The recipient is the counterparty.
local MailingLedger = {}
ns.MailingLedger = MailingLedger

-- deps: buffer (LedgerBuffer), tracker (LedgerMoney, optional), character() and serverTime().
-- Returns { Sending = fn, Sent = fn }. Call Sending(info) before the send call and Sent(info) after MAIL_SEND_SUCCESS.
-- info is { recipient, postage }. Sent returns true if it wrote a record.
function MailingLedger.New(deps)
    local ledger = {}

    -- The postage leaves the gold at the send call. The money tracker must not write a record for that change.
    function ledger.Sending(info)
        local postage = tonumber(info and info.postage) or 0
        if postage > 0 and deps.tracker then
            deps.tracker:Claim(postage, "out")
        end
    end

    function ledger.Sent(info)
        local postage = tonumber(info and info.postage) or 0
        local char = deps.character()
        if postage <= 0 or not char then
            return false
        end
        local ok = deps.buffer:Add({
            time = deps.serverTime(), char = char, type = "expense", source = "mailPostage",
            money = postage, counterparty = info.recipient,
        })
        return ok == true
    end

    return ledger
end
