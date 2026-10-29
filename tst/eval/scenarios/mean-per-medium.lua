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
            s.tool("entity.query", {sql = "SELECT m.label, e.lab_number, ms.hours, ms.od600 FROM measurement ms " ..
                "JOIN sample sa ON sa.id = ms.sample JOIN experiment e ON e.id = sa.experiment " ..
                "JOIN culture_medium m ON m.id = e.medium WHERE e.status = 'finished' AND e.archived_at IS NULL " ..
                "AND e.title LIKE 'Growth of S. demo%'"}),
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
