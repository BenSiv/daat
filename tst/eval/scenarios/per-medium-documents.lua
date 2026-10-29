-- "Do the same for the others": a follow-up that depends on the turn
-- before it, and several long writes in one turn -- where Gemini's
-- malformed tool calls showed up on daat-test.
return function(f, s)
    script = {}
    notes_ids = {}
    all_notes_ids = {}
    for _, n in ipairs(f.experiment_order) do
        e = f.experiments[n]
        if e.notes_key != nil then
            table.insert(all_notes_ids, s.id(e.notes_key))
            if e.archived == false then
                table.insert(notes_ids, s.id(e.notes_key))
            end
        end
    end
    for i, m in ipairs(f.media) do
        links = {}
        for _, n in ipairs(f.experiment_order) do
            e = f.experiments[n]
            if e.medium == m.label and e.archived == false and e.notes_key != nil then
                table.insert(links, "- " .. e.lab_number .. " (" .. e.status .. "): [[Notes: " .. e.title .. " (" .. e.lab_number .. ")]]")
            end
        end
        if i == 1 then
            table.insert(script, s.tool("entity.query", {sql = "SELECT lab_number, status FROM experiment WHERE archived_at IS NULL"}))
        elseif i == 2 then
            table.insert(script, s.tool("entity.query", {sql = "SELECT lab_number, status FROM experiment WHERE archived_at IS NULL"}))
        end
        table.insert(script, s.tool("document.create", {title = m.label .. " experiments",
            content = "# " .. m.label .. " experiments\n\n" .. table.concat(links, "\n") .. "\n"}))
        if i == 1 then
            table.insert(script, s.final("Created \"" .. m.label .. " experiments\"."))
        end
    end
    table.insert(script, s.final("Created one document per medium, each linking its experiments' notes."))
    return {
        name = "per-medium-documents",
        set = "growth",
        traps = {"write", "document-links", "multi-turn", "long-write"},
        turns = {
            "Make a summary document for the " .. f.media[1].label .. " experiments, linking each one's notes.",
            "Do the same for each of the other media, one document per medium.",
        },
        approval = "approve",
        script = script,
        checks = {
            {kind = "approval", expect_write = true},
            {kind = "links_documents", ids = notes_ids},
            {kind = "no_dangling_links"},
            {kind = "not_filed_under", ids = all_notes_ids},
            {kind = "finished"},
        },
    }
end
