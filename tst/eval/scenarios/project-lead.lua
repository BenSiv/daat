-- Two hops: experiment -> project -> person.
return function(f, s)
    e = nil
    for _, n in ipairs(f.experiment_order) do
        if e == nil and f.experiments[n].archived == false then
            e = f.experiments[n]
        end
    end
    lead = f.projects[e.project_index].lead
    sql = "SELECT pe.full_name FROM experiment e JOIN project p ON p.id = e.project " ..
        "JOIN person pe ON pe.id = p.lead WHERE e.lab_number = '" .. e.lab_number .. "'"
    return {
        name = "project-lead",
        set = "growth",
        traps = {"schema-discovery", "id-number-name"},
        turns = {"Who leads the project that " .. e.lab_number .. " belongs to?"},
        approval = "leave",
        script = {
            s.tool("entity.relationships"),
            s.tool("entity.query", {sql = sql}),
            s.final(e.lab_number .. " belongs to " .. e.project .. ", which is led by " .. lead .. "."),
        },
        checks = {
            {kind = "answer", expected = lead},
            {kind = "no_failed_lookup"},
            {kind = "finished"},
        },
    }
end
