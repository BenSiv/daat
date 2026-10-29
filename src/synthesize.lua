-- The synthesize step of the tier ladder (doc/tier-curation-ladder.md,
-- phase 3): the tier-1 notes one tag holds are written up by the agent
-- as one structured reference on that subject, checked against those
-- notes by a second call, and kept as a tier-2 document (source_type
-- "reference") that links to every note it was made from.
--
-- A tag is due once it holds SYNTHESIZE_MIN_NOTES curated notes and has
-- no reference yet, or its notes changed since the reference was
-- written; the reference is then rewritten in place, never duplicated.
-- `daat repair synthesize` queues the due tags and runs them; a tag
-- whose notes don't make one subject, or whose subject is outside the
-- team's field, comes to "nothing" with the reason recorded -- a signal
-- for tag upkeep, not an error.
--
-- knowledge_reference keeps one row per tag: the hash of the notes it
-- last saw and how that went (pending, running, referenced, nothing,
-- rejected, failed), like knowledge_curation for the curate step.

db = require("database")
document = require("document")
knowledge = require("knowledge")
config = require("config")

synthesize = {}

-- Notes a tag needs before it gets a reference.
SYNTHESIZE_MIN_NOTES = 3
-- Notes one reference is written from, the tag's most central first.
SYNTHESIZE_MAX_NOTES = 12

SYNTHESIZE_SYSTEM_PROMPT = """
You write a reference for a lab team's knowledge base: one structured document on one subject, made from curated notes that share a tag.
Start with one line "# <title>" naming the subject. Then a short overview, then sections ("## ...") by theme, not one section per note.
Merge what the notes say about the same thing. State numbers, conditions and results exactly as the notes give them. Where notes disagree, say so and cite both.
After every statement, cite the note it comes from as [[Note title]], with the title exactly as given. Say nothing the notes don't say.
At most 900 words.
If the notes don't share one subject, reply with one line: "NOTHING: <the reason, in a few words>".
"""

SYNTHESIZE_RELEVANCE_RULE = """
Judge relevance by the team's field and subject matter: published papers, books, protocols and reviews on its subjects count. Only if the notes' shared subject has nothing to do with the team's field, reply with one line: "NOTHING: <the reason, in a few words>".
"""

SYNTHESIZE_CHECK_SYSTEM_PROMPT = """
You check a reference against the notes it was written from. Reply PASS if every statement in it is supported by the note it cites, it adds nothing the notes don't say, and it doesn't drop any note's main point without saying so. Otherwise reply FAIL: followed by one short reason. Reply with nothing else.
"""

function synthesize.system_prompt()
    theme = config.load_theme(config.find_root())
    if theme.system_prompt_extra == nil or theme.system_prompt_extra == "" then
        return SYNTHESIZE_SYSTEM_PROMPT
    end
    return SYNTHESIZE_SYSTEM_PROMPT .. "\nAbout this team and its work:\n" .. theme.system_prompt_extra .. "\n" .. SYNTHESIZE_RELEVANCE_RULE
end

