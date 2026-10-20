-- The fact lives only in a document: the answer must link it.
return function(f, s)
    e = nil
    for _, n in ipairs(f.experiment_order) do
        x = f.experiments[n]
        if e == nil and x.incubator != nil and x.archived == false then
            e = x
        end
    end
    doc_id = s.id(e.notes_key)
    return {
        name = "citation-incubator",
        set = "core",
        traps = {"citation"},
        turns = {"Which incubator was " .. e.lab_number .. " grown in?"},
        approval = "leave",
        script = {
            s.tool("document.search", {query = e.lab_number .. " incubator"}),
            s.final(e.lab_number .. " was grown in " .. e.incubator .. ", according to its [lab notes](/document?entity_id=" ..
                tostring(doc_id) .. ")."),
        },
        checks = {
            {kind = "answer", expected = e.incubator},
            {kind = "cites", ids = {doc_id}},
            {kind = "finished"},
        },
    }
end
