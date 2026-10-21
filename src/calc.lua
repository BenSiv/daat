-- Arithmetic for the chat agent's calc.evaluate tool: the model writes a
-- formula over values it got from a tool, and this computes it. A model
-- doing logs and ratios in its head drifts from run to run (found by
-- the agent scorecard, doc/agent-eval.md: one doubling time came back
-- as 3.63, 3.75 and 3.85 hours from the same readings), and SQLite has
-- no LN/EXP to push the maths into a query instead.
--
-- A small recursive-descent parser over numbers, + - * / ^, parentheses
-- and a fixed set of functions -- never load()/loadstring(), so a
-- formula can't run anything but arithmetic.

calc = {}

function fold(values, pick)
    result = values[1]
    for i = 2, #values do
        result = pick(result, values[i])
    end
    return result
end

FUNCTIONS = {
    ln = {1, function(a) return math.log(a[1]) end},
    log10 = {1, function(a) return math.log10(a[1]) end},
    log2 = {1, function(a) return math.log(a[1]) / math.log(2) end},
    exp = {1, function(a) return math.exp(a[1]) end},
    sqrt = {1, function(a) return math.sqrt(a[1]) end},
    abs = {1, function(a) return math.abs(a[1]) end},
    round = {2, function(a)
        m = 10 ^ a[2]
        return math.floor(a[1] * m + 0.5) / m
    end},
    min = {-1, function(a) return fold(a, math.min) end},
    max = {-1, function(a) return fold(a, math.max) end},
}

-- Where a function is only defined for some inputs, say so instead of
-- returning nan/inf the model might quote as a result.
DOMAIN = {
    ln = function(a) return a[1] > 0 end,
    log10 = function(a) return a[1] > 0 end,
    log2 = function(a) return a[1] > 0 end,
    sqrt = function(a) return a[1] >= 0 end,
}

CONSTANTS = {pi = math.pi, e = math.exp(1)}

function tokenize(text)
    tokens = {}
    pos = 1
    while pos <= string.len(text) do
        c = string.sub(text, pos, pos)
        if string.find(c, "%s") != nil then
            pos = pos + 1
        elseif string.find(c, "[%d%.]") != nil then
            number_text = string.match(text, "^%d*%.?%d*[eE][%+%-]?%d+", pos)
            if number_text == nil then
                number_text = string.match(text, "^%d*%.?%d*", pos)
            end
            value = tonumber(number_text)
            if value == nil then
                return nil, "bad number '" .. number_text .. "'"
            end
            table.insert(tokens, {kind = "number", value = value})
            pos = pos + string.len(number_text)
        elseif string.find(c, "[%a_]") != nil then
            name = string.match(text, "^[%a_][%w_]*", pos)
            table.insert(tokens, {kind = "name", value = string.lower(name)})
            pos = pos + string.len(name)
        elseif string.find(c, "[%+%-%*/%^%(%),]") != nil then
            table.insert(tokens, {kind = c})
            pos = pos + 1
        else
            return nil, "unexpected character '" .. c .. "'"
        end
    end
    return tokens
end

-- Evaluates `expression` and returns the number, or nil and why not.
function calc.evaluate(expression)
    if type(expression) != "string" or string.find(expression, "%S") == nil then
        return nil, "empty expression"
    end
    tokens, err = tokenize(expression)
    if tokens == nil then
        return nil, err
    end
    state = {i = 1}
    -- The parse functions call each other recursively, so they live in a
    -- table and are looked up when called, not when defined.
    p = {}

    function p.peek()
        return tokens[state.i]
    end

    function p.take(kind)
        tok = tokens[state.i]
        if tok == nil or tok.kind != kind then
            return nil
        end
        state.i = state.i + 1
        return tok
    end

    -- Each parse_* returns value, err; err set means stop.
    function p.parse_expr()
        left, e = p.parse_term()
        if e != nil then
            return nil, e
        end
        while p.peek() != nil and (p.peek().kind == "+" or p.peek().kind == "-") do
            op = p.take(p.peek().kind).kind
            right, e2 = p.parse_term()
            if e2 != nil then
                return nil, e2
            end
            if op == "+" then
                left = left + right
            else
                left = left - right
            end
        end
        return left
    end

    function p.parse_term()
        left, e = p.parse_unary()
        if e != nil then
            return nil, e
        end
        while p.peek() != nil and (p.peek().kind == "*" or p.peek().kind == "/") do
            op = p.take(p.peek().kind).kind
            right, e2 = p.parse_unary()
            if e2 != nil then
                return nil, e2
            end
            if op == "*" then
                left = left * right
            else
                if right == 0 then
                    return nil, "division by zero"
                end
                left = left / right
            end
        end
        return left
    end

    function p.parse_unary()
        if p.take("-") != nil then
            v, e = p.parse_unary()
            if e != nil then
                return nil, e
            end
            return -v
        end
        if p.take("+") != nil then
            return p.parse_unary()
        end
        return p.parse_power()
    end

    -- ^ binds tighter than unary minus on its left and is right-
    -- associative: -2^2 = -4, 2^3^2 = 512.
    function p.parse_power()
        base, e = p.parse_primary()
        if e != nil then
            return nil, e
        end
        if p.take("^") != nil then
            exponent, e2 = p.parse_unary()
            if e2 != nil then
                return nil, e2
            end
            return base ^ exponent
        end
        return base
    end

    function p.parse_primary()
        tok = p.peek()
        if tok == nil then
            return nil, "expression ends too early"
        end
        if tok.kind == "number" then
            state.i = state.i + 1
            return tok.value
        end
        if tok.kind == "(" then
            state.i = state.i + 1
            v, e = p.parse_expr()
            if e != nil then
                return nil, e
            end
            if p.take(")") == nil then
                return nil, "missing ')'"
            end
            return v
        end
        if tok.kind == "name" then
            state.i = state.i + 1
            if p.take("(") == nil then
                if CONSTANTS[tok.value] != nil then
                    return CONSTANTS[tok.value]
                end
                return nil, "unknown name '" .. tok.value .. "'"
            end
            fn = FUNCTIONS[tok.value]
            if fn == nil then
                return nil, "unknown function '" .. tok.value .. "'"
            end
            args = {}
            if p.take(")") == nil then
                while true do
                    v, e = p.parse_expr()
                    if e != nil then
                        return nil, e
                    end
                    table.insert(args, v)
                    if p.take(")") != nil then
                        break
                    end
                    if p.take(",") == nil then
                        return nil, "expected ',' or ')' in " .. tok.value .. "()"
                    end
                end
            end
            if (fn[1] >= 0 and #args != fn[1]) or (fn[1] < 0 and #args == 0) then
                return nil, tok.value .. "() takes " .. tostring(math.abs(fn[1])) .. " argument(s)"
            end
            if DOMAIN[tok.value] != nil and DOMAIN[tok.value](args) == false then
                return nil, tok.value .. "() is undefined for " .. tostring(args[1])
            end
            return fn[2](args)
        end
        return nil, "unexpected '" .. tok.kind .. "'"
    end

    value, e = p.parse_expr()
    if e != nil then
        return nil, e
    end
    if state.i <= #tokens then
        return nil, "unexpected '" .. tostring(tokens[state.i].kind) .. "' after the expression"
    end
    if value != value or value == math.huge or value == -math.huge then
        return nil, "result is not a finite number"
    end
    return value
end

-- The tool's text: the formula and its value, so the model can quote
-- both. %.10g keeps full useful precision without float noise.
function calc.format(expression, value)
    return expression .. " = " .. string.format("%.10g", value)
end

return calc
