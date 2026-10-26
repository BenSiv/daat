-- A second deep fact in the same long document, asked in other words.
return function(f, s)
    h = f.handbook
    doc_id = s.id(h.doc_key)
    return {
        name = "handbook-media-cooling",
        set = "growth",
        traps = {"deep-passage", "citation"},
        turns = {h.cooling_question},
        approval = "leave",
        script = {
            s.tool("document.search", {query = "wait sterilising broth antibiotics"}),
            s.final("Wait " .. h.cooling_minutes .. " minutes, until the media is about 55 C, according to the [Lab handbook](/document?entity_id=" ..
                tostring(doc_id) .. ")."),
        },
        checks = {
            {kind = "answer", expected = h.cooling_minutes},
            {kind = "cites", ids = {doc_id}},
            {kind = "finished"},
        },
    }
end
