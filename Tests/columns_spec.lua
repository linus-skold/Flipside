local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

describe("Kit columns", function()
    local Kit

    before_each(function()
        mock.reset()
        local ns = {}
        for _, name in ipairs({ "Theme", "Widgets", "Columns" }) do
            assert(loadfile(manifest.path(name)))("Flipside", ns)
        end
        Kit = ns.Kit
    end)

    after_each(function()
        mock.teardown()
    end)

    local columns = {
        { key = "a", title = "A", width = 100 },
        { key = "b", title = "B", width = 50, number = true },
        { key = "c", title = "C" },
        { key = "d", title = "D", width = 30, justify = "CENTER" },
    }

    it("gives the justify of a column", function()
        assert.are.equal("LEFT", Kit.ColumnJustify(columns[1]))
        assert.are.equal("RIGHT", Kit.ColumnJustify(columns[2]))
        assert.are.equal("CENTER", Kit.ColumnJustify(columns[4]))
        assert.are.equal("LEFT", Kit.ColumnJustify({ number = true, justify = "LEFT" }))
    end)

    it("lays out fixed columns and gives the rest to the fill column", function()
        local layout = Kit.ColumnLayout(columns, 400, { gap = 10 })
        assert.are.same({ 0, 110, 170, 370 }, { layout[1].x, layout[2].x, layout[3].x, layout[4].x })
        assert.are.same({ 100, 50, 190, 30 }, { layout[1].width, layout[2].width, layout[3].width,
            layout[4].width })
        assert.are.equal("RIGHT", layout[2].justify)
        assert.are.equal(400, layout[4].x + layout[4].width)
    end)

    it("grows and shrinks the fill column with the width, to a minimum", function()
        assert.are.equal(290, Kit.ColumnLayout(columns, 500, { gap = 10 })[3].width)
        assert.are.equal(20, Kit.ColumnLayout(columns, 100, { gap = 10 })[3].width)
        assert.are.equal(40, Kit.ColumnLayout(columns, 100, { gap = 10, minFill = 40 })[3].width)
    end)

    it("uses left and right space and the default gap", function()
        local layout = Kit.ColumnLayout(columns, 400, { left = 4, right = 16 })
        assert.are.equal(4, layout[1].x)
        assert.are.equal(110, layout[2].x)
        assert.are.equal(400 - 16, layout[4].x + layout[4].width)
    end)

    it("keeps the same x in every layout for fixed columns (no fill column)", function()
        local fixed = { { key = "a", width = 10 }, { key = "b", width = 20 } }
        local layout = Kit.ColumnLayout(fixed, 999, { gap = 2 })
        assert.are.same({ 0, 12 }, { layout[1].x, layout[2].x })
    end)

    it("refuses two fill columns", function()
        assert.has_error(function()
            Kit.ColumnLayout({ { key = "a" }, { key = "b", width = "fill" } }, 100)
        end)
    end)

    it("anchors columns to the left, both edges, and the right edge", function()
        local anchors = Kit.ColumnAnchors(columns, { gap = 10, left = 4, right = 16 })
        assert.are.same({ side = "LEFT", x = 4, width = 100 }, { side = anchors[1].side, x = anchors[1].x,
            width = anchors[1].width })
        assert.are.equal(114, anchors[2].x)
        assert.are.same({ "BOTH", 174, 56 }, { anchors[3].side, anchors[3].x, anchors[3].right })
        assert.are.same({ "RIGHT", 16, 30, "CENTER" }, { anchors[4].side, anchors[4].right, anchors[4].width,
            anchors[4].justify })
    end)

    it("makes the anchors agree with the layout", function()
        local total = 420
        local options = { gap = 10, left = 4, right = 16 }
        local layout = Kit.ColumnLayout(columns, total, options)
        for index, anchor in ipairs(Kit.ColumnAnchors(columns, options)) do
            local x = anchor.side == "RIGHT" and (total - anchor.right - anchor.width) or anchor.x
            assert.are.equal(layout[index].x, x)
            local width = anchor.width or (total - anchor.right - anchor.x)
            assert.are.equal(layout[index].width, width)
        end
    end)

    it("makes the cell text from key, getter and formatter", function()
        assert.are.equal("5", Kit.ColumnText({ key = "n" }, { n = 5 }))
        assert.are.equal("", Kit.ColumnText({ key = "n" }, {}))
        assert.are.equal("7", Kit.ColumnText({ key = "n", get = function(d) return d.x + 2 end }, { x = 5 }))
        assert.are.equal("5c!", Kit.ColumnText({ key = "n", format = function(v, d) return v .. "c" .. d.s end },
            { n = 5, s = "!" }))
    end)

    it("builds header labels and row cells with the same anchors", function()
        local owned = { { key = "a", title = "A", width = 100, owned = true }, columns[2], columns[3] }
        local parent = CreateFrame("Frame")
        local header = Kit.CreateColumnHeader(parent, owned, { gap = 10 })
        local cells = Kit.CreateColumnCells(parent, owned, { gap = 10 })
        assert.are.equal("A", header.labels.a.text)
        assert.is_nil(cells.a)
        assert.is_not_nil(cells.b)
        Kit.SetColumnCells(cells, owned, { b = 12, c = "text" })
        assert.are.equal("12", cells.b.text)
        assert.are.equal("text", cells.c.text)
        assert.are.equal(header.labels.b.justify, cells.b.justify)
    end)

    it("leaves a hidden column out of the layout and the anchors", function()
        local cols = { { key = "a", width = 100 }, { key = "b", width = 50, hidden = true }, { key = "c" } }
        local layout = Kit.ColumnLayout(cols, 400, { gap = 10 })
        assert.are.equal(2, #layout)
        assert.are.equal(290, layout[2].width)
        local anchors = Kit.ColumnAnchors(cols, { gap = 10 })
        assert.are.same({ "a", "c" }, { anchors[1].key, anchors[2].key })
        assert.are.equal(110, anchors[2].x)
    end)

    it("hides and shows the labels with the hidden flag", function()
        local cols = { { key = "a", title = "A", width = 100 }, { key = "b", title = "B", width = 50 }, { key = "c" } }
        local header = Kit.CreateColumnHeader(CreateFrame("Frame"), cols, { gap = 10 })
        assert.is_true(header.labels.b.shown)
        cols[2].hidden = true
        Kit.LayoutColumnLabels(header.labels, header.frame, cols, { gap = 10 })
        assert.is_false(header.labels.b.shown)
        assert.is_true(header.labels.c.shown)
        cols[2].hidden = false
        Kit.LayoutColumnLabels(header.labels, header.frame, cols, { gap = 10 })
        assert.is_true(header.labels.b.shown)
    end)

    it("splits the width in equal shares for share columns", function()
        local cols = { { key = "a", width = { share = 1 }, number = true }, { key = "b", width = { share = 1 } } }
        local layout = Kit.ColumnLayout(cols, 206, { gap = 6, left = 4, right = 16 })
        assert.are.same({ 90, 90 }, { layout[1].width, layout[2].width })
        assert.are.equal(4, layout[1].x)
        assert.are.equal(100, layout[2].x)
        assert.are.equal("RIGHT", layout[1].justify)
        local three = { { key = "a", width = { share = 1 } }, { key = "b", width = { share = 1 } },
            { key = "c", width = { share = 1 } } }
        assert.are.same({ 30, 30, 30 }, { Kit.ColumnLayout(three, 102, { gap = 6 })[1].width,
            Kit.ColumnLayout(three, 102, { gap = 6 })[2].width, Kit.ColumnLayout(three, 102, { gap = 6 })[3].width })
    end)

    it("gives a weighted share and keeps fixed columns", function()
        local cols = { { key = "a", width = 50 }, { key = "b", width = { share = 1 } },
            { key = "c", width = { share = 3 } } }
        local layout = Kit.ColumnLayout(cols, 200, { gap = 0 })
        assert.are.same({ 50, 37.5, 112.5 }, { layout[1].width, layout[2].width, layout[3].width })
    end)

    it("refuses a fill column with share columns, and anchors for share columns", function()
        local mixed = { { key = "a" }, { key = "b", width = { share = 1 } } }
        assert.has_error(function() Kit.ColumnLayout(mixed, 100) end)
        assert.has_error(function() Kit.ColumnAnchors({ { key = "b", width = { share = 1 } } }) end)
    end)

    it("places share labels by the parent width and again when it changes", function()
        local cols = { { key = "a", title = "A", width = { share = 1 }, number = true },
            { key = "b", title = "B", width = { share = 1 }, number = true } }
        local header = Kit.CreateColumnHeader(CreateFrame("Frame"), cols, { gap = 6 })
        local frame = header.frame
        frame.GetWidth = function() return 106 end
        frame.scripts.OnSizeChanged(frame)
        assert.are.same({ 50, 50 }, { header.labels.a.width, header.labels.b.width })
        assert.are.equal("RIGHT", header.labels.a.justifyH)
        frame.GetWidth = function() return 206 end
        frame.scripts.OnSizeChanged(frame)
        assert.are.same({ 100, 100 }, { header.labels.a.width, header.labels.b.width })    end)end)
