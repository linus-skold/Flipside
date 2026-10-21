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

    it("uses a compact row pitch with a gap, a separator and a brown icon slot", function()
        local row = rows()[1]
        assert.are.equal(22, row.height)
        assert.is_not_nil(row.separator.colorTexture)
        assert.are.equal(1, row.separator:GetHeight())
        assert.are.equal(20, row.border:GetWidth())
        assert.are.equal(20, row.border:GetHeight())
        assert.are.equal("Interface\\Buttons\\UI-Slot-Background", row.border.texture)
        assert.is_nil(row.border.vertexColor, "the brown comes from the texture, with no tint")
        assert.are.equal(18, row.icon:GetWidth())
        assert.are.equal(18, row.icon:GetHeight())
        assert.are.same({ 0.07, 0.93, 0.07, 0.93 }, row.icon.texCoord)
        assert.is_true(row.border:IsShown())
    end)

    it("counts the rows that fit in a height", function()
        assert.are.equal(14, ns.InboxList.VisibleRows(312))
        assert.are.equal(14, ns.InboxList.VisibleRows(14 * 22))
        assert.are.equal(0, ns.InboxList.VisibleRows(10))
        assert.are.equal(0, ns.InboxList.VisibleRows(0))
    end)

    describe("empty slots", function()
        local ROWS = 8

        -- The rows that show the empty state.
        local function emptyRows()
            local out = {}
            for _, row in ipairs(rows()) do
                if row.mail == nil then
                    out[#out + 1] = row
                end
            end
            return out
        end

        before_each(function()
            list.frame.height = ROWS * 22 + 2 * 4
        end)

        it("fills the rows below the last mail with empty slots", function()
            list:Refresh()
            assert.are.equal(ROWS, #rows())
            assert.are.equal(ROWS - 3, #emptyRows())
            assert.is_not_nil(rows()[3].mail)
            assert.is_nil(rows()[4].mail)
            assert.is_true(rows()[4].slot:IsShown())
            assert.is_true(rows()[4].bar:IsShown())
            assert.is_false(rows()[1].slot:IsShown())
            assert.is_false(rows()[4].border:IsShown())
            assert.are.equal(20, rows()[4].slot:GetWidth())
            assert.are.equal("Interface\\Buttons\\UI-Slot-Background", rows()[4].slot.texture)
            assert.are.equal(3, #list.mails, "the empty rows are not mails")
        end)

        it("shows all rows as empty slots with no mail", function()
            mails = {}
            list:Refresh()
            assert.are.equal(ROWS, #emptyRows())
        end)

        it("does nothing on a click, a hover or a Shift-click of an empty row", function()
            shift = true
            list:Refresh()
            for _, row in ipairs(emptyRows()) do
                row.scripts.OnClick(row)
                row.scripts.OnEnter(row)
                assert.is_false(row.mouse)
                assert.is_false(row.selection:IsShown())
                assert.are.equal("", row.sender:GetText())
            end
            assert.are.same({}, opened)
            assert.are.same({}, looted)
            assert.is_nil(mock.tooltip.title)
        end)

        it("adds no empty row when the mails fill the list", function()
            for index = 4, 20 do
                mails[index] = { stationery = "m", sender = "S", subject = "x", money = 0, cod = 0, days = 5,
                    items = 0, read = true }
            end
            list:Refresh()
            assert.are.equal(20, #list.list:GetData())
            assert.are.equal(0, #emptyRows())
        end)

        it("draws again when the list height changes", function()
            list.frame.scripts.OnSizeChanged(list.frame)
            assert.are.equal(ROWS - 3, #emptyRows())
        end)
    end)

    describe("Anchor", function()
        local inbox, first, openAll, frame

        before_each(function()
            inbox = CreateFrame("Frame", nil, UIParent)
            inbox:SetSize(340, 424)
            first = CreateFrame("Frame", nil, inbox)
            first:SetSize(305, 45)
            first:SetPoint("TOPLEFT", inbox, "TOPLEFT", 13, -70)
            openAll = CreateFrame("Button", nil, inbox)
            openAll:SetSize(120, 24)
            openAll:SetPoint("CENTER", inbox, "BOTTOM", 0, 26)
            frame = CreateFrame("Frame", nil, inbox)
        end)

        it("fills the area down to the Open All button, with 14 or more rows", function()
            ns.InboxList.Anchor(frame, inbox, first, openAll)
            assert.are.same({ "TOPLEFT", first, "TOPLEFT", 0, 0 }, frame.points[1])
            local corner = frame.points[2]
            assert.are.equal("BOTTOMRIGHT", corner[1])
            assert.are.equal(inbox, corner[2])
            assert.are.equal(13 + 305 - 340, corner[4], "the right edge is the right edge of the client buttons")
            assert.are.equal(26 + 12 + 4, corner[5], "the bottom edge is above Open All")
            local height = 424 - 70 - corner[5]
            assert.is_true(ns.InboxList.VisibleRows(height) >= 14)
        end)

        it("ends at the last client button when there is no Open All button", function()
            local last = CreateFrame("Frame", nil, inbox)
            ns.InboxList.Anchor(frame, inbox, first, nil, last)
            assert.are.same({ "BOTTOMRIGHT", last, "BOTTOMRIGHT", 0, 0 }, frame.points[2])
        end)
    end)

    it("covers the client buttons: a higher frame level and a solid dark brown background", function()
        assert.is_true(list.frame:GetFrameLevel() > list.frame:GetParent():GetFrameLevel())
        assert.is_not_nil(list.cover.colorTexture)
        assert.are.equal(1, list.cover.colorTexture[4])
        assert.is_true(list.cover.colorTexture[1] < 0.25, "the background is dark")
        assert.is_true(list.cover.colorTexture[1] > list.cover.colorTexture[3], "the background is brown")
    end)

    it("scrolls for more mails than rows", function()
        assert.is_not_nil(list.list.rows, "the plain list has one row for each mail")
        for index = 4, 40 do
            mails[index] = { package = "p", stationery = "m", sender = "S" .. index, subject = "x", money = 0,
                cod = 0, days = 5, items = 0, read = true }
        end
        list:Refresh()
        assert.are.equal(40, #list.list:GetData())
    end)
    it("is placed by the host function", function()
        assert.are.equal("TOPLEFT", list.frame.points[1][1])
    end)

    it("draws sender, subject, attachments, money and days left from the header", function()
        local first, second, third = rows()[1], rows()[2], rows()[3]
        assert.are.equal("Ann", first.sender:GetText())
        assert.are.equal("Ore for you", first.subject:GetText())
        assert.are.equal("x3", first.extra:GetText())
        assert.are.equal("|cff20ff20" .. "29 Days|r", first.days:GetText())
        assert.are.equal("pkg1", first.icon.texture)
        assert.are.equal("12345c", second.extra:GetText())
        assert.are.equal("mail2", second.icon.texture, "a mail with no package shows the stationery icon")
        assert.are.equal("Unknown", third.sender:GetText())
        assert.are.equal("x1 |cffff2020COD 500c|r", third.extra:GetText())
        assert.are.equal("|cffff2020" .. "12 Hr|r", third.days:GetText())
        assert.are.equal("mail3", third.icon.texture, "a GM mail shows the stationery icon")
    end)

    it("colours the text as the client inbox does, from the client colour globals", function()
        _G.NORMAL_FONT_COLOR = { r = 0.9, g = 0.7, b = 0.1 }
        _G.HIGHLIGHT_FONT_COLOR = { r = 0.95, g = 0.95, b = 0.9 }
        list:Refresh()
        local unread, subject, read = rows()[1].sender.color, rows()[1].subject.color, rows()[2].sender.color
        assert.are.same({ 0.9, 0.7, 0.1 }, { unread[1], unread[2], unread[3] }, "an unread sender is normal")
        assert.are.same({ 0.95, 0.95, 0.9 }, { subject[1], subject[2], subject[3] }, "an unread subject is white")
        assert.are.same({ 0.75, 0.75, 0.75 }, { read[1], read[2], read[3] }, "a read mail is grey")
        local readSubject = rows()[2].subject.color
        assert.are.same({ 0.75, 0.75, 0.75 }, { readSubject[1], readSubject[2], readSubject[3] })
        _G.NORMAL_FONT_COLOR, _G.HIGHLIGHT_FONT_COLOR = nil, nil
    end)

    it("uses the client colour codes and day formats when they exist", function()
        _G.GREEN_FONT_COLOR_CODE, _G.RED_FONT_COLOR_CODE, _G.FONT_COLOR_CODE_CLOSE = "|cff00aa00", "|cffcc0000", "|r"
        _G.DAYS_ABBR, _G.HOURS_ABBR = "%d Dy", "%d Hrs"
        assert.are.equal("|cff00aa00" .. "5 Dy|r", ns.InboxList.DaysText(5.9))
        assert.are.equal("|cffcc0000" .. "2 Hrs|r", ns.InboxList.DaysText(0.1))
        _G.GREEN_FONT_COLOR_CODE, _G.RED_FONT_COLOR_CODE, _G.FONT_COLOR_CODE_CLOSE = nil, nil, nil
        _G.DAYS_ABBR, _G.HOURS_ABBR = nil, nil
    end)

    it("uses the client fonts for the sender and the other text", function()
        local row = rows()[1]
        assert.are.equal("GameFontNormalSmall", row.sender.fontObject or row.sender.font)
        assert.are.equal("GameFontHighlightSmall", row.subject.fontObject or row.subject.font)
    end)

    describe("sender width", function()
        it("fits the text, up to the maximum", function()
            assert.are.equal(31, ns.InboxList.SenderWidth(30, 0))
            assert.are.equal(130, ns.InboxList.SenderWidth(132, 0), "Alliance Auction House fits in the mock font")
            assert.are.equal(130, ns.InboxList.SenderWidth(400, 0), "a long sender is cut at the maximum")
        end)

        it("shows a common sender in full at the minimum frame width", function()
            assert.are.equal(116, ns.InboxList.SenderWidth(115, 305))
        end)

        it("leaves room for the subject in a narrow row", function()
            local width = ns.InboxList.SenderWidth(400, 200)
            assert.is_true(width < 130)
            -- sender, subject, money and days must fit in the row
            assert.is_true(26 + width + 4 + 40 + 4 + 60 + 4 + 40 + 2 <= 200)
        end)

        it("sets the sender width of a row and gives the rest to the subject", function()
            local row = rows()[1]
            assert.are.equal(#"Ann" * 6 + 1, row.sender:GetWidth())
            assert.are.equal(row.sender, row.subject.points[1][2], "the subject starts after the sender")
            assert.are.equal("RIGHT", row.subject.points[1][3])
            assert.are.equal(row.extra, row.subject.points[2][2], "the subject ends at the money")
        end)
    end)

    it("tints the selection and the hover with a gold glow that shows on a dark row", function()
        local row = rows()[1]
        assert.are.equal(0.2, row.selection.alpha)
        assert.are.equal("ADD", row.selection.blendMode)
        assert.is_false(row.hover:IsShown())
        row.scripts.OnEnter(row)
        assert.is_true(row.hover:IsShown())
        row.scripts.OnLeave(row)
        assert.is_false(row.hover:IsShown())
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

    it("formats the days left: green days from one day, red hours under one day", function()
        assert.are.equal("|cff20ff20" .. "5 Days|r", ns.InboxList.DaysText(5.9))
        assert.are.equal("|cff20ff20" .. "1 Days|r", ns.InboxList.DaysText(1))
        assert.are.equal("|cffff2020" .. "23 Hr|r", ns.InboxList.DaysText(0.99))
        assert.are.equal("|cffff2020" .. "1 Hr|r", ns.InboxList.DaysText(0.01))
        assert.are.equal("|cffff2020" .. "12 Hr|r", ns.InboxList.DaysText(0.5))
    end)
end)
