local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

describe("MailHost", function()
    local ns, bus, mailFrame, created, timers, delays, refreshes, running, inbox, send, openMail, lists

    local function makeView(parent, size)
        local view = { frame = CreateFrame("Frame", nil, parent), size = size, run = { IsRunning = function()
            return running
        end } }
        function view:Show()
            self.frame:Show()
        end
        function view:Hide()
            self.frame:Hide()
        end
        function view.Refresh()
            refreshes = refreshes + 1
        end
        function view:AlignBar(ref, fallback)
            self.aligned = { ref = ref, fallback = fallback }
        end
        created[#created + 1] = view
        return view
    end

    -- A child frame of the mail frame that stretches with it, as the Forever Inbox and Send frames do.
    local function stretched(name)
        local frame = CreateFrame("Frame", name, mailFrame)
        frame:SetPoint("TOPLEFT", mailFrame, "TOPLEFT")
        frame:SetPoint("BOTTOMRIGHT", mailFrame, "BOTTOMRIGHT")
        return frame
    end

    before_each(function()
        mock.reset()
        ns = {}
        assert(loadfile(manifest.path("EventBus")))("Flipside", ns)
        assert(loadfile(manifest.path("MailHost")))("Flipside", ns)
        bus = ns.EventBus.New()
        created, timers, delays, refreshes, running, lists = {}, {}, {}, 0, false, {}
        mailFrame = CreateFrame("Frame", "MailFrame", UIParent)
        mailFrame:SetSize(384, 512)
        inbox, send = stretched("InboxFrame"), stretched("SendMailFrame")
        openMail = CreateFrame("Frame", "OpenMailFrame", UIParent)
        openMail:SetPoint("TOPLEFT", inbox, "TOPRIGHT")
        ns.MailHost.Attach({
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
            createInbox = function()
                local list = { frame = CreateFrame("Frame", nil, mailFrame), refreshes = 0 }
                list.frame:Hide()
                function list.Show(self)
                    self.frame:Show()
                end
                function list.Hide(self)
                    self.frame:Hide()
                end
                function list.Refresh(self)
                    self.refreshes = self.refreshes + 1
                end
                lists[#lists + 1] = list
                return list
            end,
            after = function(seconds, fn)
                timers[#timers + 1] = fn
                delays[#delays + 1] = seconds
            end,
        })
    end)

    -- Runs the timers that are due now; a timer that a timer makes waits for the next call.
    local function runTimers()
        local due = timers
        timers, delays = {}, {}
        for _, fn in ipairs(due) do
            fn()
        end
    end

    after_each(function()
        mock.teardown()
    end)

    it("widens the mail frame on MAIL_SHOW and puts the view in the new strip", function()
        bus:Emit("MAIL_SHOW")
        assert.is_true(mailFrame:GetWidth() > 384)
        assert.are.equal(1, #created)
        assert.are.equal(mailFrame, created[1].frame.parent)
        assert.is_true(created[1].frame:IsShown())
        assert.are.equal(1, refreshes)
        local first = created[1].frame.points[1]
        assert.are.equal("TOPLEFT", first[1])
        assert.are.equal(mailFrame, first[2])
        assert.are.equal(384, first[4], "the view starts at the old right edge")
    end)

    it("restores the width, the child frames and the view on MAIL_CLOSED", function()
        bus:Emit("MAIL_SHOW")
        assert.are.equal(384, inbox:GetWidth(), "the Inbox frame keeps its width")
        assert.are.equal(2, inbox:GetNumPoints())
        local point1, _, _, _, _ = inbox:GetPoint(1)
        assert.are.equal("TOPLEFT", point1)
        local point2 = inbox:GetPoint(2)
        assert.are.equal("BOTTOMLEFT", point2, "the Inbox frame does not stretch")
        bus:Emit("MAIL_CLOSED")
        assert.are.equal(384, mailFrame:GetWidth())
        assert.is_false(created[1].frame:IsShown())
        for _, frame in ipairs({ inbox, send }) do
            assert.are.equal(0, frame:GetWidth())
            assert.are.equal("TOPLEFT", frame:GetPoint(1))
            assert.are.equal("BOTTOMRIGHT", frame:GetPoint(2))
        end
    end)

    it("moves the open-mail frame to the right edge on show and restores its anchor on close", function()
        bus:Emit("MAIL_SHOW")
        assert.are.equal(1, openMail:GetNumPoints())
        local point, relative, relativePoint, x = openMail:GetPoint(1)
        assert.are.same({ "TOPLEFT", mailFrame, "TOPRIGHT", 46 }, { point, relative, relativePoint, x })
        bus:Emit("MAIL_SHOW")
        bus:Emit("MAIL_CLOSED")
        local p, r, rp = openMail:GetPoint(1)
        assert.are.same({ "TOPLEFT", inbox, "TOPRIGHT" }, { p, r, rp })
    end)

    it("makes the view once and widens again when the mailbox opens again", function()
        bus:Emit("MAIL_SHOW")
        bus:Emit("MAIL_CLOSED")
        bus:Emit("MAIL_SHOW")
        assert.are.equal(1, #created, "the view is made once")
        assert.is_true(mailFrame:GetWidth() > 384)
        assert.is_true(created[1].frame:IsShown())
        bus:Emit("MAIL_SHOW")
        local width = mailFrame:GetWidth()
        bus:Emit("MAIL_CLOSED")
        assert.are.equal(384, mailFrame:GetWidth(), "a second MAIL_SHOW does not widen twice (was " .. width .. ")")
    end)

    it("reads the plan again on a bag update, but not while a run is active", function()
        bus:Emit("MAIL_SHOW")
        bus:Emit("BAG_UPDATE_DELAYED")
        runTimers()
        assert.are.equal(2, refreshes)
        running = true
        bus:Emit("BAG_UPDATE_DELAYED")
        runTimers()
        assert.are.equal(2, refreshes)
    end)

    it("makes one view refresh for many bag updates within 0.2 seconds", function()
        bus:Emit("MAIL_SHOW")
        for _ = 1, 5 do
            bus:Emit("BAG_UPDATE_DELAYED")
        end
        assert.are.equal(1, refreshes, "no refresh before the delay")
        assert.are.equal(1, #timers)
        assert.are.equal(0.2, delays[1])
        runTimers()
        assert.are.equal(2, refreshes)
        runTimers()
        assert.are.equal(2, refreshes)
    end)

    it("does not refresh the hidden view on bag updates, and refreshes it when it shows again", function()
        bus:Emit("MAIL_SHOW")
        created[1].frame:Hide()
        bus:Emit("BAG_UPDATE_DELAYED")
        runTimers()
        assert.are.equal(1, refreshes)
        created[1].frame:Show()
        runTimers()
        assert.are.equal(1, refreshes, "the old timer does not refresh again")
        bus:Emit("MAIL_CLOSED")
        bus:Emit("MAIL_SHOW")
        assert.are.equal(2, refreshes)
    end)

    it("shows the compact inbox list on MAIL_SHOW and hides it on MAIL_CLOSED", function()
        bus:Emit("MAIL_SHOW")
        assert.are.equal(1, #lists)
        assert.is_true(lists[1].frame:IsShown())
        bus:Emit("MAIL_CLOSED")
        assert.is_false(lists[1].frame:IsShown())
        bus:Emit("MAIL_SHOW")
        assert.are.equal(1, #lists, "the list is made once")
        assert.is_true(lists[1].frame:IsShown())
    end)

    it("refreshes the compact inbox list on MAIL_INBOX_UPDATE while the mailbox is open", function()
        bus:Emit("MAIL_INBOX_UPDATE")
        bus:Emit("MAIL_SHOW")
        bus:Emit("MAIL_INBOX_UPDATE")
        runTimers()
        assert.are.equal(1, lists[1].refreshes)
        bus:Emit("MAIL_CLOSED")
        bus:Emit("MAIL_INBOX_UPDATE")
        runTimers()
        assert.are.equal(1, lists[1].refreshes)
    end)

    it("makes one inbox list refresh for many MAIL_INBOX_UPDATE events in one frame", function()
        bus:Emit("MAIL_SHOW")
        for _ = 1, 6 do
            bus:Emit("MAIL_INBOX_UPDATE")
        end
        assert.are.equal(0, lists[1].refreshes)
        assert.are.equal(1, #timers)
        assert.are.equal(0, delays[1])
        runTimers()
        assert.are.equal(1, lists[1].refreshes)
        bus:Emit("MAIL_INBOX_UPDATE")
        runTimers()
        assert.are.equal(2, lists[1].refreshes, "a later event makes a new refresh")
    end)

    it("tries again once when the mail frame does not exist yet", function()
        local frame = mailFrame
        mailFrame = nil
        bus:Emit("MAIL_SHOW")
        assert.are.equal(0, #created)
        mailFrame = frame
        timers[1]()
        assert.are.equal(1, #created)
    end)

    it("aligns the bottom bar of the view with the client button of the tab that shows", function()
        local openAll = CreateFrame("Button", "OpenAllMail", inbox)
        local cancel = CreateFrame("Button", "SendMailCancelButton", send)
        local inboxBar, sendBar = { bottom = 14, height = 24 }, { bottom = 4, height = 22 }
        local bus2 = ns.EventBus.New()
        send:Hide()
        local host = ns.MailHost.Attach({
            bus = bus2,
            frame = function()
                return mailFrame
            end,
            children = function()
                return {}
            end,
            create = makeView,
            tabs = function()
                return {
                    { frame = inbox, ref = openAll, fallback = inboxBar },
                    { frame = send, ref = cancel, fallback = sendBar },
                }
            end,
            after = function() end,
        })
        inbox:Show()
        bus2:Emit("MAIL_SHOW")
        local view = host.View()
        assert.are.equal(2, #host.markers)
        assert.are.equal(openAll, view.aligned.ref, "the Inbox tab shows first: the bar follows Open All")
        assert.are.equal(inboxBar, view.aligned.fallback)
        host.markers[2].scripts.OnShow(host.markers[2])
        assert.are.equal(cancel, view.aligned.ref, "the Send Mail tab shows: the bar follows Cancel")
        assert.are.equal(sendBar, view.aligned.fallback)
        bus2:Emit("MAIL_CLOSED")
        bus2:Emit("MAIL_SHOW")
        assert.are.equal(2, #host.markers, "the markers are made once")
    end)
end)
