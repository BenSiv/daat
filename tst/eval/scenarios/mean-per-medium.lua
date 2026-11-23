-- One aggregate over every group at once: a mean per medium, from the
-- readings, leaving out superseded (archived) runs. Reporting some
-- groups and guessing the rest fails.
return function(f, s)
    means = {}
    labels = {}
    for _, m in ipairs(f.media) do
        total = 0
        count = 0
        for _, n in ipairs(f.experiment_order) do
            e = f.experiments[n]
            if e.medium == m.label and e.status == "finished" and e.archived == false then
                total = total + e.doubling_time_hours
                count = count + 1
            end
        end
        table.insert(means, total / count)
        table.insert(labels, m.label)
    end
    parts = {}
    for i, label in ipairs(labels) do
        table.insert(parts, string.format("%s %.2f h", label, means[i]))
    end
    return {
        name = "mean-per-medium",
        set = "growth",
        traps = {"aggregate", "calculation", "archived", "schema-discovery"},
        turns = {"For each culture medium, what is the mean doubling time of its finished \"Growth of S. demo\" " ..
            "experiments? Leave out superseded runs."},
        approval = "leave",
        script = {
            -- The short path (#9): one fit per experiment, averaged per
            -- medium by mean_by in the same call.
            s.tool("stats.fit", {sql = "SELECT m.label AS medium, e.lab_number, ms.hours, ms.od600 FROM measurement ms " ..
                "JOIN sample sa ON sa.id = ms.sample JOIN experiment e ON e.id = sa.experiment " ..
                "JOIN culture_medium m ON m.id = e.medium WHERE e.status = 'finished' AND e.archived_at IS NULL " ..
                "AND e.title LIKE 'Growth of S. demo%'", x_column = "hours", y_column = "od600", model = "exponential",
                group_column = "lab_number", mean_by = "medium"}),
            s.final("Mean doubling time per medium, each run fitted as ln(2) / slope of ln(OD600) against hours: " ..
                table.concat(parts, "; ") .. "."),
        },
        checks = {
            {kind = "answer", numbers = means, tolerance = 0.05},
            {kind = "answer", all = labels},
            {kind = "shows_method"},
            {kind = "no_latex"},
            {kind = "no_failed_lookup"},
            {kind = "finished"},
        },
    }
end
