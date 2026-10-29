-- Tag definitions as records (doc/tag-ontology.md, "Broader tags", and
-- the tier ladder's tier 3): every tag gets one short definition, written
-- by the agent the way the ontology plan asks -- the broader tag as its
-- genus, then what sets it apart from the tags beside it -- checked by a
-- second call, and kept as a tier-3 record (source_ref "tag:<id>") that
-- search and the graph see like any other record.
--
-- A specific tag is defined from its label, description, broader tag,
-- sibling tags and most central documents; a broad tag from the tags it
-- holds. knowledge_tag_definition keeps the hash of the tag's place in
-- the hierarchy (label, description, broader tag, siblings, sub-tags),
-- so a definition is rewritten in place only when that changes -- not
-- when documents come and go -- and archived when its tag is.

db = require("database")
entity = require("entity")
document = require("document")
knowledge = require("knowledge")
tag_upkeep = require("tag_upkeep")
agent_provider = require("agent_provider")

tag_define = {}

DEFINE_PROMPT = """You define one subject tag of a lab's knowledge base, for its ontology.
Write one definition of one to three sentences: what the tag covers, as a kind of its broader tag when it has one ("<Label> is <the broader area> concerned with ..."), then what sets it apart from its sibling tags. Use only what the tag's documents or sub-tags show.
Reply with the definition only."""

DEFINE_CHECK_PROMPT = """You check a tag's definition against what it was written from: the tag's label, broader tag, sibling tags and documents (or sub-tags).
Reply PASS if it describes what those show, names nothing they don't, and tells the tag apart from its siblings. Otherwise reply FAIL: followed by one short reason. Reply with nothing else."""

function define_row(db_path, tag_id)
    rows = db.query(db_path, string.format("SELECT * FROM knowledge_tag_definition WHERE tag_id = %d;", tonumber(tag_id)))
    if rows == nil then
        return nil
    end
    return rows[1]
end

function define_record(db_path, tag_id, input_hash, status, document_id, reason)
    db.exec(db_path, string.format("DELETE FROM knowledge_tag_definition WHERE tag_id = %d;", tonumber(tag_id)))
    db.exec(db_path, string.format(
        "INSERT INTO knowledge_tag_definition (tag_id, input_hash, status, document_id, reason) VALUES (%d, %s, %s, %s, %s);",
        tonumber(tag_id), db.quote(input_hash), db.quote(status), db.literal(document_id), db.literal(reason)))
end

function define_text(value)
    if value == nil or value == "" then
        return nil
    end
    return tostring(value)
end

-- Every active tag with what its definition is written from.
-- -> {{id, label, input}, ...}, by id.
function tag_define.inputs(db_path)
    rows = db.query(db_path, "SELECT id, label, description, source, parent FROM tag WHERE archived_at IS NULL OR archived_at = '' ORDER BY id;")
    if rows == nil then
        return {}
    end
    by_id, children = {}, {}
    for _, row in ipairs(rows) do
        by_id[tostring(tonumber(row.id))] = row
    end
    for _, row in ipairs(rows) do
        parent = define_text(row.parent)
        if parent != nil and by_id[parent] != nil then
            if children[parent] == nil then
                children[parent] = {}
            end
            table.insert(children[parent], row)
        end
    end
    definitions = {}
    defs = db.query(db_path, "SELECT id FROM document WHERE source_type = 'record' AND source_ref LIKE 'tag:%';")
    if defs != nil then
        for _, d in ipairs(defs) do
            definitions[tostring(tonumber(d.id))] = true
        end
    end
    centres = {}
    for _, t in ipairs(tag_upkeep.tags(db_path)) do
        centres[tostring(t.id)] = t.centre
    end

    out = {}
    for _, row in ipairs(rows) do
        key = tostring(tonumber(row.id))
        parts = {"Tag: " .. tostring(row.label)}
        if define_text(row.description) != nil then
            table.insert(parts, "Description: " .. row.description)
        end
        parent = by_id[tostring(define_text(row.parent))]
        if parent != nil then
            line = "Broader tag: " .. tostring(parent.label)
            if define_text(parent.description) != nil then
                line = line .. " -- " .. parent.description
            end
            table.insert(parts, line)
            siblings = {}
            for _, s in ipairs(children[tostring(tonumber(parent.id))]) do
                if tonumber(s.id) != tonumber(row.id) then
                    table.insert(siblings, tostring(s.label))
                end
            end
            if #siblings > 0 then
                table.insert(parts, "Sibling tags: " .. table.concat(siblings, "; "))
            end
        end
        if children[key] != nil then
            subs = {}
            for _, c in ipairs(children[key]) do
                entry = "- " .. tostring(c.label)
                if define_text(c.description) != nil then
                    entry = entry .. ": " .. c.description
                end
                table.insert(subs, entry)
            end
            table.insert(parts, "Sub-tags:\n" .. table.concat(subs, "\n"))
        end
        -- What the definition is rewritten for: the tag's place in the
        -- hierarchy, not its documents (they come and go every day; the
        -- central ones still go into the prompt).
        structure = table.concat(parts, "\n\n")
        if centres[key] != nil then
            -- Without the definitions themselves: a definition placed in
            -- a tag would otherwise change every tag's inputs, and every
            -- run would write them all again.
            members = {}
            for _, m in ipairs(tag_upkeep.members(db_path, row.id)) do
                if definitions[tostring(tonumber(m.document))] != true then
                    table.insert(members, m)
                end
            end
            table.insert(parts, "Its most central documents:\n" ..
                tag_upkeep.titles(db_path, members, centres[key], false))
        end
        -- A tag with neither documents nor sub-tags has nothing to define.
        if centres[key] != nil or children[key] != nil then
            table.insert(out, {id = tonumber(row.id), label = tostring(row.label), input = table.concat(parts, "\n\n"),
                structure = structure})
        end
    end
    return out
end

-- Defines one tag now. -> "defined", "rejected" or "failed", and the
-- record's id.
function tag_define.run(db_path, t, author)
    hash = document.content_hash(t.structure)
    previous = define_row(db_path, t.id)
    record_id = nil
    if previous != nil then
        record_id = tonumber(previous.document_id)
    end
    definition, err = agent_provider.generate(nil, tag_upkeep.context() .. DEFINE_PROMPT, t.input)
    if definition == nil then
        define_record(db_path, t.id, hash, "failed", record_id, tostring(err))
        return "failed", nil
    end
    definition = string.gsub(definition, "^%s+", "")
    definition = string.gsub(definition, "%s+$", "")
    verdict, err = agent_provider.generate(nil, DEFINE_CHECK_PROMPT, "Definition:\n" .. definition .. "\n\n" .. t.input)
    if verdict == nil then
        define_record(db_path, t.id, hash, "failed", record_id, tostring(err))
        return "failed", nil
    end
    verdict = string.gsub(verdict, "^%s+", "")
    if string.sub(verdict, 1, 4) != "PASS" then
        reason = string.gsub(verdict, "^FAIL:?%s*", "")
        define_record(db_path, t.id, hash, "rejected", record_id, string.sub(reason, 1, 500))
        return "rejected", nil
    end
    title = "Definition: " .. t.label
    if record_id != nil and knowledge.get_document(db_path, record_id) != nil then
        ok, issues = document.update_page(db_path, author, record_id, title, nil, definition, nil)
        if ok == nil then
            define_record(db_path, t.id, hash, "failed", record_id, "could not update the record")
            return "failed", nil
        end
        db.exec(db_path, string.format("UPDATE document SET content_hash = %s WHERE id = %d;",
            db.quote(document.content_hash(definition)), record_id))
    else
        record_id, issues = knowledge.create_document_note(db_path, author, title, definition, "record", nil, "tag:" .. tostring(t.id))
        if record_id == nil then
            define_record(db_path, t.id, hash, "failed", nil, "could not create the record")
            return "failed", nil
        end
    end
    knowledge.set_tier(db_path, record_id, 3)
    document.refresh_embedding(db_path, record_id)
    define_record(db_path, t.id, hash, "defined", record_id, nil)
    return "defined", record_id
end

-- `daat tag define [--dry-run] [--limit N]`: every tag whose inputs
-- changed since its definition (or that has none), and the definitions
-- of archived tags archived.
function tag_define.repair(db_path, limit, dry_run, author)
    lines = {}
    due = {}
    for _, t in ipairs(tag_define.inputs(db_path)) do
        row = define_row(db_path, t.id)
        if row == nil or row.input_hash != document.content_hash(t.structure) then
            table.insert(due, t)
        end
    end
    if limit == nil then
        limit = #due
    end
    gone = db.query(db_path, """
        SELECT k.tag_id, k.document_id FROM knowledge_tag_definition k JOIN tag t ON t.id = k.tag_id
        WHERE t.archived_at IS NOT NULL AND t.archived_at != '';""")
    if gone == nil then
        gone = {}
    end
    for i, t in ipairs(due) do
        if i > limit then
            break
        end
        if dry_run then
            table.insert(lines, string.format("would define tag #%d %s", t.id, t.label))
        else
            status, record_id = tag_define.run(db_path, t, author)
            line = string.format("tag #%d %s: %s", t.id, t.label, status)
            if record_id != nil then
                line = line .. " -> record #" .. tostring(record_id)
            end
            table.insert(lines, line)
        end
    end
    archived = 0
    if not dry_run then
        for _, g in ipairs(gone) do
            if define_text(g.document_id) != nil then
                archived_id = entity.archive(db_path, "document", tonumber(g.document_id), author, nil, "its tag was archived")
                if archived_id != nil then
                    document.on_entity_archived(db_path, "document", archived_id)
                    archived = archived + 1
                end
            end
            db.exec(db_path, string.format("DELETE FROM knowledge_tag_definition WHERE tag_id = %d;", tonumber(g.tag_id)))
        end
    end
    if dry_run then
        table.insert(lines, string.format("%d tag(s) due, %d would be defined; %d definition(s) of archived tags", #due, math.min(limit, #due), #gone))
    else
        table.insert(lines, string.format("%d tag(s) due, %d run; %d definition(s) of archived tags archived", #due, math.min(limit, #due), archived))
    end
    return lines
end

return tag_define
