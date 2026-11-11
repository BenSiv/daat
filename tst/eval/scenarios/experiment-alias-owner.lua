-- People write "Experiment 027" in prose when the stored lab_number is
-- "EXP-027" (matched by platform.lua's reference_aliases).
return function(f, s)
    e = nil
    for _, n in ipairs(f.experiment_order) do
        x = f.experiments[n]
        if e == nil and x.archived == false and x.notes_key != nil then
            e = x
        end
    end
    digits = string.match(e.lab_number, "%d+")
    exp_id = s.id(e.key)
    sql = "SELECT e.id, pe.full_name FROM experiment e JOIN person pe ON pe.id = e.owner " ..
        "WHERE e.lab_number = '" .. e.lab_number .. "' AND e.archived_at IS NULL"
    return {
        name = "experiment-alias-owner",
        set = "growth",
        traps = {"id-number-name", "schema-discovery", "citation"},
        turns = {"Who owns Experiment " .. digits .. "?"},
        approval = "leave",
        script = {
            s.tool("entity.relationships"),
            s.tool("entity.query", {sql = sql}),
            s.final(string.format("[%s](/detail?type=experiment&entity_id=%d) is owned by %s.",
                e.lab_number, exp_id, e.owner)),
        },
        checks = {
            {kind = "answer", expected = e.owner},
            {kind = "cites", ids = {exp_id, s.id(e.notes_key)}},
            {kind = "names_record", label = e.lab_number},
            {kind = "no_failed_lookup"},
            {kind = "finished"},
        },
    }
end
