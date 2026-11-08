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
--
-- A long source is also curated in parts (doc/aspect-retrieval-plan.md):
-- when searches keep finding it through one of its aspects -- a subject
-- past the start its own vector covers -- that aspect's passages are
-- curated into a note of their own, one row per aspect in
-- knowledge_aspect_curation. That is how the parts past
-- CURATE_INPUT_MAX_CHARS of a long source reach a note: one subject at a
-- time, through use.

db = require("database")
document = require("document")
knowledge = require("knowledge")

curate = {}

-- What the agent reads of a source; a paper past this is cut, with a
-- note saying so (its abstract, methods and results come first).
CURATE_INPUT_MAX_CHARS = 40000
-- Shorter than this has nothing to curate (a stub, a folder page).
CURATE_MIN_CHARS = 500

CURATE_SYSTEM_PROMPT = """
You curate a team's knowledge base. Rewrite the source below as a clean note in your own words for a colleague who hasn't read it: one line on what it is, then its key findings, methods or decisions, with the concrete numbers, conditions, materials and names that matter. Leave out boilerplate, file paths, headers, tool output, greetings and anything the source doesn't support. Never add a fact that isn't in the source.

Format: the first line is "# " and a title naming the subject specifically (not the file name). Then the note in Markdown, at most about 400 words, with short sections or bullets where they help.

If the source is a conversation between a user and an assistant, keep what it established -- conclusions, facts found, decisions -- not the back-and-forth.

If the source holds nothing worth keeping (small talk, a failed or empty exchange, text that didn't extract), reply with one line: "NOTHING: <the reason, in a few words>".
"""

-- Said after the deployment's own description of its work (theme.lua's
-- system_prompt_extra, the same text the chat agent gets). Found in
-- production 2026-10-28: the most-retrieved sources were a neuroscience
-- conference's proceedings and a mathematical software congress -- huge
-- documents a search matches on almost any query, not material the team
-- uses, and a faithful note about them would pass the check.
-- First version (2026-10-28) said "unrelated to this team's work"; the
-- model read that as the team's own lab data only and skipped a book on
-- cacao breeding. Published work in the field is what a team reads.
CURATE_RELEVANCE_RULE = """
Judge relevance by the team's field and subject matter, not only its own data: published papers, books, protocols and reviews on its subjects are worth curating. Only if the source's subject has nothing to do with the team's field, reply with one line: "NOTHING: <the reason, in a few words>".
"""

-- The curate prompt, with the deployment's description of its work when
-- it has one.
function curate.system_prompt()
    config = require("config")
    theme = config.load_theme(config.find_root())
    if theme.system_prompt_extra == nil or theme.system_prompt_extra == "" then
        return CURATE_SYSTEM_PROMPT
    end
    return CURATE_SYSTEM_PROMPT .. "\nAbout this team and its work:\n" .. theme.system_prompt_extra .. "\n" .. CURATE_RELEVANCE_RULE
end

CURATE_CHECK_SYSTEM_PROMPT = """
You check a curated note against the source it was written from. Reply PASS if every statement in the note is supported by the source, it adds nothing the source doesn't say, and it's clearly cleaner and more useful to a reader than the raw source. A long source may be cut, with a line saying so; the note was written from the part shown, so judge it against that part only. Otherwise reply FAIL: followed by one short reason. Reply with nothing else.
"""

-- Said after the curate prompt when the source shown is one part of a
-- long document (an aspect), not the whole of it.
CURATE_ASPECT_RULE = """
The source below is one part of a longer document: its passages about one subject, in document order, with "[...]" where text in between was left out. Write the note about this part only, titled by its own subject, not the whole document's.
"""

CURATE_ASPECT_CHECK_RULE = """
The source shown is one part of a longer document; judge the note against that part only.
"""

-- Document sources curate reads: synced files and pages (no
-- source_type). Not reasoning, connection notes, generated views, legacy
-- distilled facts, or anything the curation wrote itself. Not chat
-- transcripts either: a chat is curated from its conversation, by
-- session (below, "Curating a conversation"), not from its document.
CURATE_SOURCE_TYPES = {}

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
        text = document.transcript_conversation(db_path, tonumber(doc.id))
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
function curate.queue(db_path, doc, recheck)
    if not curate.is_source(doc) then
        return false
    end
    hash = curate_source_hash(doc)
    row = curate_row(db_path, doc.id)
    if row != nil and row.source_hash == hash and not (recheck == true and row.status != "curated" and row.status != "pending") then
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

