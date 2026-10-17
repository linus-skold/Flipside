local _, ns = ...

-- The mail send calls of the client, for both flavours (SPEC 5.5). Every call goes through an api table, so a test
-- can replace the client. MailClient.Default() builds the api from the client globals.
-- The calls and their arguments are the ones that Blizzard's MailFrame.lua uses in both clients
-- (Forever: Blizzard_MailFrame, TBC: Blizzard_UIPanels_Game/Classic): ClickSendMailItemButton(index, clear),
-- GetSendMailItem(index), GetSendMailPrice() and SendMail(name, subject, body[, replyMailID]).
-- Neither client source uses ClearSendMail.
local MailClient = {}
ns.MailClient = MailClient

-- The most attachments of one mail.
MailClient.MAX_ATTACHMENTS = 12

local QUEST_ITEM_CLASS = Enum and Enum.ItemClass and Enum.ItemClass.Questitem or 12

-- Enum.ItemClass names that the list leaves out (by name of the enum, so the language does not matter).
local HIDDEN_CLASSES = { Questitem = true, Key = true, WoWToken = true }

-- Returns the item classes of the client as a list of { value = classID, text = name [, ids = { classID, ... }] },
-- sorted by name. enum is Enum.ItemClass (name -> class id). getName is C_Item.GetItemClassInfo.
-- A class with no name, an obsolete class, and the classes in HIDDEN_CLASSES are left out.
-- Quiver is merged into Container: that entry has ids = { Container id, Quiver id }.
function MailClient.ItemClasses(enum, getName)
    local list = {}
    enum = enum or {}
    local merged = type(enum.Container) == "number" and type(enum.Quiver) == "number"
    for key, id in pairs(enum) do
        if type(id) == "number" and not tostring(key):find("Obsolete", 1, true) and not HIDDEN_CLASSES[key]
            and not (merged and key == "Quiver") then
            local ok, name = pcall(getName, id)
            if ok and type(name) == "string" and name ~= "" and not name:lower():find("obsolete", 1, true) then
                local entry = { value = id, text = name }
                if merged and key == "Container" then
                    entry.ids = { enum.Container, enum.Quiver }
                    table.sort(entry.ids)
                end
                list[#list + 1] = entry
            end
        end
    end
    table.sort(list, function(a, b)
        if a.text ~= b.text then
            return a.text < b.text
        end
        return a.value < b.value
    end)
    return list
end

-- Returns the api table from the client globals. sendArgs is the count of arguments of SendMail (3 or 4).
function MailClient.Default()
    return {
        sendArgs = ns.Flavour and ns.Flavour.sendMailArgs or 3,
        bagIDs = ns.Flavour.bagIDs,
        numSlots = C_Container.GetContainerNumSlots,
        itemInfo = C_Container.GetContainerItemInfo,
        pickup = C_Container.PickupContainerItem,
        itemClass = function(link)
            return select(6, C_Item.GetItemInfoInstant(link))
        end,
        keyFor = function(link)
            return ns.keyFor and ns.keyFor(link) or nil
        end,
        clearCursor = ClearCursor,
        click = ClickSendMailItemButton,
        getItem = GetSendMailItem,
        price = GetSendMailPrice,
        money = GetMoney,
        -- The call looks up SendMail each time, so the post-hook of the ledger (LedgerHooks) always runs.
        sendMail = function(...)
            return SendMail(...)
        end,
    }
end

-- Returns a client object: ReadSlots, Attach, Attachment, Attachments, ClearSlot, ClearAll, Postage, Money, Send.
function MailClient.New(api)
    local client = {}

    -- Returns the bag slots as { key, bag, slot, count, locked, soulbound, quest }. A slot with no key is left out.
    function client.ReadSlots()
        local slots = {}
        for _, bag in ipairs(api.bagIDs()) do
            for slot = 1, api.numSlots(bag) or 0 do
                local info = api.itemInfo(bag, slot)
                if type(info) == "table" and info.hyperlink then
                    local key = api.keyFor(info.hyperlink)
                    if key then
                        local class = api.itemClass(info.hyperlink)
                        slots[#slots + 1] = {
                            key = key, bag = bag, slot = slot, count = tonumber(info.stackCount) or 1,
                            locked = info.isLocked == true, soulbound = info.isBound == true,
                            quest = class == QUEST_ITEM_CLASS, quality = tonumber(info.quality), class = class,
                        }
                    end
                end
            end
        end
        return slots
    end

    -- Puts the item of a bag slot in attachment slot index. Returns true if the slot holds an item after the call.
    function client.Attach(bag, slot, index)
        api.clearCursor()
        api.pickup(bag, slot)
        api.click(index)
        local attached = api.getItem(index) ~= nil
        if not attached then
            api.clearCursor()
        end
        return attached
    end

    -- Returns { index, name, itemID, count } for an attachment slot, or nil if it is empty.
    function client.Attachment(index)
        local name, itemID, _, count = api.getItem(index)
        if not name then
            return nil
        end
        return { index = index, name = name, itemID = itemID, count = tonumber(count) or 1 }
    end

    function client.Attachments()
        local list = {}
        for index = 1, MailClient.MAX_ATTACHMENTS do
            list[#list + 1] = client.Attachment(index)
        end
        return list
    end

    -- Takes one attachment off the mail. The second argument of the click is the clear flag of the right click.
    function client.ClearSlot(index)
        api.click(index, true)
    end

    function client.ClearAll()
        for index = 1, MailClient.MAX_ATTACHMENTS do
            if api.getItem(index) ~= nil then
                api.click(index, true)
            end
        end
    end

    function client.Postage()
        return tonumber(api.price()) or 0
    end

    function client.Money()
        return tonumber(api.money()) or 0
    end

    -- Sends the mail. Forever passes four arguments (the last one is the reply mail id, nil here), TBC passes three.
    function client.Send(recipient, subject)
        if api.sendArgs == 4 then
            api.sendMail(recipient, subject, "", nil)
        else
            api.sendMail(recipient, subject, "")
        end
    end

    return client
end
