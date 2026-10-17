local _, ns = ...

-- The host of the mailing panel. It shows the panel beside Blizzard's MailFrame on MAIL_SHOW and hides it on
-- MAIL_CLOSED. Both clients have a MailFrame global, so one host serves both flavours. It reads the frame only.
local MailHost = {}
ns.MailHost = MailHost

local OWNER = "Flipside.MailHost"
local OFFSET_X, OFFSET_Y = -2, -12

-- deps: bus, create(parent) (returns a MailingPanel), after(seconds, fn), frame() (returns the MailFrame or nil).
-- Returns an object with Panel(), the panel or nil.
function MailHost.Attach(deps)
    local host = { panel = nil }

    local function show(retry)
        local mailFrame = deps.frame()
        if not mailFrame then
            -- The client can load its mail frame after this event handler runs.
            if retry then
                deps.after(0, function()
                    show(false)
                end)
            end
            return
        end
        if not host.panel then
            host.panel = deps.create(mailFrame)
            host.panel.frame:SetPoint("TOPLEFT", mailFrame, "TOPRIGHT", OFFSET_X, OFFSET_Y)
        end
        host.panel:Show()
        host.panel:Refresh()
    end

    deps.bus:Subscribe("MAIL_SHOW", OWNER, function()
        show(true)
    end)
    deps.bus:Subscribe("MAIL_CLOSED", OWNER, function()
        if host.panel then
            host.panel:Hide()
        end
    end)
    -- The bags changed: read the plan again, but not while a run changes the bags.
    deps.bus:Subscribe("BAG_UPDATE_DELAYED", OWNER, function()
        local panel = host.panel
        if panel and panel.frame:IsShown() and not panel.run:IsRunning() then
            panel:Refresh()
        end
    end)

    function host.Panel()
        return host.panel
    end
    return host
end
