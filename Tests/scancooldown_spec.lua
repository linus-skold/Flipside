local ns = {}
assert(loadfile("Core/SettingsDB.lua"))("Flipside", ns)
assert(loadfile("Services/ScanCooldown.lua"))("Flipside", ns)
local SettingsDB = ns.SettingsDB
local ScanCooldown = ns.ScanCooldown

local function Open(saved, character)
    return SettingsDB.New(saved, { character = character or "Alice-Realm", schemaVersion = 1 })
end

local function Make(saved, now, extra)
    local clock = { t = now or 1000 }
    local opts = { clock = function() return clock.t end }
    for k, v in pairs(extra or {}) do
        opts[k] = v
    end
    return ScanCooldown.New(Open(saved), opts), clock
end

describe("ScanCooldown", function()
    it("allows a scan on a new DB", function()
        local cd = Make({})
        assert.are.equal(0, cd:Remaining())
        assert.is_true(cd:CanStart())
        assert.is_nil(cd:GetLastAttempt())
        assert.is_nil(cd:GetLastSuccess())
    end)

    it("counts down after MarkAttempt", function()
        local cd, clock = Make({}, 5000)
        assert.is_true(cd:MarkAttempt())
        assert.are.equal(5000, cd:GetLastAttempt())
        assert.are.equal(900, cd:Remaining())
        assert.is_false(cd:CanStart())
        clock.t = 5001
        assert.are.equal(899, cd:Remaining())
        clock.t = 5899
        assert.are.equal(1, cd:Remaining())
        assert.is_false(cd:CanStart())
        clock.t = 5900
        assert.are.equal(0, cd:Remaining())
        assert.is_true(cd:CanStart())
        clock.t = 6000
        assert.are.equal(0, cd:Remaining())
    end)

    it("shares the cooldown between characters", function()
        local saved = {}
        local a, clock = Make(saved, 100)
        a:MarkAttempt()
        local b = ScanCooldown.New(Open(saved, "Bob-Realm"), { clock = function() return clock.t + 60 end })
        assert.are.equal(840, b:Remaining())
        assert.is_false(b:CanStart())
    end)

    it("treats a future lastAttempt as ended", function()
        local cd, clock = Make({}, 5000)
        cd:MarkAttempt()
        clock.t = 4000
        assert.are.equal(0, cd:Remaining())
        assert.is_true(cd:CanStart())
    end)

    it("uses the stored value in a read-only DB", function()
        local saved = { _schema = 9, ["a/scan.lastAttempt"] = 1000 }
        local db = SettingsDB.New(saved, { character = "Alice-Realm", schemaVersion = 1, onWarning = function() end })
        assert.is_true(db:IsReadOnly())
        local cd = ScanCooldown.New(db, { clock = function() return 1100 end })
        assert.is_false(cd:MarkAttempt())
        assert.is_false(cd:MarkSuccess())
        assert.are.equal(1000, cd:GetLastAttempt())
        assert.are.equal(800, cd:Remaining())
    end)

    it("supports a custom cooldownSeconds", function()
        local cd, clock = Make({}, 0, { cooldownSeconds = 60 })
        cd:MarkAttempt()
        clock.t = 59
        assert.are.equal(1, cd:Remaining())
        clock.t = 60
        assert.are.equal(0, cd:Remaining())
    end)

    it("stores the last success separately", function()
        local cd, clock = Make({}, 700)
        assert.is_true(cd:MarkSuccess())
        assert.are.equal(700, cd:GetLastSuccess())
        assert.is_nil(cd:GetLastAttempt())
        assert.is_true(cd:CanStart())
        clock.t = 800
        cd:MarkAttempt()
        assert.are.equal(800, cd:GetLastAttempt())
        assert.are.equal(700, cd:GetLastSuccess())
    end)

    it("uses the documented account keys", function()
        local saved = {}
        local cd = Make(saved, 42)
        cd:MarkAttempt()
        cd:MarkSuccess()
        assert.are.equal(42, saved["a/scan.lastAttempt"])
        assert.are.equal(42, saved["a/scan.lastSuccess"])
    end)

    it("raises an error for a missing db or clock", function()
        assert.has_error(function() ScanCooldown.New(nil, { clock = function() return 0 end }) end)
        assert.has_error(function() ScanCooldown.New(Open({}), {}) end)
        assert.has_error(function() ScanCooldown.New(Open({})) end)
    end)

    describe("FormatRemaining", function()
        it("formats seconds and minutes", function()
            assert.are.equal("0 s", ScanCooldown.FormatRemaining(0))
            assert.are.equal("45 s", ScanCooldown.FormatRemaining(45))
            assert.are.equal("1 min 00 s", ScanCooldown.FormatRemaining(60))
            assert.are.equal("14 min 05 s", ScanCooldown.FormatRemaining(845))
            assert.are.equal("15 min 00 s", ScanCooldown.FormatRemaining(900))
        end)

        it("rounds fractions up", function()
            assert.are.equal("1 s", ScanCooldown.FormatRemaining(0.2))
            assert.are.equal("45 s", ScanCooldown.FormatRemaining(44.1))
            assert.are.equal("1 min 00 s", ScanCooldown.FormatRemaining(59.5))
            assert.are.equal("14 min 05 s", ScanCooldown.FormatRemaining(844.01))
        end)

        it("clamps negative input to zero", function()
            assert.are.equal("0 s", ScanCooldown.FormatRemaining(-5))
        end)
    end)
end)
