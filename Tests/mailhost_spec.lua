local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

describe("MailHost", function()
    local ns, bus, mailFrame, created, timers, refreshes, running

    local function makePanel(parent)
        local panel = { frame = CreateFrame("Frame", nil, parent), run = { IsRunning = function()
            return running
        end } }
        function panel:Show()
            self.frame:Show()
        end
        function panel:Hide()
            self.frame:Hide()
        end
        function panel.Refresh()
            refreshes = refreshes + 1
        end
        created[#created + 1] = panel
        return panel
    end

    before_each(function()
        mock.reset()
        ns = {}
        assert(loadfile(manifest.path("EventBus")))("Flipside", ns)
        assert(loadfile(manifest.path("MailHost")))("Flipside", ns)
        bus = ns.EventBus.New()
        created, timers, refreshes, running = {}, {}, 0, false
        mailFrame = CreateFrame("Frame", "MailFrame", UIParent)
        ns.MailHost.Attach({
            bus = bus,
            frame = function()
                return mailFrame
            end,
            create = makePanel,
            after = function(_, fn)
                timers[#timers + 1] = fn
            end,
        })
    end)

    after_each(function()
        mock.teardown()
    end)

    it("shows the panel beside the mail frame on MAIL_SHOW and hides it on MAIL_CLOSED", function()
        bus:Emit("MAIL_SHOW")
        assert.are.equal(1, #created)
        assert.is_true(created[1].frame:IsShown())
        assert.are.equal(1, refreshes)
        bus:Emit("MAIL_CLOSED")
        assert.is_false(created[1].frame:IsShown())
        bus:Emit("MAIL_SHOW")
        assert.are.equal(1, #created, "the panel is made once")
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
