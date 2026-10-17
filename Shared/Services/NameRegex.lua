local _, ns = ...

-- Small regex engine for item-name rules. Pure Lua, no WoW API.
-- Syntax: literals, . ^ $ * + ?, [abc] [a-z] [^a], ( ), |, \ escapes, \d \s \w.
-- Not supported (error): {n,m}, lazy quantifiers, backreferences. Uppercase \D \S \W are plain letters.
-- Matching is case-insensitive and unanchored unless ^ or $ is used.
-- Matching works on bytes: a non-ASCII UTF-8 byte matches itself, and . matches one byte.
local NameRegex = {}
ns.NameRegex = NameRegex

local STEP_LIMIT = 10000
local CACHE_LIMIT = 200

local ESCAPE_CLASSES = {
    d = { { 48, 57 } },
    s = { { 32, 32 }, { 9, 13 } },
    w = { { 97, 122 }, { 48, 57 }, { 95, 95 } },
}

local function fail(msg)
    error({ msg = msg }, 0)
end

local function lowerByte(ch)
    return ch:lower():byte()
end

-- Parser: source text to an AST. A sequence is a list of nodes; a group holds a list of sequences.
local function parse(src)
    local pos = 1
    local parseAlt

    local function parseClass()
        pos = pos + 1
        local node = { t = "set", neg = false, ranges = {} }
        if src:sub(pos, pos) == "^" then
            node.neg = true
            pos = pos + 1
        end
        local count = 0
        while true do
            local ch = src:sub(pos, pos)
            if ch == "" then
                fail("missing ]")
            end
            if ch == "]" and count > 0 then
                pos = pos + 1
                return node
            end
            pos = pos + 1
            count = count + 1
            if ch == "\\" then
                ch = src:sub(pos, pos)
                if ch == "" then
                    fail("missing ]")
                end
                pos = pos + 1
                local cls = ESCAPE_CLASSES[ch]
                if cls then
                    for _, r in ipairs(cls) do
                        table.insert(node.ranges, r)
                    end
                    ch = nil
                end
            end
            if ch then
                local lo = lowerByte(ch)
                local hi = lo
                if src:sub(pos, pos) == "-" and src:sub(pos + 1, pos + 1) ~= "]" and pos + 1 <= #src then
                    hi = lowerByte(src:sub(pos + 1, pos + 1))
                    pos = pos + 2
                    if hi < lo then
                        fail("bad range in []")
                    end
                end
                table.insert(node.ranges, { lo, hi })
            end
        end
    end

    local function parseAtom(depth)
        local ch = src:sub(pos, pos)
        pos = pos + 1
        if ch == "(" then
            local node = { t = "group", alts = parseAlt(depth + 1) }
            if src:sub(pos, pos) ~= ")" then
                fail("missing )")
            end
            pos = pos + 1
            return node
        elseif ch == "[" then
            pos = pos - 1
            return parseClass()
        elseif ch == "." then
            return { t = "any" }
        elseif ch == "^" then
            return { t = "bol" }
        elseif ch == "$" then
            return { t = "eol" }
        elseif ch == "*" or ch == "+" or ch == "?" then
            fail("nothing to repeat")
        elseif ch == "{" then
            fail("{} is not supported")
        elseif ch == "\\" then
            local esc = src:sub(pos, pos)
            if esc == "" then
                fail("trailing \\")
            end
            pos = pos + 1
            if ESCAPE_CLASSES[esc] then
                return { t = "set", neg = false, ranges = ESCAPE_CLASSES[esc] }
            end
            return { t = "char", c = lowerByte(esc) }
        end
        return { t = "char", c = lowerByte(ch) }
    end

    function parseAlt(depth)
        local alts, seq = {}, {}
        while pos <= #src do
            local ch = src:sub(pos, pos)
            if ch == "|" then
                pos = pos + 1
                table.insert(alts, seq)
                seq = {}
            elseif ch == ")" then
                if depth == 0 then
                    fail("unbalanced )")
                end
                break
            else
                local atom = parseAtom(depth)
                local q = src:sub(pos, pos)
                if q == "*" or q == "+" or q == "?" then
                    if atom.t == "bol" or atom.t == "eol" then
                        fail("nothing to repeat")
                    end
                    pos = pos + 1
                    local min = (q == "+") and 1 or 0
                    local max = (q == "?") and 1 or math.huge
                    atom = { t = "rep", node = atom, min = min, max = max }
                end
                table.insert(seq, atom)
            end
        end
        table.insert(alts, seq)
        return alts
    end

    local alts = parseAlt(0)
    return { t = "group", alts = alts }
