-- Demo lab (doc/agent-eval.md): one growth experiment. lab_number
-- ("EXP-017") never equals the row id, and the title carries no
-- number, so the agent has to tell the three apart.
return {
    name = "experiment",
    fields = {
        {name = "title", type = "text", required = true, display = true},
        {name = "lab_number", type = "text", required = true},
        {name = "project", type = "reference", required = false, entity_type = "project"},
        {name = "medium", type = "reference", required = false, entity_type = "culture_medium"},
        {name = "owner", type = "reference", required = false, entity_type = "person"},
        {name = "started_on", type = "date", required = false},
        {name = "ended_on", type = "date", required = false},
        {name = "status", type = "select", required = false,
            values = {"planned", "running", "finished"}},
    },
}
