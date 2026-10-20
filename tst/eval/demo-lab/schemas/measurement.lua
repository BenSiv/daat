-- Demo lab (doc/agent-eval.md): an optical-density reading of a sample
-- at a time point. Readings follow a known exponential curve, so a
-- doubling time has one correct value.
return {
    name = "measurement",
    fields = {
        {name = "sample", type = "reference", required = true, entity_type = "sample"},
        {name = "hours", type = "number", required = true},
        {name = "od600", type = "number", required = true},
    },
}
