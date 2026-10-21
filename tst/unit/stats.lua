-- tst/unit/stats.lua
-- Unit tests for src/stats.lua, the chat agent's stats.fit tool.

stats = require("stats")

FAILURES = 0

function check(condition, message)
    if condition != true then
        FAILURES = FAILURES + 1
        print("FAIL: " .. message)
    end
end

function near(a, b, tol)
    return a != nil and math.abs(a - b) <= tol
end

function growth(doubling, hours, cap)
    ys = {}
    for _, h in ipairs(hours) do
        y = 0.05 * 2 ^ (h / doubling)
        if cap != nil and y > cap then
            y = cap
        end
        table.insert(ys, y)
    end
    return ys
end

HOURS = {0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24}

function test_linear_fit()
    print("Testing a linear fit recovers slope, intercept and r2")
    slope, intercept, r2 = stats.linear_fit({1, 2, 3, 4}, {3, 5, 7, 9})
    check(near(slope, 2, 1e-12) and near(intercept, 1, 1e-12) and near(r2, 1, 1e-12), "y = 1 + 2x")
    check(stats.linear_fit({1, 1, 1}, {1, 2, 3}) == nil, "all-equal x can't be fitted")
end

function test_pure_exponential_uses_every_point()
    print("Testing a pure exponential is fitted over all its points")
    fit = stats.exponential_fit(HOURS, growth(3.0, HOURS, nil))
    check(near(math.log(2) / fit.rate, 3.0, 1e-9), "doubling time 3.0, got " .. tostring(math.log(2) / fit.rate))
    check(fit.n == #HOURS, "expected every point, got " .. tostring(fit.n))
end

function test_plateau_is_left_out()
    print("Testing a culture that levels off is fitted over its growth phase only")
    for _, doubling in ipairs({2.0, 2.8, 3.6, 4.6}) do
        fit = stats.exponential_fit(HOURS, growth(doubling, HOURS, 0.8))
        got = math.log(2) / fit.rate
        check(near(got, doubling, doubling * 0.03), string.format("doubling %.1f, got %.3f", doubling, got))
        check(fit.phase == "detected", "phase should be detected")
    end
    -- First vs last over the whole run is what the agent did by hand:
    endpoint = 24 * math.log(2) / math.log(0.8 / 0.05)
    check(endpoint > 5.9, "the endpoint estimate really is far off (" .. tostring(endpoint) .. ")")
end

function test_lag_phase_is_left_out()
    print("Testing a flat lag before growth is left out too")
    ys = {0.05, 0.05, 0.05, 0.1, 0.2, 0.4, 0.8}
    fit = stats.exponential_fit({0, 2, 4, 6, 8, 10, 12}, ys)
    check(near(math.log(2) / fit.rate, 2.0, 1e-6), "doubling 2.0 after the lag, got " .. tostring(math.log(2) / fit.rate))
end

function test_given_range_and_errors()
    print("Testing an explicit range, and refusing values an exponential can't take")
    fit = stats.exponential_fit(HOURS, growth(2.0, HOURS, 0.8), {x_min = 0, x_max = 6})
    check(fit.phase == "given" and fit.n == 4, "range 0..6 gives 4 points")
    value, err = stats.exponential_fit({0, 1, 2}, {1, 0, 2})
    check(value == nil and err != nil, "a zero y can't be log-fitted")
end

function test_describe_names_the_method()
    print("Testing the tool text states the fit, the doubling time and which points")
    fit = stats.exponential_fit(HOURS, growth(2.0, HOURS, 0.8))
    text = stats.describe("exponential", fit, "hours", "od600", #HOURS)
    check(string.find(text, "doubling time 2 (in hours)", 1, true) != nil, "got: " .. text)
    check(string.find(text, "exponential phase", 1, true) != nil, "should say the phase was found from the data")
end

test_linear_fit()
test_pure_exponential_uses_every_point()
test_plateau_is_left_out()
test_lag_phase_is_left_out()
test_given_range_and_errors()
test_describe_names_the_method()

if FAILURES > 0 then
    print(FAILURES .. " failure(s)")
    os.exit(1)
end
print("All stats tests passed")
