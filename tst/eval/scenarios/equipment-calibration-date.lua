-- An entity type with no `display = true` field (`equipment`): EQ-041 was
-- registered directly in daat (so its builtin `name` column is unset too),
-- and its `number` (3) is neither 41 nor its database id.
return function(f, s)
    eq = f.equipment["EQ-041"]
    eq_id = s.id(eq.key)
    sql = "SELECT id, asset_code, room, calibrated_on FROM equipment " ..
        "WHERE asset_code = '" .. eq.asset_code .. "' AND archived_at IS NULL"
    return {
        name = "equipment-calibration-date",
        set = "growth",
        traps = {"id-number-name", "schema-discovery", "citation"},
        turns = {"When was " .. eq.asset_code .. " last calibrated, and which room is it in?"},
        approval = "leave",
        script = {
            s.tool("entity.relationships"),
            s.tool("entity.query", {sql = sql}),
            s.final(string.format("[%s](/detail?type=equipment&entity_id=%d) is in %s and was last calibrated on %s.",
                eq.asset_code, eq_id, eq.room, eq.calibrated_on)),
        },
        checks = {
            {kind = "answer", date = eq.calibrated_on},
            {kind = "answer", expected = eq.room},
            {kind = "cites", ids = {eq_id}},
            {kind = "names_record", label = eq.asset_code},
            {kind = "labels_not_ids", ids = {eq_id}},
            {kind = "no_failed_lookup"},
            {kind = "finished"},
        },
    }
end
