local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local ns

local function loadAddon()
    local space = {}
    for _, path in ipairs(manifest.files()) do
        assert(loadfile(path))("Flipside", space)
    end
    return space
end

local function login()
    mock.fire("ADDON_LOADED", "Flipside")
    mock.fire("PLAYER_LOGIN")
end

local function slash(text)
    mock.messages = {}
    _G.SlashCmdList.FLIPSIDE(text)
end

-- Return the data messages of a set from another member.
local function remoteSet(scope, keys, market)
    local list = {}
    for i, key in ipairs(keys) do
        list[i] = { key = key, min = market - 10, market = market, qty = 4, time = GetServerTime() - 5 }
    end
    return assert(ns.GuildSyncCodec.BuildSet(scope, 9, list))
end

local function receive(text, sender, channel)
    mock.fire("CHAT_MSG_ADDON", "Flipside", text, channel or "GUILD", sender or "Bob-TestRealm", "", 0, 0, "", 0)
end

describe("Init guild sharing", function()
    before_each(function()
        mock.reset()
        local methods = getmetatable(CreateFrame("Frame")).__index
        methods.SetJustifyH = function() end
        _G.ScrollUtil = nil
        _G.ChatEdit_InsertLink = function()
            return true
        end
        _G.hooksecurefunc = function() end
        _G.C_Timer.NewTicker = function()
            return { Cancel = function() end }
        end
        mock.playerName = "Tester"
        mock.realmName = "TestRealm"
        ns = loadAddon()
        login()
    end)

    after_each(function()
        _G.hooksecurefunc = nil
        _G.ChatEdit_InsertLink = nil
        mock.teardown()
    end)

    it("is off by default and sends nothing", function()
        assert.is_table(ns.guildSync)
        assert.is_false(ns.guildSync:IsEnabled())
        mock.inGuild = true
        mock.advance(60)
        assert.are.equal(0, #mock.addonSent)
        assert.are.equal(0, #mock.addonPrefixes)
    end)

    it("prints the state with /flip sync", function()
        slash("sync")
        assert.are.equal("Flipside: guild sharing: off, not in a guild", mock.messages[1])
        assert.are.equal("Flipside: group sharing: off, not in a group", mock.messages[2])
        assert.are.equal(4, #mock.messages)
        assert.is_truthy(mock.messages[4]:find("shared items 0", 1, true))
    end)

    it("turns on with the setting, registers the prefix and shows it in /flip sync", function()
        assert.is_true(ns.SetGuildSync(true))
        assert.is_true(ns.db:Get("account", "sync.guildEnabled"))
        assert.are.same({ "Flipside" }, mock.addonPrefixes)
        mock.inGuild = true
        slash("sync")
        assert.are.equal("Flipside: guild sharing: on, in a guild", mock.messages[1])
    end)

    it("sends a request at once with /flip sync request", function()
        ns.SetGuildSync(true)
        mock.inGuild = true
        slash("sync request")
        assert.are.equal(1, #mock.addonSent)
        local call = mock.addonSent[1]
        assert.are.equal("Flipside", call.prefix)
        assert.are.equal("GUILD", call.chatType)
        assert.are.equal("Q", ns.GuildSyncCodec.Parse(call.text).kind)
        assert.are.equal("Flipside: request sent to the guild", mock.messages[1])
    end)

    it("sends no request when the setting is off or the player has no guild", function()
        mock.inGuild = true
        slash("sync request")
        assert.are.equal("Flipside: request not sent: disabled", mock.messages[1])
        ns.SetGuildSync(true)
        mock.inGuild = false
        slash("sync request")
        assert.are.equal("Flipside: request not sent: not-in-guild", mock.messages[1])
        assert.are.equal(0, #mock.addonSent)
    end)

    it("sends a request after the login delay when it is on and the player is in a guild", function()
        ns.SetGuildSync(true)
        mock.inGuild = true
        mock.advance(31)
        assert.are.equal(1, #mock.addonSent)
    end)

    describe("group sharing", function()
        it("is off by default: no message, no prefix, group messages are ignored", function()
            mock.inGroup = true
            mock.fire("GROUP_ROSTER_UPDATE")
            mock.advance(10)
            assert.is_false(ns.db:Get("account", "sync.groupEnabled") == true)
            assert.are.equal(0, #mock.addonSent)
            assert.are.equal(0, #mock.addonPrefixes)
            for _, text in ipairs(remoteSet(ns.guildSync.deps.scope, { "3001" }, 5000)) do
                receive(text, nil, "PARTY")
            end
            assert.are.equal(0, ns.guildSync:Status().items)
        end)

        it("turns on with the setting, registers the prefix once for both settings", function()
            assert.is_true(ns.SetGroupSync(true))
            assert.is_true(ns.db:Get("account", "sync.groupEnabled"))
            assert.are.same({ "Flipside" }, mock.addonPrefixes)
            ns.SetGuildSync(true)
            assert.are.same({ "Flipside" }, mock.addonPrefixes)
        end)

        it("sends to PARTY in a party and to RAID in a raid, and prints the state", function()
            ns.SetGroupSync(true)
            mock.inGroup = true
            slash("sync")
            assert.are.equal("Flipside: group sharing: on, channel PARTY", mock.messages[2])
            slash("sync request")
            assert.are.equal("PARTY", mock.addonSent[1].chatType)
            assert.are.equal("Flipside: request sent to the group", mock.messages[1])
            mock.inRaid = true
            slash("sync")
            assert.are.equal("Flipside: group sharing: on, channel RAID", mock.messages[2])
            slash("sync request")
            assert.are.equal("RAID", mock.addonSent[2].chatType)
        end)

        it("asks the guild and the group with /flip sync request", function()
            ns.SetGroupSync(true)
            ns.SetGuildSync(true)
            mock.inGuild, mock.inGroup = true, true
            slash("sync request")
            assert.are.equal(2, #mock.addonSent)
            assert.are.equal("GUILD", mock.addonSent[1].chatType)
            assert.are.equal("PARTY", mock.addonSent[2].chatType)
            assert.are.equal("Flipside: request sent to the guild and the group", mock.messages[1])
        end)

        it("sends no request when the player is in no group", function()
            ns.SetGroupSync(true)
            slash("sync request")
            assert.are.equal("Flipside: request not sent: not-in-group", mock.messages[1])
            assert.are.equal(0, #mock.addonSent)
        end)

        it("sends one request 5 s after the roster settles when the player joins a group", function()
            ns.SetGroupSync(true)
            mock.inGroup = true
            mock.fire("GROUP_ROSTER_UPDATE")
            mock.advance(4)
            mock.fire("GROUP_ROSTER_UPDATE")
            mock.advance(4)
            assert.are.equal(0, #mock.addonSent)
            mock.advance(2)
            assert.are.equal(1, #mock.addonSent)
            assert.are.equal("PARTY", mock.addonSent[1].chatType)
            assert.are.equal("Q", ns.GuildSyncCodec.Parse(mock.addonSent[1].text).kind)
        end)

        it("stores group messages and drops own messages", function()
            ns.SetGroupSync(true)
            local scope = ns.guildSync.deps.scope
            for _, text in ipairs(remoteSet(scope, { "3001" }, 5000)) do
                receive(text, "Tester-TestRealm", "PARTY")
            end
            assert.are.equal(0, ns.guildSync:Status().items)
            for _, text in ipairs(remoteSet(scope, { "3001" }, 5000)) do
                receive(text, nil, "RAID")
            end
            assert.are.equal(1, ns.guildSync:Status().items)
            assert.are.equal(4990, ns.formulaRun:Evaluate("scanmin", "3001"))
        end)

        it("leaves the guild path as it was: guild messages are ignored while only the group is on", function()
            ns.SetGroupSync(true)
            for _, text in ipairs(remoteSet(ns.guildSync.deps.scope, { "3001" }, 5000)) do
                receive(text, nil, "GUILD")
            end
            assert.are.equal(0, ns.guildSync:Status().items)
        end)
    end)

    it("keeps the marker of the last own share in the settings DB", function()
        local scope = ns.guildSync.deps.scope
        local markers = ns.db:Get("account", "sync.guildShare")
        assert.are.equal(markers[scope], ns.guildSync.marker)
    end)

    describe("received prices", function()
        local scope

        before_each(function()
            scope = ns.guildSync.deps.scope
        end)

        -- Put a local record. Without withDays it is like the record of a partial scan: no day data.
        local function putLocal(key, age, min, withDays)
            local record = ns.ScanRecord.New()
            local time = GetServerTime() - age
            record.latest = { time = time, min = min, market = min + 1, qty = 1, auctions = 1, partial = false }
            if withDays then
                record.days = { { day = ns.ScanClock.DayOf(time), min = min, market = min + 1, qty = 1, scans = 1 } }
            end
            ns.scanStore:Put(key, record)
        end

        it("fill the day data of a newer partial local record, so ScanMarket has a value", function()
            ns.SetGuildSync(true)
            putLocal("2592", 1, 111)
            for _, text in ipairs(remoteSet(scope, { "2592" }, 5000)) do
                receive(text)
            end
            assert.are.equal(111, ns.formulaRun:Evaluate("scanmin", "2592"))
            assert.are.equal(5000, ns.formulaRun:Evaluate("scanmarket", "2592"))
            assert.is_true(ns.IsGuildPrice("2592"))
        end)

        it("fill a gap in the price sources, and a newer local record wins", function()
            ns.SetGuildSync(true)
            putLocal("3002", 1, 111, true)
            for _, text in ipairs(remoteSet(scope, { "3001", "3002" }, 5000)) do
                receive(text)
            end
            assert.are.equal(2, ns.guildSync:Status().items)
            assert.are.equal(4990, ns.formulaRun:Evaluate("scanmin", "3001"))
            assert.are.equal(111, ns.formulaRun:Evaluate("scanmin", "3002"))
            assert.is_true(ns.IsGuildPrice("3001"))
            assert.is_false(ns.IsGuildPrice("3002"))
        end)

        it("win over an older local record", function()
            ns.SetGuildSync(true)
            putLocal("3002", 100, 111)
            for _, text in ipairs(remoteSet(scope, { "3002" }, 5000)) do
                receive(text)
            end
            assert.are.equal(4990, ns.formulaRun:Evaluate("scanmin", "3002"))
            assert.is_true(ns.IsGuildPrice("3002"))
        end)

        it("show in /flip price with a guild mark", function()
            ns.SetGuildSync(true)
            for _, text in ipairs(remoteSet(scope, { "3001" }, 5000)) do
                receive(text)
            end
            slash("price 3001")
            assert.is_true(mock.messages[1]:find("key 3001 (guild): ScanMin 4990", 1, true) ~= nil)
        end)

        it("are ignored while the setting is off", function()
            for _, text in ipairs(remoteSet(scope, { "3001" }, 5000)) do
                receive(text)
            end
            assert.are.equal(0, ns.guildSync:Status().items)
            assert.is_nil(ns.priceReader:Get("3001"))
        end)

        it("are hidden again when the setting goes off", function()
            ns.SetGuildSync(true)
            for _, text in ipairs(remoteSet(scope, { "3001" }, 5000)) do
                receive(text)
            end
            assert.is_not_nil(ns.priceReader:Get("3001"))
            ns.SetGuildSync(false)
            assert.is_nil(ns.priceReader:Get("3001"))
        end)

        it("are kept in the settings DB, apart from the scan data", function()
            ns.SetGuildSync(true)
            for _, text in ipairs(remoteSet(scope, { "3001" }, 5000)) do
                receive(text)
            end
            assert.is_string(ns.db:Get("account", "sync.guild")[scope].items["3001"])
            assert.is_nil(ns.scanStore:Get("3001"))
        end)
    end)
end)
