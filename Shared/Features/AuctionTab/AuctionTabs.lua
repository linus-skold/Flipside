local _, ns = ...

-- Registry of the extra Auction House tabs (Buying, later Selling). The Flipside tab attaches itself.
-- A host that supports many tabs sets host.multiTab. Other hosts (TBC) get no extra tab.
local AuctionTabs = {}
ns.AuctionTabs = AuctionTabs

local specs = {}

-- spec: { id, label, create(deps) -> core, available(deps) -> boolean (optional) }.
-- The core needs Mount, Unmount, Select, Leave, Deselect, IsActive and core.deps.bus.
-- The same id replaces the earlier spec.
function AuctionTabs.Register(spec)
    if type(spec) ~= "table" or type(spec.id) ~= "string" or spec.id == "" then
        error("spec.id must be a non-empty string", 2)
    end
    if type(spec.label) ~= "string" or type(spec.create) ~= "function" then
        error("spec needs a label and a create function", 2)
    end
    for index, existing in ipairs(specs) do
        if existing.id == spec.id then
            specs[index] = spec
            return
        end
    end
    specs[#specs + 1] = spec
end

-- Returns a copy of the specs, in registration order.
function AuctionTabs.List()
    return { unpack(specs) }
end

local function report(text)
    if ns.ReportError then
        ns.ReportError(text)
    end
end

-- Create and attach each registered tab. deps goes to create and available; deps.host is optional.
-- Returns a table of the cores by id.
function AuctionTabs.AttachAll(deps)
    local cores = {}
    local host = deps.host or ns.AuctionTabHost
    if type(host) ~= "table" or not host.multiTab or type(host.Attach) ~= "function" then
        return cores
    end
    for _, spec in ipairs(specs) do
        if not spec.available or spec.available(deps) then
            local ok, core = pcall(spec.create, deps)
            if ok then
                local attached, err = pcall(host.Attach, core, { id = spec.id, label = spec.label })
                if attached then
                    cores[spec.id] = core
                else
                    report("the " .. spec.label .. " tab is not available: " .. tostring(err))
                end
            else
                report("the " .. spec.label .. " tab is not available: " .. tostring(core))
            end
        end
    end
    return cores
end
