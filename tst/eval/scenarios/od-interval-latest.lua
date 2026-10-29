-- Conflicting sources: two notes with the same title disagree, and the
-- later one replaces the earlier. The answer is the latest decision,
-- with the note it comes from.
return function(f, s)
    d = f.od_interval
    doc_id = s.id(d.doc_key)
    return {
        name = "od-interval-latest",
        set = "growth",
        traps = {"conflicting-sources", "duplicate-titles", "citation"},
        turns = {"How often should we read OD600 during a growth run?"},
        approval = "leave",
        script = {
            s.tool("document.search", {query = "OD600 reading schedule decision"}),
            s.final(string.format("Every %d hours: the [Weekly lab meeting](/document?entity_id=%d) of %s changed it " ..
                "from every %d hours, which missed the end of the exponential phase.", d.hours, doc_id,
                d.meeting_date, d.replaced_hours)),
        },
        checks = {
            {kind = "answer", any = {d.hours .. " hours", d.hours .. " h", "two hours", d.hours .. "-hour", d.hours .. "h"}},
            {kind = "answer", date = d.meeting_date},
            {kind = "cites", ids = {doc_id}},
            {kind = "finished"},
        },
    }
end
