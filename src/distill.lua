-- The distill step of the tier ladder (doc/tier-curation-ladder.md,
-- "Tier 3 design"): a tier-2 reference is read with the notes it cites
-- and split into records -- one claim each, self-contained, citing its
-- notes -- kept at tier 3 (source_type "record").
--
-- Each candidate claim is embedded and compared with the records and the
-- legacy distilled facts already in the pool. Anything at
-- DISTILL_NEAR_COSINE or closer goes to one judge call: SAME (the claim
-- is already there), UPDATE (the candidate is more complete or exact:
-- the record is rewritten in place) or NEW. A legacy fact matched SAME
-- or UPDATE is archived with merged_into the record that covers it, so
-- the legacy set shrinks as tier 3 grows (Ben, 2026-10-29). A last call
-- checks every record to be written against the notes it cites; a
-- record that fails is dropped and counted.
--
-- knowledge_distillation keeps one row per reference: the content hash
-- it last saw and how that went, like knowledge_curation. A reference is
-- distilled again once it's rewritten; dedup keeps that from repeating
-- records.

db = require("database")
entity = require("entity")
document = require("document")
knowledge = require("knowledge")
config = require("config")
json = require("dkjson")

distill = {}

-- Claims one reference yields at most.
DISTILL_MAX_CLAIMS = 12
-- Cosine at or above which a candidate and an existing record or legacy
-- fact are put to the judge (Ben, 2026-10-29: 0.80, measured on prod
-- before trusting it).
DISTILL_NEAR_COSINE = 0.80
-- Existing records shown to the judge per candidate.
DISTILL_JUDGE_MATCHES = 3

DISTILL_SYSTEM_PROMPT = """
You split a reference from a lab team's knowledge base into records: single claims a team member would look up on their own -- a result with its numbers and conditions, a condition that worked or failed, a protocol parameter, a definition.
Each record is self-contained: it names the organism, cell line, medium or method it is about, so it reads correctly without the reference. One to three sentences. Use only what the reference and its notes say, with numbers exactly as given.
At most 12 records, the most useful first. Skip background a reader wouldn't look up.
Reply with the records only, each in this form, separated by a blank line:
CLAIM: <the claim itself in at most 15 words -- a statement, not a topic>
TEXT: <one to three sentences>
NOTES: <the title of each note it rests on, exactly as given, separated by "; ">
If the reference holds no such claim, reply with one line: "NOTHING: <the reason, in a few words>".
"""

DISTILL_JUDGE_SYSTEM_PROMPT = """
You compare a new claim with existing records in a lab team's knowledge base.
Reply SAME <n> if record n already states this claim (the new one adds nothing that matters), UPDATE <n> if it states the same claim but the new one is more complete or more exact, or NEW if no record states this claim. Reply with that one line only.
"""

DISTILL_CHECK_SYSTEM_PROMPT = """
You check records against the notes they cite. For each numbered record, reply on its own line "<n>: PASS" if every statement in it is supported by the notes it cites, adds nothing they don't say, and reads correctly on its own; otherwise "<n>: FAIL: <one short reason>". Reply with those lines only.
"""

