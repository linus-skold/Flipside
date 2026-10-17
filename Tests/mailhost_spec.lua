local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

describe("MailHost", function()
    local ns, bus, mailFrame, created, timers, refreshes, running, inbox, send

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
        created, timers, refreshes, running = {}, {}, 0, false
        mailFrame = CreateFrame("Frame", "MailFrame", UIParent)
        mailFrame:SetSize(384, 512)
        inbox, send = stretched("InboxFrame"), stretched("SendMailFrame")
        ns.MailHost.Attach({
            bus = bus,
            frame = function()
                return mailFrame
            end,
            children = function()
                return { inbox, send }
            end,
            create = makeView,
            after = function(_, fn)
                timers[#timers + 1] = fn
            end,
        })
    end)

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
        assert.are.equal(2, refreshes)
        running = true
        bus:Emit("BAG_UPDATE_DELAYED")
        assert.are.equal(2, refreshes)
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
end)
