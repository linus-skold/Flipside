local _, ns = ...

-- Compiles formula text with checks, caches it, and evaluates it for an item.

local FormulaRun = {}
ns.FormulaRun = FormulaRun

local Run = {}
Run.__index = Run

local MAX_MEMO = 5000

local NO_STORE = {
    Get = function()
        return nil
    end,
}

function FormulaRun.New(deps)
    deps = deps or {}
    local self = setmetatable({}, Run)
    self.store = deps.store
    self.sources = deps.sources
    self.serverTime = deps.serverTime
    self:ClearCache()
    return self
end

function Run:ClearCache()
    self.compiled = {}
    self.memo = {}
    self.memoCount = 0
end

-- Returns a compiled formula, or nil plus { message, pos }.
function Run:Compile(text)
    local cached = self.compiled[text]
    if cached then
        return cached
    end
    local tree, err = ns.FormulaParse.Parse(text)
    if not tree then
        return nil, err
    end
    local sources = self.sources
    local ok, result = ns.FormulaEval.Check(tree, function(name)
        return sources:Status(name) ~= "unknown"
    end)
    if not ok then
        return nil, result
    end
    local later = {}
    for _, name in ipairs(result) do
        if sources:Status(name) == "later" then
            later[#later + 1] = name
        end
    end
    local compiled = { text = text, tree = tree, names = result, later = later }
    self.compiled[text] = compiled
    return compiled
end

function Run:_evaluate(compiled, input)
    local store = self.store or NO_STORE
    local record, key, itemID = ns.FormulaLookup.Find(store, input)
    if itemID == nil then
        return nil, { kind = "error", message = "not an item" }
    end
    local ctx = { record = record, now = self.serverTime(), itemID = itemID }
    local sources = self.sources
    local missing = {}
    local value = ns.FormulaEval.Evaluate(compiled.tree, function(name)
        local v = sources:Read(name, ctx)
        if v == nil then
            missing[#missing + 1] = name
        end
        return v
    end)
    table.sort(missing)
    local copper = ns.FormulaFunctions.RoundCopper(value)
    return copper, {
        kind = copper ~= nil and "ok" or "invalid",
        key = key,
        missing = missing,
        later = compiled.later,
    }
end

-- Returns copper (or nil) and an info table.
function Run:Evaluate(text, input)
    local compiled, err = self:Compile(text)
    if not compiled then
        return nil, { kind = "error", message = err.message, pos = err.pos }
    end
    local version = self.store and self.store:GetVersion() or 0
    local minute = math.floor(self.serverTime() / 60)
    local memoKey = table.concat({ text, tostring(input), version, minute }, "\0")
    local hit = self.memo[memoKey]
    if hit then
        return hit.copper, hit.info
    end
    local copper, info = self:_evaluate(compiled, input)
    if self.memoCount >= MAX_MEMO then
        self.memo = {}
        self.memoCount = 0
    end
    self.memo[memoKey] = { copper = copper, info = info }
    self.memoCount = self.memoCount + 1
    return copper, info
end
