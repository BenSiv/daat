-- The answer needs a join through a junction table: guessing columns fails.
return function(f, s)
    e = nil
    for _, n in ipairs(f.experiment_order) do
        if e == nil and f.experiments[n].status == "finished" and f.experiments[n].archived == false then
            e = f.experiments[n]
        end
    end
    medium = f.media[e.medium_index]
    sql = "SELECT i.label FROM experiment e " ..
        "JOIN culture_medium_ingredients mi ON mi.culture_medium_id = e.medium " ..
        "JOIN ingredient i ON i.id = mi.ingredients_id " ..
        "WHERE e.lab_number = '" .. e.lab_number .. "' AND e.archived_at IS NULL ORDER BY i.label"
    return {
        name = "schema-medium-ingredients",
        set = "core",
        traps = {"schema-discovery"},
        turns = {"Which ingredients are in the medium used for " .. e.lab_number .. "?"},
        approval = "leave",
        script = {
            s.tool("entity.fields", {entity_type = "experiment"}),
            s.tool("entity.relationships"),
            s.tool("entity.query", {sql = sql}),
            s.final(e.lab_number .. " used " .. medium.label .. ", which contains " ..
                table.concat(medium.ingredients, ", ") .. "."),
        },
        checks = {
            {kind = "answer", all = medium.ingredients},
            {kind = "no_failed_lookup"},
            {kind = "finished"},
        },
    }
end