-- Drafts a note from `text`, checks it against the same text, and
-- writes it (rewriting `note_id` in place when there is one). Returns
-- the status ("curated", "nothing", "rejected", "failed"), the note id,
-- and the reason when there is one.
function write_note(db_path, author, doc, text, system_prompt, check_prompt, note_id, source_line, source_ref)
    agent_provider = require("agent_provider")
    draft, err = agent_provider.generate(nil, system_prompt, "Title: " .. tostring(doc.title) .. "\n\n" .. text)
    if draft == nil then
        return "failed", note_id, tostring(err)
    end
    draft = string.gsub(draft, "^%s+", "")
    draft = string.gsub(draft, "%s+$", "")
    if draft == "" or string.sub(draft, 1, 7) == "NOTHING" then
        why = string.gsub(string.sub(draft, 8), "^:?%s*", "")
        if why == "" then
            why = nil
        end
        return "nothing", note_id, why
    end

    -- The check sees exactly what the writer saw, cut line included.
    -- Found in production 2026-10-28: cutting it again here dropped
    -- that line, and the check rejected a faithful note on a 200k
    -- character book for covering more than the "truncated" text.
    verdict, err = agent_provider.generate(nil, check_prompt, "Note:\n" .. draft .. "\n\nSource:\n" .. text)
    if verdict == nil then
        return "failed", note_id, tostring(err)
    end
    verdict = string.gsub(verdict, "^%s+", "")
    if string.sub(verdict, 1, 4) != "PASS" then
        reason = string.gsub(verdict, "^FAIL:?%s*", "")
        return "rejected", note_id, string.sub(reason, 1, 500)
    end

    title, body = curate_note_title(draft)
    body = body .. "\n\n" .. source_line
    if note_id != nil and knowledge.get_document(db_path, note_id) != nil then
        ok, issues = document.update_page(db_path, author, note_id, title, nil, body, nil)
        if ok == nil then
            return "failed", note_id, "could not update the note"
        end
        db.exec(db_path, string.format("UPDATE document SET content_hash = %s WHERE id = %d;",
            db.quote(document.content_hash(body)), note_id))
    else
        note_id, issues = knowledge.create_document_note(db_path, author, title, body, "curated", doc.id, source_ref)
        if note_id == nil then
            return "failed", nil, "could not create the note"
        end
    end
    knowledge.set_tier(db_path, note_id, 1)
    return "curated", note_id, nil
end

-- A live, curatable source, or nil.
function curate_source_doc(db_path, document_id)
    doc = knowledge.get_document(db_path, tonumber(document_id))
    if doc == nil or (doc.archived_at != nil and doc.archived_at != "") or not curate.is_source(doc) then
        return nil
    end
    return doc
end

-- Curates one source now. Returns the status written: "curated",
-- "nothing" (the agent found nothing to keep), "rejected" (the check
-- failed), "failed" (a model call failed), or "skipped" (too short or
-- not a source), and the note id when one was written.
function curate.run(db_path, document_id, author)
    doc = curate_source_doc(db_path, document_id)
    if doc == nil then
        db.exec(db_path, string.format("DELETE FROM knowledge_curation WHERE document_id = %d;", tonumber(document_id)))
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
    status, note_id, reason = write_note(db_path, author, doc, text, curate.system_prompt(), CURATE_CHECK_SYSTEM_PROMPT,
        note_id, curate_source_line(db_path, doc), nil)
    curate_record(db_path, doc.id, hash, status, note_id, reason)
    if status == "curated" then
        return status, note_id
    end
    return status, nil
end

--------------------------------------------------------------------------
-- Curating one aspect of a long source
--------------------------------------------------------------------------

