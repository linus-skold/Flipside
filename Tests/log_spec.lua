local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local BASE_TIME = 1000000

local function load()
    local ns = {}
    assert(loadfile(manifest.path("Log")))("Flipside", ns)
    return ns.Log
end

describe("Log", function()
    local Log

    before_each(function()
        mock.reset()
        _G.time = function()
            return BASE_TIME
        end
        mock.clock = 5.25
        Log = load()
    end)

    after_each(function()
        mock.teardown()
    end)

    local function texts(entries)
        local list = {}
        for i, entry in ipairs(entries) do
            list[i] = entry.text
        end
        return list
    end

    it("writes and reads an entry", function()
        Log.Write("scan", "info", "hello")
        local entries = Log.Query()
        assert.are.equal(1, #entries)
        assert.are.equal("scan", entries[1].category)
        assert.are.equal("info", entries[1].level)
        assert.are.equal("hello", entries[1].text)
        assert.are.equal(BASE_TIME, entries[1].time)
        assert.are.equal(0, entries[1].ms)
    end)

    it("gives milliseconds from GetTime", function()
        Log.Write("core", "info", "a")
        mock.clock = 5.75
        Log.Write("core", "info", "b")
        local entries = Log.Query()
        assert.are.equal(BASE_TIME, entries[2].time)
        assert.are.equal(500, entries[2].ms)
        assert.is_truthy(Log.FormatTime(entries[2]):find("^%d%d:%d%d:%d%d%.500$"))
    end)

    it("uses info for an unknown level", function()
        Log.Write("core", "loud", "x")
        assert.are.equal("info", Log.Query()[1].level)
    end)

    it("does not store debug entries by default", function()
        assert.is_false(Log.IsDebug())
        Log.Write("core", "debug", "hidden")
        Log.Writef("core", "debug", "hidden %d", 1)
        assert.are.equal(0, Log.Count())
        Log.Write("core", "info", "shown")
        Log.Write("core", "warn", "shown")
        Log.Write("core", "error", "shown")
        assert.are.equal(3, Log.Count())
    end)

    it("stores debug entries when the setting is on", function()
        Log.SetDebug(true)
        Log.Write("core", "debug", "seen")
        assert.are.same({ "seen" }, texts(Log.Query()))
    end)

    it("drops the oldest entries at the cap", function()
        Log.SetCap(100)
        for i = 1, 105 do
            Log.Write("core", "info", "m" .. i)
        end
        assert.are.equal(100, Log.Count())
        local entries = Log.Query()
        assert.are.equal("m6", entries[1].text)
        assert.are.equal("m105", entries[100].text)
    end)

    it("keeps the cap in range and defaults to 3000", function()
        assert.are.equal(3000, Log.GetCap())
        Log.SetCap(5)
        assert.are.equal(100, Log.GetCap())
        Log.SetCap(10 ^ 9)
        assert.are.equal(20000, Log.GetCap())
        Log.SetCap("x")
        assert.are.equal(3000, Log.GetCap())
    end)

    it("formats with Writef", function()
        Log.Writef("scan", "info", "rows %d of %s", 5, "ten")
        assert.are.equal("rows 5 of ten", Log.Query()[1].text)
    end)

    it("logs the raw format when Writef fails", function()
        Log.Writef("scan", "info", "rows %d", "abc")
        Log.Writef("scan", "info", "bad %z", 1)
        Log.Writef("scan", "info", "need %s")
        assert.are.same({ "rows %d", "bad %z", "need %s" }, texts(Log.Query()))
    end)

    it("never raises an error on nil or table arguments", function()
        local bad = setmetatable({}, {
            __tostring = function()
                error("no text")
            end,
        })
        assert.has_no.errors(function()
            Log.Write(nil, nil, nil)
            Log.Write({}, {}, {})
            Log.Write("core", "info", bad)
            Log.Writef(nil, nil, nil)
            Log.Writef("core", "info", "%s %s %s", nil, {}, bad)
            Log.Writef("core", "info", {}, nil)
            Log.Trace(nil)
            Log.SessionMarker(nil)
        end)
        assert.is_true(Log.Count() >= 5)
    end)

    it("keeps one line for a multi-line text and limits the length", function()
        Log.Write("core", "error", "line one\nline two")
        Log.Write("core", "info", string.rep("x", 2000))
        local entries = Log.Query()
        assert.are.equal("line one | line two", entries[1].text)
        assert.is_true(#entries[2].text <= 600)
    end)

    it("writes the session marker", function()
        Log.SessionMarker({
            version = "1.2.3", flavour = "FlipsideDB", client = "1.60.1", build = 70338, interface = 16001,
            realm = "Realm", character = "Me",
        })
        local entry = Log.Query()[1]
        assert.are.equal("core", entry.category)
        assert.are.equal("info", entry.level)
        assert.is_truthy(entry.text:find("1.2.3", 1, true))
        assert.is_truthy(entry.text:find("FlipsideDB", 1, true))
        assert.is_truthy(entry.text:find("70338", 1, true))
        assert.is_truthy(entry.text:find("Realm", 1, true))
        assert.is_truthy(entry.text:find("Me", 1, true))
    end)

    describe("persistence", function()
        it("fills a saved table with the ring shape", function()
            local saved = Log.Attach({})
            assert.are.equal(1, saved.version)
            assert.are.equal(1, saved.first)
            assert.are.equal(0, saved.last)
            assert.are.same({}, saved.entries)
            assert.is_false(saved.debug)
            assert.is_false(saved.trace)
            assert.are.equal(3000, saved.cap)
            Log.Write("scan", "info", "kept")
            assert.are.equal(1, saved.last)
            assert.are.same(
                { time = BASE_TIME, ms = 0, level = "info", category = "scan", text = "kept" }, saved.entries[1])
        end)

        it("moves the entries that were written before the attach", function()
            Log.Write("core", "info", "early")
            local saved = Log.Attach({})
            Log.Write("core", "info", "late")
            assert.are.same({ "early", "late" }, texts(Log.Query()))
            assert.are.equal(2, saved.last)
        end)

        it("keeps the entries and settings over a reload", function()
            local saved = Log.Attach({})
            Log.SetDebug(true)
            Log.SetTrace(true)
            Log.Write("mail", "warn", "before reload")
            local reloaded = load()
            reloaded.Attach(saved)
            assert.are.same({ "before reload" }, texts(reloaded.Query()))
            assert.is_true(reloaded.IsDebug())
            assert.is_true(reloaded.IsTrace())
        end)

        it("clears a broken saved table", function()
            local saved = Log.Attach({ first = "x", last = 5, entries = 3, cap = "bad" })
            assert.are.equal(0, Log.Count())
            assert.are.equal(1, saved.first)
            assert.are.equal(3000, saved.cap)
            assert.has_no.errors(function()
                Log.Write("core", "info", "ok")
            end)
        end)

        it("trims a saved table that is above the cap", function()
            local entries = {}
            for i = 1, 150 do
                entries[i] = { time = 1, ms = 0, level = "info", category = "core", text = "e" .. i }
            end
            Log.Attach({ first = 1, last = 150, entries = entries, cap = 100 })
            Log.Write("core", "info", "new")
            assert.are.equal(100, Log.Count())
            assert.are.equal("new", Log.Query()[100].text)
        end)

        it("returns a table when the saved value is not a table", function()
            assert.is_table(Log.Attach(nil))
            assert.is_table(Log.Attach("x"))
        end)
    end)

    describe("event trace", function()
        it("does nothing while the trace is off", function()
            Log.Trace("BAG_UPDATE", 1)
            assert.are.equal(0, Log.Count())
        end)

        it("records a game event with shortened arguments, also with debug off", function()
            Log.SetTrace(true)
            Log.Trace("MAIL_SEND_SUCCESS", 1, "two", nil, { 3 }, string.rep("y", 100))
            local entry = Log.Query()[1]
            assert.are.equal("event", entry.category)
            assert.are.equal("debug", entry.level)
            assert.is_truthy(entry.text:find("^MAIL_SEND_SUCCESS 1, two, nil, table: "))
            assert.is_true(#entry.text < 160)
        end)

        it("shows how many arguments it left out", function()
            Log.SetTrace(true)
            Log.Trace("BAG_UPDATE", 1, 2, 3, 4, 5, 6, 7, 8)
            assert.are.equal("BAG_UPDATE 1, 2, 3, 4, 5, 6 (+2)", Log.Query()[1].text)
        end)

        it("ignores internal events", function()
            Log.SetTrace(true)
            Log.Trace("Flipside.ScanProgress", 1)
            assert.are.equal(0, Log.Count())
        end)
    end)

    describe("queries", function()
        before_each(function()
            Log.SetDebug(true)
            Log.Write("scan", "debug", "query sent")
            Log.Write("scan", "info", "scan started")
            Log.Write("mail", "warn", "Mail to Bob failed")
            Log.Write("core", "error", "handler failed")
        end)

        it("filters by the minimum level", function()
            assert.are.equal(4, #Log.Query({ minLevel = "debug" }))
            assert.are.equal(3, #Log.Query({ minLevel = "info" }))
            assert.are.same({ "Mail to Bob failed", "handler failed" }, texts(Log.Query({ minLevel = "warn" })))
            assert.are.same({ "handler failed" }, texts(Log.Query({ minLevel = "error" })))
        end)

        it("filters by category", function()
            assert.are.same({ "query sent", "scan started" }, texts(Log.Query({ category = "scan" })))
            assert.are.equal(4, #Log.Query({ category = "" }))
        end)

        it("filters by text, not case-sensitive, also in the category", function()
            assert.are.same({ "Mail to Bob failed" }, texts(Log.Query({ search = "BOB" })))
            assert.are.same({ "Mail to Bob failed" }, texts(Log.Query({ search = "mail" })))
            assert.are.equal(0, #Log.Query({ search = "nothing" }))
        end)

        it("lists the categories sorted", function()
            assert.are.same({ "core", "mail", "scan" }, Log.Categories())
        end)

        it("clears the entries and keeps the settings", function()
            Log.Clear()
            assert.are.equal(0, Log.Count())
            assert.is_true(Log.IsDebug())
            Log.Write("core", "info", "again")
            assert.are.equal(1, Log.Count())
        end)

        it("formats the text of entries", function()
            local line = Log.FormatEntry({ time = BASE_TIME, ms = 7, level = "warn", category = "mail", text = "x" })
            assert.is_truthy(line:find("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%.007 %[warn%] %[mail%] x$"))
            local text = Log.ToText(Log.Query({ minLevel = "warn" }))
            local lines = {}
            for each in text:gmatch("[^\n]+") do
                lines[#lines + 1] = each
            end
            assert.are.equal(2, #lines)
            assert.is_truthy(lines[1]:find("[warn] [mail] Mail to Bob failed", 1, true))
            assert.is_truthy(lines[2]:find("[error] [core] handler failed", 1, true))
        end)
    end)

    it("calls the listener after each entry", function()
        local count = 0
        Log.SetListener(function()
            count = count + 1
        end)
        Log.Write("core", "info", "a")
        Log.Write("core", "debug", "dropped")
        assert.are.equal(1, count)
        Log.SetListener(nil)
        Log.Write("core", "info", "b")
        assert.are.equal(1, count)
    end)
end)
