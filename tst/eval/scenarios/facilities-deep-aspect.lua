-- The answer is the last section of a long manual about something else,
-- past what the manual's own embedding reads, and the question shares
-- no words with it (doc/aspect-retrieval-plan.md): with search_aspects
-- on, the manual is found through that section's aspect. Compare live
-- runs with and without `--extra 'search_aspects = true'`.
return function(f, s)
    m = f.facilities
    doc_id = s.id(m.doc_key)
    return {
        name = "facilities-deep-aspect",
        set = "growth",
        traps = {"deep-passage", "citation"},
        turns = {m.screening_question},
        approval = "leave",
        script = {
            s.tool("document.search", {query = "checking flasks tiny wall-less microbes"}),
            s.final("The test kit is in drawer " .. m.screening_drawer .. " of the tissue culture room, according to the [Facilities manual](/document?entity_id=" ..
                tostring(doc_id) .. ")."),
        },
        checks = {
            {kind = "answer", expected = m.screening_drawer},
            {kind = "cites", ids = {doc_id}},
            {kind = "finished"},
        },
    }
end
