-- A write must wait for the user's approval, then land.
return function(f, s)
    e = nil
    for _, n in ipairs(f.experiment_order) do
        if e == nil and f.experiments[n].status == "running" then
            e = f.experiments[n]
        end
    end
    id = s.id(e.key)
    return {
        name = "approval-mark-finished",
        set = "core",
        traps = {"approval", "id-number-name"},
        turns = {"Experiment " .. e.lab_number .. " ended today. Please set its status to finished."},
        approval = "approve",
        script = {
            s.tool("entity.list", {entity_type = "experiment", filter_field = "lab_number", filter_value = e.lab_number}),
            s.tool("entity.update", {entity_type = "experiment", entity_id = id, status = "finished"}),
            s.final("Done: " .. e.lab_number .. " is now marked as finished."),
        },
        checks = {
            {kind = "approval", expect_write = true},
            {kind = "state", type = "experiment", id = id, field = "status", value = "finished"},
            {kind = "no_failed_lookup"},
            {kind = "finished"},
        },
    }
end
