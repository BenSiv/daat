-- The answer sits in a late section of a long document and shares few
-- words with the question (doc/passage-retrieval-plan.md): search has
-- to show the passage that answers, not the document's opening.
return function(f, s)
    h = f.handbook
    doc_id = s.id(h.doc_key)
    return {
        name = "handbook-deep-passage",
        set = "growth",
        traps = {"deep-passage", "citation"},
        turns = {h.stocks_question},
        approval = "leave",
        script = {
            s.tool("document.search", {query = "frozen backups yeast kept"}),
            s.final("They're kept in freezer " .. h.stocks_location .. ", rack B, box 12, according to the [Lab handbook](/document?entity_id=" ..
                tostring(doc_id) .. ")."),
        },
        checks = {
            {kind = "answer", expected = h.stocks_location},
            {kind = "cites", ids = {doc_id}},
            {kind = "finished"},
        },
    }
end
