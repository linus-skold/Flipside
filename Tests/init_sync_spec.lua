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

local function receive(text, sender)
    mock.fire("CHAT_MSG_ADDON", "Flipside", text, "GUILD", sender or "Bob-TestRealm", "", 0, 0, "", 0)
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
        assert.are.equal(3, #mock.messages)
        assert.is_truthy(mock.messages[3]:find("shared items 0", 1, true))
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

    describe("received prices", function()
        local scope

        before_each(function()
            scope = ns.guildSync.deps.scope
        end)

        it("fill a gap in the price sources, and the local record wins", function()
            ns.SetGuildSync(true)
            local record = ns.ScanRecord.New()
            record.latest = { time = GetServerTime() - 100, min = 111, market = 222, qty = 1, auctions = 1,
                partial = false }
            ns.scanStore:Put("3002", record)
            for _, text in ipairs(remoteSet(scope, { "3001", "3002" }, 5000)) do
                receive(text)
            end
            assert.are.equal(2, ns.guildSync:Status().items)
            assert.are.equal(4990, ns.formulaRun:Evaluate("scanmin", "3001"))
            assert.are.equal(111, ns.formulaRun:Evaluate("scanmin", "3002"))
            assert.is_true(ns.IsGuildPrice("3001"))
            assert.is_false(ns.IsGuildPrice("3002"))
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
