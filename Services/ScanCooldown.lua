local _, ns = ...

local ScanCooldown = {}
ns.ScanCooldown = ScanCooldown

local DEFAULT_COOLDOWN = 900
local ATTEMPT_KEY = "scan.lastAttempt"
local SUCCESS_KEY = "scan.lastSuccess"

local Cooldown = {}
Cooldown.__index = Cooldown

function ScanCooldown.New(db, options)
    if type(db) ~= "table" then
        error("db is required", 2)
    end
    options = options or {}
    if type(options.clock) ~= "function" then
        error("options.clock must be a function", 2)
    end
    return setmetatable({
        _db = db,
        _clock = options.clock,
        _cooldown = options.cooldownSeconds or DEFAULT_COOLDOWN,
    }, Cooldown)
end

function Cooldown:GetLastAttempt()
    return self._db:Get("account", ATTEMPT_KEY)
end

function Cooldown:GetLastSuccess()
    return self._db:Get("account", SUCCESS_KEY)
end

-- Returns seconds until a new scan is allowed; 0 if allowed now.
function Cooldown:Remaining()
    local last = self:GetLastAttempt()
    if type(last) ~= "number" then
        return 0
    end
    local now = self._clock()
    if last > now then
        return 0
    end
    local left = last + self._cooldown - now
    if left < 0 then
        return 0
    end
    return left
end

function Cooldown:CanStart()
    return self:Remaining() == 0
end

function Cooldown:MarkAttempt()
    return self._db:Set("account", ATTEMPT_KEY, self._clock())
end

function Cooldown:MarkSuccess()
    return self._db:Set("account", SUCCESS_KEY, self._clock())
end

-- Returns text such as "14 min 05 s"; whole seconds, rounded up.
function ScanCooldown.FormatRemaining(seconds)
    local total = math.ceil(seconds or 0)
    if total < 0 then
        total = 0
    end
    local minutes = math.floor(total / 60)
    local rest = total - minutes * 60
    if minutes == 0 then
        return rest .. " s"
    end
    return string.format("%d min %02d s", minutes, rest)
end
