-- A summary over replicates: the mean must follow from the per-replicate
-- values, each from its growth phase, and every replicate counted.
return function(f, s)
    series = f.replicate_series
    script = {}
    parts = {}
    for _, rep in ipairs(series.replicates) do
        sql = "SELECT m.hours, m.od600 FROM measurement m JOIN sample s ON s.id = m.sample " ..
            "WHERE s.label = '" .. rep.label .. "' ORDER BY m.hours"
        table.insert(script, s.tool("stats.fit", {sql = sql, x_column = "hours", y_column = "od600", model = "exponential"}))
        table.insert(parts, string.format("%.2f", rep.doubling_time_hours))
    end
    table.insert(script, s.tool("calc.evaluate", {expression = "(" .. table.concat(parts, " + ") .. ") / " .. #parts}))
    table.insert(script, s.final(string.format("The mean doubling time across the %d replicates of %s is %.2f hours " ..
        "(mean of %s, each from a log-linear fit over its growth phase).",
        #parts, series.lab_number, series.mean_doubling_time_hours, table.concat(parts, ", "))))
    return {
        name = "replicate-mean",
        set = "growth",
        traps = {"calculation", "growth-phase", "summary"},
        turns = {"What is the average doubling time across the replicates of " .. series.lab_number .. "?"},
        approval = "leave",
        script = script,
        checks = {
            {kind = "answer", number = series.mean_doubling_time_hours, tolerance = 0.05},
            {kind = "shows_method"},
            {kind = "no_latex"},
            {kind = "labels_not_ids"},
            {kind = "no_tool_names"},
            {kind = "finished"},
        },
    }
end
