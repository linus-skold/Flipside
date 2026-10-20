local _, ns = ...

-- Reads bags, bank, mail and own auctions into the holdings when the client events say they changed.

local InventoryCapture = {}
ns.InventoryCapture = InventoryCapture

local DEBOUNCE_SECONDS = 0.5
local OWNER = "Flipside.InventoryCapture"

-- deps: bus, holdings, holdingsRead, api, resolver, after, report.
-- Optional deps: ownedEvent (default: Forever name), bagIDs and bankIDs (lists of container ids).
-- api: { container = { numSlots, itemInfo }, mail = { numItems, itemLink, itemInfo }, auctions = { owned } }.
function InventoryCapture.Attach(deps)
    local capture = { bankOpen = false }
    local api = deps.api or {}
    local reported = {}
    local pending = {}

    local function report(kind, message)
        if reported[kind] or not deps.report then
            return
        end
        reported[kind] = true
        deps.report("inventory " .. kind .. " failed: " .. tostring(message))
    end

    -- Read one location and save it. Returns true if the read and the save had no error.
    local function read(kind, location, reader, readerApi, ...)
        if not readerApi then
            return false
        end
        local ok, items, stats = pcall(reader, readerApi, deps.resolver, ...)
        if not ok then
            report(kind, items)
            return false
        end
        local clean = true
        if stats and stats.errors and stats.errors > 0 then
            clean = false
            report(kind, stats.errors .. " client calls failed")
        end
        local okSet, err = pcall(deps.holdings.SetLocation, deps.holdings, location, items)
        if not okSet then
            report(kind, err)
            return false
        end
        return clean
    end

    -- A cheap text of the inbox headers: the count, and for each mail the sender, subject, money and item count.
    -- Returns nil if the client gives no header function or a call fails.
    local function mailSignature()
        local mailApi = api.mail
        if not (mailApi and mailApi.header) then
            return nil
        end
        local okNum, count = pcall(mailApi.numItems)
        if not okNum then
            return nil
        end
        count = tonumber(count) or 0
        local parts = { count }
        for index = 1, count do
            local okHeader, _, _, sender, subject, money, _, _, itemCount = pcall(mailApi.header, index)
            if not okHeader or (sender == nil and subject == nil) then
                return nil
            end
            parts[#parts + 1] = table.concat({ tostring(sender), tostring(subject), tostring(money),
                tostring(itemCount) }, "\31")
        end
        return table.concat(parts, "\30")
    end

    function capture.ReadBags()
        read("bags", "bags", deps.holdingsRead.Bags, api.container, deps.bagIDs)
    end

    function capture.ReadBank()
        read("bank", "bank", deps.holdingsRead.Bank, api.container,
            deps.bankIDs or deps.holdingsRead.BANK_BAGS)
    end

    -- Skips the attachment read and the save if the inbox headers are the same as at the last clean read.
    function capture.ReadMail()
        local signature = mailSignature()
        if signature and signature == capture.mailSignature then
            return
        end
        capture.mailSignature = nil
        if read("mail", "mail", deps.holdingsRead.Mail, api.mail) then
            capture.mailSignature = signature
        end
    end

    function capture.ReadAuctions()
        read("auctions", "auctions", deps.holdingsRead.Auctions, api.auctions)
    end

    -- Run the read once after the delay, however many events come in the meantime.
    local function schedule(kind, fn)
        if pending[kind] then
            return
        end
        pending[kind] = true
        deps.after(DEBOUNCE_SECONDS, function()
            pending[kind] = false
            fn()
        end)
    end

    local function readBagsAndOpenBank()
        capture.ReadBags()
        if capture.bankOpen then
            capture.ReadBank()
        end
    end

    deps.bus:Subscribe("BAG_UPDATE_DELAYED", OWNER, function()
        schedule("bags", readBagsAndOpenBank)
    end)
    deps.bus:Subscribe("BANKFRAME_OPENED", OWNER, function()
        capture.bankOpen = true
        capture.ReadBank()
    end)
    deps.bus:Subscribe("BANKFRAME_CLOSED", OWNER, function()
        capture.bankOpen = false
    end)
    deps.bus:Subscribe("PLAYERBANKSLOTS_CHANGED", OWNER, function()
        if capture.bankOpen then
            schedule("bank", function()
                if capture.bankOpen then
                    capture.ReadBank()
                end
            end)
        end
    end)
    deps.bus:Subscribe("MAIL_INBOX_UPDATE", OWNER, function()
        schedule("mail", function()
            capture.ReadMail()
        end)
    end)
    deps.bus:Subscribe(deps.ownedEvent or "OWNED_AUCTIONS_UPDATED", OWNER, function()
        schedule("auctions", function()
            capture.ReadAuctions()
        end)
    end)

    schedule("bags", readBagsAndOpenBank)
    return capture
end
