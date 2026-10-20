-- Demo lab (doc/agent-eval.md): who works in the lab.
return {
    name = "person",
    fields = {
        {name = "full_name", type = "text", required = true, display = true},
        {name = "role", type = "select", required = false,
            values = {"scientist", "technician", "student"}},
    },
}
