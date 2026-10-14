local mock = require("Tests.wow_mock")

local REPLICATE = "REPLICATE_ITEM_LIST_UPDATE"
local DAY = 86400

local ns

-- Load the files in the order of the TOC, as the client does.
local function tocFiles()
    local files = {}
    for line in io.lines("Flipside.toc") do
        local path = line:match("^([%w]+\\[%w]+%.lua)%s*$")
        if path then
            table.insert(files, (path:gsub("\\", "/")))
        end
    end
    return files
end

local function hasMessage(text)
    for _, msg in ipairs(mock.messages) do
        if msg:find(text, 1, true) then
            return true
        end
    end
    return false
end

local function slash(text)
    _G.SlashCmdList.FLIPSIDE(text)
end

local function gearLink(id, bonus)
    return "|cffffffff|Hitem:" .. id .. "::::::::::::1:" .. bonus .. "|h[Gear]|h|r"
end

local function commodityLink(id)
    return "|cffffffff|Hitem:" .. id .. "::::::::70:::::|h[Stuff]|h|r"
end

-- Three gear items (1001-1003) and two commodities (2001, 2002) with three rows each.
local function fillRows()
    for i = 1, 3 do
        local id = 1000 + i
        mock.commodity[id] = false
        table.insert(mock.rows, {
            itemID = id, count = 1, buyout = 5000 + i * 10, hasAll = true, link = gearLink(id, 6000 + i),
        })
    end
    for id = 2001, 2002 do
        mock.commodity[id] = true
        for n = 1, 3 do
            table.insert(mock.rows, {
                itemID = id, count = 5, buyout = 5000 * n, hasAll = true, link = commodityLink(id),
            })
        end
    end
end

-- Run frames: one second passes in each frame.
local function pump(frames)
    for _ = 1, frames do
        mock.update()
        mock.advance(1)
    end
end

-- Start a scan in the open Auction House and run it to the end.
local function runScan()
    mock.fire("AUCTION_HOUSE_SHOW")
    slash("scan")
    mock.acceptPopup()
    pump(2)
    mock.fire(REPLICATE)
    for _ = 1, 300 do
        if not ns.scanEngine:IsRunning() then
            return
        end
        pump(1)
    end
    error("the scan did not end")
end

local function login()
    mock.fire("ADDON_LOADED", "Flipside")
    mock.fire("PLAYER_LOGIN")
end

