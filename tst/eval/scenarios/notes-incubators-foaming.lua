-- An answer gathered across many documents: the incubators named in
-- every Molasses medium experiment's notes, and which runs foamed. No
-- single search excerpt holds it all.
return function(f, s)
    incubators = {}
    seen = {}
    foamed = {}
    for _, n in ipairs(f.experiment_order) do
        e = f.experiments[n]
        if e.medium == f.media_decision.medium and e.archived == false and e.notes_key != nil then
            if seen[e.incubator] == nil then
                seen[e.incubator] = true
                table.insert(incubators, e.incubator)
            end
            if string.find(e.observation, "foaming", 1, true) != nil then
                table.insert(foamed, e.lab_number)
            end
        end
    end
    expected = {}
    for _, x in ipairs(incubators) do
        table.insert(expected, x)
    end
    for _, x in ipairs(foamed) do
        table.insert(expected, x)
    end
    return {
        name = "notes-incubators-foaming",
        set = "growth",
        traps = {"cross-document", "retrieval"},
        turns = {"Which incubators were the " .. f.media_decision.medium .. " experiments grown in, and which of " ..
            "those experiments had foaming?"},
        approval = "leave",
        script = {
            s.tool("document.search", {query = f.media_decision.medium .. " notes incubator foaming", detail = "full"}),
            s.final("From the lab notes: grown in " .. table.concat(incubators, ", ") .. ". Foaming was noted in " ..
                table.concat(foamed, ", ") .. "."),
        },
        checks = {
            {kind = "answer", all = expected},
            {kind = "no_failed_lookup"},
            {kind = "finished"},
        },
    }
end
