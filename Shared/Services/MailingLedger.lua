local _, ns = ...

-- Writes the ledger records of each mail that the player sends (SPEC 5.5, 5.8). The send hook (LedgerHooks) calls
-- OnSendMail right after the SendMail call, while the send form still holds the mail. This is the only writer for
-- both the Blizzard Send tab and the Flipside mailing run. A send gives these records after MAIL_SEND_SUCCESS:
-- one mailPostage expense, one mailMoneySent expense (if gold goes with the mail) and one mailSent row for each
-- attachment. The recipient is the counterparty of all of them.
local MailingLedger = {}
ns.MailingLedger = MailingLedger

local OWNER = "Flipside.MailingLedger"

-- The postage and the sent gold leave the money when the server takes the mail. On Forever a mail to a stranger can
-- wait for a confirm dialog first, so the claim lasts long (seconds).
MailingLedger.CLAIM_SECONDS = 30
-- A send that gets neither MAIL_SEND_SUCCESS nor MAIL_FAILED in this time (seconds) is dropped (a cancelled dialog).
MailingLedger.PENDING_SECONDS = 120
-- The most attachments of one mail.
MailingLedger.MAX_ATTACHMENTS = 12

-- deps: buffer (LedgerBuffer), tracker (LedgerMoney, optional), character(), serverTime(), now() (GetTime),
-- itemKey(itemID) and api { item(index), money(), price() } (the send form reads). bus is optional: with it the
-- module listens to MAIL_SEND_SUCCESS and MAIL_FAILED. Returns { OnSendMail, Sent, Failed, Pending }.
function MailingLedger.New(deps)
    local ledger = {}
    local pending = {}

    local function number(value)
        return type(value) == "number" and value > 0 and value or 0
    end

    -- Read the send form. Every read is in a pcall, so a nil or a failing API gives an empty field.
    local function readForm()
        local api = deps.api
        local items = {}
        for index = 1, MailingLedger.MAX_ATTACHMENTS do
            local ok, name, itemID, _, count = pcall(api.item, index)
            if ok and (name ~= nil or itemID ~= nil) then
                items[#items + 1] = {
                    name = type(name) == "string" and name or nil,
                    itemID = type(itemID) == "number" and itemID or nil,
                    count = type(count) == "number" and count >= 1 and math.floor(count) or 1,
                }
            end
        end
        local okMoney, money = pcall(api.money)
        local okPrice, postage = pcall(api.price)
        return items, okMoney and number(money) or 0, okPrice and number(postage) or 0
    end

    local function expire()
        local now = deps.now()
        local keep = {}
        for _, send in ipairs(pending) do
            if now - send.time > MailingLedger.PENDING_SECONDS then
                if deps.tracker and send.group then
                    deps.tracker:ReleaseClaims(send.group)
                end
            else
                keep[#keep + 1] = send
            end
        end
        pending = keep
    end

    -- Called right after SendMail. Reads the form and claims the money that leaves, so the tracker writes no record.
    function ledger.OnSendMail(recipient)
        expire()
        local items, money, postage = readForm()
        if #items == 0 and money == 0 and postage == 0 then
            return false
        end
        local send = {
            recipient = type(recipient) == "string" and recipient or "", items = items, money = money,
            postage = postage, time = deps.now(),
        }
        if deps.tracker then
            send.group = deps.tracker:ClaimGroup({ postage, money }, "out", MailingLedger.CLAIM_SECONDS)
        end
        pending[#pending + 1] = send
        return true
    end

    local function add(fields)
        local char = deps.character()
        if not char then
            return false
        end
        fields.time, fields.char = deps.serverTime(), char
        local ok = deps.buffer:Add(fields)
        return ok == true
    end

    -- MAIL_SEND_SUCCESS: write the records of the oldest pending send. Returns the number of records.
    function ledger.Sent()
        expire()
        local send = table.remove(pending, 1)
        if not send then
            return 0
        end
        local counterparty = send.recipient ~= "" and send.recipient or nil
        local written = 0
        local function write(fields)
            fields.type, fields.counterparty = "expense", counterparty
            if add(fields) then
                written = written + 1
            end
        end
        if send.postage > 0 then
            write({ source = "mailPostage", money = send.postage })
        end
        if send.money > 0 then
            write({ source = "mailMoneySent", money = send.money })
        end
        for _, item in ipairs(send.items) do
            local key = item.itemID and deps.itemKey(item.itemID) or nil
            write({
                source = "mailSent", money = 0, item = key, itemName = (key == nil) and item.name or nil,
                qty = (key or item.name) and item.count or nil,
            })
        end
        return written
    end

    -- MAIL_FAILED: drop the oldest pending send and release its claims.
    function ledger.Failed()
        expire()
        local send = table.remove(pending, 1)
        if send and deps.tracker and send.group then
            deps.tracker:ReleaseClaims(send.group)
        end
        return send ~= nil
    end

    function ledger.Pending()
        return #pending
    end

    if deps.bus then
        deps.bus:Subscribe("MAIL_SEND_SUCCESS", OWNER, function()
            ledger.Sent()
        end)
        deps.bus:Subscribe("MAIL_FAILED", OWNER, function()
            ledger.Failed()
        end)
    end

    return ledger
end
