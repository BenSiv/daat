-- The culture levels off: only a growth-phase fit gives the right
-- doubling time; first-vs-last over the whole run is far too slow.
return function(f, s)
    series = f.replicate_series
    rep = series.replicates[4]
    sql = "SELECT m.hours, m.od600 FROM measurement m JOIN sample s ON s.id = m.sample " ..
        "WHERE s.label = '" .. rep.label .. "' ORDER BY m.hours"
    return {
        name = "plateau-doubling-time",
        set = "growth",
        traps = {"calculation", "growth-phase"},
        turns = {"What was the doubling time of sample " .. rep.label .. "?"},
        approval = "leave",
        script = {
            s.tool("stats.fit", {sql = sql, x_column = "hours", y_column = "od600", model = "exponential"}),
            s.final(string.format("The doubling time of %s was %.2f hours, from a log-linear fit over its " ..
                "exponential growth phase (the culture levels off after that, so later readings are left out).",
                rep.label, rep.doubling_time_hours)),
        },
        checks = {
            {kind = "answer", number = rep.doubling_time_hours, tolerance = 0.1},
            {kind = "shows_method"},
            {kind = "no_tool_names"},
            {kind = "finished"},
        },
    }
end