end

local function inSet(node, b)
    local found = false
    for _, r in ipairs(node.ranges) do
        if b >= r[1] and b <= r[2] then
            found = true
            break
        end
    end
    return found ~= node.neg
end

-- Backtracking matcher. Each node calls the continuation k with the next index.
local function search(ast, s)
    local steps = 0
    local matchNode

    local function matchSeq(seq, idx, i, k)
        if idx > #seq then
            return k(i)
        end
        return matchNode(seq[idx], i, function(j)
            return matchSeq(seq, idx + 1, j, k)
        end)
    end

    local function matchRep(node, count, i, k)
        if count < node.max then
            local ok = matchNode(node.node, i, function(j)
                if j == i then
                    return k(j)
                end
                return matchRep(node, count + 1, j, k)
            end)
            if ok then
                return true
            end
        end
        return count >= node.min and k(i)
    end

    function matchNode(node, i, k)
        steps = steps + 1
        if steps > STEP_LIMIT then
            return false
        end
        local t = node.t
        if t == "char" then
            return s:byte(i) == node.c and k(i + 1)
        elseif t == "any" then
            return i <= #s and k(i + 1)
        elseif t == "set" then
            local b = s:byte(i)
            return b ~= nil and inSet(node, b) and k(i + 1)
        elseif t == "bol" then
            return i == 1 and k(i)
        elseif t == "eol" then
            return i == #s + 1 and k(i)
        elseif t == "rep" then
            return matchRep(node, 0, i, k)
        end
        for _, seq in ipairs(node.alts) do
            if matchSeq(seq, 1, i, k) then
                return true
            end
        end
        return false
    end

    for start = 1, #s + 1 do
        if matchNode(ast, start, function() return true end) then
            return true
        end
        if steps > STEP_LIMIT then
            return false
        end
    end
    return false
end

local Matcher = {}
Matcher.__index = Matcher

-- Return true if the pattern matches the name. Returns false if the step limit is reached.
function Matcher:Match(name)
    return search(self.ast, tostring(name or ""):lower())
end

-- Compile pattern text (with or without surrounding slashes). Returns matcher, or nil and an error text.
function NameRegex.Compile(source)
    source = tostring(source or "")
    if #source >= 2 and source:sub(1, 1) == "/" and source:sub(-1) == "/" then
        source = source:sub(2, -2)
    end
    if source == "" then
        return nil, "empty pattern"
    end
    local ok, ast = pcall(parse, source)
    if not ok then
        if type(ast) == "table" then
            return nil, ast.msg
        end
        error(ast, 0)
    end
    return setmetatable({ ast = ast }, Matcher), nil
end

local cache, cacheSize = {}, 0

-- Compile (with a cache) and match. Returns match result, or nil and an error text.
function NameRegex.Test(source, name)
    local entry = cache[source]
    if not entry then
        local matcher, err = NameRegex.Compile(source)
        entry = { matcher = matcher, err = err }
        if cacheSize >= CACHE_LIMIT then
            cache, cacheSize = {}, 0
        end
        cache[source] = entry
        cacheSize = cacheSize + 1
    end
    if not entry.matcher then
        return nil, entry.err
    end
    return entry.matcher:Match(name)
end
