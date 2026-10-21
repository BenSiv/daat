-- Date arithmetic in the database's own dialect.
return function(f, s)
    e = nil
    for _, n in ipairs(f.experiment_order) do
        x = f.experiments[n]
        if e == nil and x.days != nil and x.archived == false and x.days >= 3 then
            e = x
        end
    end
    sql = "SELECT julianday(ended_on) - julianday(started_on) AS days FROM experiment " ..
        "WHERE lab_number = '" .. e.lab_number .. "'"
    return {
        name = "days-between-dates",
        set = "growth",
        traps = {"sql-dialect"},
        turns = {"How many days did " .. e.lab_number .. " run?"},
        approval = "leave",
        script = {
            s.tool("entity.query", {sql = sql}),
            s.final(string.format("%s ran for %d days, from %s to %s.", e.lab_number, e.days, e.started_on, e.ended_on)),
        },
        checks = {
            {kind = "answer", number = e.days, tolerance = 0},
            {kind = "no_failed_lookup"},
            {kind = "finished"},
        },
    }
end
