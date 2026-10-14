local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local FILES = {
    manifest.path("EventBus"),
    manifest.path("Scheduler"),
    manifest.path("ItemString"),
    manifest.path("SettingsDB"),
    manifest.path("ItemInfoCache"),
    manifest.path("Core_Forever/Flavour"),
    manifest.path("AuctionClient"),
    manifest.path("ForeverBackend"),
    manifest.path("Init"),
}

local ns

local function hasMessage(text)
    for _, msg in ipairs(mock.messages) do
        if msg:find(text, 1, true) then
            return true
        end
    end
    return false
end

describe("Init", function()
    before_each(function()
        mock.reset()
        ns = { scanModulesOptional = true }
        for _, path in ipairs(FILES) do
            assert(loadfile(path))("Flipside", ns)
        end
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("game events", function()
        it("delivers a game event to a bus subscriber", function()
            local got
            ns.bus:Subscribe("AUCTION_HOUSE_SHOW", "test", function(event, a, b)
                got = { event, a, b }
            end)
            mock.fire("AUCTION_HOUSE_SHOW", 1, 2)
            assert.are.same({ "AUCTION_HOUSE_SHOW", 1, 2 }, got)
        end)

        it("registers at the first subscriber and unregisters at the last", function()
            local handler = function() end
            assert.is_false(mock.isRegistered("AUCTION_HOUSE_SHOW"))
            ns.bus:Subscribe("AUCTION_HOUSE_SHOW", "a", handler)
            assert.is_true(mock.isRegistered("AUCTION_HOUSE_SHOW"))
            ns.bus:Subscribe("AUCTION_HOUSE_SHOW", "b", handler)
            ns.bus:Unsubscribe("AUCTION_HOUSE_SHOW", "a")
            assert.is_true(mock.isRegistered("AUCTION_HOUSE_SHOW"))
            ns.bus:Unsubscribe("AUCTION_HOUSE_SHOW", "b")
            assert.is_false(mock.isRegistered("AUCTION_HOUSE_SHOW"))
        end)

        it("never registers an internal event name", function()
            ns.bus:Subscribe("Flipside.Loaded", "test", function() end)
            ns.bus:Subscribe("Flipside.Custom_Thing", "test", function() end)
            assert.is_false(mock.isRegistered("Flipside.Loaded"))
            assert.is_false(mock.isRegistered("Flipside.Custom_Thing"))
            ns.bus:Unsubscribe("Flipside.Loaded", "test")
        end)

        it("keeps ADDON_LOADED registered after the last unsubscribe", function()
            ns.bus:Subscribe("ADDON_LOADED", "test", function() end)
            ns.bus:Unsubscribe("ADDON_LOADED", "test")
            assert.is_true(mock.isRegistered("ADDON_LOADED"))
        end)

        it("reports a failing RegisterEvent and does not raise an error", function()
            mock.invalidEvents.NOT_A_REAL_EVENT = true
            assert.has_no.errors(function()
                ns.bus:Subscribe("NOT_A_REAL_EVENT", "test", function() end)
            end)
            assert.is_false(mock.isRegistered("NOT_A_REAL_EVENT"))
            assert.is_true(hasMessage("Flipside: cannot register event NOT_A_REAL_EVENT"))
        end)

        it("prints a failing handler as one Flipside line", function()
            ns.bus:Subscribe("AUCTION_HOUSE_SHOW", "test", function()
                error("boom", 0)
            end)
            mock.fire("AUCTION_HOUSE_SHOW")
            assert.are.equal(1, #mock.messages)
            assert.is_true(mock.messages[1]:find("^Flipside: .*AUCTION_HOUSE_SHOW.*boom") ~= nil)
        end)
    end)

    describe("lifecycle events", function()
        it("emits Flipside.Loaded only for this addon", function()
            local count = 0
            ns.bus:Subscribe("Flipside.Loaded", "test", function()
                count = count + 1
            end)
            mock.fire("ADDON_LOADED", "OtherAddon")
            assert.are.equal(0, count)
            mock.fire("ADDON_LOADED", "Flipside")
            assert.are.equal(1, count)
        end)

        it("emits Flipside.Login on PLAYER_LOGIN", function()
            local count = 0
            ns.bus:Subscribe("Flipside.Login", "test", function()
                count = count + 1
            end)
            mock.fire("PLAYER_LOGIN")
            assert.are.equal(1, count)
        end)

        it("does not write FlipsideDB or FlipsideScanDB", function()
            mock.fire("ADDON_LOADED", "Flipside")
            mock.fire("PLAYER_LOGIN")
            assert.is_nil(_G.FlipsideDB)
            assert.is_nil(_G.FlipsideScanDB)
        end)
    end)

    describe("jobs", function()
        it("runs a job on update ticks and hides the update frame when idle", function()
            local steps = 0
            local job = ns.StartJob("count", function(j)
                for _ = 1, 3 do
                    steps = steps + 1
                    j:Yield()
                end
            end)
            local frame = mock.frames[#mock.frames]
            assert.is_true(frame:IsShown())
            mock.update()
            assert.are.equal(1, steps)
            mock.update()
            mock.update()
            assert.are.equal(3, steps)
            assert.is_true(frame:IsShown())
            mock.update()
            assert.are.equal("done", job:GetStatus())
            assert.is_false(frame:IsShown())
            mock.update()
            assert.are.equal(3, steps)
        end)

        it("shows the update frame again for a new job", function()
            ns.StartJob("one", function() end)
            mock.update()
            local frame = mock.frames[#mock.frames]
            assert.is_false(frame:IsShown())
            ns.StartJob("two", function() end)
            assert.is_true(frame:IsShown())
        end)

        it("prints a failing job and runs the next job", function()
            local ran = false
            ns.StartJob("bad", function()
                error("job boom", 0)
            end)
            ns.StartJob("good", function()
                ran = true
            end)
            mock.update()
            assert.is_true(hasMessage("Flipside: job bad failed: job boom"))
            mock.update()
            assert.is_true(ran)
        end)
    end)

    describe("slash commands", function()
        it("registers /flipside and /flip", function()
            assert.are.equal("/flipside", _G.SLASH_FLIPSIDE1)
            assert.are.equal("/flip", _G.SLASH_FLIPSIDE2)
            assert.is_function(_G.SlashCmdList.FLIPSIDE)
        end)

        it("prints help for the help argument", function()
            _G.SlashCmdList.FLIPSIDE("help")
            assert.are.same({
                "Flipside: /flip opens the Flipside window",
                "Flipside: client 1.60.1, build 70009, interface 16001",
                "Flipside: No feature exists yet.",
            }, mock.messages)
        end)

        it("prints the same help for help and an unknown argument", function()
            _G.SlashCmdList.FLIPSIDE("help")
            local expected = mock.messages
            mock.messages = {}
            _G.SlashCmdList.FLIPSIDE("nonsense words")
            assert.are.same(expected, mock.messages)
        end)

        it("prints only the version line for version", function()
            _G.SlashCmdList.FLIPSIDE("  VERSION ")
            assert.are.same({ "Flipside: client 1.60.1, build 70009, interface 16001" }, mock.messages)
        end)
    end)

    describe("settings DB", function()
        before_each(function()
            mock.playerName = "Tester"
            mock.realmName = "TestRealm"
        end)

        it("loads the files from the TOC in sequence", function()
            local inFiles, toc = {}, {}
            for _, path in ipairs(FILES) do
                inFiles[path] = true
            end
            for _, path in ipairs(manifest.files()) do
                if inFiles[path] then
                    table.insert(toc, path)
                end
            end
            assert.are.same(FILES, toc)
        end)

        it("does not create ns.db before PLAYER_LOGIN", function()
            mock.fire("ADDON_LOADED", "Flipside")
            assert.is_nil(ns.db)
            assert.is_nil(_G.FlipsideDB)
        end)

        it("creates a new FlipsideDB at PLAYER_LOGIN", function()
            mock.fire("PLAYER_LOGIN")
            assert.is_table(ns.db)
            assert.are.equal(1, _G.FlipsideDB._schema)
            assert.are.equal("Default", ns.db:GetProfile())
            local found = false
            for _, value in pairs(_G.FlipsideDB) do
                if type(value) == "table" and value["Tester-TestRealm"] == "Default" then
                    found = true
                end
            end
            assert.is_true(found)
            assert.are.equal(0, #mock.messages)
        end)

        it("keeps an existing FlipsideDB table and its unknown keys", function()
            local saved = { _schema = 1, futureKey = { a = 1 } }
            _G.FlipsideDB = saved
            mock.fire("PLAYER_LOGIN")
            assert.are.equal(saved, _G.FlipsideDB)
            assert.are.same({ a = 1 }, saved.futureKey)
            assert.are.equal(1, saved._schema)
        end)

        it("replaces a FlipsideDB that is not a table", function()
            _G.FlipsideDB = "broken"
            mock.fire("PLAYER_LOGIN")
            assert.is_table(_G.FlipsideDB)
            assert.is_table(ns.db)
        end)

        it("creates no DB and prints one line for a nil name", function()
            mock.playerName = nil
            mock.fire("PLAYER_LOGIN")
            assert.is_nil(ns.db)
            assert.is_nil(_G.FlipsideDB)
            assert.are.equal(1, #mock.messages)
            assert.is_true(mock.messages[1]:find("^Flipside: settings are not available") ~= nil)
        end)

        it("creates no DB and prints one line for a nil or empty realm", function()
            mock.realmName = nil
            mock.fire("PLAYER_LOGIN")
            assert.is_nil(ns.db)
            assert.are.equal(1, #mock.messages)
            mock.messages = {}
            mock.realmName = ""
            mock.fire("PLAYER_LOGIN")
            assert.is_nil(ns.db)
            assert.are.equal(1, #mock.messages)
        end)

        it("emits Flipside.DBReady before Flipside.Login", function()
            local order = {}
            ns.bus:Subscribe("Flipside.DBReady", "test", function()
                table.insert(order, "DBReady")
            end)
            ns.bus:Subscribe("Flipside.Login", "test", function()
                table.insert(order, "Login:" .. tostring(ns.db ~= nil))
            end)
            mock.fire("PLAYER_LOGIN")
            assert.are.same({ "DBReady", "Login:true" }, order)
        end)

        it("gives a read-only DB and one warning for a newer schema", function()
            _G.FlipsideDB = { _schema = 99 }
            mock.fire("PLAYER_LOGIN")
            assert.is_table(ns.db)
            assert.is_true(ns.db:IsReadOnly())
            assert.are.equal(99, _G.FlipsideDB._schema)
            assert.are.equal(1, #mock.messages)
            assert.is_true(mock.messages[1]:find("^Flipside: ") ~= nil)
        end)

        it("prints one line and leaves ns.db nil if SettingsDB.New fails", function()
            ns.SettingsDB.New = function()
                error("boom", 0)
            end
            mock.fire("PLAYER_LOGIN")
            assert.is_nil(ns.db)
            assert.are.equal(1, #mock.messages)
            assert.is_true(mock.messages[1]:find("boom", 1, true) ~= nil)
        end)

        it("shows the profile line in /flipside only if the DB exists", function()
            _G.SlashCmdList.FLIPSIDE("help")
            assert.are.equal(3, #mock.messages)
            mock.fire("PLAYER_LOGIN")
            mock.messages = {}
            _G.SlashCmdList.FLIPSIDE("help")
            assert.are.same({
                "Flipside: /flip opens the Flipside window",
                "Flipside: profile Default",
                "Flipside: client 1.60.1, build 70009, interface 16001",
                "Flipside: No feature exists yet.",
            }, mock.messages)
        end)
    end)

    describe("item info cache", function()
        it("registers ITEM_DATA_LOAD_RESULT on the frame", function()
            assert.is_true(mock.isRegistered("ITEM_DATA_LOAD_RESULT"))
        end)

        it("runs a stored callback when the load result arrives", function()
            local got
            ns.itemCache:Request(123, function(itemID, info, state)
                got = { itemID, info and info.name, state }
            end)
            assert.is_nil(got)
            mock.itemInfo[123] = { "Sword", "link" }
            mock.fire("ITEM_DATA_LOAD_RESULT", 123, true)
            assert.are.same({ 123, "Sword", "loaded" }, got)
        end)

        it("calls RequestLoadItemDataByID once for two requests", function()
            ns.itemCache:Request(55, function() end)
            ns.itemCache:Request(55, function() end)
            assert.are.same({ 55 }, mock.loadRequests)
        end)

        it("returns data at once if the client has the item", function()
            mock.itemInfo[7] = { "Shield" }
            local got
            ns.itemCache:Request(7, function(_, info, state)
                got = { info.name, state }
            end)
            assert.are.same({ "Shield", "loaded" }, got)
            assert.are.same({}, mock.loadRequests)
        end)
    end)end)
