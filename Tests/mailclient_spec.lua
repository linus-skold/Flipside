local manifest = require("Tests.manifest")

describe("MailClient", function()
    local ns, api, calls, held, bags

    local function load(name)
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end

    local function client(sendArgs)
        api.sendArgs = sendArgs
        return ns.MailClient.New(api)
    end

    before_each(function()
        ns = { Flavour = {} }
        load("MailClient")
        calls, held, bags = {}, {}, {
            [0] = {
                { hyperlink = "link:A", stackCount = 5, isLocked = false, isBound = false, quality = 3 },
                { hyperlink = "link:B", stackCount = 1, isLocked = true, isBound = true },
                false,
                { hyperlink = "link:Q", stackCount = 2 },
            },
        }
        api = {
            bagIDs = function()
                return { 0 }
            end,
            numSlots = function(bag)
                return #bags[bag]
            end,
            itemInfo = function(bag, slot)
                return bags[bag][slot] or nil
            end,
            keyFor = function(link)
                return "key:" .. link
            end,
            itemClass = function(link)
                return link == "link:Q" and 12 or 0
            end,
            clearCursor = function()
                calls[#calls + 1] = { "clearCursor" }
            end,
            pickup = function(bag, slot)
                calls[#calls + 1] = { "pickup", bag, slot }
            end,
            click = function(index, clear)
                calls[#calls + 1] = { "click", index, clear }
                if clear then
                    held[index] = nil
                elseif api.accept ~= false then
                    held[index] = { "Name" .. index, 100 + index, "icon", 3 }
                end
            end,
            getItem = function(index)
                local item = held[index]
                if item then
                    return unpack(item)
                end
            end,
            price = function()
                return 30
            end,
            money = function()
                return 12345
            end,
            sendMail = function(...)
                calls[#calls + 1] = { "sendMail", select("#", ...), ... }
            end,
        }
    end)

    it("reads the bag slots with the lock, bound and quest flags", function()
        local slots = client(3).ReadSlots()
        assert.are.equal(3, #slots)
        assert.are.same({ key = "key:link:A", bag = 0, slot = 1, count = 5, locked = false, soulbound = false,
            quest = false, quality = 3, class = 0 }, slots[1])
        assert.is_true(slots[2].locked)
        assert.is_true(slots[2].soulbound)
        assert.is_true(slots[3].quest)
        assert.are.equal(4, slots[3].slot)
    end)

    it("reads no rarity for a slot that has none", function()
        local slots = client(3).ReadSlots()
        assert.is_nil(slots[2].quality)
        assert.are.equal(0, slots[2].class)
    end)

    it("lists the item classes of the client by name and leaves out obsolete and unnamed ones", function()
        local names = { [0] = "Consumable", [2] = "Weapon", [4] = "Armor", [10] = "", [14] = "Old" }
        local enum = { Consumable = 0, Weapon = 2, Armor = 4, CurrencyTokenObsolete = 10, PermanentObsolete = 14,
            Housing = 20 }
        local list = ns.MailClient.ItemClasses(enum, function(id)
            return names[id]
        end)
        assert.are.same({
            { value = 4, text = "Armor" }, { value = 0, text = "Consumable" }, { value = 2, text = "Weapon" },
        }, list)
        assert.are.same({}, ns.MailClient.ItemClasses(nil, function() end))
    end)

    it("attaches with a pickup and a click, and reads the attachment back", function()
        local c = client(3)
        assert.is_true(c.Attach(0, 1, 2))
        assert.are.same({ "pickup", 0, 1 }, calls[2])
        assert.are.same({ "click", 2 }, calls[3])
        assert.are.same({ index = 2, name = "Name2", itemID = 102, count = 3 }, c.Attachment(2))
        assert.are.equal(1, #c.Attachments())
    end)

    it("clears the cursor when the click attaches nothing", function()
        api.accept = false
        local c = client(3)
        assert.is_false(c.Attach(0, 1, 1))
        assert.are.same({ "clearCursor" }, calls[#calls])
    end)

    it("clears one attachment or all with the clear flag of the click", function()
        local c = client(3)
        c.Attach(0, 1, 1)
        c.Attach(0, 1, 2)
        c.ClearSlot(1)
        assert.is_nil(c.Attachment(1))
        assert.is_not_nil(c.Attachment(2))
        c.ClearAll()
        assert.are.equal(0, #c.Attachments())
        assert.are.same({ "click", 2, true }, calls[#calls])
    end)

    it("passes three arguments to SendMail on TBC", function()
        client(3).Send("Bank", "Subject")
        assert.are.same({ "sendMail", 3, "Bank", "Subject", "" }, calls[#calls])
    end)

    it("passes four arguments to SendMail on Forever", function()
        client(4).Send("Bank", "Subject")
        assert.are.same({ "sendMail", 4, "Bank", "Subject", "" }, calls[#calls])
    end)

    it("reads the postage and the money", function()
        local c = client(3)
        assert.are.equal(30, c.Postage())
        assert.are.equal(12345, c.Money())
    end)

    it("takes the argument count of SendMail from the flavour", function()
        ns.Flavour.sendMailArgs = 4
        ns.Flavour.bagIDs = api.bagIDs
        _G.C_Container = { GetContainerNumSlots = api.numSlots, GetContainerItemInfo = api.itemInfo,
            PickupContainerItem = api.pickup }
        _G.C_Item = { GetItemInfoInstant = function() end }
        local defaults = ns.MailClient.Default()
        _G.C_Container, _G.C_Item = nil, nil
        assert.are.equal(4, defaults.sendArgs)
    end)
end)
