local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

describe("InboxList", function()
    local ns, list, mails, opened, openID, clientFrames, openMail, failing, shift, looted, free, told

    local function loadModules()
        local env = { Flavour = {} }
        for _, name in ipairs({ "Theme", "Widgets", "List", "InboxList" }) do
            assert(loadfile(manifest.path(name)))("Flipside", env)
        end
        return env
    end

    -- The order of the results of GetInboxHeaderInfo: package icon, stationery icon, sender, subject, money, COD,
    -- days left, item count, was read, was returned, text created, can reply, is GM.
    local function header(index)
        if failing then
            error("no mail")
        end
        local mail = mails[index]
        return mail.package, mail.stationery, mail.sender, mail.subject, mail.money, mail.cod, mail.days,
            mail.items, mail.read, false, false, true, mail.gm
    end

    -- The list rows, in order.
    local function rows()
        local out = {}
        for _, row in ipairs(list.list.rows) do
            if row:IsShown() then
                out[#out + 1] = row
            end
        end
        return out
    end

    before_each(function()
        mock.reset()
        _G.ScrollUtil = nil
        ns = loadModules()
        mails = {
            { package = "pkg1", stationery = "mail1", sender = "Ann", subject = "Ore for you", money = 0, cod = 0,
                days = 29.5, items = 3, read = false },
            { package = nil, stationery = "mail2", sender = "Bob", subject = "Gold", money = 12345, cod = 0,
                days = 3, items = nil, read = true },
            { package = "pkg3", stationery = "mail3", sender = nil, subject = "Pay me", money = 0, cod = 500,
                days = 0.5, items = 1, read = false, gm = true },
        }
        opened, openID, failing, shift, looted, free, told = {}, 0, false, false, {}, 10, {}
        clientFrames = {
            CreateFrame("Frame", "MailItem1", UIParent),
            CreateFrame("Frame", "MailItem2", UIParent),
            CreateFrame("Button", "InboxNextPageButton", UIParent),
        }
        clientFrames[3]:Hide()
        openMail = CreateFrame("Frame", "OpenMailFrame", UIParent)
        local parent = CreateFrame("Frame", "InboxFrame", UIParent)
        list = ns.InboxList.Create(parent, {
            api = {
                numItems = function()
                    return #mails, #mails
                end,
                header = header,
                openID = function()
                    return openID
                end,
                isModified = function()
                    return shift
                end,
                autoLoot = function(index)
                    looted[#looted + 1] = index
                end,
                freeSlots = function()
                    return free
                end,
                open = function(index)
                    opened[#opened + 1] = index
                    openID = openID == index and 0 or index
                end,
            },
            formatMoney = function(copper)
                return copper .. "c"
            end,
            notify = function(text)
                told[#told + 1] = text
            end,
            blizzard = function()
                return clientFrames
            end,
            openMail = function()
                return openMail
            end,
            place = function(frame)
                frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 13, -70)
            end,
        })
        list:Show()
    end)

    after_each(function()
        mock.teardown()
    end)

    it("shows one row for each mail, all in one list", function()
        assert.are.equal(3, #rows())
        assert.are.equal(3, #list.list:GetData())
    end)

    it("uses the row height of the Ledger list", function()
        assert.are.equal(18, rows()[1].height)
    end)

    it("is placed by the host function", function()
        assert.are.equal("TOPLEFT", list.frame.points[1][1])
    end)

    it("draws sender, subject, attachments, money and days left from the header", function()
        local first, second, third = rows()[1], rows()[2], rows()[3]
        assert.are.equal("Ann", first.sender:GetText())
        assert.are.equal("Ore for you", first.subject:GetText())
        assert.are.equal("x3", first.extra:GetText())
        assert.are.equal("|cff40ff40" .. "29d|r", first.days:GetText())
        assert.are.equal("pkg1", first.icon.texture)
        assert.are.equal("12345c", second.extra:GetText())
        assert.are.equal("mail2", second.icon.texture, "a mail with no package shows the stationery icon")
        assert.are.equal("Unknown", third.sender:GetText())
        assert.are.equal("x1 |cffff4040COD 500c|r", third.extra:GetText())
        assert.are.equal("|cffff4040" .. "12h|r", third.days:GetText())
        assert.are.equal("mail3", third.icon.texture, "a GM mail shows the stationery icon")
    end)

    it("shows unread mail in colour and read mail in grey", function()
        local unread, read = rows()[1].sender.color, rows()[2].sender.color
        assert.are.same({ 1, 0.82, 0 }, { unread[1], unread[2], unread[3] })
        assert.are.same({ 0.75, 0.75, 0.75 }, { read[1], read[2], read[3] })
    end)

    it("opens the mail of a row on a click and marks the open mail", function()
        local row = rows()[2]
        row.scripts.OnClick(row)
        assert.are.same({ 2 }, opened)
        assert.is_true(rows()[2].selection:IsShown())
        assert.is_false(rows()[1].selection:IsShown())
    end)

    it("opens the mail and takes all its contents on a Shift-click", function()
        shift = true
        local row = rows()[1]
        row.scripts.OnClick(row)
        assert.are.same({ 1 }, looted)
        assert.are.same({ 1 }, opened)
    end)

    it("takes a mail with only money on a Shift-click even when the bags are full", function()
        shift, free = true, 0
        local row = rows()[2]
        row.scripts.OnClick(row)
        assert.are.same({ 2 }, looted)
    end)

    it("skips a COD mail on a Shift-click, opens it, and never pays", function()
        shift = true
        local row = rows()[3]
        row.scripts.OnClick(row)
        assert.are.same({}, looted)
        assert.are.same({ 3 }, opened)
        assert.are.same({ "COD mail skipped: Shift-click never pays" }, told)
    end)

    it("stops the take when the bags are full", function()
        shift, free = true, 0
        local row = rows()[1]
        row.scripts.OnClick(row)
        assert.are.same({}, looted)
        assert.are.same({ "Bags are full" }, told)
        assert.are.same({ 1 }, opened)
    end)

    it("logs each step of a take to the mail log", function()
        local logged = {}
        ns.Log = { Write = function(category, level, text)
            logged[#logged + 1] = { category, level, text }
        end }
        shift = true
        rows()[1].scripts.OnClick(rows()[1])
        free = 0
        rows()[1].scripts.OnClick(rows()[1])
        assert.are.equal("mail", logged[1][1])
        assert.is_truthy(logged[1][3]:find("take all from mail 1", 1, true))
        assert.is_truthy(logged[2][3]:find("bags are full", 1, true))
    end)

    it("does not take anything on a normal click", function()
        local row = rows()[1]
        row.scripts.OnClick(row)
        assert.are.same({}, looted)
        assert.are.same({ 1 }, opened)
    end)

    it("closes the open mail on a second click, as the client does", function()
        local row = rows()[1]
        row.scripts.OnClick(row)
        row = rows()[1]
        row.scripts.OnClick(row)
        assert.are.same({ 1, 1 }, opened)
        assert.is_false(rows()[1].selection:IsShown())
    end)

    it("shows the tooltip of a mail", function()
        local row = rows()[3]
        row.scripts.OnEnter(row)
        assert.are.equal("Pay me", mock.tooltip.title)
        assert.are.same({ "From: Unknown", "Attachments: 1", "COD: 500c" }, mock.tooltip.lines)
        row.scripts.OnLeave(row)
        assert.is_false(mock.tooltip.shown)
    end)

    it("hides the client mail buttons and page buttons while it shows", function()
        assert.is_false(clientFrames[1]:IsShown())
        assert.is_false(clientFrames[2]:IsShown())
        assert.is_false(clientFrames[3]:IsShown())
        assert.is_true(list.frame:IsShown())
    end)

    it("puts the client frames back as they were when it hides", function()
        list:Hide()
        assert.is_false(list.frame:IsShown())
        assert.is_true(clientFrames[1]:IsShown())
        assert.is_true(clientFrames[2]:IsShown())
        assert.is_false(clientFrames[3]:IsShown(), "a frame that was hidden stays hidden")
    end)

    it("keeps the first state of the client frames when it shows twice", function()
        list:Show()
        list:Hide()
        assert.is_true(clientFrames[1]:IsShown())
        assert.is_false(clientFrames[3]:IsShown())
    end)

    it("reads the mails again on Refresh", function()
        mails[#mails + 1] = { stationery = "mail4", sender = "Cy", subject = "New", money = 0, cod = 0, days = 2,
            items = nil, read = false }
        list:Refresh()
        assert.are.equal(4, #rows())
        mails[#mails] = nil
        list:Refresh()
        assert.are.equal(3, #list.list:GetData())
    end)

    it("draws the selection again when the open-mail frame hides", function()
        openID = 3
        assert.is_false(rows()[3].selection:IsShown())
        openMail:Hide()
        assert.is_true(rows()[3].selection:IsShown())
    end)

    it("leaves the client buttons alone when the list cannot read the mails", function()
        list:Hide()
        failing = true
        list:Show()
        assert.is_false(list.frame:IsShown())
        assert.is_true(clientFrames[1]:IsShown())
        assert.is_true(clientFrames[2]:IsShown())
    end)

    it("formats the days left", function()
        assert.are.equal("|cff40ff40" .. "5d|r", ns.InboxList.DaysText(5.9))
        assert.are.equal("|cffff4040" .. "1h|r", ns.InboxList.DaysText(0.01))
        assert.are.equal("|cffff4040" .. "12h|r", ns.InboxList.DaysText(0.5))
    end)
end)
