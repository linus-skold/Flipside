local _, ns = ...

-- Walks and evaluates a formula tree. A nil value means "no price".

local FormulaEval = {}
ns.FormulaEval = FormulaEval

local INVALID = "invalid"

-- Evaluates a tree; resolve(name) returns a number or nil. Each name is resolved once.
function FormulaEval.Evaluate(tree, resolve)
    local F = ns.FormulaFunctions
    local memo, seen = {}, {}

    local function read(name)
        if not seen[name] then
            seen[name] = true
            memo[name] = resolve(name)
        end
        return memo[name]
    end

    local eval

    local function evalCall(node)
        local args = node.args
        if F.SPECS[node.name] and F.SPECS[node.name].lazy then
            return F.CallLazy(node.name, function(i)
                return args[i] and eval(args[i]) or nil
            end, #args)
        end
        local values = { n = #args }
        for i = 1, #args do
            values[i] = eval(args[i])
        end
        return F.Call(node.name, values)
    end

    function eval(node)
        local kind = node.kind
        if kind == "num" then
            return node.value
        elseif kind == "name" then
            if node.name == INVALID then
                return nil
            end
            return read(node.name)
        elseif kind == "neg" then
            return F.Negate(eval(node.expr))
        elseif kind == "bin" then
            local left = eval(node.left)
            local right = eval(node.right)
            return F.Arith(node.op, left, right)
        elseif kind == "call" then
            return evalCall(node)
        end
        return nil
    end

    return eval(tree)
end

-- Returns true plus a sorted list of source names, or false plus { message, pos }.
function FormulaEval.Check(tree, isKnownSource)
    local F = ns.FormulaFunctions
    local used = {}
    local failure

    local function fail(message, pos)
        failure = { message = message, pos = pos }
    end

    local function walk(node)
        if failure then
            return
        end
        local kind = node.kind
        if kind == "name" then
            if node.name ~= INVALID then
                if not isKnownSource(node.name) then
                    fail("Unknown source '" .. node.name .. "'.", node.pos)
                    return
                end
                used[node.name] = true
            end
        elseif kind == "neg" then
            walk(node.expr)
        elseif kind == "bin" then
            walk(node.left)
            walk(node.right)
        elseif kind == "call" then
            if not F.IsKnown(node.name) then
                fail("Unknown function '" .. node.name .. "'.", node.pos)
                return
            end
            local ok, message = F.CheckArity(node.name, #node.args)
            if not ok then
                fail(message, node.pos)
                return
            end
            for i = 1, #node.args do
                walk(node.args[i])
            end
        end
    end

    walk(tree)
    if failure then
        return false, failure
    end
    local names = {}
    for name in pairs(used) do
        names[#names + 1] = name
    end
    table.sort(names)
    return true, names
end
