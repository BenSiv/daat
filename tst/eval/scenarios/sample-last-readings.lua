-- Samples by their labels, never their row ids (found live: "sample 41"),
-- and the subcultured sample that has no readings is said to have none
-- rather than given its parent's.
return function(f, s)
    e = nil
    for _, n in ipairs(f.experiment_order) do
        x = f.experiments[n]
        if e == nil and x.status == "finished" and x.archived == false and x.od_last != nil then
            e = x
        end
    end
    a = s.id(e.key .. "-s1")
    b = s.id(e.key .. "-s2")
    return {
        name = "sample-last-readings",
        set = "growth",
        traps = {"id-number-name", "missing-information", "schema-discovery"},
        turns = {"Which samples belong to " .. e.lab_number .. ", and what was each one's last OD600 reading?"},
        approval = "leave",
        script = {
            s.tool("entity.query", {sql = "SELECT sa.label, MAX(ms.hours) AS last_hour FROM sample sa " ..
                "LEFT JOIN measurement ms ON ms.sample = sa.id JOIN experiment e ON e.id = sa.experiment " ..
                "WHERE e.lab_number = '" .. e.lab_number .. "' GROUP BY sa.label"}),
            s.final(string.format("%s has two samples. %s-A: last OD600 %s at 12 h. %s-B was subcultured from " ..
                "%s-A and has no readings recorded.", e.lab_number, e.lab_number, tostring(e.od_last),
                e.lab_number, e.lab_number)),
        },
        checks = {
            {kind = "answer", all = {e.lab_number .. "-A", e.lab_number .. "-B"}},
            {kind = "answer", number = e.od_last, tolerance = 0.01},
            {kind = "labels_not_ids", ids = {a, b}},
            {kind = "names_record", label = e.lab_number .. "-B"},
            {kind = "no_failed_lookup"},
            {kind = "finished"},
        },
    }
end