-- What the agent reads of an aspect: its passages in document order,
-- each led by its heading, "[...]" where the document skips text
-- between them; cut to the input cap. Returns the text and where the
-- aspect's most central passage starts, or nil when the aspect is gone.
function curate.aspect_text(db_path, document_id, n)
    part = require("aspect").passages(db_path, document_id, n)
    if part == nil then
        return nil
    end
    pieces = {}
    previous_end = nil
    for _, p in ipairs(part.passages) do
        if previous_end != nil and p.offset > previous_end + 1 then
            table.insert(pieces, "[...]")
        end
        text = p.text
        if p.heading != nil and string.sub(text, 1, string.len(p.heading)) != p.heading then
            text = p.heading .. "\n" .. text
        end
        table.insert(pieces, (string.gsub(string.gsub(text, "^%s+", ""), "%s+$", "")))
        previous_end = p.offset + string.len(p.text) - 1
    end
    text = table.concat(pieces, "\n\n")
    if string.len(text) > CURATE_INPUT_MAX_CHARS then
        text = string.sub(text, 1, CURATE_INPUT_MAX_CHARS) ..
            "\n\n[...part cut here, showing the first " .. tostring(CURATE_INPUT_MAX_CHARS) .. " characters...]"
    end
    return text, part.passage_offset
end

function aspect_curate_row(db_path, document_id, n)
    rows = db.query(db_path, string.format(
        "SELECT * FROM knowledge_aspect_curation WHERE document_id = %d AND aspect = %d;", tonumber(document_id), tonumber(n)))
    if rows == nil then
        return nil
    end
    return rows[1]
end

function aspect_curate_record(db_path, document_id, n, source_hash, status, note_id, reason)
    db.exec(db_path, string.format("DELETE FROM knowledge_aspect_curation WHERE document_id = %d AND aspect = %d;",
        tonumber(document_id), tonumber(n)))
    db.exec(db_path, string.format(
        "INSERT INTO knowledge_aspect_curation (document_id, aspect, source_hash, status, note_id, reason) VALUES (%d, %d, %s, %s, %s, %s);",
        tonumber(document_id), tonumber(n), db.quote(source_hash), db.quote(status), db.literal(note_id), db.literal(reason)))
end

-- Queues aspect `n` of a source unless this version of that part is
-- already queued or done. Returns true when it queued.
function curate.queue_aspect(db_path, doc, n)
    if not curate.is_source(doc) then
        return false
    end
    text = curate.aspect_text(db_path, doc.id, n)
    if text == nil then
        return false
    end
    hash = document.content_hash(text)
    row = aspect_curate_row(db_path, doc.id, n)
    if row != nil and row.source_hash == hash then
        return false
    end
    note_id = nil
    if row != nil then
        note_id = row.note_id
    end
    aspect_curate_record(db_path, doc.id, n, hash, "pending", note_id, nil)
    return true
end

-- Curates aspect `n` of a source now; the same outcomes as curate.run.
-- An aspect gone since it was queued (the document changed and its
-- aspects were rebuilt) comes to "nothing", keeping any note it had.
function curate.run_aspect(db_path, document_id, n, author)
    doc = curate_source_doc(db_path, document_id)
    if doc == nil then
        db.exec(db_path, string.format("DELETE FROM knowledge_aspect_curation WHERE document_id = %d AND aspect = %d;",
            tonumber(document_id), tonumber(n)))
        return "skipped", nil
    end
    previous = aspect_curate_row(db_path, doc.id, n)
    note_id = nil
    hash = ""
    if previous != nil then
        note_id = tonumber(previous.note_id)
        hash = previous.source_hash
    end
    text, offset = curate.aspect_text(db_path, doc.id, n)
    if text == nil then
        aspect_curate_record(db_path, doc.id, n, hash, "nothing", note_id, "the aspect no longer exists")
        return "nothing", nil
    end
    hash = document.content_hash(text)
    if string.len(text) < CURATE_MIN_CHARS then
        aspect_curate_record(db_path, doc.id, n, hash, "nothing", note_id, "too little text")
        return "nothing", nil
    end
    source_line = curate_source_line(db_path, doc) .. ", the part at character " .. tostring(offset)
    status, note_id, reason = write_note(db_path, author, doc, text,
        curate.system_prompt() .. CURATE_ASPECT_RULE, CURATE_CHECK_SYSTEM_PROMPT .. CURATE_ASPECT_CHECK_RULE,
        note_id, source_line, "aspect " .. tostring(n))
    aspect_curate_record(db_path, doc.id, n, hash, status, note_id, reason)
    if status == "curated" then
        return status, note_id
    end
    return status, nil
end

