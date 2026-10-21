-- Least-squares fits for the chat agent's stats.fit tool. A growth rate
-- or doubling time read off two hand-picked points depends on which
-- points the model picks: first-vs-last over a culture that levelled
-- off counts the plateau as slow growth (found by the agent scorecard,
-- doc/agent-eval.md). A fit over every point, with the exponential
-- phase found from the data, gives one answer from the same rows.

stats = {}

-- Ordinary least squares y = intercept + slope * x. Returns slope,
-- intercept, r2 (1 when every point is on the line), or nil and why.
function stats.linear_fit(xs, ys)
    n = #xs
    if n < 2 then
        return nil, "need at least 2 points"
    end
    sx, sy = 0, 0
    for i = 1, n do
        sx = sx + xs[i]
        sy = sy + ys[i]
    end
    mx, my = sx / n, sy / n
    sxx, sxy, syy = 0, 0, 0
    for i = 1, n do
        dx, dy = xs[i] - mx, ys[i] - my
        sxx = sxx + dx * dx
        sxy = sxy + dx * dy
        syy = syy + dy * dy
    end
    if sxx == 0 then
        return nil, "all x values are the same"
    end
    slope = sxy / sxx
    intercept = my - slope * mx
    r2 = 1
    if syy > 0 then
        r2 = (sxy * sxy) / (sxx * syy)
    end
    return slope, intercept, r2
end

-- The points sorted by x, as parallel arrays.
function sorted_points(xs, ys)
    order = {}
    for i = 1, #xs do
        table.insert(order, i)
    end
    table.sort(order, function(a, b) return xs[a] < xs[b] end)
    sx, sy = {}, {}
    for _, i in ipairs(order) do
        table.insert(sx, xs[i])
        table.insert(sy, ys[i])
    end
    return sx, sy
end

-- How close a window's slope must come to the steepest one to count as
-- the same growth phase, and how straight (on a log scale) it must be.
PHASE_SLOPE_SHARE = 0.97
PHASE_MIN_R2 = 0.98
PHASE_MIN_POINTS = 3

-- Fits ln(y) = intercept + rate * x. With opts.x_min/x_max, over that
-- range only. Otherwise the exponential phase is found from the data:
-- among windows of consecutive points that are straight on a log scale
-- (r2 >= PHASE_MIN_R2), the steepest growth, widened to the longest
-- window that grows nearly as fast -- so a lag or a plateau at either
-- end is left out. Returns a table {rate, intercept, r2, n, x_from,
-- x_to, phase = "given"|"detected"|"all"}, or nil and why.
function stats.exponential_fit(xs, ys, opts)
    if opts == nil then
        opts = {}
    end
    px, py = {}, {}
    for i = 1, #xs do
        inside = true
        if opts.x_min != nil and xs[i] < opts.x_min then
            inside = false
        end
        if opts.x_max != nil and xs[i] > opts.x_max then
            inside = false
        end
        if inside == true then
            if ys[i] <= 0 then
                return nil, "an exponential fit needs every y above 0 (got " .. tostring(ys[i]) .. " at x = " .. tostring(xs[i]) .. ")"
            end
            table.insert(px, xs[i])
            table.insert(py, math.log(ys[i]))
        end
    end
    px, py = sorted_points(px, py)
    if #px < 2 then
        return nil, "need at least 2 points in range"
    end

    function fit_window(a, b)
        wx, wy = {}, {}
        for i = a, b do
            table.insert(wx, px[i])
            table.insert(wy, py[i])
        end
        rate, intercept, r2 = stats.linear_fit(wx, wy)
        if rate == nil then
            return nil
        end
        return {rate = rate, intercept = intercept, r2 = r2, n = b - a + 1, x_from = px[a], x_to = px[b]}
    end

    whole = fit_window(1, #px)
    if whole == nil then
        return nil, "cannot fit these points"
    end
    if opts.x_min != nil or opts.x_max != nil or #px < PHASE_MIN_POINTS + 1 then
        whole.phase = "given"
        if opts.x_min == nil and opts.x_max == nil then
            whole.phase = "all"
        end
        return whole
    end

    windows = {}
    steepest = nil
    for a = 1, #px - PHASE_MIN_POINTS + 1 do
        for b = a + PHASE_MIN_POINTS - 1, #px do
            w = fit_window(a, b)
            if w != nil and w.r2 >= PHASE_MIN_R2 and w.rate > 0 then
                table.insert(windows, w)
                if steepest == nil or w.rate > steepest.rate then
                    steepest = w
                end
            end
        end
    end
    if steepest == nil then
        whole.phase = "all"
        return whole
    end
    best = steepest
    for _, w in ipairs(windows) do
        if w.rate >= steepest.rate * PHASE_SLOPE_SHARE and w.n > best.n then
            best = w
        end
    end
    best.phase = "detected"
    return best
end

-- The tool's text: what was fitted over which points, and the derived
-- values, so the model can quote the method as well as the result.
function stats.describe(model, fit, x_column, y_column, total_points)
    lines = {}
    if model == "exponential" then
        table.insert(lines, string.format("exponential fit ln(%s) = %.6g + %.6g * %s", y_column, fit.intercept, fit.rate, x_column))
        if fit.rate > 0 then
            table.insert(lines, string.format("growth rate %.6g per unit of %s; doubling time %.4g (in %s) = ln 2 / rate",
                fit.rate, x_column, math.log(2) / fit.rate, x_column))
        elseif fit.rate < 0 then
            table.insert(lines, string.format("decay rate %.6g per unit of %s; half-life %.4g (in %s) = ln 2 / -rate",
                -fit.rate, x_column, math.log(2) / -fit.rate, x_column))
        end
    else
        table.insert(lines, string.format("linear fit %s = %.6g + %.6g * %s", y_column, fit.intercept, fit.rate, x_column))
    end
    phase_note = ""
    if fit.phase == "detected" then
        phase_note = " -- the exponential phase, found from the data; points outside it (lag or plateau) left out"
    elseif fit.phase == "given" then
        phase_note = " -- the range you gave"
    end
    table.insert(lines, string.format("fitted %d of %d points, %s from %.6g to %.6g%s; r^2 = %.4f",
        fit.n, total_points, x_column, fit.x_from, fit.x_to, phase_note, fit.r2))
    return table.concat(lines, "\n")
end

return stats
