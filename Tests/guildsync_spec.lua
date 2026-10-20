local manifest = require("Tests.manifest")

describe("GuildSync", function()
    local ns, Codec, sync, deps, enabled, inGuild, clock, timers, wire, logs, localData, lastScan, prefixes
    local sendResult

    local SCOPE = "EU._.standard"
    local NOW = 1760000000

    before_each(function()
        ns = {}
        for _, name in ipairs({ "ScanClock", "ScanRecord", "GuildSyncCodec", "GuildPriceStore", "GuildSyncQueue",
            "GuildSync" }) do
            assert(loadfile(manifest.path(name)))("Flipside", ns)
        end
        Codec = ns.GuildSyncCodec
        enabled, inGuild, clock, timers, wire, logs, prefixes = true, true, NOW, {}, {}, {}, {}
        sendResult = 0
        localData = {}
        lastScan = NOW - 100
        local queue = ns.GuildSyncQueue.New({
            send = function(text)
                wire[#wire + 1] = text
                return sendResult
            end,
            after = function(seconds, fn)
                timers[#timers + 1] = { at = clock + seconds, fn = fn }
            end,
            clock = function()
                return clock
            end,
            burst = 1000,
        })
        deps = {
            isEnabled = function()
                return enabled
            end,
            isInGuild = function()
                return inGuild
            end,
            selfName = function()
                return "Me-Realm"
            end,
            realm = function()
                return "Realm"
            end,
            scope = SCOPE,
            localStore = {
                Keys = function()
                    local keys = {}
                    for key in pairs(localData) do
                        keys[#keys + 1] = key
                    end
                    table.sort(keys)
                    return keys
                end,
                Get = function(_, key)
                    return localData[key]
                end,
                GetVersion = function()
                    return 0
                end,
            },
            guildStore = ns.GuildPriceStore.New({}, {
                scope = SCOPE,
                now = function()
                    return clock
                end,
            }),
            queue = queue,
            clock = function()
                return clock
            end,
            after = function(seconds, fn)
                timers[#timers + 1] = { at = clock + seconds, fn = fn }
            end,
            random = function(low)
                return low
            end,
            registerPrefix = function(prefix)
                prefixes[#prefixes + 1] = prefix
            end,
            runJob = function(_, fn)
                fn(nil)
            end,
            lastScan = function()
                return lastScan
            end,
            log = function(level, fmt, ...)
                logs[#logs + 1] = level .. ": " .. string.format(fmt, ...)
            end,
        }
        sync = ns.GuildSync.New(deps)
    end)

    local function addLocal(count)
        for i = 1, count do
            localData[tostring(2000 + i)] = { latest = { time = NOW - i * 10, min = 900 + i, market = 1000 + i,
                qty = 3, auctions = 1, partial = false }, days = {} }
        end
    end

    -- A data set from another member, as messages.
    local function remoteSet(count, setId, scope, time)
        local list = {}
        for i = 1, count do
            list[i] = { key = tostring(3000 + i), min = 50 + i, market = 60 + i, qty = 2, time = time or NOW - 5 }
        end
        return assert(Codec.BuildSet(scope or SCOPE, setId or 5, list))
    end

    local function receive(text, sender, channel, prefix)
        sync:OnAddon("CHAT_MSG_ADDON", prefix or Codec.PREFIX, text, channel or "GUILD", sender or "Bob-Realm")
    end

    local function logged(pattern)
        for _, line in ipairs(logs) do
            if line:find(pattern) then
                return true
            end
        end
        return false
    end

    local function runTimers()
        local due = timers
        timers = {}
        for _, t in ipairs(due) do
            t.fn()
        end
    end

    describe("receive", function()
        it("stores the items of a full set from another member", function()
            for _, text in ipairs(remoteSet(30)) do
                receive(text)
            end
            assert.are.equal(30, deps.guildStore:Count())
            assert.are.equal(61, deps.guildStore:Get("3001").market)
            local status = sync:Status()
            assert.are.equal(1, status.senders)
            assert.are.equal(30, status.items)
            assert.are.equal(clock, status.lastReceive)
            assert.is_true(logged("^info: receive from Bob%-Realm"))
        end)

        it("stores nothing from an incomplete set", function()
            local messages = remoteSet(30)
            for i = 1, #messages - 1 do
                receive(messages[i])
            end
            assert.are.equal(0, deps.guildStore:Count())
            assert.are.equal(1, sync:Status().incoming)
            clock = clock + 120
            receive(Codec.BuildRequest(SCOPE, NOW))
            assert.are.equal(0, sync:Status().incoming)
            assert.is_true(logged("drop incomplete set from Bob"))
        end)

        it("ignores everything while the setting is off", function()
            enabled = false
            for _, text in ipairs(remoteSet(10)) do
                receive(text)
            end
            assert.are.equal(0, deps.guildStore:Count())
            assert.are.equal(0, sync:Status().senders)
            assert.are.equal(0, #timers)
        end)

        it("drops a message with another protocol version", function()
            for _, text in ipairs(remoteSet(5)) do
                receive((text:gsub("^1;", "2;")))
            end
            assert.are.equal(0, deps.guildStore:Count())
            assert.is_true(logged("drop version message"))
        end)

        it("drops a message with another region or ruleset key", function()
            for _, text in ipairs(remoteSet(5, 5, "US._.standard")) do
                receive(text)
            end
            for _, text in ipairs(remoteSet(5, 6, "EU._.hardcore")) do
                receive(text)
            end
            assert.are.equal(0, deps.guildStore:Count())
            assert.is_true(logged("drop key mismatch"))
        end)

        it("drops a message that is not valid", function()
            receive("hello")
            assert.is_true(logged("drop malformed message"))
        end)

        it("ignores own messages, with or without the realm in the sender", function()
            for _, text in ipairs(remoteSet(5)) do
                receive(text, "Me-Realm")
                receive(text, "me")
                receive(text, "ME-Realm")
            end
            assert.are.equal(0, deps.guildStore:Count())
            assert.are.equal(0, sync:Status().senders)
        end)

        it("ignores other prefixes and other channels", function()
            for _, text in ipairs(remoteSet(5)) do
                receive(text, "Bob-Realm", "GUILD", "Other")
                receive(text, "Bob-Realm", "PARTY")
            end
            assert.are.equal(0, deps.guildStore:Count())
        end)

        it("keeps the newest record of an item", function()
            for _, text in ipairs(remoteSet(3, 5, SCOPE, NOW - 5)) do
                receive(text, "Bob-Realm")
            end
            for _, text in ipairs(remoteSet(3, 6, SCOPE, NOW - 500)) do
                receive(text, "Ann-Realm")
            end
            assert.are.equal(NOW - 5, deps.guildStore:Get("3001").time)
            assert.are.equal(2, sync:Status().senders)
        end)
    end)

    describe("send", function()
        it("queues the local data as messages after a scan", function()
            addLocal(25)
            sync:OnScanFinished("Flipside.ScanFinished", { result = "ok" })
            assert.is_true(#wire >= 1)
            local items = 0
            for _, text in ipairs(wire) do
                assert.is_true(#text <= Codec.MAX_BYTES)
                local chunk = assert(Codec.Parse(text))
                assert.are.equal(SCOPE, chunk.scope)
                items = items + #Codec.ParseItems(chunk.items, chunk.time)
            end
            assert.are.equal(25, items)
            assert.are.equal(clock, sync:Status().lastSend)
            assert.same({ Codec.PREFIX }, prefixes)
        end)

        it("shares at most the newest MAX_ITEMS items", function()
            addLocal(Codec.MAX_ITEMS + 20)
            sync:SendSet("test")
            local items = 0
            for _, text in ipairs(wire) do
                local chunk = assert(Codec.Parse(text))
                items = items + #Codec.ParseItems(chunk.items, chunk.time)
            end
            assert.are.equal(Codec.MAX_ITEMS, items)
        end)

        it("does not share old items, empty prices or odd keys", function()
            localData["1"] = { latest = { time = NOW - 30 * 86400, min = 5, market = 5, qty = 1, auctions = 1,
                partial = false }, days = {} }
            localData["2"] = { latest = { time = NOW, min = 0, market = 5, qty = 1, auctions = 1, partial = false },
                days = {} }
            localData["x;y"] = { latest = { time = NOW, min = 5, market = 5, qty = 1, auctions = 1,
                partial = false }, days = {} }
            sync:SendSet("test")
            assert.are.equal(0, #wire)
            assert.is_true(logged("no data to share"))
        end)

        it("sends nothing while the setting is off", function()
            enabled = false
            addLocal(5)
            sync:OnScanFinished("Flipside.ScanFinished", { result = "ok" })
            assert.are.same({ false, "disabled" }, { sync:SendSet("test") })
            assert.are.same({ false, "disabled" }, { sync:SendRequest(true) })
            assert.are.equal(0, #wire)
            assert.are.equal(0, #prefixes)
        end)

        it("sends nothing when the player is not in a guild", function()
            inGuild = false
            addLocal(5)
            sync:OnScanFinished("Flipside.ScanFinished", { result = "ok" })
            assert.are.same({ false, "not-in-guild" }, { sync:SendRequest(true) })
            assert.are.equal(0, #wire)
        end)

        it("sends nothing after a scan that did not end well or a page scan", function()
            addLocal(5)
            sync:OnScanFinished("Flipside.ScanFinished", { result = "cancelled" })
            sync:OnScanFinished("Flipside.ScanFinished", { result = "ok", mode = "page" })
            assert.are.equal(0, #wire)
        end)

        it("replaces an older set that still waits in the queue", function()
            addLocal(25)
            sendResult = 3
            sync:SendSet("first")
            sync:SendSet("second")
            local waiting = deps.queue:Pending()
            assert.is_true(waiting > 0)
            sync:SendSet("third")
            assert.are.equal(waiting, deps.queue:Pending())
        end)

        it("retries later when the client refuses a message", function()
            addLocal(3)
            sendResult = 3
            sync:SendSet("test")
            local tries = #wire
            assert.are.equal(1, tries)
            sendResult = 0
            clock = clock + 10
            runTimers()
            assert.is_true(#wire > tries)
            assert.are.equal(0, deps.queue:Pending())
        end)
    end)

    describe("request and reply", function()
        it("sends a request with the newest time", function()
            assert.is_true(sync:SendRequest(true))
            local request = assert(Codec.Parse(wire[1]))
            assert.are.same({ kind = "Q", scope = SCOPE, newest = lastScan }, request)
            assert.are.equal(clock, sync:Status().lastRequest)
        end)

        it("does not send a second request soon unless forced", function()
            assert.is_true(sync:SendRequest())
            assert.are.same({ false, "recent" }, { sync:SendRequest() })
            assert.is_true(sync:SendRequest(true))
            assert.are.equal(2, #wire)
        end)

        it("answers a request when it has newer data, after a delay", function()
            addLocal(5)
            receive(Codec.BuildRequest(SCOPE, NOW - 10000))
            assert.are.equal(0, #wire)
            assert.are.equal(1, #timers)
            assert.are.equal(clock + ns.GuildSync.REPLY_DELAY_MIN, timers[1].at)
            runTimers()
            assert.is_true(#wire >= 1)
        end)

        it("does not answer when its data is not newer", function()
            addLocal(5)
            receive(Codec.BuildRequest(SCOPE, lastScan))
            receive(Codec.BuildRequest(SCOPE, lastScan + 5000))
            assert.are.equal(0, #timers)
            assert.are.equal(0, #wire)
        end)

        it("does not answer a request of its own account or with another key", function()
            addLocal(5)
            receive(Codec.BuildRequest(SCOPE, 0), "Me-Realm")
            receive(Codec.BuildRequest("US._.standard", 0))
            assert.are.equal(0, #timers)
        end)

        it("does not answer when someone else sent data first", function()
            addLocal(5)
            receive(Codec.BuildRequest(SCOPE, 0))
            receive(remoteSet(2)[1], "Ann-Realm")
            runTimers()
            assert.are.equal(0, #wire)
            assert.is_true(logged("reply cancelled"))
        end)

        it("plans only one reply, and waits before it answers again", function()
            addLocal(5)
            receive(Codec.BuildRequest(SCOPE, 0))
            receive(Codec.BuildRequest(SCOPE, 0), "Ann-Realm")
            assert.are.equal(1, #timers)
            runTimers()
            local sentNow = #wire
            receive(Codec.BuildRequest(SCOPE, 0), "Ann-Realm")
            assert.are.equal(0, #timers)
            assert.are.equal(sentNow, #wire)
            clock = clock + ns.GuildSync.REPLY_COOLDOWN + 1
            receive(Codec.BuildRequest(SCOPE, 0), "Ann-Realm")
            assert.are.equal(1, #timers)
        end)

        it("sends no reply if the setting went off during the delay", function()
            addLocal(5)
            receive(Codec.BuildRequest(SCOPE, 0))
            enabled = false
            runTimers()
            assert.are.equal(0, #wire)
        end)
    end)

    describe("setting", function()
        it("registers the prefix once, only when on", function()
            enabled = false
            sync:EnsureRegistered()
            assert.are.equal(0, #prefixes)
            enabled = true
            sync:OnSettingChanged()
            sync:EnsureRegistered()
            assert.same({ Codec.PREFIX }, prefixes)
        end)

        it("clears the send queue when turned off", function()
            addLocal(25)
            sendResult = 3
            sync:SendSet("test")
            assert.is_true(deps.queue:Pending() > 0)
            enabled = false
            sync:OnSettingChanged()
            assert.are.equal(0, deps.queue:Pending())
        end)
    end)

    describe("status lines", function()
        it("shows the state", function()
            local lines = ns.GuildSync.StatusLines(sync:Status(), clock)
            assert.are.equal("guild sharing: on, in a guild", lines[1])
            assert.are.equal("last send never, last receive never, last request never", lines[2])
            assert.are.equal("senders this session 0, shared items 0, queued messages 0, incoming sets 0", lines[3])
        end)

        it("shows off and not in a guild, and times that passed", function()
            enabled, inGuild = false, false
            local status = sync:Status()
            status.lastSend = clock - 30
            status.lastReceive = clock - 600
            local lines = ns.GuildSync.StatusLines(status, clock)
            assert.are.equal("guild sharing: off, not in a guild", lines[1])
            assert.are.equal("last send 30 s ago, last receive 10 min ago, last request never", lines[2])
        end)
    end)
end)