function new_claim_token()
    urandom = io.open("/dev/urandom", "rb")
    if urandom == nil then
        return nil
    end
    raw = io.read(urandom, 8)
    io.close(urandom)
    return (string.gsub(raw, ".", function(c) return string.format("%02x", string.byte(c)) end))
end

-- Takes a queued source for this process: pending -> running, marked
-- with a token only this process knows, so two runners never curate
-- the same source. Found in production 2026-10-28: the jobs worker
-- (curate-pending every 2 minutes) took the same pending rows as a
-- `repair curate` batch and wrote a second note for one source. A row
-- left running by a process that died is retried by `--recheck`.
function curate_claim(db_path, document_id)
    token = new_claim_token()
    if token == nil then
        return false
    end
    db.exec(db_path, string.format(
        "UPDATE knowledge_curation SET status = 'running', reason = %s WHERE document_id = %d AND status = 'pending';",
        db.quote(token), document_id))
    row = curate_row(db_path, document_id)
    return row != nil and row.status == "running" and row.reason == token
end

-- curate_claim for one aspect's row.
function aspect_curate_claim(db_path, document_id, n)
    token = new_claim_token()
    if token == nil then
        return false
    end
    db.exec(db_path, string.format(
        "UPDATE knowledge_aspect_curation SET status = 'running', reason = %s WHERE document_id = %d AND aspect = %d AND status = 'pending';",
        db.quote(token), document_id, n))
    row = aspect_curate_row(db_path, document_id, n)
    return row != nil and row.status == "running" and row.reason == token
end

-- Queues the conversations that are due, then runs up to `limit`
-- queued sources, oldest first, then queued conversations and queued
-- aspects with what's left of the limit. Returns report lines.
function curate.run_pending(db_path, limit, author)
    if limit == nil then
        limit = 5
    end
    curate.queue_due_conversations(db_path)
    rows = db.query(db_path, string.format(
        "SELECT document_id FROM knowledge_curation WHERE status = 'pending' ORDER BY queued_at, document_id LIMIT %d;",
        tonumber(limit)))
    lines = {}
    if rows == nil then
        rows = {}
    end
    for _, row in ipairs(rows) do
        if curate_claim(db_path, tonumber(row.document_id)) then
            status, note_id = curate.run(db_path, tonumber(row.document_id), author)
            line = string.format("#%d %s", tonumber(row.document_id), status)
            if note_id != nil then
                line = line .. " -> note #" .. tostring(note_id)
            end
            table.insert(lines, line)
        end
    end
    left = tonumber(limit) - #rows
    if left <= 0 then
        return lines
    end
    conversation_rows = db.query(db_path, string.format(
        "SELECT session_id FROM knowledge_conversation_curation WHERE status = 'pending' ORDER BY queued_at, session_id LIMIT %d;",
        left))
    if conversation_rows == nil then
        conversation_rows = {}
    end
    for _, row in ipairs(conversation_rows) do
        if curate.claim_conversation(db_path, row.session_id) then
            status, note_id = curate.run_conversation(db_path, row.session_id, author)
            line = string.format("chat %s %s", tostring(row.session_id), status)
            if note_id != nil then
                line = line .. " -> note #" .. tostring(note_id)
            end
            table.insert(lines, line)
        end
    end
    left = left - #conversation_rows
    if left <= 0 then
        return lines
    end
    aspect_rows = db.query(db_path, string.format(
        "SELECT document_id, aspect FROM knowledge_aspect_curation WHERE status = 'pending' ORDER BY queued_at, document_id, aspect LIMIT %d;",
        left))
    if aspect_rows == nil then
        return lines
    end
    for _, row in ipairs(aspect_rows) do
        id = tonumber(row.document_id)
        n = tonumber(row.aspect)
        if aspect_curate_claim(db_path, id, n) then
            status, note_id = curate.run_aspect(db_path, id, n, author)
            line = string.format("#%d aspect %d %s", id, n, status)
            if note_id != nil then
                line = line .. " -> note #" .. tostring(note_id)
            end
            table.insert(lines, line)
        end
    end
    return lines
end

