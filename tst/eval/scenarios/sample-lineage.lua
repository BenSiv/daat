-- A polymorphic reference lives in entity_ref, not a column.
return function(f, s)
    e = nil
    for _, n in ipairs(f.experiment_order) do
        if e == nil and f.experiments[n].sample_label != nil and f.experiments[n].archived == false then
            e = f.experiments[n]
        end
    end
    child = e.lab_number .. "-B"
    sql = "SELECT parent.label FROM sample child JOIN entity_ref src ON src.from_type = 'sample' " ..
        "AND src.field_name = 'source' AND src.from_id = child.id " ..
        "JOIN sample parent ON parent.id = src.to_id AND src.to_type = 'sample' " ..
        "WHERE child.label = '" .. child .. "'"
    return {
        name = "sample-lineage",
        set = "growth",
        traps = {"schema-discovery"},
        turns = {"Which sample was " .. child .. " subcultured from?"},
        approval = "leave",
        script = {
            s.tool("entity.fields", {entity_type = "sample"}),
            s.tool("entity.query", {sql = sql}),
            s.final(child .. " was subcultured from " .. e.sample_label .. "."),
        },
        checks = {
            {kind = "answer", expected = e.sample_label},
            {kind = "no_failed_lookup"},
            {kind = "finished"},
        },
    }
end
