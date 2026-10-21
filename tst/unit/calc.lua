-- tst/unit/calc.lua
-- Unit tests for src/calc.lua, the chat agent's calc.evaluate tool.

calc = require("calc")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function near(a, b)
    return a != nil and math.abs(a - b) < 1e-9
end

function test_precedence_and_associativity()
    print("Testing operator precedence, unary minus and right-associative ^")
    check(near(calc.evaluate("1 + 2 * 3"), 7), "1 + 2 * 3 = 7")
    check(near(calc.evaluate("(1 + 2) * 3"), 9), "(1 + 2) * 3 = 9")
    check(near(calc.evaluate("-2^2"), -4), "-2^2 = -4")
    check(near(calc.evaluate("2^3^2"), 512), "2^3^2 = 512")
    check(near(calc.evaluate("10 / 4 - 1"), 1.5), "10 / 4 - 1 = 1.5")
    check(near(calc.evaluate("1.5e3 + .5"), 1500.5), "scientific notation and a leading dot")
end

function test_functions_and_constants()
    print("Testing ln/log10/exp/sqrt/round/min/max and constants")
    check(near(calc.evaluate("ln(e)"), 1), "ln(e) = 1")
    check(near(calc.evaluate("log10(1000)"), 3), "log10(1000) = 3")
    check(near(calc.evaluate("log2(8)"), 3), "log2(8) = 3")
    check(near(calc.evaluate("round(2/3, 2)"), 0.67), "round(2/3, 2) = 0.67")
    check(near(calc.evaluate("max(1, 5, 3) - min(4, 2)"), 3), "max - min")
    check(near(calc.evaluate("SQRT(16)"), 4), "function names are case-insensitive")
end

function test_doubling_time_from_readings()
    print("Testing the doubling-time formula the scorecard asks for")
    value = calc.evaluate("12 * ln(2) / ln(0.8502 / 0.098)")
    check(value != nil and math.abs(value - 3.85) < 0.01, "expected about 3.85, got " .. tostring(value))
end

function test_errors_are_reported_not_returned_as_numbers()
    print("Testing bad input gives an error, never nan/inf or code execution")
    for _, bad in ipairs({"", "1 +", "(1 + 2", "1 / 0", "ln(0)", "sqrt(-1)", "foo(2)", "x + 1",
            "os.exit(1)", "1; 2", "round(1)", "2 3"}) do
        value, err = calc.evaluate(bad)
        check(value == nil and err != nil, "should refuse: '" .. bad .. "', got " .. tostring(value))
    end
end

function test_format()
    print("Testing the tool text shows the formula and its value")
    check(calc.format("2/3", calc.evaluate("2/3")) == "2/3 = 0.6666666667", "got " .. calc.format("2/3", calc.evaluate("2/3")))
end

test_precedence_and_associativity()
test_functions_and_constants()
test_doubling_time_from_readings()
test_errors_are_reported_not_returned_as_numbers()
test_format()

if FAILURES > 0 then
    print(FAILURES .. " failure(s)")
    os.exit(1)
end
print("All calc tests passed")
