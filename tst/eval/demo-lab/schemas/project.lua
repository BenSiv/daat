-- Demo lab (doc/agent-eval.md): a research project grouping experiments.
return {
    name = "project",
    fields = {
        {name = "title", type = "text", required = true, display = true},
        {name = "lead", type = "reference", required = false, entity_type = "person"},
        {name = "status", type = "select", required = false,
            values = {"active", "closed"}},
    },
}
