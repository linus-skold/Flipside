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

    it("leaves out Quest, Key, WoW Token and Generic and merges Quiver into Container", function()
        local names = { [0] = "Consumable", [1] = "Container", [8] = "Generic(OBSOLETE)", [11] = "Quiver",
            [12] = "Quest", [13] = "Key", [18] = "WoW Token", [19] = "Profession" }
        local enum = { Consumable = 0, Container = 1, ItemEnhancement = 8, Quiver = 11, Questitem = 12, Key = 13,
            WoWToken = 18, Profession = 19 }
        local list = ns.MailClient.ItemClasses(enum, function(id)
            return names[id]
        end)
        assert.are.same({
            { value = 0, text = "Consumable" }, { value = 1, text = "Container", ids = { 1, 11 } },
            { value = 19, text = "Profession" },
        }, list)
    end)

    it("keeps Quiver as its own entry when the client has no Container", function()
        local list = ns.MailClient.ItemClasses({ Quiver = 11 }, function()
            return "Quiver"
        end)
        assert.are.same({ { value = 11, text = "Quiver" } }, list)
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

    describe("recipient name", function()
        local keys = { "Bank-Realm", "Me-Realm" }

        -- The same wiring as Init: the recipient goes through CharacterName.MailName with the own characters.
        local function wired(flavour)
            ns.Flavour = flavour
            load("CharacterName")
            ns.CharacterName.Setup({
                db = {
                    GetFor = function(_, key, name)
                        return key == "Bank-Realm" and name == "surname" and "Jones" or nil
                    end,
                },
            })
            api.recipientName = function(text)
                return ns.CharacterName.MailName(text, keys)
            end
        end

        it("sends the full name of an own character on Forever", function()
            wired({ usesSurname = true })
            local c = client(4)
            c.Send("Bank Jones", "Subject")
            assert.are.same({ "sendMail", 4, "Bank Jones", "Subject", "" }, calls[#calls])
            c.Send("bank-realm", "Subject")
            assert.are.same({ "sendMail", 4, "Bank Jones", "Subject", "" }, calls[#calls])
            c.Send("Bank", "Subject")
            assert.are.same({ "sendMail", 4, "Bank Jones", "Subject", "" }, calls[#calls])
        end)

        it("does not call SendMail for an own character with no saved surname on Forever", function()
            wired({ usesSurname = true })
            local c = client(4)
            c.Send("Bank", "Subject")
            local before = #calls
            local sent, reason = c.Send("Me", "Subject")
            assert.is_false(sent)
            assert.is_truthy(reason:find("log in to Me once", 1, true))
            assert.are.equal(before, #calls)
        end)

        it("sends a name that is not an own character as it is on Forever", function()
            wired({ usesSurname = true })
            client(4).Send("Stranger Jones", "Subject")
            assert.are.same({ "sendMail", 4, "Stranger Jones", "Subject", "" }, calls[#calls])
        end)

        it("sends the recipient as it is on TBC", function()
            wired({ usesSurname = false })
            local c = client(3)
            c.Send("Bank-Realm", "Subject")
            assert.are.same({ "sendMail", 3, "Bank-Realm", "Subject", "" }, calls[#calls])
            c.Send("bank", "Subject")
            assert.are.same({ "sendMail", 3, "bank", "Subject", "" }, calls[#calls])
        end)
    end)

    describe("for the Send page", function()
        it("reads one slot with its icon and quality, and lists only the filled slots", function()
            held[2] = { "Name2", 102, "icon2", 4, 3 }
            held[5] = { "Name5", 105, "icon5", 1 }
            local c = client(4)
            assert.is_nil(c.Item(1))
            assert.are.same({ index = 2, name = "Name2", itemID = 102, texture = "icon2", count = 4, quality = 3 },
                c.Item(2))
            local items = c.Items()
            assert.are.equal(2, #items)
            assert.are.same({ 2, 5 }, { items[1].index, items[2].index })
        end)

        it("clicks a slot with the clear flag, or with no argument for the cursor item", function()
            local c = client(4)
            c.Click(3, false)
            assert.are.same({ "click", 3, false }, calls[#calls])
            c.Click(3, true)
            assert.are.same({ "click", 3, true }, calls[#calls])
            c.Click()
            assert.are.same({ "click" }, calls[#calls])
        end)

        it("passes the flag of the send page to the client, and nothing if the api has no call", function()
            local shown
            local c = client(4)
            c.SetShowing(true)
            api.setShowing = function(flag)
                shown = flag
            end
            c.SetShowing(1)
            assert.is_true(shown)
            c.SetShowing(nil)
            assert.is_false(shown)
        end)

        it("sends the text and sets the money as the client does: both to 0, then one amount", function()
            local order = {}
            api.setMoney = function(copper)
                order[#order + 1] = { "money", copper }
            end
            api.setCOD = function(copper)
                order[#order + 1] = { "cod", copper }
            end
            local c = client(4)
            assert.is_true(c.Send("Bank", "Subject", "Hello", { money = 500, cod = 0 }))
            assert.are.same({ { "cod", 0 }, { "money", 0 }, { "money", 500 } }, order)
            assert.are.same({ "sendMail", 4, "Bank", "Subject", "Hello" }, calls[#calls])
            order = {}
            c.Send("Bank", "Subject", "Hello", { money = 0, cod = 900 })
            assert.are.same({ { "cod", 0 }, { "money", 0 }, { "cod", 900 } }, order)
            -- A send with no options (the mailing run) still sets both to 0, so no old amount goes with it.
            order = {}
            c.Send("Bank", "Subject", "Hello")
            assert.are.same({ { "cod", 0 }, { "money", 0 } }, order)
        end)

        it("sets money and cash on delivery to 0 with ResetMoney, and does nothing if the api has no setter", function()
            local order = {}
            local c = client(4)
            c.ResetMoney()
            api.setMoney = function(copper)
                order[#order + 1] = { "money", copper }
            end
            api.setCOD = function(copper)
                order[#order + 1] = { "cod", copper }
            end
            c.ResetMoney()
            assert.are.same({ { "cod", 0 }, { "money", 0 } }, order)
        end)

        it("sets no money if the recipient has no full name", function()
            local order = {}
            api.setMoney = function(copper)
                order[#order + 1] = copper
            end
            api.setCOD = api.setMoney
            api.recipientName = function()
                return nil, "no surname"
            end
            local sent, reason = client(4).Send("Me", "Subject", "", { money = 5, cod = 0 })
            assert.is_false(sent)
            assert.are.equal("no surname", reason)
            assert.are.same({}, order)
        end)
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
