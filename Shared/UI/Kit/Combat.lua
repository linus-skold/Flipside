local _, ns = ...
ns.Kit = ns.Kit or {}
local Kit = ns.Kit

local queue = {}
local eventFrame

local function flush()
    local list = queue
    queue = {}
    for _, fn in ipairs(list) do
        fn()
    end
end

-- Run fn now, or once after combat ends. Use it for actions that the client blocks in combat.
function Kit.AfterCombat(fn)
    if not InCombatLockdown() then
        fn()
        return
    end
    table.insert(queue, fn)
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        eventFrame:SetScript("OnEvent", flush)
    end
end
