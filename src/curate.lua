-- The curate step of the tier ladder (doc/tier-curation-ladder.md): a
-- source the team uses -- a synced file, a page someone wrote, a chat --
-- is rewritten by the agent as a clean note in its own words, checked
-- against the source by a second call, and kept as a tier-1 document
-- (source_type "curated") that links to its source. The source itself
-- is never edited and stays at tier 0.
--
-- Use decides what gets curated, not a scan of the pool: review queues
-- a source once it's due (knowledge.due_for_review), and the jobs
-- worker runs the queue (`daat knowledge curate-pending`). `daat repair
-- curate` queues every source already due by its usage so far, most
-- used first -- the backfill after the tier reset (store migration 7).
--
-- knowledge_curation keeps one row per source: the content hash it
-- last saw and how that went (pending, curated, nothing, rejected,
-- failed). A source is curated again only once its content changes,
-- and its existing note is then rewritten in place.

db = require("database")
document = require("document")
knowledge = require("knowledge")

curate = {}

-- What the agent reads of a source; a paper past this is cut, with a
-- note saying so (its abstract, methods and results come first).
CURATE_INPUT_MAX_CHARS = 40000
-- Shorter than this has nothing to curate (a stub, a folder page).
CURATE_MIN_CHARS = 500
-- How much of the source the check sees next to the note.
CURATE_CHECK_SOURCE_MAX_CHARS = 40000

CURATE_SYSTEM_PROMPT = """
You curate a team's knowledge base. Rewrite the source below as a clean note in your own words for a colleague who hasn't read it: one line on what it is, then its key findings, methods or decisions, with the concrete numbers, conditions, materials and names that matter. Leave out boilerplate, file paths, headers, tool output, greetings and anything the source doesn't support. Never add a fact that isn't in the source.

Format: the first line is "# " and a title naming the subject specifically (not the file name). Then the note in Markdown, at most about 400 words, with short sections or bullets where they help.

If the source is a conversation between a user and an assistant, keep what it established -- conclusions, facts found, decisions -- not the back-and-forth.

If the source holds nothing worth keeping (small talk, a failed or empty exchange, text that didn't extract), reply with exactly: NOTHING
"""

CURATE_CHECK_SYSTEM_PROMPT = """
You check a curated note against the source it was written from. Reply PASS if every statement in the note is supported by the source, it adds nothing the source doesn't say, and it's clearly cleaner and more useful to a reader than the raw source. Otherwise reply FAIL: followed by one short reason. Reply with nothing else.
"""

-- Sources curate reads: synced files and pages (no source_type) and
-- chats. Not reasoning, connection notes, generated views, legacy
-- distilled facts, or anything the curation wrote itself.
CURATE_SOURCE_TYPES = {chat_session = true}

function curate.is_source(doc)
    if doc == nil then
        return false
    end
    if doc.source_type != nil and doc.source_type != "" and CURATE_SOURCE_TYPES[doc.source_type] != true then
        return false
    end
    if document.is_connection_title(doc.title) then
        return false
    end
    return true
end

-- What the agent reads: a chat's conversation without tool results, or
-- a document's own text past its sync header; cut to the input cap.
function curate.source_text(db_path, doc)
    text = nil
    if doc.source_type == "chat_session" then
        text = transcript_conversation(db_path, tonumber(doc.id))
    end
    if text == nil then
        content = doc.content
        if content == nil then
            content = ""
        end
        text = string.sub(content, document.preamble_end(content))
    end
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    if string.len(text) > CURATE_INPUT_MAX_CHARS then
        text = string.sub(text, 1, CURATE_INPUT_MAX_CHARS) ..
            "\n\n[...source cut here, showing the first " .. tostring(CURATE_INPUT_MAX_CHARS) .. " characters...]"
    end
    return text
end