-- Sources already due by their use, most used first, that this version
-- of hasn't been curated or tried. With `recheck`, sources whose last
-- try came to nothing, was rejected or failed count as due again --
-- after the prompts change, say.
function curate.due_sources(db_path, recheck)
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
            retry = recheck == true and existing != nil and existing.status != "curated" and existing.status != "pending"
            if existing == nil or existing.source_hash != curate_source_hash(row) or retry then
                table.insert(due, row)
            end
        end
    end
    return due
end

-- `daat repair curate [--limit N] [--dry-run] [--recheck]`.
function curate.repair(db_path, limit, dry_run, author, recheck)
    lines = {}
    due = curate.due_sources(db_path, recheck)
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
            curate.queue(db_path, row, recheck)
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

--------------------------------------------------------------------------
-- Curating a conversation
--------------------------------------------------------------------------
--
-- doc/agent-data.md, "Curation": a chat is one curation source, read by
-- type -- what the person asked and decided (`request`), what the agent
-- concluded (`answer`) and how it got there (`reasoning`), from every
-- loop, a sub-agent's steps included. Tool traces are never read. The
-- note is the only thing of the chat in the pool; the conversation
-- itself stays on /chat for its owner.
--
-- A conversation is due once it has been quiet for
-- agent_curate_quiet_minutes and has changed since it was last
-- curated. One row per session in knowledge_conversation_curation, with
-- the statuses and the in-place rewrite of knowledge_curation.

CURATE_CONVERSATION_RULE = """
The source is a conversation between a member of the team and the assistant. "User" lines are what they asked, "Decision" lines what they approved or declined; state corrections and stated preferences as such. "Research" lines are the assistant's own sub-investigations. Write the note for the whole team: state what was established, decided and still open, and the caveats raised, not who asked or how the conversation went. Name the records and documents the answers relied on.
"""

-- The label each kind of row is shown with in the curation input.
function or_empty(rows)
    if rows == nil then
        return {}
    end
    return rows
end

function conversation_label(row)
    if row.role == "user" then
        return "User"
    elseif row.role == "decision" then
        return "Decision"
    elseif row.role == "compaction_summary" then
        return "Summary of earlier conversation"
    elseif row.role == "self_check" then
        return "Self-check"
    elseif row.parent_message_id != nil and row.parent_message_id != "" then
        if row.data_type == "answer" then
            return "Research finding"
        end
        return "Research step"
    end
    return "Assistant"
end

-- The conversation's entries, in order: {label, text, core}. `core`
-- entries (requests, answers) are kept whole first when the input is
-- too long; reasoning fills what's left. A session from before decision
-- rows were written gets its decided actions from agent_pending_action
-- instead, at the end (doc/approval-request-rows.md).
function conversation_entries(db_path, session_id)
    agent = require("agent")
    rows = db.query(db_path, string.format(
        "SELECT id, role, content, data_type, parent_message_id FROM agent_message WHERE session_id = %s " ..
        "AND data_type IN ('request', 'answer', 'reasoning') ORDER BY id;", db.quote(session_id)))
    entries = {}
    has_decisions = false
    for _, row in ipairs(or_empty(rows)) do
        if row.role == "decision" then
            has_decisions = true
        end
        text = agent.display_content(row.content, row.role, false)
        if text != nil then
            text = string.gsub(string.gsub(text, "^%s+", ""), "%s+$", "")
        end
        if text != nil and text != "" then
            table.insert(entries, {label = conversation_label(row), text = text, core = row.data_type != "reasoning"})
        end
    end
    if has_decisions == false then
        decided = db.query(db_path, string.format(
            "SELECT id, tool, method, args_json, status FROM agent_pending_action WHERE session_id = %s " ..
            "AND status IN ('approved', 'denied') ORDER BY id;", db.quote(session_id)))
        for _, p in ipairs(or_empty(decided)) do
            verb = "Approved"
            if p.status == "denied" then
                verb = "Denied"
            end
            args = tostring(p.args_json)
            if string.len(args) > 300 then
                args = string.sub(args, 1, 300) .. "..."
            end
            table.insert(entries, {label = "Decision", core = true,
                text = string.format("%s %s.%s (pending action #%d): %s", verb, tostring(p.tool), tostring(p.method), tonumber(p.id), args)})
        end
    end
    return entries
end

