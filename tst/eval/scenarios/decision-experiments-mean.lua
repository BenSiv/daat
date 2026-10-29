-- Several hops: meeting note -> the medium it chose and when it took
-- effect -> the finished runs on that medium since -> their mean
-- doubling time. No single document or row holds the answer.
return function(f, s)
    d = f.media_decision
    picked = {}
    labels = {}
    total = 0
    for _, n in ipairs(f.experiment_order) do
        e = f.experiments[n]
        if e.medium == d.medium and e.status == "finished" and e.archived == false and e.started_on >= "2026-03-01" then
            table.insert(picked, e)
            table.insert(labels, e.lab_number)
            total = total + e.doubling_time_hours
        end
    end
    mean = total / #picked
    meeting_id = s.id(d.doc_key)
    return {
        name = "decision-experiments-mean",
        set = "growth",
        traps = {"multi-hop", "duplicate-titles", "calculation", "archived"},
        turns = {"Which finished experiments ran on the medium we chose at the February lab meeting, after that " ..
            "decision took effect? What was their mean doubling time?"},
        approval = "leave",
        script = {
            s.tool("document.search", {query = "decision medium screening runs"}),
            s.tool("entity.query", {sql = "SELECT e.lab_number FROM experiment e JOIN culture_medium m ON m.id = e.medium " ..
                "WHERE m.label = '" .. d.medium .. "' AND e.status = 'finished' AND e.started_on >= '2026-03-01' AND e.archived_at IS NULL"}),
            s.final(string.format("The [Weekly lab meeting](/document?entity_id=%d) of %s chose %s from March. " ..
                "Finished runs on it since: %s. Their mean doubling time is %.2f hours, calculated as the mean " ..
                "of each run's ln(2) / slope of ln(OD600) over time.", meeting_id, d.meeting_date, d.medium,
                table.concat(labels, ", "), mean)),
        },
        checks = {
            {kind = "answer", all = labels},
            {kind = "answer", number = mean, tolerance = 0.05},
            {kind = "cites", ids = {meeting_id}},
            {kind = "shows_method"},
            {kind = "no_latex"},
            {kind = "no_failed_lookup"},
            {kind = "finished"},
        },
    }
end
