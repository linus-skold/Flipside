local _, ns = ...

local FormulaFunctions = {}
ns.FormulaFunctions = FormulaFunctions

local huge = math.huge

FormulaFunctions.SPECS = {
    min = { minArgs = 1, maxArgs = huge, lazy = false },
    max = { minArgs = 1, maxArgs = huge, lazy = false },
    avg = { minArgs = 1, maxArgs = huge, lazy = false },
    first = { minArgs = 1, maxArgs = huge, lazy = false },
    check = { minArgs = 2, maxArgs = 2, lazy = false },
    round = { minArgs = 1, maxArgs = 1, lazy = false },
    ifgt = { minArgs = 3, maxArgs = 4, lazy = true },
    iflt = { minArgs = 3, maxArgs = 4, lazy = true },
    ifeq = { minArgs = 3, maxArgs = 4, lazy = true },
}

-- Returns the number, or nil if it is nil, nan or infinite.
local function Finite(x)
    if type(x) ~= "number" or x ~= x or x == huge or x == -huge then
        return nil
    end
    return x
end

-- Rounds half up to a whole number; nil stays nil.
function FormulaFunctions.RoundCopper(x)
    x = Finite(x)
    if x == nil then
        return nil
    end
    return Finite(math.floor(x + 0.5))
end

-- Applies + - * / with the invalid rules.
function FormulaFunctions.Arith(op, a, b)
    if Finite(a) == nil or Finite(b) == nil then
        return nil
    end
    if op == "+" then
        return Finite(a + b)
    elseif op == "-" then
        return Finite(a - b)
    elseif op == "*" then
        return Finite(a * b)
    elseif op == "/" then
        if b == 0 then
            return nil
        end
        return Finite(a / b)
    end
    return nil
end

function FormulaFunctions.Negate(a)
    a = Finite(a)
    if a == nil then
        return nil
    end
    return -a
end

local function Lower(name)
    return type(name) == "string" and name:lower() or nil
end

function FormulaFunctions.IsKnown(name)
    local key = Lower(name)
    return key ~= nil and FormulaFunctions.SPECS[key] ~= nil
end

-- Returns true, or false plus a message.
function FormulaFunctions.CheckArity(name, n)
    local key = Lower(name)
    local spec = key and FormulaFunctions.SPECS[key]
    if not spec then
        return false, "unknown function " .. tostring(name)
    end
    if n < spec.minArgs then
        return false, key .. " needs at least " .. spec.minArgs .. " arguments"
    end
    if n > spec.maxArgs then
        return false, key .. " takes at most " .. spec.maxArgs .. " arguments"
    end
    return true
end

-- Returns the valid numbers in args as a list.
local function Valid(args)
    local list = {}
    local n = args.n or #args
    for i = 1, n do
        local v = Finite(args[i])
        if v ~= nil then
            list[#list + 1] = v
        end
    end
    return list
end

local EAGER = {}

function EAGER.min(args)
    local list = Valid(args)
    local best = list[1]
    for i = 2, #list do
        if list[i] < best then
            best = list[i]
        end
    end
    return best
end

function EAGER.max(args)
    local list = Valid(args)
    local best = list[1]
    for i = 2, #list do
        if list[i] > best then
            best = list[i]
        end
    end
    return best
end

function EAGER.avg(args)
    local list = Valid(args)
    if #list == 0 then
        return nil
    end
    local sum = 0
    for i = 1, #list do
        sum = sum + list[i]
    end
    return Finite(sum / #list)
end

function EAGER.first(args)
    return Valid(args)[1]
end

function EAGER.check(args)
    local a = Finite(args[1])
    if a ~= nil and a > 0 then
        return Finite(args[2])
    end
    return nil
end

function EAGER.round(args)
    return FormulaFunctions.RoundCopper(args[1])
end

local TESTS = {
    ifgt = function(a, b) return a > b end,
    iflt = function(a, b) return a < b end,
    ifeq = function(a, b) return a == b end,
}

-- Calls an eager function; args is an array with args.n entries.
function FormulaFunctions.Call(name, args)
    local fn = EAGER[Lower(name)]
    if not fn then
        return nil
    end
    return fn(args or { n = 0 })
end

-- Calls a lazy function; getArg(i) evaluates argument i.
function FormulaFunctions.CallLazy(name, getArg, n)
    local key = Lower(name)
    local test = TESTS[key]
    if not test then
        return nil
    end
    local value = Finite(getArg(1))
    local limit = Finite(getArg(2))
    if value == nil or limit == nil then
        return nil
    end
    if test(value, limit) then
        return Finite(getArg(3))
    end
    if n >= 4 then
        return Finite(getArg(4))
    end
    return nil
end

FormulaFunctions.DOCS = {
    min = {
        usage = "min(a, b, ...)",
        text = "Gives the lowest value. It skips invalid arguments. It is invalid only if all arguments are invalid.",
        example = "min(scanmin, scanmarket)",
    },
    max = {
        usage = "max(a, b, ...)",
        text = "Gives the highest value. It skips invalid arguments. It is invalid only if all arguments are invalid.",
        example = "max(scanmin, 1.5 * vendorsell)",
    },
    avg = {
        usage = "avg(a, b, ...)",
        text = "Gives the average of the values. It skips invalid arguments. It is invalid only if all are invalid.",
        example = "avg(scanmarket, scanhistorical)",
    },
    first = {
        usage = "first(a, b, ...)",
        text = "Gives the first argument that is valid. It skips invalid arguments.",
        example = "first(crafting, scanmarket)",
    },
    check = {
        usage = "check(a, b)",
        text = "Gives b only if a is valid and above 0. Otherwise it gives invalid.",
        example = "check(scanmarket, 0.8 * scanmarket)",
    },
    ifgt = {
        usage = "ifgt(value, limit, then, else)",
        text = "If value is above limit, gives then. Otherwise it gives else. Without else, it gives invalid.",
        example = "ifgt(scanage, 72, invalid, scanmarket)",
    },
    iflt = {
        usage = "iflt(value, limit, then, else)",
        text = "If value is below limit, gives then. Otherwise it gives else. Without else, it gives invalid.",
        example = "iflt(scanqty, 5, 2 * scanmarket, scanmarket)",
    },
    ifeq = {
        usage = "ifeq(value, limit, then, else)",
        text = "If value equals limit, gives then. Otherwise it gives else. Without else, it gives invalid.",
        example = "ifeq(scansamples, 14, scanmarket, scanrecent)",
    },
    round = {
        usage = "round(x)",
        text = "Rounds x to whole copper. Half rounds up.",
        example = "round(scanmarket * 0.95)",
    },
}