local _, ns = ...

-- Loads the ledger addon on demand and moves the buffer into the ledger store (SPEC 5.8 point 1).
-- It never loads in combat: it waits for PLAYER_REGEN_ENABLED.
local LedgerLoader = {}
ns.LedgerLoader = LedgerLoader

LedgerLoader.EVENT_LOADED = "Flipside.LedgerLoaded"
LedgerLoader.EVENT_FAILED = "Flipside.LedgerLoadFailed"

local Loader = {}
Loader.__index = Loader

-- Moves the buffer into the store. Puts the records back if the move fails.
function Loader:_Flush()
    local records = self._buffer:Drain()
    if #records == 0 then
        return true
    end
    local ok, moved = pcall(self._store.Move, self._store, records)
    if ok and moved then
        return true
    end
    self._buffer:Restore(records)
    return false, ok and "the ledger is read-only" or tostring(moved)
end

function Loader:_Fail(reason)
    self._failed = true
    self._bus:Emit(LedgerLoader.EVENT_FAILED, reason)
    return false, reason
end

-- Loads the ledger addon and moves the buffer into the store. Call it when the page opens or a feature needs
-- the ledger. Returns true, or false and a reason: "combat" (queued), "busy" or the failure text.
function Loader:Ensure()
    if self._busy then
        return false, "busy"
    end
    if self._job then
        self._job:Cancel()
    end
    if self._inCombat() then
        self._pending = true
        return false, "combat"
    end
    self._pending = false
    self._busy = true
    local ok, a, b = pcall(self._ensure, self)
    self._busy = false
    if not ok then
        return self:_Fail(tostring(a))
    end
    return a, b
end

-- Loads the addon and opens the store (synchronous). Returns true, or false and a reason.
function Loader:_Open()
    local loaded, reason = self._loadAddOn(self._addonName)
    if not loaded then
        return false, reason or "unknown"
    end
    local store = self._openStore()
    if not store then
        return false, "the ledger data is not available"
    end
    self._store = store
    self._failed = false
    return true
end

-- Compacts the store once per session. step() (optional) is passed to Store:Compact.
function Loader:_Compact(step)
    self._compacted = true
    self._store:Compact(self._now(), {
        retentionDays = self._setting("ledger.retentionDays"),
        logDays = self._setting("ledger.logDays"),
    }, step)
    self._bus:Emit(LedgerLoader.EVENT_LOADED)
end

function Loader:_ensure()
    if not self._store then
        local opened, reason = self:_Open()
        if not opened then
            return self:_Fail(reason)
        end
    end
    if not self._compacted then
        self:_Compact()
    end
    local ok, reason = self:_Flush()
    if not ok then
        return self:_Fail(reason)
    end
    return true
end

local MOVE_CHUNK = 100

-- Body of the sliced flush job. Each slice takes a chunk from the buffer and moves it with no yield between,
-- so a reload between two slices loses no record and moves none twice. Records added during the job
-- stay at the end of the buffer and are moved by a later slice.
function Loader:_Sliced(job)
    if not self._store then
        local opened, reason = self:_Open()
        if not opened then
            self:_Fail(reason)
            return
        end
    end
    if not self._compacted then
        self:_Compact(function()
            job:Checkpoint(1)
        end)
    end
    while self._buffer:Count() > 0 do
        local chunk = self._buffer:TakeFront(MOVE_CHUNK)
        if #chunk == 0 then
            return
        end
        local ok, moved = pcall(self._store.Move, self._store, chunk)
        if not (ok and moved) then
            self._buffer:Restore(chunk)
            self:_Fail(ok and "the ledger is read-only" or tostring(moved))
            return
        end
        job:Checkpoint(#chunk)
    end
end

-- Starts the flush as a Scheduler job. Returns true if it started. A sync Ensure cancels a running job first.
function Loader:_StartSliced()
    self._pending = false
    self._flushing = true
    local job = self._startJob("ledger-flush", function(running)
        self:_Sliced(running)
    end)
    self._job = job
    job:OnDone(function(_, status, message)
        self._flushing = false
        self._job = nil
        if status == "failed" then
            self:_Fail(tostring(message))
        end
    end)
    return true
end

-- Called by the buffer at the cap. It loads the addon later, out of the call. After a failed load it does
-- nothing again in this session; Ensure still tries. With a startJob option it flushes in slices;
-- a second call while a flush runs does nothing.
function Loader:RequestFlush()
    if self._failed or self._requested or self._flushing then
        return
    end
    self._requested = true
    local function run()
        self._requested = false
        if self._flushing then
            return
        end
        if self._startJob then
            if self._inCombat() then
                self._pending = true
                return
            end
            self:_StartSliced()
            return
        end
        self:Ensure()
    end
    if self._after then
        self._after(0, run)
    else
        run()
    end
end

-- Returns the store if the addon is loaded; otherwise nil.
function Loader:Store()
    return self._store
end

-- Returns true if a load waits for the end of combat.
function Loader:IsPending()
    return self._pending
end

-- Subscribes to PLAYER_REGEN_ENABLED (run a queued load) and PLAYER_ENTERING_WORLD (load once at login
-- if the buffer is not empty).
function Loader:Attach()
    self._bus:Subscribe("PLAYER_REGEN_ENABLED", self, function()
        if self._pending then
            self:Ensure()
        end
    end)
    self._bus:Subscribe("PLAYER_ENTERING_WORLD", self, function()
        if self._loginDone then
            return
        end
        self._loginDone = true
        if self._buffer:Count() > 0 then
            self:Ensure()
        end
    end)
end

-- options: bus, buffer, openStore() -> store or nil, loadAddOn(name) -> loaded, reason, inCombat(),
-- now(), setting(key) -> number or nil, addonName, after(seconds, fn) (optional),
-- startJob(name, fn) -> job (optional; a Scheduler job starter; without it the flush is synchronous).
function LedgerLoader.New(options)
    for _, name in ipairs({ "bus", "buffer", "openStore", "loadAddOn", "inCombat", "now" }) do
        if options[name] == nil then
            error("options." .. name .. " is missing", 2)
        end
    end
    return setmetatable({
        _bus = options.bus,
        _buffer = options.buffer,
        _openStore = options.openStore,
        _loadAddOn = options.loadAddOn,
        _inCombat = options.inCombat,
        _now = options.now,
        _setting = options.setting or function() end,
        _after = options.after,
        _startJob = options.startJob,
        _compacted = false,
        _flushing = false,
        _addonName = options.addonName or "Flipside_Ledger",
        _pending = false,
        _failed = false,
        _busy = false,
        _requested = false,
        _loginDone = false,
    }, Loader)
end
