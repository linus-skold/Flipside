local _, ns = ...

-- The "Scan and buy" walk of the Vendor source (SPEC 5.3 point 24a). This is the state of the walk and its
-- decisions, with no frame code and no AH call. The Buying tab does the searches and the buys. The walk only says
-- which row is next. It never buys (D26).
local BuyWalk = {}
ns.BuyWalk = BuyWalk

BuyWalk.TEXT = {
    cooldown = "scan skipped because of the cooldown, search of the current list started",
    partial = "the scan was partial, scan and buy stopped",
    failed = "the scan did not finish, scan and buy stopped",
    done = "scan and buy done",
    stopped = "scan and buy stopped",
    empty = "no items to buy",
}

-- The reasons of Tab:_NextBuy that mean that the item has no level left to buy at or below the max price.
local NONE_LEFT = {
    ["nothing left to buy"] = true,
    ["above max price"] = true,
    ["own listing"] = true,
    ["own listing below the selected level"] = true,
}

-- True if the item has no buyable level left. level is the next level (or nil), reason is the buy refusal (or nil).
function BuyWalk.NoneLeft(level, reason)
    if level == nil and reason == nil then
        return true
    end
    return reason ~= nil and NONE_LEFT[reason] == true
end

-- True if a finished scan is a full scan that saved its data. summary is the payload of Flipside.ScanFinished.
function BuyWalk.IsFullScan(summary)
    if type(summary) ~= "table" or summary.result ~= "ok" then
        return false
    end
    return summary.mode == nil or summary.mode == "full"
end

-- Decide what a click on "Scan and buy" does. input:
--   canStart (boolean) and reason (text) are the result of the scan engine CanStart.
--   state (text or nil) is the state text of the Vendor list (nil for a list with rows).
--   partial (boolean) is true if the last scan was partial.
-- Returns "scan", "walk" (cooldown: skip the scan, use the list) or "empty" (cooldown, no usable list, with the
-- state text), or "refuse" (with the reason).
function BuyWalk.Decide(input)
    if input.canStart then
        return "scan"
    end
    if input.reason == "cooldown" or input.reason == "client" then
        if input.state == nil and not input.partial then
            return "walk"
        end
        return "empty", input.state or BuyWalk.TEXT.empty
    end
    return "refuse", input.reason
end

local Walk = {}
Walk.__index = Walk

-- Create a walk. Phases: "idle", "scan" (waits for the end of the scan), "list" (waits for the Vendor list) and
-- "walk" (goes through the rows).
function BuyWalk.New()
    return setmetatable({ phase = "idle", keys = {}, pos = 0 }, Walk)
end

function Walk:IsActive()
    return self.phase ~= "idle"
end

function Walk:IsWalking()
    return self.phase == "walk"
end

function Walk:IsWaitingForScan()
    return self.phase == "scan"
end

function Walk:IsWaitingForList()
    return self.phase == "list"
end

-- The key of the current row, or nil.
function Walk:Current()
    return self.phase == "walk" and self.keys[self.pos] or nil
end

-- Wait for a scan that the tab started.
function Walk:BeginScan()
    self.phase, self.keys, self.pos = "scan", {}, 0
end

-- End the walk. Returns true if it was active.
function Walk:Stop()
    local was = self.phase ~= "idle"
    self.phase, self.keys, self.pos = "idle", {}, 0
    return was
end

-- Start the walk over a list of item keys (most profit first), from any phase.
-- Returns the first key, or nil and a text.
function Walk:Begin(keys)
    if #keys == 0 then
        self:Stop()
        return nil, BuyWalk.TEXT.empty
    end
    self.phase, self.keys, self.pos = "walk", { unpack(keys) }, 0
    return self:Advance()
end

-- Go to the next row. Returns its key, or nil and the done text after the last row (the walk ends).
function Walk:Advance()
    if self.phase ~= "walk" then
        return nil
    end
    self.pos = self.pos + 1
    local key = self.keys[self.pos]
    if key == nil then
        self:Stop()
        return nil, BuyWalk.TEXT.done
    end
    return key
end

-- The scan ended. Only a walk that waits for a scan reacts. Returns "list" when a full scan saved its data (the walk now
-- waits for the Vendor list), "stop" and a text for a failed or partial scan, or nil when the walk did not wait for a scan.
function Walk:OnScanFinished(summary)
    if self.phase ~= "scan" then
        return nil
    end
    if BuyWalk.IsFullScan(summary) then
        self.phase = "list"
        return "list"
    end
    self:Stop()
    if type(summary) == "table" and summary.result == "partial" then
        return "stop", BuyWalk.TEXT.partial
    end
    return "stop", BuyWalk.TEXT.failed
end
