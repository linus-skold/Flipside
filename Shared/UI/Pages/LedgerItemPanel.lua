local _, ns = ...

-- The item detail panel of the Ledger page (SPEC 5.8 point 9, "Item detail"). A small Kit window. It only shows
-- numbers that the page gives it. It has no ledger logic.
local LedgerItemPanel = {}
ns.LedgerItemPanel = LedgerItemPanel

local WINDOW_NAME = "FlipsideLedgerItemTotal"
local WIDTH, HEIGHT = 340, 290
local ROWS = {
    { key = "sold", label = "Sold", qty = "soldQty", money = "soldMoney" },
    { key = "bought", label = "Bought", qty = "boughtQty", money = "boughtMoney" },
    { key = "deposits", label = "Deposits lost", money = "deposits" },
    { key = "active", label = "Deposits active", money = "activeDeposits" },
    { key = "cut", label = "AH cut (out of Sold)", money = "cut" },
    { key = "net", label = "Net profit", money = "net" },
}
-- The count line: posted, sold, expired, cancelled. A count that is nil shows a dash.
local COUNTS = {
    { label = "Posted", field = "postedQty" },
    { label = "Sold", field = "soldQty" },
    { label = "Expired", field = "expiredQty" },
    { label = "Cancelled", field = "cancelledQty" },
}
LedgerItemPanel.NO_COUNT = "\226\128\148"

-- Returns the text of the count line of a total.
function LedgerItemPanel.CountsText(total)
    local parts = {}
    for _, count in ipairs(COUNTS) do
        local value = total[count.field]
        parts[#parts + 1] = count.label .. " " .. (value ~= nil and tostring(value) or LedgerItemPanel.NO_COUNT)
    end
    return table.concat(parts, "  ")
end
LedgerItemPanel.NOTE_SUMS = "Older records that the ledger keeps as daily totals are not included."

local window

local function build()
    local Kit = ns.Kit
    local pad = Kit.Theme.padding
    window = Kit.CreateWindow(WINDOW_NAME, { width = WIDTH, height = HEIGHT, title = "Item total", square = true })
    window:SetFrameStrata("DIALOG")
    window:SetToplevel(true)
    window.item = Kit.Label(window, "", "highlight")
    window.item:SetPoint("TOPLEFT", window, "TOPLEFT", pad + 8, -36)
    window.item:SetWidth(WIDTH - 2 * pad - 16)
    window.item:SetJustifyH("LEFT")
    window.scope = Kit.Label(window, "", "small")
    window.scope:SetPoint("TOPLEFT", window.item, "BOTTOMLEFT", 0, -4)
    window.scope:SetWidth(WIDTH - 2 * pad - 16)
    window.scope:SetJustifyH("LEFT")
    window.rows = {}
    local previous = window.scope
    for _, row in ipairs(ROWS) do
        local cells = { label = Kit.Label(window, row.label, row.key == "net" and "highlight" or "normal") }
        cells.label:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -10)
        cells.qty = Kit.Label(window, "", "small")
        cells.qty:SetPoint("LEFT", cells.label, "LEFT", 110, 0)
        cells.money = Kit.Money(window, function(copper)
            return window.formatMoney(copper)
        end)
        cells.money:SetPoint("RIGHT", window, "RIGHT", -(pad + 8), 0)
        cells.money:SetPoint("TOP", cells.label, "TOP", 0, 0)
        cells.money:SetJustifyH("RIGHT")
        window.rows[row.key] = cells
        previous = cells.label
    end
    window.counts = Kit.Label(window, "", "small")
    window.counts:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -12)
    window.counts:SetWidth(WIDTH - 2 * pad - 16)
    window.counts:SetJustifyH("LEFT")
    window.note = Kit.Label(window, "", "disabled")
    window.note:SetPoint("TOPLEFT", window.counts, "BOTTOMLEFT", 0, -8)
    window.note:SetWidth(WIDTH - 2 * pad - 16)
    window.note:SetJustifyH("LEFT")
    window:HookScript("OnHide", function(self)
        if self.onClose then
            local callback = self.onClose
            self.onClose = nil
            callback()
        end
    end)
end

-- Shows the panel. info: itemText, scopeText, total (LedgerItemTotal.Compute), formatMoney(copper) (the shared money
-- formatter), anchor (a frame to place the panel next to), onClose (optional, called when the panel hides).
function LedgerItemPanel.Show(info)
    if not window then
        build()
    end
    window.onClose = nil
    window.formatMoney = info.formatMoney
    window.item:SetText(info.itemText or "")
    window.scope:SetText(info.scopeText or "")
    local total = info.total
    for _, row in ipairs(ROWS) do
        local cells = window.rows[row.key]
        local value = total[row.money]
        cells.money:SetCopper(value)
        if row.qty then
            local qty = total[row.qty]
            cells.qty:SetText((qty ~= nil and tostring(qty) or LedgerItemPanel.NO_COUNT) .. " items")
        end
        if row.key == "net" then
            if value > 0 then
                cells.money:SetTextColor(0.25, 1, 0.25)
            elseif value < 0 then
                cells.money:SetTextColor(1, 0.25, 0.25)
            else
                cells.money:SetTextColor(1, 1, 1)
            end
        end
    end
    window.counts:SetText(LedgerItemPanel.CountsText(total))
    window.note:SetText(total.hasSums and LedgerItemPanel.NOTE_SUMS or "")
    window:ClearAllPoints()
    if info.anchor then
        window:SetPoint("TOPLEFT", info.anchor, "TOPRIGHT", 8, 0)
    else
        window:SetPoint("CENTER")
    end
    window:Show()
    window.onClose = info.onClose
end

function LedgerItemPanel.Hide()
    if window then
        window:Hide()
    end
end

function LedgerItemPanel.IsShown()
    return window ~= nil and window:IsShown()
end