function render_entries(entries, keep)
    parts = {}
    skipped = false
    for i, e in ipairs(entries) do
        if keep == nil or keep[i] == true then
            if skipped then
                table.insert(parts, "[...]")
                skipped = false
            end
            table.insert(parts, e.label .. ": " .. e.text)
        else
            skipped = true
        end
    end
    if skipped then
        table.insert(parts, "[...]")
    end
    return table.concat(parts, "\n\n")
end

-- The whole conversation as curation reads it, uncut: a kept
-- transcript document (agent_transcript_documents = "whole").
function curate.conversation_full(db_path, session_id)
    return render_entries(conversation_entries(db_path, session_id), nil)
end

-- curate.conversation_text(db_path, session_id) -> text, hash
-- What the agent reads of a conversation, and the hash of all of it
-- (so a change anywhere makes it due again, even past the cap). Within
-- CURATE_INPUT_MAX_CHARS: requests and answers first, newest first,
-- then reasoning, newest first, shown in conversation order with "[...]"
-- where entries were left out.
function curate.conversation_text(db_path, session_id)
    entries = conversation_entries(db_path, session_id)
    full = render_entries(entries, nil)
    hash = document.content_hash(full)
    if string.len(full) <= CURATE_INPUT_MAX_CHARS then
        return full, hash
    end
    keep = {}
    budget = CURATE_INPUT_MAX_CHARS - 200
    for _, wanted in ipairs({true, false}) do
        for i = #entries, 1, -1 do
            e = entries[i]
            size = string.len(e.label) + string.len(e.text) + 9
            if e.core == wanted and size <= budget then
                keep[i] = true
                budget = budget - size
            end
        end
    end
    return render_entries(entries, keep) ..
        "\n\n[...conversation shortened to fit: the newest requests and answers are shown whole, earlier reasoning in part...]", hash
end

