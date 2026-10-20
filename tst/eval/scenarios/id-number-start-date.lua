-- The lab number is not the row id: looking it up by id gives the wrong
-- experiment. Prefer one whose number is another experiment's id.
return function(f, s)
    ids_in_use = {}
    for _, n in ipairs(f.experiment_order) do
        ids_in_use[s.id(f.experiments[n].key)] = true
    end
    e = nil
    fallback = nil
    for _, n in ipairs(f.experiment_order) do
        x = f.experiments[n]
        if x.started_on != nil and x.archived == false then
            if fallback == nil then
                fallback = x
            end
            number = tonumber(string.match(x.lab_number, "%d+"))
            if e == nil and ids_in_use[number] == true and s.id(x.key) != number then
                e = x
            end
        end
    end
    if e == nil then
        e = fallback
    end
    return {
        name = "id-number-start-date",
        set = "core",
        traps = {"id-number-name"},
        turns = {"When did " .. e.lab_number .. " start?"},
        approval = "leave",
        script = {
            s.tool("entity.list", {entity_type = "experiment", filter_field = "lab_number", filter_value = e.lab_number}),
            s.final(e.lab_number .. " started on " .. e.started_on .. "."),
        },
        checks = {
            {kind = "answer", date = e.started_on},
            {kind = "no_failed_lookup"},
            {kind = "finished"},
        },
    }
end
