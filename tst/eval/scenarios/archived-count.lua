-- Superseded runs are archived: a count that forgets archived_at is wrong.
return function(f, s)
    p = nil
    for i, project in ipairs(f.projects) do
        if p == nil then
            for _, n in ipairs(f.experiment_order) do
                x = f.experiments[n]
                if x.project_index == i and x.archived == true then
                    p = project
                end
            end
        end
    end
    sql = "SELECT COUNT(*) AS n FROM experiment e JOIN project p ON p.id = e.project " ..
        "WHERE p.title = '" .. p.title .. "' AND e.status = 'finished' " ..
        "AND (e.archived_at IS NULL OR e.archived_at = '')"
    return {
        name = "archived-count",
        set = "growth",
        traps = {"archived-rows", "schema-discovery"},
        turns = {"How many finished experiments are there in the project \"" .. p.title .. "\"?"},
        approval = "leave",
        script = {
            s.tool("entity.query", {sql = sql}),
            s.final(string.format("There are %d finished experiments in %s (superseded, archived runs not counted).",
                p.finished_count, p.title)),
        },
        checks = {
            {kind = "answer", number = p.finished_count, tolerance = 0},
            {kind = "no_failed_lookup"},
            {kind = "finished"},
        },
    }
end