function conversation_row(db_path, session_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM knowledge_conversation_curation WHERE session_id = %s;", db.quote(session_id)))
    if rows == nil then
        return nil
    end
    return rows[1]
end

function conversation_record(db_path, session_id, source_hash, status, note_id, reason)
    db.exec(db_path, string.format("DELETE FROM knowledge_conversation_curation WHERE session_id = %s;", db.quote(session_id)))
    db.exec(db_path, string.format(
        "INSERT INTO knowledge_conversation_curation (session_id, source_hash, status, note_id, reason, checked_at) VALUES (%s, %s, %s, %s, %s, %s);",
        db.quote(session_id), db.quote(source_hash), db.quote(status), db.literal(tonumber(note_id)), db.literal(reason), db.now_expr(db_path)))
end

-- The note a chat already has from when it was curated as a transcript
-- document, if any, so the conversation's note rewrites it in place
-- (doc/chat-history-migration.md, decision 3).
function transcript_note_id(db_path, session_id)
    rows = db.query(db_path, string.format(
        "SELECT c.note_id FROM document d JOIN knowledge_curation c ON c.document_id = d.id " ..
        "WHERE d.source_type = 'chat_session' AND d.source_ref = %s AND c.note_id IS NOT NULL;", db.quote(session_id)))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return tonumber(rows[1].note_id)
end

-- Queues one conversation (keeping its note to rewrite in place).
function curate.queue_conversation(db_path, session_id, hash)
    row = conversation_row(db_path, session_id)
    note_id = nil
    if row != nil then
        note_id = tonumber(row.note_id)
    end
    if note_id == nil then
        note_id = transcript_note_id(db_path, session_id)
    end
    conversation_record(db_path, session_id, hash, "pending", note_id, nil)
end

-- curate.due_conversations(db_path, quiet_minutes) -> {{session_id, login, title, hash, chars}}
-- Sessions quiet for `quiet_minutes` that changed since they were last
-- checked, and whose conversation differs from what was last curated.
-- One that was touched but didn't change only has its checked_at moved.
-- Nothing queued or running is due.
function curate.due_conversations(db_path, quiet_minutes)
    if quiet_minutes == nil then
        quiet_minutes = require("config").platform_config().agent_curate_quiet_minutes
    end
    cutoff = os.date("!%Y-%m-%d %H:%M:%S", os.time() - math.floor(quiet_minutes * 60))
    rows = db.query(db_path, string.format(
        "SELECT s.id, s.login, s.title, c.source_hash, c.status FROM agent_session s " ..
        "LEFT JOIN knowledge_conversation_curation c ON c.session_id = s.id " ..
        "WHERE s.updated_at <= %s AND (c.session_id IS NULL OR c.checked_at IS NULL OR s.updated_at >= c.checked_at) " ..
        "AND (c.status IS NULL OR c.status NOT IN ('pending', 'running')) ORDER BY s.updated_at, s.id;", db.quote(cutoff)))
    due = {}
    for _, row in ipairs(or_empty(rows)) do
        text, hash = curate.conversation_text(db_path, row.id)
        if row.source_hash != nil and row.source_hash == hash then
            db.exec(db_path, string.format(
                "UPDATE knowledge_conversation_curation SET checked_at = %s WHERE session_id = %s;",
                db.now_expr(db_path), db.quote(row.id)))
        else
            table.insert(due, {session_id = row.id, login = row.login, title = row.title, hash = hash, chars = string.len(text)})
        end
    end
    return due
end

-- Queues every due conversation (the jobs worker, via run_pending).
-- Returns how many it queued.
function curate.queue_due_conversations(db_path)
    due = curate.due_conversations(db_path, nil)
    for _, d in ipairs(due) do
        curate.queue_conversation(db_path, d.session_id, d.hash)
    end
    return #due
end

-- curate_claim for one conversation's row.
function curate.claim_conversation(db_path, session_id)
    token = new_claim_token()
    if token == nil then
        return false
    end
    db.exec(db_path, string.format(
        "UPDATE knowledge_conversation_curation SET status = 'running', reason = %s WHERE session_id = %s AND status = 'pending';",
        db.quote(token), db.quote(session_id)))
    row = conversation_row(db_path, session_id)
    return row != nil and row.status == "running" and row.reason == token
end

-- Where a conversation's note points: the chat on /chat, which only its
-- owner (and admins) can open.
function conversation_source_line(session)
    title = session.title
    if title == nil or title == "" then
        title = "Untitled chat"
    end
    title = string.gsub(title, "[%[%]\n]", " ")
    return "Source: [Chat: " .. title .. "](chat?session_id=" .. tostring(session.id) .. ") (open to its owner)"
end

-- Curates one conversation now. Returns the status written (as
-- curate.run) and the note id when one was written.
function curate.run_conversation(db_path, session_id, author)
    sessions = db.query(db_path, string.format("SELECT * FROM agent_session WHERE id = %s;", db.quote(session_id)))
    if sessions == nil or sessions[1] == nil then
        db.exec(db_path, string.format("DELETE FROM knowledge_conversation_curation WHERE session_id = %s;", db.quote(session_id)))
        return "skipped", nil
    end
    session = sessions[1]
    text, hash = curate.conversation_text(db_path, session_id)
    previous = conversation_row(db_path, session_id)
    note_id = nil
    if previous != nil then
        note_id = tonumber(previous.note_id)
    end
    if note_id == nil then
        note_id = transcript_note_id(db_path, session_id)
    end
    if string.len(text) < CURATE_MIN_CHARS then
        conversation_record(db_path, session_id, hash, "nothing", note_id, "too little text")
        return "nothing", nil
    end
    title = session.title
    if title == nil or title == "" then
        title = "Untitled chat"
    end
    status, note_id, reason = write_note(db_path, author, {id = nil, title = "Chat: " .. title}, text,
        curate.system_prompt() .. "\n" .. CURATE_CONVERSATION_RULE, CURATE_CHECK_SYSTEM_PROMPT,
        note_id, conversation_source_line(session), session_id)
    conversation_record(db_path, session_id, hash, status, note_id, reason)
    if status == "curated" then
        return status, note_id
    end
    return status, nil
end

--------------------------------------------------------------------------
-- Moving old chats over (doc/chat-history-migration.md, steps 2 and 3)
--------------------------------------------------------------------------

-- `daat repair curate-chats [--limit N] [--dry-run] [--skip-login L]...`:
-- every conversation that is due, oldest first. A session of a skipped
-- login is marked `nothing` without a model call (decision 1: testing
-- chats aren't written up as team notes); the rest are curated, up to
-- `limit`. --dry-run lists what it would do and makes no model call (it
-- may move checked_at on unchanged chats, which changes no outcome).
function curate.repair_chats(db_path, limit, dry_run, skip_logins, author)
    skip = {}
    for _, login in ipairs(skip_logins) do
        skip[login] = true
    end
    due = curate.due_conversations(db_path, nil)
    lines = {}
    to_run = {}
    skipped = 0
    for _, d in ipairs(due) do
        title = d.title
        if title == nil or title == "" then
            title = "Untitled chat"
        end
        what = string.format("chat %s (%s, \"%s\", %d characters)", tostring(d.session_id), tostring(d.login), tostring(title), d.chars)
        if skip[d.login] == true then
            skipped = skipped + 1
            if dry_run then
                table.insert(lines, "would skip " .. what)
            else
                conversation_record(db_path, d.session_id, d.hash, "nothing", transcript_note_id(db_path, d.session_id),
                    "skipped: login " .. tostring(d.login))
                table.insert(lines, "skipped " .. what)
            end
        elseif limit == nil or #to_run < limit then
            table.insert(to_run, d)
            if dry_run then
                table.insert(lines, "would curate " .. what)
            end
        end
    end
    if dry_run == false then
        for _, d in ipairs(to_run) do
            curate.queue_conversation(db_path, d.session_id, d.hash)
            if curate.claim_conversation(db_path, d.session_id) then
                status, note_id = curate.run_conversation(db_path, d.session_id, author)
                line = string.format("chat %s %s", tostring(d.session_id), status)
                if note_id != nil then
                    line = line .. " -> note #" .. tostring(note_id)
                end
                table.insert(lines, line)
            end
        end
    end
    verb = "run"
    if dry_run then
        verb = "would be run"
    end
    table.insert(lines, string.format("%d chat(s) due: %d skipped by login, %d %s", #due, skipped, #to_run, verb))
    return lines
end

-- `daat repair retire-transcripts [--dry-run]`: archives each chat
-- transcript document whose conversation has its note, or came to
-- nothing; keeps the rest and says why. Refuses while the deployment
-- still keeps transcripts (agent_transcript_documents = "whole"): new
-- turns would keep writing them. Archived, never deleted: each line
-- "archived #N" is what --undo reads back.
function curate.retire_transcripts(db_path, dry_run, author)
    if require("config").platform_config().agent_transcript_documents == "whole" then
        return {"Transcript documents are still kept (agent_transcript_documents = \"whole\"); set it to \"off\" first."}
    end
    entity = require("entity")
    rows = db.query(db_path,
        "SELECT d.id, d.title, d.source_ref, c.status FROM document d " ..
        "LEFT JOIN knowledge_conversation_curation c ON c.session_id = d.source_ref " ..
        "WHERE d.source_type = 'chat_session' AND (d.archived_at IS NULL OR d.archived_at = '') ORDER BY d.id;")
    lines = {}
    retired = 0
    kept = 0
    for _, row in ipairs(or_empty(rows)) do
        status = row.status
        if status == nil or status == "" then
            status = "not curated"
        end
        what = string.format("#%d %s (chat %s: %s)", tonumber(row.id), tostring(row.title), tostring(row.source_ref), status)
        if status == "curated" or status == "nothing" then
            retired = retired + 1
            if dry_run then
                table.insert(lines, "would archive " .. what)
            else
                entity.archive(db_path, "document", tonumber(row.id), author, nil, "chat transcript retired: its conversation is curated")
                table.insert(lines, "archived " .. what)
            end
        else
            kept = kept + 1
            table.insert(lines, "kept " .. what)
        end
    end
    verb = "archived"
    if dry_run then
        verb = "would be archived"
    end
    table.insert(lines, string.format("%d transcript(s) %s, %d kept", retired, verb, kept))
    return lines
end

-- `daat repair retire-transcripts --undo <log>`: brings back the
-- transcripts a run archived, from its output ("archived #N" lines).
function curate.unretire_transcripts(db_path, log_path, author)
    entity = require("entity")
    file = io.open(log_path, "r")
    if file == nil then
        return {"Cannot read " .. tostring(log_path)}
    end
    lines = {}
    for line in io.lines(log_path) do
        id = string.match(line, "^archived #(%d+) ")
        if id != nil then
            entity.unarchive(db_path, "document", tonumber(id), author, nil)
            table.insert(lines, "restored #" .. id)
        end
    end
    io.close(file)
    table.insert(lines, string.format("%d transcript(s) restored", #lines))
    return lines
end

return curate
