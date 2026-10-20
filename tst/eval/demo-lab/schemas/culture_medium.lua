-- Demo lab (doc/agent-eval.md): a growth medium. Its ingredients live
-- in the culture_medium_ingredients junction table, not a column, so
-- "what is in medium X" needs a join (the schema-discovery trap).
return {
    name = "culture_medium",
    fields = {
        {name = "label", type = "text", required = true, display = true},
        {name = "ingredients", type = "multi_reference", required = false, entity_type = "ingredient"},
        {name = "ph", type = "number", required = false},
    },
}
