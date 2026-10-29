-- Two turns: summarise, then save the summary as a document that links
-- each experiment's notes (found live on daat-test: the links went to
-- the experiment records as Markdown, which connects no documents, and
-- the summary was filed under one experiment's notes).
return function(f, s)
    medium = f.media[1].label
    rows = {}
    notes_ids = {}
    all_notes_ids = {}
    links = {}
    for _, n in ipairs(f.experiment_order) do
        e = f.experiments[n]
        if e.notes_key != nil then
            table.insert(all_notes_ids, s.id(e.notes_key))
        end
        if e.medium == medium and e.archived == false and e.notes_key != nil then
            table.insert(notes_ids, s.id(e.notes_key))
            table.insert(rows, "| " .. e.lab_number .. " | " .. e.status .. " | " .. string.format("%.2f", e.doubling_time_hours) .. " |")
            table.insert(links, "- " .. e.lab_number .. ": [[Notes: " .. e.title .. " (" .. e.lab_number .. ")]]")
        end
    end
    table_text = "| Lab number | Status | Doubling time (h) |\n|---|---|---|\n" .. table.concat(rows, "\n")
    return {
        name = "summary-document-links",
        set = "growth",
        traps = {"write", "document-links", "multi-turn"},
        turns = {
            "Summarise the " .. medium .. " experiments: lab number, status and doubling time for each.",
            "Save that as a new document called \"" .. medium .. " experiments\", linking each experiment's notes.",
        },
        approval = "approve",
        script = {
            s.tool("entity.query", {sql = "SELECT e.lab_number, e.status FROM experiment e JOIN culture_medium m ON m.id = e.medium " ..
                "WHERE m.label = '" .. medium .. "' AND e.archived_at IS NULL"}),
            s.final(table_text),
            s.tool("document.create", {title = medium .. " experiments",
                content = "# " .. medium .. " experiments\n\n" .. table_text .. "\n\n## Notes\n\n" .. table.concat(links, "\n") .. "\n"}),
            s.final("Saved as \"" .. medium .. " experiments\", linking each experiment's notes."),
        },
        checks = {
            {kind = "approval", expect_write = true},
            {kind = "links_documents", ids = notes_ids},
            {kind = "no_dangling_links"},
            {kind = "not_filed_under", ids = all_notes_ids},
            {kind = "no_latex"},
            {kind = "finished"},
        },
    }
end
