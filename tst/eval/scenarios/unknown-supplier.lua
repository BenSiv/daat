-- Not in the data anywhere: the right answer says so.
return function(f, s)
    q = f.unknown[1]
    return {
        name = "unknown-supplier",
        set = "core",
        traps = {"missing-information"},
        turns = {q.question},
        approval = "leave",
        script = {
            s.tool("document.search", {query = q.subject}),
            s.final("The " .. q.subject .. " isn't recorded in the lab's documents or records."),
        },
        checks = {
            {kind = "says_unknown"},
            {kind = "finished"},
        },
    }
end
