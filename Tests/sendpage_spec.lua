local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local MODULES = { "Theme", "Widgets", "MoneyInput", "EventBus", "CharacterName", "MailCompose", "MailContacts",
    "SendPage" }

describe("SendPage wiring", function()
    local ns, page, saved, running, calls

    local function makePage()
        local client = {
            Items = function()
                return {}
            end,
            Item = function() end,
            Postage = function()
                return 0
            end,
            Money = function()
                return 0
            end,
            ClearAll = function()
                calls.clear = calls.clear + 1
            end,
            ResetMoney = function() end,
            SetShowing = function() end,
            Click = function() end,
        }
        return ns.SendPage.Create(CreateFrame("Frame"), {
            client = client,
            bus = ns.EventBus.New(),
            after = function() end,
            characters = function()
                return { "Me-Home", "Alt-Home" }
            end,
            selfName = function()
                return "Me-Home"
            end,
            mailName = function(text)
                return text
            end,
            formatMoney = tostring,
            isRunning = function()
                return running
            end,
            windowShown = function()
                return false
            end,
            clientSendShown = function()
                return false
            end,
            realm = function()
                return "Home"
            end,
            contacts = function()
                return saved
            end,
            saveContacts = function(list)
                saved = list
                return true
            end,
        })
    end

    local function type_(text)
        page.recipient:SetText(text)
        page:Refresh()
    end

    local function click(button)
        button.scripts.OnClick(button)
    end

    before_each(function()
        mock.reset()
        ns = {}
        for _, name in ipairs(MODULES) do
            assert(loadfile(manifest.path(name)))("Flipside", ns)
        end
        saved, running, calls = {}, false, { clear = 0 }
        page = makePage()
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("the clear on a tab switch", function()
        it("clears on the Inbox and Mailing rules tabs only", function()
            page:OnTab("send")
            assert.are.equal(0, calls.clear)
            page:OnTab("inbox")
            page:OnTab("rules")
            assert.are.equal(2, calls.clear)
        end)

        it("empties the fields", function()
            type_("Alt")
            page.subject:SetText("Hello")
            page:OnTab("inbox")
            assert.are.equal("", page.recipient:GetText())
            assert.are.equal("", page.subject:GetText())
        end)

        it("does not clear during a mailing run or while a send is pending", function()
            running = true
            page:OnTab("inbox")
            running = false
            page.pending = true
            page:OnTab("rules")
            assert.are.equal(0, calls.clear)
        end)
    end)

    describe("the Save and Remove buttons", function()
        it("are off with an empty box", function()
            page:Refresh()
            assert.is_false(page.saveContact:IsEnabled())
            assert.is_false(page.removeContact:IsEnabled())
        end)

        it("save a new name, then Save is off and Remove is on", function()
            type_("Zed")
            assert.is_true(page.saveContact:IsEnabled())
            assert.is_false(page.removeContact:IsEnabled())
            click(page.saveContact)
            assert.are.same({ "Zed" }, saved)
            assert.is_false(page.saveContact:IsEnabled())
            assert.is_true(page.removeContact:IsEnabled())
            click(page.removeContact)
            assert.are.same({}, saved)
            assert.is_true(page.saveContact:IsEnabled())
            assert.is_false(page.removeContact:IsEnabled())
        end)

        it("do not save the current character or an own character", function()
            type_("me")
            assert.is_false(page.saveContact:IsEnabled())
            type_("Alt-Home")
            assert.is_false(page.saveContact:IsEnabled())
            click(page.saveContact)
            assert.are.same({}, saved)
        end)

        it("do not save a name over the client limit", function()
            type_(string.rep("a", ns.MailContacts.MAX_NAME + 1))
            assert.is_false(page.saveContact:IsEnabled())
        end)
    end)
end)