describe("Init scan", function()
    before_each(function()
        mock.reset()
        mock.playerName = "Tester"
        mock.realmName = "TestRealm"
        ns = {}
        for _, path in ipairs(tocFiles()) do
            assert(loadfile(path))("Flipside", ns)
        end
        fillRows()
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("TOC", function()
        it("loads the scan modules before Init, and Init last", function()
            local files = tocFiles()
            assert.are.equal("Core/Init.lua", files[#files])
            local position = {}
            for i, path in ipairs(files) do
                position[path] = i
            end
            for _, name in ipairs({ "Clock", "Record", "Market", "Key", "Cooldown", "Bucket", "Store", "Rows",
                "ItemLoad", "Sources", "Engine" }) do
                assert.is_truthy(position["Services/Scan" .. name .. ".lua"], name)
            end
            assert.is_true(position["Services/ScanEngine.lua"] < position["Core/Init.lua"])
        end)
    end)

    describe("login", function()
        it("creates the store, the cooldown and the engine", function()
            login()
            assert.is_table(ns.scanStore)
            assert.is_table(ns.scanCooldown)
            assert.is_table(ns.scanEngine)
            assert.are.equal("EU", ns.scanStore:GetRegion())
            assert.are.equal("standard", ns.scanStore:GetRuleset())
            assert.is_table(_G.FlipsideScanDB)
            assert.is_true(_G.FlipsideScanDB.data.EU.standard.meta.isStandard)
            assert.are.equal(0, #mock.messages)
        end)

        it("makes no engine and prints one line without a region name", function()
            mock.region = nil
            login()
            assert.is_nil(ns.scanStore)
            assert.is_nil(ns.scanEngine)
            assert.are.equal(1, #mock.messages)
            assert.is_true(mock.messages[1]:find("^Flipside: ") ~= nil)
            mock.messages = {}
            mock.region = ""
            mock.fire("PLAYER_LOGIN")
            assert.is_nil(ns.scanEngine)
            assert.are.equal(1, #mock.messages)
        end)

        it("makes no engine when the settings DB is not open", function()
            mock.playerName = nil
            login()
            assert.is_nil(ns.scanStore)
            assert.is_nil(ns.scanEngine)
            assert.is_nil(_G.FlipsideScanDB)
        end)

        it("prints why /flip scan does nothing when there is no engine", function()
            mock.region = nil
            login()
            mock.messages = {}
            slash("scan")
            assert.are.equal(1, #mock.messages)
            assert.is_nil(mock.popup)
        end)
    end)

    describe("/flip scan", function()
        before_each(login)

        it("prints a reason outside the Auction House and shows no popup", function()
            slash("scan")
            assert.is_nil(mock.popup)
            assert.is_true(hasMessage("Flipside: full scan not started: open the Auction House first"))
        end)

        it("tracks the Auction House events", function()
            assert.is_false(ns.IsAuctionHouseOpen())
            mock.fire("AUCTION_HOUSE_SHOW")
            assert.is_true(ns.IsAuctionHouseOpen())
            mock.fire("AUCTION_HOUSE_CLOSED")
            assert.is_false(ns.IsAuctionHouseOpen())
        end)

        it("shows the warning popup when the Auction House is open", function()
            mock.fire("AUCTION_HOUSE_SHOW")
            slash("scan")
            assert.are.equal("FLIPSIDE_FULL_SCAN", mock.popup.which)
            assert.is_true(mock.popup.text:find("disconnected clients", 1, true) ~= nil)
            local dialog = _G.StaticPopupDialogs.FLIPSIDE_FULL_SCAN
            assert.are.equal(0, dialog.timeout)
            assert.is_true(dialog.hideOnEscape)
            assert.is_true(dialog.showAlert)
            assert.are.equal("Accept", dialog.button1)
            assert.are.equal("Cancel", dialog.button2)
            assert.is_false(ns.scanEngine:IsRunning())
        end)

        it("starts the scan on Accept", function()
            mock.fire("AUCTION_HOUSE_SHOW")
            slash("scan")
            mock.acceptPopup()
            assert.is_true(ns.scanEngine:IsRunning())
            assert.is_true(hasMessage("Flipside: full scan started"))
            pump(2)
            assert.are.equal(1, mock.replicateCalls)
        end)

        it("checks the start conditions again on Accept", function()
            mock.fire("AUCTION_HOUSE_SHOW")
            slash("scan")
            mock.fire("AUCTION_HOUSE_CLOSED")
            mock.acceptPopup()
            assert.is_false(ns.scanEngine:IsRunning())
            assert.is_true(hasMessage("open the Auction House first"))
        end)

        it("completes a scan over frames and fills the store", function()
            runScan()
            assert.is_true(hasMessage("Flipside: full scan ok: 9 rows, 5 items, 5 keys"))
            assert.are.same({ "1001#b6001", "1002#b6002", "1003#b6003", "2001", "2002" }, ns.scanStore:Keys())
            assert.are.equal(1, mock.replicateCalls)
        end)

        it("prints the commodity check and skipped rows after a scan", function()
            runScan()
            assert.is_true(hasMessage("Flipside: commodity check: client 5, stack 0, unknown 0, mismatch 0"))
            assert.is_true(hasMessage("Flipside: rows skipped: empty 0, bid-only 0, pet 0, bad count 0"))
        end)

        it("prints the price values with /flip price", function()
            runScan()
            mock.messages = {}
            slash("price 2001")
            assert.are.same({
                "Flipside: key 2001: ScanMin 1000 (0g 10s 0c), ScanRecent 1000 (0g 10s 0c)",
                "Flipside: ScanMarket 1000 (0g 10s 0c), ScanHistorical -",
                "Flipside: ScanQty 15, ScanAge 0.0 h, ScanSamples 1",
            }, mock.messages)
        end)

        it("finds a gear item by its link and a commodity by a link", function()
            runScan()
            mock.messages = {}
            slash("price " .. gearLink(1001, 6001))
            assert.is_true(hasMessage("Flipside: key 1001#b6001: ScanMin 5010 (0g 50s 10c)"))
            mock.messages = {}
            slash("price " .. commodityLink(2002))
            assert.is_true(hasMessage("Flipside: key 2002: ScanMin 1000"))
        end)

        it("prints no scan data for an unknown item and a usage line for bad input", function()
            runScan()
            mock.messages = {}
            slash("price 99")
            assert.are.same({ "Flipside: no scan data for 99" }, mock.messages)
            mock.messages = {}
            slash("price " .. gearLink(77, 1))
            assert.are.same({ "Flipside: no scan data for 77#b1 or 77" }, mock.messages)
            mock.messages = {}
            slash("price nonsense")
            assert.is_true(hasMessage("usage: /flip price"))
        end)

        it("prints the cooldown for a second scan inside 15 minutes", function()
            runScan()
            mock.advance(300)
            mock.messages = {}
            mock.popup = nil
            slash("scan")
            assert.is_nil(mock.popup)
            assert.is_true(hasMessage("Flipside: full scan not started: scan on cooldown, "))
            assert.is_true(hasMessage(" left"))
        end)

        it("allows a scan again after 15 minutes", function()
            runScan()
            mock.advance(16 * 60)
            mock.popup = nil
            slash("scan")
            assert.is_not_nil(mock.popup)
        end)

        it("stops a running scan with /flip scan stop and stores nothing", function()
            mock.fire("AUCTION_HOUSE_SHOW")
            slash("scan")
            mock.acceptPopup()
            pump(2)
            slash("scan stop")
            pump(2)
            assert.is_false(ns.scanEngine:IsRunning())
            assert.is_true(hasMessage("Flipside: full scan cancelled"))
            assert.are.same({}, ns.scanStore:Keys())
        end)

        it("says that no scan runs for /flip scan stop", function()
            slash("scan stop")
            assert.are.same({ "Flipside: no scan is running" }, mock.messages)
        end)
    end)

    describe("logout", function()
        before_each(login)

        it("flushes the store to encoded strings", function()
            runScan()
            local items = _G.FlipsideScanDB.data.EU.standard.items
            assert.is_nil(next(items))
            mock.logout()
            assert.are.equal("string", type(items["2001"]))
            assert.are.equal("string", type(items["1001#b6001"]))
        end)

        it("writes nothing from a scan that did not end before the logout", function()
            mock.fire("AUCTION_HOUSE_SHOW")
            slash("scan")
            mock.acceptPopup()
            pump(2)
            mock.fire(REPLICATE)
            mock.logout()
            assert.is_nil(next(_G.FlipsideScanDB.data.EU.standard.items))
        end)
    end)

    describe("roll-up at login", function()
        before_each(function()
            mock.serverBase = 200 * DAY
        end)

        local function seed(daysAgo, key, noLatest)
            local record = ns.ScanRecord.New()
            local time = mock.serverBase - daysAgo * DAY
            ns.ScanBucket.Apply(record, { min = 100, market = 200, qty = 7, auctions = 2 }, time, false)
            if noLatest then
                record.latest = nil
            end
            _G.FlipsideScanDB = {
                _schema = 1,
                data = { EU = { standard = { items = { [key] = ns.ScanRecord.Encode(record) } } } },
            }
        end

        it("turns the snapshots of an earlier day into a daily record", function()
            seed(2, "2001")
            login()
            pump(2)
            local record = ns.scanStore:Get("2001")
            assert.is_nil(record.today)
            assert.are.equal(1, #record.days)
            assert.are.equal(math.floor(mock.serverBase / DAY) - 2, record.days[1].day)
            assert.are.equal(0, #mock.messages)
            mock.logout()
            assert.are.equal("string", type(_G.FlipsideScanDB.data.EU.standard.items["2001"]))
        end)

        it("removes a record that is empty after pruning", function()
            seed(100, "2001", true)
            login()
            pump(2)
            assert.are.same({}, ns.scanStore:Keys())
            mock.logout()
            assert.is_nil(_G.FlipsideScanDB.data.EU.standard.items["2001"])
        end)
    end)

    describe("help", function()
        it("shows the scan line and the command list", function()
            login()
            mock.messages = {}
            slash("")
            assert.are.same({
                "Flipside: addon Flipside",
                "Flipside: profile Default",
                "Flipside: client 1.60.1, build 70009, interface 16001",
                "Flipside: scan: 0 items stored, last scan never, cooldown ready",
                "Flipside: commands: scan, scan stop, price <item>, version",
                "Flipside: No feature exists yet.",
            }, mock.messages)
        end)

        it("shows the item count, the last scan and the cooldown after a scan", function()
            login()
            runScan()
            mock.advance(300)
            mock.messages = {}
            slash("help")
            assert.is_true(hasMessage("Flipside: scan: 5 items stored, last scan 0.1 h ago, cooldown "))
            assert.is_false(hasMessage("cooldown ready"))
        end)

        it("shows no scan line when there is no store", function()
            mock.region = nil
            login()
            mock.messages = {}
            slash("")
            assert.is_false(hasMessage("scan:"))
        end)
    end)
end)
