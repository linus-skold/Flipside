local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local LINK = "|cff1eff00|Hitem:100::::::::70:::::|h[Peacebloom]|h|r"

describe("RowTooltip", function()
    local ns, row, inserted, modified

    before_each(function()
        mock.reset()
        ns = { ReportError = function() end }
        for _, name in ipairs({ "ItemString", "RowTooltip" }) do
            assert(loadfile(manifest.path(name)))("Flipside", ns)
        end
        row = CreateFrame("Button")
        inserted, modified = {}, true
        _G.IsModifiedClick = function() return modified end
        _G.ChatEdit_InsertLink = function(link)
            inserted[#inserted + 1] = link
            return true
        end
    end)

    after_each(function()
        _G.IsModifiedClick, _G.ChatEdit_InsertLink = nil, nil
        mock.teardown()
    end)

    describe("Payload", function()
        it("takes the payload of the auction link first", function()
            local payload = ns.RowTooltip.Payload({ link = LINK, key = "100", itemID = 100 })
            assert.are.equal("item:100::::::::70:::::", payload)
        end)

        it("builds an item string from a plain key", function()
            assert.are.equal("item:100", ns.RowTooltip.Payload({ key = "100" }))
        end)

        it("keeps the suffix and the bonus ids of a key", function()
            assert.are.equal("item:100::::::-5::::::2:10:20", ns.RowTooltip.Payload({ key = "100#s-5#b10,20" }))
            assert.are.equal("item:100::::::0::::::1:7", ns.RowTooltip.Payload({ key = "100#b7" }))
        end)

        it("falls back to the item id", function()
            assert.are.equal("item:55", ns.RowTooltip.Payload({ itemID = 55 }))
            assert.are.equal("item:55", ns.RowTooltip.Payload({ key = "not a key", itemID = 55 }))
        end)

        it("gives nil for no item", function()
            assert.is_nil(ns.RowTooltip.Payload(nil))
            assert.is_nil(ns.RowTooltip.Payload({}))
            assert.is_nil(ns.RowTooltip.Payload({ itemID = 0 }))
            assert.is_nil(ns.RowTooltip.Payload({ link = "[Name]" }))
        end)
    end)

    describe("Link", function()
        it("shows the item tooltip at the right of the row and hides it on leave", function()
            assert.is_true(ns.RowTooltip.Link(row, { key = "100" }))
            row.scripts.OnEnter(row)
            assert.are.equal(row, mock.tooltip.owner)
            assert.are.equal("item:100", mock.tooltip.hyperlink)
            assert.is_true(mock.tooltip.shown)
            row.scripts.OnLeave(row)
            assert.is_false(mock.tooltip.shown)
        end)

        it("removes the tooltip of an earlier use when there is no item", function()
            ns.RowTooltip.Link(row, { key = "100" })
            assert.is_false(ns.RowTooltip.Link(row, nil))
            assert.is_nil(row.scripts.OnEnter)
            assert.is_nil(row.scripts.OnLeave)
        end)

        it("does nothing in OnEnter when the client has no tooltip", function()
            ns.RowTooltip.Link(row, { key = "100" })
            local tip = _G.GameTooltip
            _G.GameTooltip = nil
            assert.has_no.errors(function()
                row.scripts.OnEnter(row)
                row.scripts.OnLeave(row)
            end)
            _G.GameTooltip = tip
        end)

        it("leaves the OnClick script alone without a chat link", function()
            local click = function() end
            row:SetScript("OnClick", click)
            ns.RowTooltip.Link(row, { key = "100" })
            assert.are.equal(click, row.scripts.OnClick)
        end)

        it("puts the chat link in the chat on a shift-click, and keeps the other clicks", function()
            local clicks = {}
            row:SetScript("OnClick", function(_, button) clicks[#clicks + 1] = button end)
            ns.RowTooltip.Link(row, { key = "100" }, { chatLink = LINK })
            row.scripts.OnClick(row, "LeftButton")
            assert.are.same({ LINK }, inserted)
            assert.are.same({}, clicks)
            row.scripts.OnClick(row, "RightButton")
            modified = false
            row.scripts.OnClick(row, "LeftButton")
            assert.are.same({ "RightButton", "LeftButton" }, clicks)
            assert.are.same({ LINK }, inserted)
        end)
    end)
end)
