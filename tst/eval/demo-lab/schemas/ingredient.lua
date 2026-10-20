-- Demo lab (doc/agent-eval.md): a medium ingredient.
return {
    name = "ingredient",
    fields = {
        {name = "label", type = "text", required = true, display = true},
        {name = "grams_per_litre", type = "number", required = false, min = 0},
    },
}
