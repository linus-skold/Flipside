local _, ns = ...

local FormulaParse = {}
ns.FormulaParse = FormulaParse

local MAX_LENGTH = 500
local MAX_DEPTH = 16
local UNIT_VALUE = { g = 10000, s = 100, c = 1 }
local UNIT_ORDER = { g = 1, s = 2, c = 3 }

local function Fail(message, pos)
    return nil, { message = message, pos = pos }
end

-- Reads a money literal such as 1g50s25c at start. Returns the copper value and the next index.
local function ReadMoney(text, start)
    local total, last, i = 0, 0, start
    while text:find("^%d", i) do
        local digits = text:match("^%d+", i)
        local unit = text:sub(i + #digits, i + #digits)
        local order = UNIT_ORDER[unit]
        if not order or order <= last then
            return nil
        end
        total = total + tonumber(digits) * UNIT_VALUE[unit]
        last = order
        i = i + #digits + 1
    end
    if text:find("^[%w_.]", i) then
        return nil
    end
    return total, i
end

-- Splits text into tokens. Returns nil and an error table when the text is not valid.
function FormulaParse.Tokenize(text)
    if type(text) ~= "string" then
        return Fail("The formula must be text.", 1)
    end
    if #text > MAX_LENGTH then
        return Fail("The formula is too long (more than " .. MAX_LENGTH .. " characters).", MAX_LENGTH + 1)
    end
    local tokens = {}
    local i = 1
    while i <= #text do
        local ch = text:sub(i, i)
        if ch == " " or ch == "\t" then
            i = i + 1
        elseif ch:find("%d") then
            local whole = text:match("^%d+", i)
            local nextChar = text:sub(i + #whole, i + #whole)
            if nextChar:find("^[%a_]") then
                local value, after = ReadMoney(text, i)
                if not value then
                    return Fail("Bad money literal. Use the order g, s, c, for example 1g50s25c.", i)
                end
                tokens[#tokens + 1] = { type = "number", value = value, pos = i }
                i = after
            else
                local numText = text:match("^%d+%.?%d*", i)
                local after = i + #numText
                if text:find("^[%a_]", after) then
                    return Fail("Bad number. A decimal number cannot have a unit.", i)
                end
                if text:sub(after, after) == "%" then
                    tokens[#tokens + 1] = { type = "percent", value = tonumber(numText) / 100, pos = i }
                    after = after + 1
                else
                    tokens[#tokens + 1] = { type = "number", value = tonumber(numText), pos = i }
                end
                i = after
            end
        elseif ch:find("[%a_]") then
            local name = text:match("^[%w_]+", i)
            tokens[#tokens + 1] = { type = "name", value = name:lower(), pos = i }
            i = i + #name
        elseif ch == "+" or ch == "-" or ch == "*" or ch == "/" then
            tokens[#tokens + 1] = { type = "op", value = ch, pos = i }
            i = i + 1
        elseif ch == "(" then
            tokens[#tokens + 1] = { type = "lparen", pos = i }
            i = i + 1
        elseif ch == ")" then
            tokens[#tokens + 1] = { type = "rparen", pos = i }
            i = i + 1
        elseif ch == "," then
            tokens[#tokens + 1] = { type = "comma", pos = i }
            i = i + 1
        else
            return Fail("Unexpected character '" .. ch .. "'.", i)
        end
    end
    tokens[#tokens + 1] = { type = "eof", pos = #text + 1 }
    return tokens
end

local function Raise(message, pos)
    error({ message = message, pos = pos }, 0)
end

local function Describe(tok)
    if tok.type == "eof" then
        return "the end of the formula"
    elseif tok.type == "lparen" then
        return "'('"
    elseif tok.type == "rparen" then
        return "')'"
    elseif tok.type == "comma" then
        return "','"
    end
    return "'" .. tostring(tok.value) .. "'"
end

local function NewState(tokens)
    return { tokens = tokens, index = 1, depth = 0 }
end

local function Peek(state)
    return state.tokens[state.index]
end

local function Advance(state)
    local tok = state.tokens[state.index]
    state.index = state.index + 1
    return tok
end

local ParseExpr

local function Enter(state, pos)
    state.depth = state.depth + 1
    if state.depth > MAX_DEPTH then
        Raise("The formula is nested too deep (more than " .. MAX_DEPTH .. " levels of brackets).", pos)
    end
end

local function ParseCall(state, nameTok)
    local lparen = Advance(state)
    Enter(state, lparen.pos)
    local args = {}
    while true do
        local tok = Peek(state)
        if tok.type == "comma" or tok.type == "rparen" then
            Raise("Empty argument in the call to '" .. nameTok.value .. "'.", tok.pos)
        end
        args[#args + 1] = ParseExpr(state)
        tok = Peek(state)
        if tok.type == "comma" then
            Advance(state)
        elseif tok.type == "rparen" then
            Advance(state)
            break
        else
            Raise("Missing ')' to close the call to '" .. nameTok.value .. "'.", tok.pos)
        end
    end
    state.depth = state.depth - 1
    return { kind = "call", name = nameTok.value, args = args, pos = nameTok.pos }
end

local function StartsOperand(tok)
    return tok.type == "number" or tok.type == "name" or tok.type == "lparen"
end

local ParseUnary

local function ParsePrimary(state)
    local tok = Peek(state)
    if tok.type == "number" then
        Advance(state)
        return { kind = "num", value = tok.value }
    elseif tok.type == "percent" then
        Advance(state)
        local node = { kind = "num", value = tok.value }
        if StartsOperand(Peek(state)) then
            return { kind = "bin", op = "*", left = node, right = ParsePrimary(state) }
        end
        return node
    elseif tok.type == "name" then
        Advance(state)
        if Peek(state).type == "lparen" then
            return ParseCall(state, tok)
        end
        return { kind = "name", name = tok.value, pos = tok.pos }
    elseif tok.type == "lparen" then
        Advance(state)
        Enter(state, tok.pos)
        local node = ParseExpr(state)
        local closing = Peek(state)
        if closing.type ~= "rparen" then
            Raise("Missing ')' to close the '(' at position " .. tok.pos .. ".", closing.pos)
        end
        Advance(state)
        state.depth = state.depth - 1
        return node
    end
    Raise("Unexpected " .. Describe(tok) .. ". Expected a number, a name or '('.", tok.pos)
end

function ParseUnary(state)
    local tok = Peek(state)
    if tok.type == "op" and tok.value == "-" then
        Advance(state)
        return { kind = "neg", expr = ParseUnary(state) }
    end
    return ParsePrimary(state)
end

local function ParseTerm(state)
    local left = ParseUnary(state)
    while true do
        local tok = Peek(state)
        if tok.type == "op" and (tok.value == "*" or tok.value == "/") then
            Advance(state)
            left = { kind = "bin", op = tok.value, left = left, right = ParseUnary(state) }
        else
            return left
        end
    end
end

function ParseExpr(state)
    local left = ParseTerm(state)
    while true do
        local tok = Peek(state)
        if tok.type == "op" and (tok.value == "+" or tok.value == "-") then
            Advance(state)
            left = { kind = "bin", op = tok.value, left = left, right = ParseTerm(state) }
        else
            return left
        end
    end
end

-- Parses a formula into a tree. Returns nil and an error table when the formula is not valid.
function FormulaParse.Parse(text)
    local tokens, err = FormulaParse.Tokenize(text)
    if not tokens then
        return nil, err
    end
    if #tokens == 1 then
        return Fail("The formula is empty.", 1)
    end
    local state = NewState(tokens)
    local ok, result = pcall(function()
        local tree = ParseExpr(state)
        local tok = Peek(state)
        if tok.type ~= "eof" then
            Raise("Unexpected " .. Describe(tok) .. " after the end of the formula.", tok.pos)
        end
        return tree
    end)
    if not ok then
        if type(result) == "table" then
            return nil, result
        end
        error(result, 0)
    end
    return result
end
