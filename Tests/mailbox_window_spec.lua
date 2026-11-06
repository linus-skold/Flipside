local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local MODULES = { "Theme", "Window", "Widgets", "Tabs", "EventBus", "MailboxWindow", "MailHost" }

describe("MailboxWindow and the Forever layouts of MailHost", function()
    local ns, bus, mailFrame, inbox, send, openMail, db, host, closeCalls, created, lists

    local function fakeDb()
        local values = {}
        return {
            values = values,
            Get = function(_, scope, key)
                return values[scope .. "/" .. key]
            end,
            Set = function(_, scope, key, value)
                values[scope .. "/" .. key] = value
                return true
            end,
        }
    end

    local function makeView(parent)
        local view = { frame = CreateFrame("Frame", nil, parent), refreshes = 0, run = { IsRunning = function()
            return false
        end } }
        function view:Show()
            self.frame:Show()
        end
        function view:Hide()
            self.frame:Hide()
        end
        function view:Refresh()
            self.refreshes = self.refreshes + 1
        end
        function view.AlignBar() end
        created[#created + 1] = view
        return view
    end

    local function stretched(name)
        local frame = CreateFrame("Frame", name, mailFrame)
        frame:SetPoint("TOPLEFT", mailFrame, "TOPLEFT")
        frame:SetPoint("BOTTOMRIGHT", mailFrame, "BOTTOMRIGHT")
        return frame
    end

    -- The wiring of Init.lua for Forever: the mode comes from the setting, a click on a button sets it.
    local function attach(forever)
        local deps = {
            bus = bus,
            frame = function()
                return mailFrame
            end,
            openMail = function()
                return openMail
            end,
            children = function()
                return { inbox, send }
            end,
            create = makeView,
            createInbox = function(_, page)
                local list = { frame = CreateFrame("Frame", nil, page or mailFrame), page = page }
                list.frame:Hide()
                function list.Show(self)
                    self.frame:Show()
                end
                function list.Hide(self)
                    self.frame:Hide()
                end
                function list.Refresh() end
                lists[#lists + 1] = list
                return list
            end,
            after = function() end,
        }
        if forever then
            local function setOn(on)
                ns.MailboxWindow.SetOn(db, on)
                host.Switch()
            end
            deps.mode = function()
                return ns.MailboxWindow.IsOn(db) and "window" or "plain"
            end
            deps.createToggle = function(frame)
                return ns.MailboxWindow.CreateToggle(frame, function()
                    setOn(true)
                end)
            end
            deps.createWindow = function()
                return ns.MailboxWindow.Create({
                    onToggle = function()
                        setOn(false)
                    end,
                    closeMail = function()
                        closeCalls = closeCalls + 1
                    end,
                })
            end
        end
        host = ns.MailHost.Attach(deps)
    end

    local function windowFrames()
        local list = {}
        for _, frame in ipairs(mock.frames) do
            if frame.name == "FlipsideMailboxWindow" then
                list[#list + 1] = frame
            end
        end
        return list
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
        bus = ns.EventBus.New()
        db, closeCalls, created, lists = fakeDb(), 0, {}, {}
        mailFrame = CreateFrame("Frame", "MailFrame", UIParent)
        mailFrame:SetSize(338, 424)
        inbox, send = stretched("InboxFrame"), stretched("SendMailFrame")
        openMail = CreateFrame("Frame", "OpenMailFrame", UIParent)
        openMail:SetPoint("TOPLEFT", mailFrame, "TOPRIGHT", 0, 0)
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("the setting", function()
        it("is on by default and keeps the last choice", function()
            assert.is_true(ns.MailboxWindow.IsOn(db))
            assert.is_true(ns.MailboxWindow.SetOn(db, false))
            assert.is_false(ns.MailboxWindow.IsOn(db))
            assert.are.equal(false, db.values["account/mail.window"])
            ns.MailboxWindow.SetOn(db, true)
            assert.is_true(ns.MailboxWindow.IsOn(db))
        end)
    end)

    describe("with the Flipside window", function()
        before_each(function()
            attach(true)
            bus:Emit("MAIL_SHOW")
        end)

        it("covers MailFrame, which stays shown and keeps its size", function()
            local frames = windowFrames()
            assert.are.equal(1, #frames)
            local window = frames[1]
            assert.is_true(window:IsShown())
            assert.is_true(mailFrame:IsShown())
            assert.are.equal(338, mailFrame:GetWidth())
            local point, relative = window:GetPoint(1)
            assert.are.same({ "TOPLEFT", mailFrame }, { point, relative })
            assert.is_true(window:GetWidth() >= mailFrame:GetWidth())
            assert.is_true(window:GetHeight() >= mailFrame:GetHeight())
            assert.are.equal("HIGH", window.strata)
            assert.is_true(window.mouse, "the window takes the mouse, so clicks do not reach MailFrame")
            assert.is_false(window.movable, "the user cannot drag the window away from MailFrame")
        end)

        it("puts the view in the rules page and the inbox list in the inbox page", function()
            local pages = host.window.pages
            assert.are.equal(pages.rules, created[1].frame.parent)
            assert.are.equal(pages.rules, created[1].frame.allPoints)
            assert.are.equal(pages.inbox, lists[1].page)
            assert.is_true(lists[1].frame:IsShown())
            assert.are.equal(1, created[1].refreshes)
            assert.is_not_nil(pages.send)
        end)

        it("leaves the child frames of MailFrame as they are", function()
            assert.are.equal(2, inbox:GetNumPoints())
            assert.are.equal("BOTTOMRIGHT", (inbox:GetPoint(2)))
        end)

        it("hides the Blizzard toggle and moves the open-mail frame beside the window, above it", function()
            assert.is_false(host.toggle:IsShown())
            local _, relative, relativePoint = openMail:GetPoint(1)
            assert.are.same({ host.window.frame, "TOPRIGHT" }, { relative, relativePoint })
            assert.are.equal("DIALOG", openMail.strata)
        end)

        it("hides on MAIL_CLOSED and does not end the session again", function()
            bus:Emit("MAIL_CLOSED")
            assert.is_false(host.window.frame:IsShown())
            assert.is_false(lists[1].frame:IsShown())
            assert.are.equal(0, closeCalls)
            local _, relative, relativePoint = openMail:GetPoint(1)
            assert.are.same({ mailFrame, "TOPRIGHT" }, { relative, relativePoint })
            assert.are.equal("MEDIUM", openMail.strata)
            bus:Emit("MAIL_SHOW")
            assert.is_true(host.window.frame:IsShown())
            assert.are.equal(1, #windowFrames(), "the window is made once")
            assert.are.equal(1, #created, "the view is made once")
        end)

        it("hides when MailFrame hides (ESC or walking away)", function()
            mailFrame:Hide()
            assert.is_false(host.window.frame:IsShown())
            assert.are.equal(0, closeCalls)
        end)

        it("ends the mail session when the user closes the window", function()
            host.window.frame:Hide()
            assert.are.equal(1, closeCalls)
        end)

        it("switches to the Blizzard mailbox with its button, with no new MAIL_SHOW", function()
            click(host.window.toggle)
            assert.is_false(ns.MailboxWindow.IsOn(db))
            assert.is_false(host.window.frame:IsShown())
            assert.is_false(lists[1].frame:IsShown())
            assert.is_true(host.toggle:IsShown())
            assert.is_true(mailFrame:IsShown())
            assert.are.equal(0, closeCalls)
            assert.are.equal(338, mailFrame:GetWidth())
            assert.are.equal("MEDIUM", openMail.strata)
        end)

        it("switches back to the window with the button on MailFrame", function()
            click(host.window.toggle)
            click(host.toggle)
            assert.is_true(ns.MailboxWindow.IsOn(db))
            assert.is_true(host.window.frame:IsShown())
            assert.is_true(lists[1].frame:IsShown())
            assert.is_false(host.toggle:IsShown())
            assert.are.equal(1, #windowFrames())
            assert.are.equal(1, #created)
            assert.are.equal(2, created[1].refreshes, "the view reads the plan again when it shows")
        end)
    end)

    describe("with the Blizzard mailbox", function()
        before_each(function()
            ns.MailboxWindow.SetOn(db, false)
            attach(true)
            bus:Emit("MAIL_SHOW")
        end)

        it("is the plain MailFrame: no window, no view, no inbox list, no change of size or anchors", function()
            assert.are.equal(0, #windowFrames())
            assert.are.equal(0, #created)
            assert.are.equal(0, #lists)
            assert.are.equal(338, mailFrame:GetWidth())
            assert.are.equal(2, inbox:GetNumPoints())
            assert.are.equal("BOTTOMRIGHT", (inbox:GetPoint(2)))
            assert.are.equal(mailFrame, (select(2, openMail:GetPoint(1))))
            assert.are.equal("MEDIUM", openMail.strata)
        end)

        it("shows only the toggle button, which opens the window", function()
            assert.is_true(host.toggle:IsShown())
            assert.are.equal(mailFrame, host.toggle.parent)
            click(host.toggle)
            assert.is_true(host.window.frame:IsShown())
            assert.is_false(host.toggle:IsShown())
            assert.are.equal(1, #created)
        end)

        it("hides the toggle on MAIL_CLOSED", function()
            bus:Emit("MAIL_CLOSED")
            assert.is_false(host.toggle:IsShown())
        end)

        it("does nothing on Switch when the mailbox is closed", function()
            bus:Emit("MAIL_CLOSED")
            ns.MailboxWindow.SetOn(db, true)
            host.Switch()
            assert.are.equal(0, #windowFrames())
        end)
    end)

    describe("on TBC (no mode)", function()
        it("keeps the wide layout: no window and no toggle", function()
            attach(false)
            bus:Emit("MAIL_SHOW")
            assert.are.equal(0, #windowFrames())
            assert.is_nil(host.toggle)
            assert.is_true(mailFrame:GetWidth() > 338)
            assert.are.equal(mailFrame, created[1].frame.parent)
            assert.are.equal(mailFrame, lists[1].frame.parent)
            bus:Emit("MAIL_CLOSED")
            assert.are.equal(338, mailFrame:GetWidth())
        end)
    end)
end)