function synthesize_row(db_path, tag_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM knowledge_reference WHERE tag_id = %d;", tonumber(tag_id)))
    if rows == nil then
        return nil
    end
    return rows[1]
end

function synthesize_record(db_path, tag_id, notes_hash, status, document_id, reason)
    db.exec(db_path, string.format("DELETE FROM knowledge_reference WHERE tag_id = %d;", tonumber(tag_id)))
    db.exec(db_path, string.format(
        "INSERT INTO knowledge_reference (tag_id, notes_hash, status, document_id, reason) VALUES (%d, %s, %s, %s, %s);",
        tonumber(tag_id), db.quote(notes_hash), db.quote(status), db.literal(document_id), db.literal(reason)))
end

-- A tag's active curated notes, most central first.
function synthesize.notes(db_path, tag_id)
    rows = db.query(db_path, string.format("""
        SELECT d.id, d.title, d.content, d.content_hash FROM document_tag dt
        JOIN document d ON d.id = dt.document
        WHERE dt.tag = %d AND (dt.archived_at IS NULL OR dt.archived_at = '') AND dt.decision != 'excluded'
          AND d.source_type = 'curated' AND (d.archived_at IS NULL OR d.archived_at = '')
        ORDER BY dt.score DESC, d.id;""", tonumber(tag_id)))
    if rows == nil then
        return {}
    end
    return rows
end

-- What a reference is made from, as one hash: the notes it would read.
function synthesize_notes_hash(notes)
    parts = {}
    for i, note in ipairs(notes) do
        if i > SYNTHESIZE_MAX_NOTES then
            break
        end
        table.insert(parts, tostring(note.id) .. ":" .. tostring(note.content_hash))
    end
    return document.content_hash(table.concat(parts, ","))
end

-- Active tags with enough notes, most notes first, whose notes this
-- reference hasn't seen. With `recheck`, tags whose last try came to
-- nothing, was rejected or failed (or was left running) count too.
function synthesize.due_tags(db_path, recheck)
    rows = db.query(db_path, string.format("""
        SELECT t.id, t.label, t.description, COUNT(DISTINCT d.id) AS notes FROM tag t
        JOIN document_tag dt ON dt.tag = t.id AND (dt.archived_at IS NULL OR dt.archived_at = '') AND dt.decision != 'excluded'
        JOIN document d ON d.id = dt.document AND d.source_type = 'curated' AND (d.archived_at IS NULL OR d.archived_at = '')
        WHERE (t.archived_at IS NULL OR t.archived_at = '')
        GROUP BY t.id, t.label, t.description
        HAVING COUNT(DISTINCT d.id) >= %d
        ORDER BY notes DESC, t.id;""", SYNTHESIZE_MIN_NOTES))
    due = {}
    if rows == nil then
        return due
    end
    for _, t in ipairs(rows) do
        existing = synthesize_row(db_path, t.id)
        hash = synthesize_notes_hash(synthesize.notes(db_path, t.id))
        retry = recheck == true and existing != nil and existing.status != "referenced" and existing.status != "pending"
        if existing == nil or existing.notes_hash != hash or retry then
            table.insert(due, t)
        end
    end
    return due
end

-- Takes a queued tag for this process: pending -> running, marked with a
-- token only this process knows, so two runners never write the same
-- reference (as curate_claim, src/curate.lua).
function synthesize_claim(db_path, tag_id)
    urandom = io.open("/dev/urandom", "rb")
    if urandom == nil then
        return false
    end
    raw = io.read(urandom, 8)
    io.close(urandom)
    token = string.gsub(raw, ".", function(c) return string.format("%02x", string.byte(c)) end)
    db.exec(db_path, string.format(
        "UPDATE knowledge_reference SET status = 'running', reason = %s WHERE tag_id = %d AND status = 'pending';",
        db.quote(token), tonumber(tag_id)))
    row = synthesize_row(db_path, tag_id)
    return row != nil and row.status == "running" and row.reason == token
end

function synthesize_title(text)
    title = string.match(text, "^#%s+([^\n]+)")
    if title == nil then
        return document.guess_title_from_body(text), text
    end
    title = string.gsub(title, "%s+$", "")
    body = string.gsub(text, "^#[^\n]*\n*", "")
    return title, body
end

-- Writes one tag's reference now. Returns the status written:
-- "referenced", "nothing", "rejected", "failed" or "skipped" (the tag is
-- gone or has too few notes), and the reference's id when one was written.
function synthesize.run(db_path, tag_id, author)
    agent_provider = require("agent_provider")
    tags = db.query(db_path, string.format(
        "SELECT id, label, description FROM tag WHERE id = %d AND (archived_at IS NULL OR archived_at = '');", tonumber(tag_id)))
    notes = synthesize.notes(db_path, tag_id)
    if tags == nil or tags[1] == nil or #notes < SYNTHESIZE_MIN_NOTES then
        db.exec(db_path, string.format("DELETE FROM knowledge_reference WHERE tag_id = %d;", tonumber(tag_id)))
        return "skipped", nil
    end
    t = tags[1]
    hash = synthesize_notes_hash(notes)
    previous = synthesize_row(db_path, tag_id)
    reference_id = nil
    if previous != nil then
        reference_id = tonumber(previous.document_id)
    end

    parts = {"Tag: " .. tostring(t.label)}
    if t.description != nil and t.description != "" then
        table.insert(parts, "Tag description: " .. tostring(t.description))
    end
    used = {}
    for i, note in ipairs(notes) do
        if i > SYNTHESIZE_MAX_NOTES then
            break
        end
        table.insert(used, note)
        table.insert(parts, "### Note: " .. tostring(note.title) .. "\n" .. tostring(note.content))
    end
    input = table.concat(parts, "\n\n")

    draft, err = agent_provider.generate(nil, synthesize.system_prompt(), input)
    if draft == nil then
        synthesize_record(db_path, tag_id, hash, "failed", reference_id, tostring(err))
        return "failed", nil
    end
    draft = string.gsub(draft, "^%s+", "")
    draft = string.gsub(draft, "%s+$", "")
    if draft == "" or string.sub(draft, 1, 7) == "NOTHING" then
        why = string.gsub(string.sub(draft, 8), "^:?%s*", "")
        if why == "" then
            why = nil
        end
        synthesize_record(db_path, tag_id, hash, "nothing", reference_id, why)
        return "nothing", nil
    end

    verdict, err = agent_provider.generate(nil, SYNTHESIZE_CHECK_SYSTEM_PROMPT,
        "Reference:\n" .. draft .. "\n\nNotes:\n" .. input)
    if verdict == nil then
        synthesize_record(db_path, tag_id, hash, "failed", reference_id, tostring(err))
        return "failed", nil
    end
    verdict = string.gsub(verdict, "^%s+", "")
    if string.sub(verdict, 1, 4) != "PASS" then
        reason = string.gsub(verdict, "^FAIL:?%s*", "")
        synthesize_record(db_path, tag_id, hash, "rejected", reference_id, string.sub(reason, 1, 500))
        return "rejected", nil
    end

    -- Every note it was made from is linked, cited or not.
    refs = {}
    for _, note in ipairs(used) do
        ref = document.link_ref(db_path, tonumber(note.id))
        if ref != nil then
            table.insert(refs, ref)
        end
    end
    title, body = synthesize_title(draft)
    body = body .. "\n\nNotes: " .. table.concat(refs, " · ")
    if reference_id != nil and knowledge.get_document(db_path, reference_id) != nil then
        ok, issues = document.update_page(db_path, author, reference_id, title, nil, body, nil)
        if ok == nil then
            synthesize_record(db_path, tag_id, hash, "failed", reference_id, "could not update the reference")
            return "failed", nil
        end
        db.exec(db_path, string.format("UPDATE document SET content_hash = %s WHERE id = %d;",
            db.quote(document.content_hash(body)), reference_id))
    else
        reference_id, issues = knowledge.create_document_note(db_path, author, title, body, "reference", nil, "tag:" .. tostring(tag_id))
        if reference_id == nil then
            synthesize_record(db_path, tag_id, hash, "failed", nil, "could not create the reference")
            return "failed", nil
        end
    end
    knowledge.set_tier(db_path, reference_id, 2)
    synthesize_record(db_path, tag_id, hash, "referenced", reference_id, nil)
    return "referenced", reference_id
end

-- Runs up to `limit` queued tags, oldest first. Returns report lines.
function synthesize.run_pending(db_path, limit, author)
    if limit == nil then
        limit = 3
    end
    rows = db.query(db_path, string.format(
        "SELECT tag_id FROM knowledge_reference WHERE status = 'pending' ORDER BY queued_at, tag_id LIMIT %d;",
        tonumber(limit)))
    lines = {}
    if rows == nil then
        return lines
    end
    for _, row in ipairs(rows) do
        if synthesize_claim(db_path, tonumber(row.tag_id)) then
            status, reference_id = synthesize.run(db_path, tonumber(row.tag_id), author)
            line = string.format("tag #%d %s", tonumber(row.tag_id), status)
            if reference_id != nil then
                line = line .. " -> reference #" .. tostring(reference_id)
            end
            table.insert(lines, line)
        end
    end
    return lines
end

-- `daat repair synthesize [--limit N] [--dry-run] [--recheck]`.
function synthesize.repair(db_path, limit, dry_run, author, recheck)
    lines = {}
    due = synthesize.due_tags(db_path, recheck)
    if limit == nil then
        limit = #due
    end
    for i, t in ipairs(due) do
        if i > limit then
            break
        end
        if dry_run then
            table.insert(lines, string.format("would write a reference for tag #%d %s (%d notes)",
                tonumber(t.id), tostring(t.label), tonumber(t.notes)))
        else
            existing = synthesize_row(db_path, t.id)
            reference_id = nil
            if existing != nil then
                reference_id = tonumber(existing.document_id)
            end
            if existing == nil or existing.status != "running" or recheck == true then
                synthesize_record(db_path, t.id, synthesize_notes_hash(synthesize.notes(db_path, t.id)), "pending", reference_id, nil)
            end
        end
    end
    if dry_run then
        table.insert(lines, string.format("%d tag(s) due, %d would get a reference", #due, math.min(limit, #due)))
        return lines
    end
    for _, line in ipairs(synthesize.run_pending(db_path, limit, author)) do
        table.insert(lines, line)
    end
    table.insert(lines, string.format("%d tag(s) due, %d run", #due, math.min(limit, #due)))
    return lines
end

return synthesize