function curate_row(db_path, document_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM knowledge_curation WHERE document_id = %d;", tonumber(document_id)))
    if rows == nil then
        return nil
    end
    return rows[1]
end

function curate_record(db_path, document_id, source_hash, status, note_id, reason)
    db.exec(db_path, string.format("DELETE FROM knowledge_curation WHERE document_id = %d;", tonumber(document_id)))
    db.exec(db_path, string.format(
        "INSERT INTO knowledge_curation (document_id, source_hash, status, note_id, reason) VALUES (%d, %s, %s, %s, %s);",
        tonumber(document_id), db.quote(source_hash), db.quote(status), db.literal(note_id), db.literal(reason)))
end

function curate_source_hash(doc)
    content = doc.content
    if content == nil then
        content = ""
    end
    return document.content_hash(content)
end

-- Queues a source for curation unless this version of it is already
-- queued or done. Cheap: one read, at most one write. Returns true
-- when it queued.
function curate.queue(db_path, doc)
    if not curate.is_source(doc) then
        return false
    end
    hash = curate_source_hash(doc)
    row = curate_row(db_path, doc.id)
    if row != nil and row.source_hash == hash then
        return false
    end
    note_id = nil
    if row != nil then
        note_id = row.note_id
    end
    curate_record(db_path, doc.id, hash, "pending", note_id, nil)
    return true
end

function curate_note_title(text)
    title = string.match(text, "^#%s+([^\n]+)")
    if title == nil then
        return document.guess_title_from_body(text), text
    end
    title = string.gsub(title, "%s+$", "")
    body = string.gsub(text, "^#[^\n]*\n*", "")
    return title, body
end

function curate_source_line(db_path, doc)
    ref = document.link_ref(db_path, tonumber(doc.id))
    if ref == nil then
        ref = "document #" .. tostring(doc.id) .. " (" .. tostring(doc.title) .. ")"
    end
    return "Source: " .. ref
end

-- Curates one source now. Returns the status written: "curated",
-- "nothing" (the agent found nothing to keep), "rejected" (the check
-- failed), "failed" (a model call failed), or "skipped" (too short or
-- not a source), and the note id when one was written.
function curate.run(db_path, document_id, author)
    agent_provider = require("agent_provider")
    doc = knowledge.get_document(db_path, tonumber(document_id))
    if doc == nil or (doc.archived_at != nil and doc.archived_at != "") or not curate.is_source(doc) then
        return "skipped", nil
    end
    hash = curate_source_hash(doc)
    previous = curate_row(db_path, doc.id)
    note_id = nil
    if previous != nil and tonumber(previous.note_id) != nil then
        note_id = tonumber(previous.note_id)
    end
    text = curate.source_text(db_path, doc)
    if string.len(text) < CURATE_MIN_CHARS then
        curate_record(db_path, doc.id, hash, "nothing", note_id, "too little text")
        return "nothing", nil
    end

    draft, err = agent_provider.generate(nil, CURATE_SYSTEM_PROMPT, "Title: " .. tostring(doc.title) .. "\n\n" .. text)
    if draft == nil then
        curate_record(db_path, doc.id, hash, "failed", note_id, tostring(err))
        return "failed", nil
    end
    draft = string.gsub(draft, "^%s+", "")
    draft = string.gsub(draft, "%s+$", "")
    if draft == "" or draft == "NOTHING" then
        curate_record(db_path, doc.id, hash, "nothing", note_id, nil)
        return "nothing", nil
    end

    check_source = text
    if string.len(check_source) > CURATE_CHECK_SOURCE_MAX_CHARS then
        check_source = string.sub(check_source, 1, CURATE_CHECK_SOURCE_MAX_CHARS)
    end
    verdict, err = agent_provider.generate(nil, CURATE_CHECK_SYSTEM_PROMPT,
        "Note:\n" .. draft .. "\n\nSource:\n" .. check_source)
    if verdict == nil then
        curate_record(db_path, doc.id, hash, "failed", note_id, tostring(err))
        return "failed", nil
    end
    verdict = string.gsub(verdict, "^%s+", "")
    if string.sub(verdict, 1, 4) != "PASS" then
        reason = string.gsub(verdict, "^FAIL:?%s*", "")
        curate_record(db_path, doc.id, hash, "rejected", note_id, string.sub(reason, 1, 500))
        return "rejected", nil
    end

    title, body = curate_note_title(draft)
    body = body .. "\n\n" .. curate_source_line(db_path, doc)
    if note_id != nil and knowledge.get_document(db_path, note_id) != nil then
        ok, issues = document.update_page(db_path, author, note_id, title, nil, body, nil)
        if ok == nil then
            curate_record(db_path, doc.id, hash, "failed", note_id, "could not update the note")
            return "failed", nil
        end
        db.exec(db_path, string.format("UPDATE document SET content_hash = %s WHERE id = %d;",
            db.quote(document.content_hash(body)), note_id))
    else
        note_id, issues = knowledge.create_document_note(db_path, author, title, body, "curated", doc.id, nil)
        if note_id == nil then
            curate_record(db_path, doc.id, hash, "failed", nil, "could not create the note")
            return "failed", nil
        end
    end
    knowledge.set_tier(db_path, note_id, 1)
    curate_record(db_path, doc.id, hash, "curated", note_id, nil)
    return "curated", note_id
end

-- Runs up to `limit` queued sources, oldest first. Returns report lines.
function curate.run_pending(db_path, limit, author)
    if limit == nil then
        limit = 5
    end
    rows = db.query(db_path, string.format(
        "SELECT document_id FROM knowledge_curation WHERE status = 'pending' ORDER BY queued_at, document_id LIMIT %d;",
        tonumber(limit)))
    lines = {}
    if rows == nil then
        return lines
    end
    for _, row in ipairs(rows) do
        status, note_id = curate.run(db_path, tonumber(row.document_id), author)
        line = string.format("#%d %s", tonumber(row.document_id), status)
        if note_id != nil then
            line = line .. " -> note #" .. tostring(note_id)
        end
        table.insert(lines, line)
    end
    return lines
end

-- Sources already due by their use, most used first, that this version
-- of hasn't been curated or tried.
function curate.due_sources(db_path)
    rows = db.query(db_path, """
        SELECT d.id, d.title, d.content, d.source_type, d.retrieval_count FROM document d
        LEFT JOIN knowledge_curation c ON c.document_id = d.id
        WHERE (d.archived_at IS NULL OR d.archived_at = '')
          AND (d.merged_into IS NULL OR d.merged_into = '')
          AND (d.source_type IS NULL OR d.source_type = '' OR d.source_type = 'chat_session')
          AND d.retrieval_count >= 2
        ORDER BY d.retrieval_count DESC, d.id;""")
    due = {}
    if rows == nil then
        return due
    end
    for _, row in ipairs(rows) do
        if curate.is_source(row) then
            existing = curate_row(db_path, row.id)
            if existing == nil or existing.source_hash != curate_source_hash(row) then
                table.insert(due, row)
            end
        end
    end
    return due
end

-- `daat repair curate [--limit N] [--dry-run]`.
function curate.repair(db_path, limit, dry_run, author)
    lines = {}
    due = curate.due_sources(db_path)
    if limit == nil then
        limit = #due
    end
    for i, row in ipairs(due) do
        if i > limit then
            break
        end
        if dry_run then
            table.insert(lines, string.format("would curate #%d %s (retrieved %d times)",
                tonumber(row.id), tostring(row.title), tonumber(row.retrieval_count)))
        else
            curate.queue(db_path, row)
        end
    end
    if dry_run then
        table.insert(lines, string.format("%d source(s) due, %d would be curated", #due, math.min(limit, #due)))
        return lines
    end
    for _, line in ipairs(curate.run_pending(db_path, limit, author)) do
        table.insert(lines, line)
    end
    table.insert(lines, string.format("%d source(s) due, %d run", #due, math.min(limit, #due)))
    return lines
end

return curate
