-- Demo lab (doc/agent-eval.md): a culture sample. Its source is either
-- the experiment's inoculum or an earlier sample (polymorphic).
return {
    name = "sample",
    fields = {
        {name = "label", type = "text", required = true, display = true},
        {name = "experiment", type = "reference", required = true, entity_type = "experiment"},
        {name = "source", type = "polymorphic_reference", required = false,
            allowed_entity_types = {"experiment", "sample"}},
    },
}
