-- Three meeting notes share one title; only one records the decision.
return function(f, s)
    d = f.media_decision
    doc_id = s.id(d.doc_key)
    return {
        name = "duplicate-title-decision",
        set = "growth",
        traps = {"duplicate-titles", "citation"},
        turns = {"Which medium did we decide to use for new screening runs, and in which meeting?"},
        approval = "leave",
        script = {
            s.tool("document.search", {query = "decision screening runs medium"}),
            s.final("New screening runs use " .. d.medium .. ", decided in the weekly lab meeting of " ..
                d.meeting_date .. " ([Weekly lab meeting](/document?entity_id=" .. tostring(doc_id) .. "))."),
        },
        checks = {
            {kind = "answer", expected = d.medium},
            {kind = "answer", date = d.meeting_date},
            {kind = "cites", ids = {doc_id}},
            {kind = "finished"},
        },
    }
end