function distill_row(db_path, reference_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM knowledge_distillation WHERE reference_id = %d;", tonumber(reference_id)))
    if rows == nil then
        return nil
    end
    return rows[1]
end

function distill_record_status(db_path, reference_id, reference_hash, status, reason)
    db.exec(db_path, string.format("DELETE FROM knowledge_distillation WHERE reference_id = %d;", tonumber(reference_id)))
    db.exec(db_path, string.format(
        "INSERT INTO knowledge_distillation (reference_id, reference_hash, status, reason) VALUES (%d, %s, %s, %s);",
        tonumber(reference_id), db.quote(reference_hash), db.quote(status), db.literal(reason)))
end

-- Active references, most retrieved first, whose current text hasn't
-- been distilled. With `recheck`, references whose last try came to
-- nothing or failed (or was left running) count too.
function distill.due_references(db_path, recheck)
    rows = db.query(db_path, """
        SELECT id, title, content_hash, retrieval_count FROM document
        WHERE source_type = 'reference' AND (archived_at IS NULL OR archived_at = '')
        ORDER BY retrieval_count DESC, id;""")
    due = {}
    if rows == nil then
        return due
    end
    for _, r in ipairs(rows) do
        existing = distill_row(db_path, r.id)
        retry = recheck == true and existing != nil and existing.status != "distilled" and existing.status != "pending"
        if existing == nil or existing.reference_hash != tostring(r.content_hash) or retry then
            table.insert(due, r)
        end
    end
    return due
end

-- The curated notes a reference links to: {title -> row}.
function distill_notes(db_path, reference_id)
    rows = db.query(db_path, string.format("""
        SELECT DISTINCT d.id, d.title, d.content FROM document_link l
        JOIN document d ON d.id = l.to_document_id
        WHERE l.from_document_id = %d AND (l.archived_at IS NULL OR l.archived_at = '')
          AND d.source_type = 'curated' AND (d.archived_at IS NULL OR d.archived_at = '')
        ORDER BY d.id;""", tonumber(reference_id)))
    notes = {}
    if rows == nil then
        return notes, {}
    end
    for _, row in ipairs(rows) do
        notes[row.title] = row
    end
    return notes, rows
end

-- A note as the model reads it: without its "Source: [[...]]" line.
function distill_note_text(content)
    text = string.gsub(tostring(content), "\n*Source: [^\n]*%s*$", "")
    return text
end

-- The extract reply as candidates: {title, text, notes = {title...}}.
function distill.parse_claims(reply)
    claims = {}
    current = nil
    for line in string.gmatch(reply .. "\n", "([^\n]*)\n") do
        claim = string.match(line, "^%s*CLAIM:%s*(.-)%s*$")
        text = string.match(line, "^%s*TEXT:%s*(.-)%s*$")
        cited = string.match(line, "^%s*NOTES:%s*(.-)%s*$")
        if claim != nil then
            current = {title = claim, text = "", notes = {}}
            table.insert(claims, current)
        elseif text != nil and current != nil then
            current.text = text
        elseif cited != nil and current != nil then
            for title in string.gmatch(cited, "[^;]+") do
                title = string.gsub(title, "^%s*%[*", "")
                title = string.gsub(title, "%]*%s*$", "")
                if title != "" then
                    table.insert(current.notes, title)
                end
            end
        end
    end
    kept = {}
    for _, c in ipairs(claims) do
        if c.title != "" and c.text != "" and #kept < DISTILL_MAX_CLAIMS then
            table.insert(kept, c)
        end
    end
    return kept
end

function distill_dot(a, b)
    if a == nil or b == nil then
        return 0
    end
    sum = 0
    for i = 1, math.min(#a, #b) do
        sum = sum + a[i] * b[i]
    end
    return sum
end

function distill_unit(vector)
    if vector == nil then
        return nil
    end
    return document.unpack_vector(document.pack_vector(vector))
end

-- Records and legacy facts with a stored vector for `model`:
-- {id, title, content, source_type, unit}.
function distill_pool(db_path, model)
    rows = db.query(db_path, string.format("""
        SELECT d.id, d.title, d.content, d.source_type, e.vector_packed,
               CASE WHEN e.vector_packed IS NULL THEN e.vector_json END AS vector_json
        FROM document d JOIN document_embedding e ON e.document_id = d.id AND e.model = %s
        WHERE d.source_type IN ('record', 'distilled') AND (d.archived_at IS NULL OR d.archived_at = '')
          AND (d.merged_into IS NULL OR d.merged_into = '');""", db.quote(model)))
    pool = {}
    if rows == nil then
        return pool
    end
    for _, row in ipairs(rows) do
        unit = document.unpack_vector(row.vector_packed)
        if unit == nil and row.vector_json != nil then
            decoded, _, _ = json.decode(row.vector_json)
            unit = distill_unit(decoded)
        end
        if unit != nil then
            table.insert(pool, {id = tonumber(row.id), title = row.title, content = row.content,
                source_type = row.source_type, unit = unit})
        end
    end
    return pool
end

-- The pool entries at DISTILL_NEAR_COSINE or closer, nearest first.
function distill_near(pool, unit)
    near = {}
    for _, entry in ipairs(pool) do
        cosine = distill_dot(unit, entry.unit)
        if cosine >= DISTILL_NEAR_COSINE then
            table.insert(near, {entry = entry, cosine = cosine})
        end
    end
    table.sort(near, function(a, b) return a.cosine > b.cosine end)
    while #near > DISTILL_JUDGE_MATCHES do
        table.remove(near)
    end
    return near
end

-- "SAME 2" -> "same", entry; "NEW" -> "new", nil.
function distill_judge(candidate, near)
    agent_provider = require("agent_provider")
    lines = {"New claim: " .. candidate.title .. "\n" .. candidate.text, "", "Existing records:"}
    for i, m in ipairs(near) do
        body = string.gsub(distill_note_text(m.entry.content), "\n*Notes: [^\n]*%s*$", "")
        table.insert(lines, string.format("%d. %s\n%s", i, tostring(m.entry.title), body))
    end
    reply, err = agent_provider.generate(nil, DISTILL_JUDGE_SYSTEM_PROMPT, table.concat(lines, "\n"))
    if reply == nil then
        return nil, nil, err
    end
    verdict, n = string.match(reply, "^%s*(%u+)%s*(%d*)")
    if verdict == "SAME" or verdict == "UPDATE" then
        m = near[tonumber(n)]
        if m != nil then
            return string.lower(verdict), m.entry
        end
    end
    return "new", nil
end

function distill_body(db_path, candidate, notes)
    refs = {}
    for _, title in ipairs(candidate.notes) do
        note = notes[title]
        if note != nil then
            ref = document.link_ref(db_path, tonumber(note.id))
            if ref != nil then
                table.insert(refs, ref)
            end
        end
    end
    body = candidate.text
    if #refs > 0 then
        body = body .. "\n\nNotes: " .. table.concat(refs, " · ")
    end
    return body
end

-- Distills one reference now. Returns the status written ("distilled",
-- "nothing", "failed", "skipped") and counts {new, updated, same,
-- rejected, absorbed}.
function distill.run(db_path, reference_id, author)
    agent_provider = require("agent_provider")
    counts = {new = 0, updated = 0, same = 0, rejected = 0, absorbed = 0}
    ref = knowledge.get_document(db_path, tonumber(reference_id))
    if ref == nil or (ref.archived_at != nil and ref.archived_at != "") or ref.source_type != "reference" then
        db.exec(db_path, string.format("DELETE FROM knowledge_distillation WHERE reference_id = %d;", tonumber(reference_id)))
        return "skipped", counts
    end
    hash = tostring(ref.content_hash)
    notes, note_rows = distill_notes(db_path, ref.id)

    parts = {"Reference: " .. tostring(ref.title) .. "\n" .. tostring(ref.content)}
    for _, note in ipairs(note_rows) do
        table.insert(parts, "### Note: " .. tostring(note.title) .. "\n" .. distill_note_text(note.content))
    end
    input = table.concat(parts, "\n\n")
    reply, err = agent_provider.generate(nil, DISTILL_SYSTEM_PROMPT, input)
    if reply == nil then
        distill_record_status(db_path, ref.id, hash, "failed", tostring(err))
        return "failed", counts
    end
    reply = string.gsub(reply, "^%s+", "")
    if string.sub(reply, 1, 7) == "NOTHING" then
        why = string.gsub(string.sub(reply, 8), "^:?%s*", "")
        distill_record_status(db_path, ref.id, hash, "nothing", why)
        return "nothing", counts
    end
    candidates = distill.parse_claims(reply)
    if #candidates == 0 then
        distill_record_status(db_path, ref.id, hash, "failed", "no claim could be read from the reply")
        return "failed", counts
    end

    -- Dedup against the pool, and against this run's own candidates.
    model = agent_provider.embedding_model()
    pool = {}
    if model != nil then
        pool = distill_pool(db_path, model)
    end
    writes = {}
    for _, c in ipairs(candidates) do
        unit = nil
        if model != nil then
            vector, _ = agent_provider.embeddings(model, c.title .. "\n\n" .. c.text)
            unit = distill_unit(vector)
        end
        verdict, match = "new", nil
        near = {}
        if unit != nil then
            near = distill_near(pool, unit)
        end
        if #near > 0 then
            verdict, match, err = distill_judge(c, near)
            if verdict == nil then
                verdict, match = "new", nil
            end
        end
        if verdict == "same" and match != nil and match.source_type == "record" then
            counts.same = counts.same + 1
        else
            table.insert(writes, {candidate = c, verdict = verdict, match = match})
            if unit != nil then
                table.insert(pool, {id = -#writes, title = c.title, content = c.text, source_type = "candidate", unit = unit})
            end
        end
    end

    -- Check every record to be written against the notes it cites.
    if #writes > 0 then
        lines = {}
        for i, w in ipairs(writes) do
            table.insert(lines, string.format("%d. %s\n%s\nCites: %s", i, w.candidate.title, w.candidate.text,
                table.concat(w.candidate.notes, "; ")))
        end
        verdicts, err = agent_provider.generate(nil, DISTILL_CHECK_SYSTEM_PROMPT,
            "Records:\n" .. table.concat(lines, "\n\n") .. "\n\nNotes:\n" .. table.concat(parts, "\n\n", 2))
        if verdicts == nil then
            distill_record_status(db_path, ref.id, hash, "failed", tostring(err))
            return "failed", counts
        end
        passed = {}
        absorbed = {}
        for n, rest in string.gmatch(verdicts, "(%d+)%s*:%s*(%u+)") do
            if rest == "PASS" then
                passed[tonumber(n)] = true
            end
        end
        for i, w in ipairs(writes) do
            if passed[i] != true then
                counts.rejected = counts.rejected + 1
            else
                body = distill_body(db_path, w.candidate, notes)
                if w.verdict == "update" and w.match != nil and w.match.source_type == "record" then
                    ok, issues = document.update_page(db_path, author, w.match.id, w.candidate.title, nil, body, nil)
                    if ok != nil then
                        db.exec(db_path, string.format("UPDATE document SET content_hash = %s WHERE id = %d;",
                            db.quote(document.content_hash(body)), w.match.id))
                        counts.updated = counts.updated + 1
                    end
                elseif w.match == nil or w.match.source_type != "candidate" or w.verdict == "new" then
                    record_id = knowledge.create_document_note(db_path, author, w.candidate.title, body, "record", nil,
                        "reference:" .. tostring(ref.id))
                    if record_id != nil then
                        knowledge.set_tier(db_path, record_id, 3)
                        counts.new = counts.new + 1
                        -- A legacy fact this record covers is absorbed.
                        -- Once: a second candidate matching the same
                        -- fact (prod 2026-10-29) leaves it where the
                        -- first put it.
                        if w.match != nil and w.match.source_type == "distilled" and absorbed[w.match.id] != true then
                            absorbed[w.match.id] = true
                            archived_id = entity.archive(db_path, "document", w.match.id, author, nil, "covered by record #" .. tostring(record_id))
                            if archived_id != nil then
                                document.on_entity_archived(db_path, "document", archived_id)
                                db.exec(db_path, string.format("UPDATE document SET merged_into = %d WHERE id = %d;", record_id, w.match.id))
                                counts.absorbed = counts.absorbed + 1
                            end
                        end
                    end
                else
                    counts.same = counts.same + 1
                end
            end
        end
    end
    distill_record_status(db_path, ref.id, hash, "distilled", string.format(
        "%d new, %d updated, %d already there, %d rejected, %d legacy absorbed",
        counts.new, counts.updated, counts.same, counts.rejected, counts.absorbed))
    return "distilled", counts
end

-- Takes a queued reference for this process (as curate_claim).
function distill_claim(db_path, reference_id)
    urandom = io.open("/dev/urandom", "rb")
    if urandom == nil then
        return false
    end
    raw = io.read(urandom, 8)
    io.close(urandom)
    token = string.gsub(raw, ".", function(c) return string.format("%02x", string.byte(c)) end)
    db.exec(db_path, string.format(
        "UPDATE knowledge_distillation SET status = 'running', reason = %s WHERE reference_id = %d AND status = 'pending';",
        db.quote(token), tonumber(reference_id)))
    row = distill_row(db_path, reference_id)
    return row != nil and row.status == "running" and row.reason == token
end

-- `daat repair distill [--limit N] [--dry-run] [--recheck]`, and the
-- jobs worker's `daat knowledge distill-due [N]`.
function distill.repair(db_path, limit, dry_run, author, recheck)
    lines = {}
    due = distill.due_references(db_path, recheck)
    if limit == nil then
        limit = #due
    end
    queued = {}
    for i, r in ipairs(due) do
        if i > limit then
            break
        end
        if dry_run then
            table.insert(lines, string.format("would distill reference #%d %s", tonumber(r.id), tostring(r.title)))
        else
            existing = distill_row(db_path, r.id)
            if existing == nil or existing.status != "running" or recheck == true then
                distill_record_status(db_path, r.id, tostring(r.content_hash), "pending", nil)
                table.insert(queued, tonumber(r.id))
            end
        end
    end
    if dry_run then
        table.insert(lines, string.format("%d reference(s) due, %d would be distilled", #due, math.min(limit, #due)))
        return lines
    end
    for _, id in ipairs(queued) do
        if distill_claim(db_path, id) then
            status, counts = distill.run(db_path, id, author)
            line = string.format("reference #%d %s", id, status)
            if status == "distilled" then
                line = line .. string.format(": %d new, %d updated, %d already there, %d rejected, %d legacy absorbed",
                    counts.new, counts.updated, counts.same, counts.rejected, counts.absorbed)
            end
            table.insert(lines, line)
        end
    end
    table.insert(lines, string.format("%d reference(s) due, %d run", #due, math.min(limit, #due)))
    return lines
end

return distill
