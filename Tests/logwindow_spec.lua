local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local KIT = { "Theme", "Window", "Widgets", "List", "Columns", "Combat" }
local BASE_TIME = 1000000

describe("LogWindow", function()
    local ns, view, timers

    local function texts()
        local list = {}
        for i, row in ipairs(view:GetRows()) do
            list[i] = row.text
        end
        return list
    end

    before_each(function()
        mock.reset()
        _G.time = function()
            return BASE_TIME
        end
        ns = {}
        for _, name in ipairs(KIT) do
            assert(loadfile(manifest.path(name)))("Flipside", ns)
        end
        assert(loadfile(manifest.path("Log")))("Flipside", ns)
        assert(loadfile(manifest.path("LogWindow")))("Flipside", ns)
        ns.Log.SetDebug(true)
        ns.Log.Write("scan", "debug", "query sent")
        ns.Log.Write("scan", "info", "scan started")
        ns.Log.Write("mail", "warn", "Mail to Bob failed")
        ns.Log.Write("core", "error", "handler failed")
        timers = {}
        view = ns.LogWindow.Create({
            log = ns.Log,
            after = function(seconds, fn)
                timers[#timers + 1] = { seconds = seconds, fn = fn }
            end,
        })
        view:Refresh()
    end)

    after_each(function()
        mock.teardown()
    end)

    it("creates the window once, with a title", function()
        assert.are.equal(view, ns.LogWindow.Create({ log = ns.Log }))
        assert.are.equal("Flipside log", view.frame.title)
    end)

    it("shows the newest entry first by default", function()
        assert.are.same({ "handler failed", "Mail to Bob failed", "scan started", "query sent" }, texts())
        assert.are.equal("4 of 4 entries shown", view.status:GetText())
    end)

    it("has a column for the time, the level, the category and the text", function()
        local row = view:GetRows()[1]
        assert.is_truthy(row.clock:find("^%d%d:%d%d:%d%d%.%d%d%d$"))
        assert.are.equal("error", row.level)
        assert.are.equal("core", row.category)
    end)

    it("shows the oldest entry first when the order is switched", function()
        view:SetNewestFirst(false)
        assert.are.same({ "query sent", "scan started", "Mail to Bob failed", "handler failed" }, texts())
    end)

    it("filters by the minimum level", function()
        view:SetMinLevel("warn")
        assert.are.same({ "handler failed", "Mail to Bob failed" }, texts())
        assert.are.equal("2 of 4 entries shown", view.status:GetText())
    end)

    it("filters by category", function()
        view:SetCategory("scan")
        assert.are.same({ "scan started", "query sent" }, texts())
        view:SetCategory(nil)
        assert.are.equal(4, #texts())
    end)

    it("filters by text", function()
        view:SetSearch("bob")
        assert.are.same({ "Mail to Bob failed" }, texts())
    end)

    it("combines the filters", function()
        view:SetMinLevel("info")
        view:SetCategory("scan")
        view:SetSearch("started")
        assert.are.same({ "scan started" }, texts())
    end)

    it("gives the filtered entries as plain text, oldest first", function()
        view:SetMinLevel("warn")
        local lines = {}
        for line in view:GetText():gmatch("[^\n]+") do
            lines[#lines + 1] = line
        end
        assert.are.equal(2, #lines)
        assert.is_truthy(lines[1]:find("%d%d:%d%d:%d%d%.%d%d%d %[warn%] %[mail%] Mail to Bob failed$"))
        assert.is_truthy(lines[2]:find("%[error%] %[core%] handler failed$"))
    end)

    it("opens a read-only copy dialog with the text", function()
        view:SetCategory("mail")
        local dialog = view:Copy()
        assert.is_true(dialog:IsShown())
        assert.are.equal(view:GetText(), dialog.input:GetText())
        assert.is_truthy(dialog.input:GetText():find("Mail to Bob failed", 1, true))
    end)

    it("clears the log", function()
        view:Clear()
        assert.are.equal(0, ns.Log.Count())
        assert.are.same({}, texts())
        assert.are.equal("0 of 0 entries shown", view.status:GetText())
    end)

    it("asks for a confirm before the Clear button removes the entries", function()
        view.clearButton.scripts.OnClick(view.clearButton)
        assert.is_not_nil(mock.popup)
        assert.are.equal(4, ns.Log.Count())
        StaticPopupDialogs.FLIPSIDE_LOG_CLEAR.OnAccept()
        assert.are.equal(0, ns.Log.Count())
    end)

    it("sets the debug and the trace switch from the check boxes", function()
        view.debugCheck:SetChecked(false)
        view.debugCheck.scripts.OnClick(view.debugCheck)
        assert.is_false(ns.Log.IsDebug())
        view.traceCheck:SetChecked(true)
        view.traceCheck.scripts.OnClick(view.traceCheck)
        assert.is_true(ns.Log.IsTrace())
    end)

    it("refreshes after a new entry while it is shown, at most once for each wait", function()
        view.frame:Show()
        view.frame.scripts.OnShow(view.frame)
        ns.Log.Write("core", "info", "new one")
        ns.Log.Write("core", "info", "new two")
        assert.are.equal(1, #timers)
        timers[1].fn()
        assert.are.equal("new two", texts()[1])
    end)

    it("stops the refresh when it is hidden", function()
        view.frame:Show()
        view.frame.scripts.OnShow(view.frame)
        view.frame:Hide()
        ns.Log.Write("core", "info", "late")
        assert.are.equal(0, #timers)
    end)
end)
