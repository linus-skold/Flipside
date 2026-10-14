local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

describe("Price table on a tooltip", function()
    local ns, onItem, rowsOf, minWidths

    local model = {
        kind = "table",
        header = "Flipside (updated 2 h ago)",
        columns = { "Min", "Avg", "Max", "Market" },
        rows = {
            { label = "1d", cells = { "4s", "5s", "6s", "50s" } },
            { label = "14d", cells = { "-", "-", "-", "-" } },
            { label = "30d", cells = { "1g", "2g", "3g", "4g" } },
            { label = "60d", cells = { "1c", "2c", "3c", "4c" } },
        },
    }

    -- A tooltip frame with the client methods that the table needs.
    local function newTooltip(name)
        local tip = CreateFrame("Frame", name)
        tip.lines, tip.leftLines = {}, {}
        function tip:AddLine(text, r)
            self.lines[#self.lines + 1] = { text = text, r = r }
            self.leftLines[#self.lines] = self:CreateFontString(nil, "ARTWORK", "GameTooltipText")
        end
        function tip:AddDoubleLine(left, right)
            self.lines[#self.lines + 1] = { left = left, right = right }
            self.leftLines[#self.lines] = self:CreateFontString(nil, "ARTWORK", "GameTooltipText")
        end
        function tip:NumLines()
            return #self.lines
        end
        function tip:GetLeftLine(index)
            return self.leftLines[index]
        end
        function tip:SetMinimumWidth(width, force)
            minWidths[#minWidths + 1] = { self, width, force }
        end
        function tip.GetOwner() end
        -- The client runs these scripts when a tooltip is cleared or hidden.
        function tip:Clear()
            self.lines, self.leftLines = {}, {}
            self.scripts.OnTooltipCleared(self)
        end
        return tip
    end

    local function viewOf(tip)
        return ns.TooltipTable.For(tip).view
    end

    before_each(function()
        mock.reset()
        minWidths = {}
        ns = {}
        assert(loadfile(manifest.path("TooltipTable")))("Flipside", ns)
        assert(loadfile(manifest.path("Tooltip")))("Flipside", ns)
        ns.TooltipLines = {
            Build = function()
                return rowsOf()
            end,
        }
        rowsOf = function()
            return { model, { left = "Total: 5", color = "normal" } }
        end
        local registered
        ns.Tooltip.Attach({
            tooltipConfig = { Get = function() return { lines = {} } end },
            now = function() return 0 end,
            isAltDown = function() return false end,
            hook = {
                Install = function(fn)
                    registered = fn
                    return true
                end,
            },
            clock = function() return 0 end,
            report = function(message) error(message) end,
        })
        onItem = registered
    end)

    after_each(function()
        mock.teardown()
    end)

    it("uses the table header as the title and reserves one blank line per row", function()
        local tip = newTooltip("GameTooltip")
        onItem(tip, "item:5")
        assert.are.equal(" ", tip.lines[1].text)
        assert.are.equal("Flipside (updated 2 h ago)", tip.lines[2].text)
        for i = 3, 7 do
            assert.are.equal(" ", tip.lines[i].text)
        end
        assert.are.equal("Total: 5", tip.lines[8].left)
        assert.are.equal(8, #tip.lines)
    end)

    it("anchors each row to its reserved line and draws five columns", function()
        local tip = newTooltip("GameTooltip")
        onItem(tip, "item:5")
        local view = viewOf(tip)
        assert.is_true(view.frame:IsShown())
        assert.are.equal(tip, view.frame:GetParent())
        for index = 1, 5 do
            local row = view.rows[index]
            assert.are.equal(tip.leftLines[index + 2], row.label.points[1][2])
            assert.are.equal("TOPLEFT", row.label.points[1][1])
            assert.are.equal(4, #row.cells)
            assert.are.equal("TOPRIGHT", row.cells[4].points[1][1])
            assert.are.equal("RIGHT", row.cells[1].justifyH)
            assert.are.equal("LEFT", row.label.justifyH)
        end
        assert.are.equal("Min", view.rows[1].cells[1]:GetText())
        assert.are.equal("14d", view.rows[3].label:GetText())
        assert.are.equal("3g", view.rows[4].cells[3]:GetText())
    end)

    it("right-aligns the columns at growing offsets", function()
        local tip = newTooltip("GameTooltip")
        onItem(tip, "item:5")
        local cells = viewOf(tip).rows[2].cells
        local last = 0
        for j = 1, 4 do
            local x = cells[j].points[1][4]
            assert.is_true(x > last)
            last = x
        end
    end)

    it("uses client fonts: gold header, grey labels, white values", function()
        local tip = newTooltip("GameTooltip")
        onItem(tip, "item:5")
        local view = viewOf(tip)
        assert.are.equal("GameFontNormal", view.rows[1].cells[2].fontObject)
        assert.are.equal("GameFontDisable", view.rows[2].label.fontObject)
        assert.are.equal("GameFontHighlight", view.rows[2].cells[2].fontObject)
    end)

    it("makes the tooltip wide enough", function()
        local tip = newTooltip("GameTooltip")
        onItem(tip, "item:5")
        assert.are.equal(1, #minWidths)
        assert.are.equal(tip, minWidths[1][1])
        assert.are.equal(viewOf(tip).width + 20, minWidths[1][2])
        assert.is_false(minWidths[1][3])
    end)

    it("hides the table and resets the width when the tooltip is cleared", function()
        local tip = newTooltip("GameTooltip")
        onItem(tip, "item:5")
        tip:Clear()
        assert.is_false(viewOf(tip).frame:IsShown())
        assert.are.equal(2, #minWidths)
        assert.are.equal(0, minWidths[2][2])
    end)

    it("hides the table when the tooltip hides", function()
        local tip = newTooltip("GameTooltip")
        onItem(tip, "item:5")
        tip.scripts.OnHide(tip)
        assert.is_false(viewOf(tip).frame:IsShown())
    end)

    it("reuses one frame for each tooltip and keeps the tooltips apart", function()
        local game, ref = newTooltip("GameTooltip"), newTooltip("ItemRefTooltip")
        onItem(game, "item:5")
        local frame = viewOf(game).frame
        game:Clear()
        onItem(game, "item:6")
        assert.are.equal(frame, viewOf(game).frame)
        assert.is_true(frame:IsShown())
        onItem(ref, "item:5")
        assert.are_not.equal(frame, viewOf(ref).frame)
        assert.are.equal(ref, viewOf(ref).frame:GetParent())
        local count = 0
        for _, f in ipairs(mock.frames) do
            if f.parent == game and f.kind == "Frame" then count = count + 1 end
        end
        assert.are.equal(1, count)
    end)

    it("shows no table after a switch to an item without a table", function()
        local tip = newTooltip("GameTooltip")
        onItem(tip, "item:5")
        tip:Clear()
        rowsOf = function()
            return { { left = "Prices", right = "invalid price", color = "dim" } }
        end
        onItem(tip, "item:6")
        assert.is_false(viewOf(tip).frame:IsShown())
        assert.are.equal("Flipside", tip.lines[2].text)
    end)

    it("hides a stale table when the item is shown again without a clear", function()
        local tip = newTooltip("GameTooltip")
        onItem(tip, "item:5")
        onItem(tip, nil)
        assert.is_false(viewOf(tip).frame:IsShown())
    end)

    it("falls back to text rows without the line API", function()
        local tip = newTooltip("GameTooltip")
        tip.NumLines = nil
        onItem(tip, "item:5")
        assert.are.equal("Min  Avg  Max  Market", tip.lines[3].right)
        assert.are.equal("1d", tip.lines[4].left)
        assert.are.equal("4s  5s  6s  50s", tip.lines[4].right)
        assert.are.equal(8, #tip.lines)
    end)

    it("does not draw on a forbidden tooltip", function()
        local tip = newTooltip("GameTooltip")
        tip.IsForbidden = function() return true end
        onItem(tip, "item:5")
        assert.are.equal(0, #tip.lines)
    end)
end)
