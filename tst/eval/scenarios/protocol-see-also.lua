-- Edit an existing document: add a linked "See also" section without
-- losing what's there. A content update replaces the whole field, so
-- writing only the new section drops the protocol.
return function(f, s)
    protocol_id = s.id(f.protocol_doc_key)
    notes_ids = {}
    links = {}
    for _, n in ipairs(f.experiment_order) do
        e = f.experiments[n]
        if e.medium == f.media_decision.medium and e.status == "finished" and e.archived == false then
            table.insert(notes_ids, s.id(e.notes_key))
            table.insert(links, "- [[Notes: " .. e.title .. " (" .. e.lab_number .. ")]]")
        end
    end
    return {
        name = "protocol-see-also",
        set = "growth",
        traps = {"write", "document-links", "update-keeps-content"},
        turns = {"Add a \"See also\" section to the OD600 protocol linking the notes of every finished " ..
            f.media_decision.medium .. " experiment."},
        approval = "approve",
        script = {
            s.tool("entity.get", {entity_type = "document", entity_id = protocol_id, field = "content", offset = 0}),
            s.tool("entity.query", {sql = "SELECT lab_number FROM experiment WHERE status = 'finished' AND archived_at IS NULL"}),
            -- The test provider can't read the protocol back, so the
            -- script writes the generator's own text plus the section.
            s.tool("document.update", {entity_id = protocol_id, content = "# Measuring culture density (OD600)\n\n" ..
                "## Purpose\n\nTrack growth of liquid cultures by optical density at 600 nm.\n\n" ..
                "## Equipment\n\n- Spectrophotometer, 1 cm cuvettes\n- Sterile medium for blanks\n\n" ..
                "## Steps\n\n1. Blank the instrument with sterile medium.\n" ..
                "2. Take 1 ml of culture aseptically.\n" ..
                "3. Dilute 1:10 if the reading is above 0.8, and multiply back.\n" ..
                "4. Record the reading with the sample label and hours since inoculation.\n\n" ..
                "## Calculating doubling time\n\nFit ln(OD600) against time in hours over the exponential phase. " ..
                "The doubling time is ln(2) divided by the slope.\n\n" ..
                "## Safety\n\nWork at the bench with gloves; autoclave cuvettes after use.\n\n" ..
                "## See also\n\n" .. table.concat(links, "\n") .. "\n"}),
            s.final("Added a \"See also\" section to the OD600 protocol, linking the notes of each finished " ..
                f.media_decision.medium .. " experiment."),
        },
        checks = {
            {kind = "approval", expect_write = true},
            {kind = "links_documents", from = protocol_id, ids = notes_ids},
            {kind = "keeps_content", id = protocol_id, texts = {"## Steps", "Dilute 1:10", "## Calculating doubling time", "## Safety"}},
            {kind = "no_dangling_links"},
            {kind = "finished"},
        },
    }
end
