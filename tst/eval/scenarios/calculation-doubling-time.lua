-- One correct number, from the readings: and the answer shows how.
return function(f, s)
    e = nil
    for _, n in ipairs(f.experiment_order) do
        x = f.experiments[n]
        if e == nil and x.doubling_time_hours != nil and x.status == "finished" and x.archived == false then
            e = x
        end
    end
    sql = "SELECT m.hours, m.od600 FROM measurement m " ..
        "JOIN sample s ON s.id = m.sample JOIN experiment e ON e.id = s.experiment " ..
        "WHERE e.lab_number = '" .. e.lab_number .. "' AND m.archived_at IS NULL ORDER BY m.hours"
    return {
        name = "calculation-doubling-time",
        set = "core",
        traps = {"calculation"},
        turns = {"What was the doubling time of " .. e.lab_number .. "?"},
        approval = "leave",
        script = {
            s.tool("entity.query", {sql = sql}),
            s.final(string.format("The doubling time of %s was about %.2f hours, calculated as " ..
                "ln(2) divided by the slope of ln(OD600) against time, from this query: %s",
                e.lab_number, e.doubling_time_hours, sql)),
        },
        checks = {
            {kind = "answer", number = e.doubling_time_hours, tolerance = 0.05},
            {kind = "shows_method"},
            {kind = "no_failed_lookup"},
            {kind = "finished"},
        },
    }
end
