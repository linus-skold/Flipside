local mock = require("Tests.wow_mock")

local EVENT = "REPLICATE_ITEM_LIST_UPDATE"

local function loadAddon()
    local chunk = assert(loadfile("ScanTest/ScanTest.lua"))
    chunk()
    mock.fire("ADDON_LOADED", "ScanTest")
end

local function openAuctionHouse()
    mock.fire("AUCTION_HOUSE_SHOW")
end

-- Start a run up to the point where the addon waits for the event.
local function startRun()
    mock.runSlash()
    mock.acceptPopup()
end

local function hasMessage(text)
    for _, msg in ipairs(mock.messages) do
        if msg:find(text, 1, true) then
            return true
        end
    end
    return false
end

-- Build 2500 rows. Items: 1001 stacks to 200, 1002 stacks to 1, 1003 has no stack size.
local function buildRows()
    local expected = {
        rows = 0, uniqueItems = 3, totalQuantity = 0, rowsWithBuyout = 0, rowsMissingInfo = 0,
        rowsStackable = 0, rowsStackUnknown = 0, emptyRows = 0,
    }
    local items = { 1001, 1002, 1003 }
    for i = 1, 2500 do
        local row = {
            itemID = items[(i - 1) % 3 + 1],
            count = i % 5 + 1,
            buyout = (i % 2 == 0) and 100 or 0,
            hasAll = (i % 4 ~= 0) and true or nil,
        }
        if i == 10 or i == 20 then
            row.itemID = nil
        end
        mock.rows[i] = row

        expected.rows = expected.rows + 1
        expected.totalQuantity = expected.totalQuantity + row.count
        if row.buyout > 0 then
            expected.rowsWithBuyout = expected.rowsWithBuyout + 1
        end
        if row.hasAll ~= true then
            expected.rowsMissingInfo = expected.rowsMissingInfo + 1
        end
        if row.itemID == nil then
            expected.emptyRows = expected.emptyRows + 1
        elseif row.itemID == 1001 then
            expected.rowsStackable = expected.rowsStackable + 1
        elseif row.itemID == 1003 then
            expected.rowsStackUnknown = expected.rowsStackUnknown + 1
        end
    end
    mock.stackSizes[1001] = 200
    mock.stackSizes[1002] = 1
    return expected
end

describe("ScanTest", function()
    before_each(function()
        mock.reset()
        loadAddon()
    end)

    after_each(function()
        mock.teardown()
    end)

    it("creates the saved variable and prints the build line at load", function()
        assert.are.same({}, _G.ScanTestDB.runs)
        assert.is_true(hasMessage("interface 16001"))
        assert.is_true(hasMessage("project id 99"))
    end)

    it("saves a run when the API is not available", function()
        openAuctionHouse()
        _G.C_AuctionHouse = nil
        mock.runSlash()
        assert.is_nil(mock.popup)
        assert.are.equal(1, #_G.ScanTestDB.runs)
        assert.are.equal("API not available", _G.ScanTestDB.runs[1].result)
        assert.is_true(hasMessage("API not available"))
    end)

    it("saves a run when ReplicateItems is missing", function()
        openAuctionHouse()
        _G.C_AuctionHouse.ReplicateItems = nil
        mock.runSlash()
        assert.are.equal("API not available", _G.ScanTestDB.runs[1].result)
    end)

    it("does not start when the Auction House is not open", function()
        mock.runSlash()
        assert.is_nil(mock.popup)
        assert.are.equal(0, #_G.ScanTestDB.runs)
        assert.are.equal(0, mock.replicateCalls)
        assert.is_true(hasMessage("open the Auction House first"))
    end)

    it("does not start when the Auction House was closed again", function()
        openAuctionHouse()
        mock.fire("AUCTION_HOUSE_CLOSED")
        mock.runSlash()
        assert.is_nil(mock.popup)
    end)

    it("counts all rows in 3 frames on the happy path", function()
        local expected = buildRows()
        openAuctionHouse()
        mock.runSlash()
        assert.is_not_nil(mock.popup)
        assert.is_nil(mock.popup.text:find("Cooldown", 1, true))
        mock.acceptPopup()
        assert.are.equal(1, mock.replicateCalls)
        assert.is_true(mock.isRegistered(EVENT))
        assert.is_truthy(_G.ScanTestDB.lastAttempt)

        mock.advance(2)
        mock.fire(EVENT)
        assert.is_false(mock.isRegistered(EVENT))

        mock.update()
        mock.update()
        assert.are.equal(0, #_G.ScanTestDB.runs)
        mock.update()
        assert.are.equal(1, #_G.ScanTestDB.runs)
        mock.update()

        local run = _G.ScanTestDB.runs[1]
        assert.are.equal("ok", run.result)
        assert.are.equal(3, run.frames)
        assert.are.equal(2000, run.timeToFirstEvent)
        assert.is_number(run.processingMs)
        assert.is_number(run.memBefore)
        assert.is_number(run.memAfter)
        assert.are.equal(run.memAfter - run.memBefore, run.memDiff)
        assert.are.equal(16001, run.build.interface)
        assert.are.same(expected, run.counts)
        assert.are.equal(2500, run.counts.rows)
        assert.are.equal(2, run.counts.emptyRows)

        -- A late timeout must not change the saved run.
        mock.advance(60)
        assert.are.equal(1, #_G.ScanTestDB.runs)
        assert.are.equal("ok", run.result)
    end)

    it("ignores a second /scantest while a run is in progress", function()
        openAuctionHouse()
        startRun()
        mock.popup = nil
        mock.runSlash()
        assert.is_nil(mock.popup)
        assert.is_true(hasMessage("a run is in progress"))
    end)

    it("reports no response after 60 seconds", function()
        openAuctionHouse()
        startRun()
        mock.advance(59)
        assert.are.equal(0, #_G.ScanTestDB.runs)
        mock.advance(1)
        assert.are.equal(1, #_G.ScanTestDB.runs)
        assert.are.equal("no response (cooldown or blocked)", _G.ScanTestDB.runs[1].result)
        assert.is_false(mock.isRegistered(EVENT))

        -- A late event must not start a read.
        mock.fire(EVENT)
        mock.update()
        assert.are.equal(1, #_G.ScanTestDB.runs)
    end)

    it("reports call failed when ReplicateItems raises an error", function()
        openAuctionHouse()
        _G.C_AuctionHouse.ReplicateItems = function()
            error("boom")
        end
        startRun()
        local run = _G.ScanTestDB.runs[1]
        assert.are.equal("call failed", run.result)
        assert.is_truthy(run.error:find("boom", 1, true))
        assert.is_false(mock.isRegistered(EVENT))
    end)

    it("shows the cooldown time on a second run inside 15 minutes", function()
        openAuctionHouse()
        startRun()
        mock.advance(60)
        mock.advance(240)
        mock.runSlash()
        assert.is_not_nil(mock.popup)
        assert.is_truthy(mock.popup.text:find("10 min 0 s", 1, true))
    end)

    it("shows no cooldown time after 15 minutes", function()
        openAuctionHouse()
        startRun()
        mock.advance(60)
        mock.advance(840)
        mock.runSlash()
        assert.is_nil(mock.popup.text:find("Cooldown", 1, true))
    end)
end)
