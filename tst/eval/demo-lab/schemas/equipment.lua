-- Demo lab (doc/agent-eval.md): a lab instrument. Deliberately has no
-- `display = true` field, matching imported schemas on real deployments:
-- imported rows carry the builtin `name` column, while rows registered
-- directly in daat carry only their fields (`number`, `asset_code`, ...).
-- `asset_code` is the name people use, so it's an identifier: entity.find
-- resolves "EQ-041" to its row, and shows the row by it.
return {
    name = "equipment",
    fields = {
        {name = "number", type = "number", required = true},
        {name = "asset_code", type = "text", required = true, identifier = true},
        {name = "kind", type = "select", required = true,
            values = {"spectrophotometer", "centrifuge", "shaker", "autoclave"}},
        {name = "room", type = "text", required = false},
        {name = "calibrated_on", type = "date", required = false},
        {name = "status", type = "select", required = true,
            values = {"in_service", "maintenance", "retired"}},
    },
}
