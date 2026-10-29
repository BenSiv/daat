-- The knowledge pool: retrieval activity logging, tiering, and
-- rule-based review (see doc/architecture.md's "Knowledge pool" section
-- for the full design, including what this was adapted from and
-- deliberately dropped).
--
-- Tier/heat/retrieval_count/source_*/content_hash/duplicate_of/
-- merged_into are columns directly on `document` itself (see
-- document.lua's ensure_document_knowledge_columns) -- one unified
-- pool, not two concepts mirroring each other's content. A document
-- that gets searched IS the record that accrues heat/tier; there's no
-- separate "note" created to shadow it. The only thing still created
-- fresh here is a genuinely new document (e.g. a chat's leaked
-- reasoning text, or a distilled note) that has no existing document to
-- attach to -- those land under document.ensure_knowledge_pool_folder,
-- visible and browsable like any other document folder, never hidden.
--
-- The pure tier/heat/dedup heuristics (content_hash, effective_heat,
-- promotion_target_tier, content_shape, was_revised, title_is_generic,
-- ...) live in document.lua now, alongside the columns they score --
-- this file depends on document.lua, never the reverse.
--
-- Retrieval/review bookkeeping (knowledge_retrieval, and one
-- knowledge_retrieval_hit per document it returned, which also carries
-- that hit's review) stays in its own hand-rolled tables here -- these
-- are event logs, not pool content, so they don't belong on `document`.

db = require("database")
document = require("document")
entity = require("entity")
config = require("config")

knowledge = {}

KNOWLEDGE_SCHEMA = """
CREATE TABLE IF NOT EXISTS knowledge_retrieval (
    id INTEGER PRIMARY KEY %s,
    session_id TEXT,
    query_text TEXT,
    hit_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT DEFAULT (%s)
);

-- `rank` (backtick-quoted, not a bare identifier): a genuine reserved
-- word in MySQL 8.0 (window functions), though not in MariaDB (see
-- doc/mariadb-migration.md). Backtick quoting is valid MySQL/MariaDB
-- syntax and SQLite's own MySQL-compatibility extension, so this is a
-- single, unified fix needing no per-backend branch.
-- One row per document a retrieval returned: its rank and score, the
-- heat reinforcement it got, and -- once knowledge.review_retrieval has
-- looked at it -- the rule-based review outcome (reviewed_at set).
CREATE TABLE IF NOT EXISTS knowledge_retrieval_hit (
    retrieval_id INTEGER NOT NULL,
    document_id INTEGER NOT NULL,
    `rank` INTEGER,
    score REAL,
    tier_weight REAL,
    reinforcement_delta REAL,
    atomicity_status VARCHAR(32),
    connectivity_status VARCHAR(32),
    duplication_status VARCHAR(32),
    title_status VARCHAR(32),
    reviewed_at TEXT,
    PRIMARY KEY (retrieval_id, document_id)
);

-- One row per *pair* of documents whose co-retrieval has been evaluated
-- (linked or declined) -- document_a_id is always the smaller id, so
-- (a,b) and (b,a) are always the same row. What makes "don't re-ask on
-- every shared retrieval" and "re-ask once co-occurrence has grown
-- enough since a decline" both possible without re-running the same
-- model call over and over.
CREATE TABLE IF NOT EXISTS knowledge_link_review (
    document_a_id INTEGER NOT NULL,
    document_b_id INTEGER NOT NULL,
    last_co_count INTEGER NOT NULL,
    -- VARCHAR(32), not TEXT -- same MariaDB/InnoDB key-length reasoning
    -- as every other short-code column in this codebase (ledger.lua's
    -- own SCHEMA comment has the full story) -- not itself part of this
    -- table's key, but kept consistent with that convention regardless.
    decision VARCHAR(32) NOT NULL,
    evaluated_at TEXT DEFAULT (%s),
    PRIMARY KEY (document_a_id, document_b_id)
);

-- One row per document that's had its tier judged by the agent at
-- least once -- lets due_for_tier_judgment skip re-asking the model
-- when nothing has changed since the last judgment, the same
-- "don't re-run the same model call over and over" reasoning as
-- knowledge_link_review's own last_co_count column.
CREATE TABLE IF NOT EXISTS document_tier_judgment (
    document_id INTEGER PRIMARY KEY,
    judged_hash TEXT NOT NULL,
    judged_tier INTEGER NOT NULL,
    evaluated_at TEXT DEFAULT (%s)
);

-- The curate step's queue and outcomes, one row per source (src/curate.lua,
-- doc/tier-curation-ladder.md): the content hash it last saw, and how
-- that went -- pending, curated (note_id is the tier-1 note), nothing,
-- rejected (reason from the check), failed.
CREATE TABLE IF NOT EXISTS knowledge_curation (
    document_id INTEGER PRIMARY KEY,
    source_hash VARCHAR(64) NOT NULL,
    status VARCHAR(32) NOT NULL,
    note_id INTEGER,
    reason TEXT,
    queued_at TEXT DEFAULT (%s)
);

-- The synthesize step's queue and outcomes, one row per tag
-- (src/synthesize.lua): the hash of the notes it last saw, and how that
-- went -- pending, running, referenced (document_id is the tier-2
-- reference), nothing, rejected, failed.
CREATE TABLE IF NOT EXISTS knowledge_reference (
    tag_id INTEGER PRIMARY KEY,
    notes_hash VARCHAR(64) NOT NULL,
    status VARCHAR(32) NOT NULL,
    document_id INTEGER,
    reason TEXT,
    queued_at TEXT DEFAULT (%s)
);

"""

function knowledge_schema_sql(db_path)
    return string.format(KNOWLEDGE_SCHEMA,
        db.autoincrement_keyword(db_path), db.now_expr(db_path),
        db.now_expr(db_path),
        db.now_expr(db_path),
        db.now_expr(db_path),
        db.now_expr(db_path)
    )
end

-- Real MySQL has no "CREATE INDEX IF NOT EXISTS" at all (a syntax error,
-- not a no-op, unlike MariaDB -- see doc/mariadb-migration.md). Pulled
-- out of KNOWLEDGE_SCHEMA's own semicolon batch into their own guarded
-- execs (db.index_exists first, same "check, then conditionally create"
-- shape schema.lua's own CREATE INDEX call sites use) since a single bad
-- statement fails the whole batch on MySQL, not just that one statement.
function ensure_knowledge_indexes(db_path)
    indexes = {
        {name = "knowledge_retrieval_document_document_idx", table = "knowledge_retrieval_hit",
         sql = "CREATE INDEX knowledge_retrieval_document_document_idx ON knowledge_retrieval_hit(document_id);"},
    }
    for _, idx in ipairs(indexes) do
        if db.index_exists(db_path, idx.table, idx.name) == false then
            db.exec(db_path, idx.sql)
        end
    end
end

-- The model's one-sentence reason behind a link review's decision --
-- for "linked" it's also written as the new link's own note
-- (document_link.note); for "declined" this is the only place it's
-- kept, so a NO can be audited later instead of being a bare verdict.
function ensure_link_review_reason_column(db_path)
    existing = db.get_columns(db_path, "knowledge_link_review")
    have = {}
    for _, name in ipairs(existing) do
        have[name] = true
    end
    if have["reason"] == nil then
        db.exec(db_path, "ALTER TABLE knowledge_link_review ADD COLUMN reason TEXT DEFAULT NULL;")
    end
end

function knowledge.init_schema(db_path)
    db.exec(db_path, knowledge_schema_sql(db_path))
    ensure_knowledge_indexes(db_path)
    ensure_link_review_reason_column(db_path)
end

-- Same treatment as document.lua's KNOWLEDGE_POOL_SQL_COLUMNS: these are
-- hand-rolled event-log tables, not schema.register()'d, so
-- entity.fields would otherwise fall through to "unknown entity type"
-- for any of them -- a console request like "average messages per chat
-- session" hits the identical invented-table-name risk, just against
-- these instead of document.
HAND_ROLLED_TABLE_COLUMNS = {
    knowledge_retrieval = {
        {name = "id", note = "primary key"},
        {name = "session_id", note = "agent_session.id this retrieval happened within"},
        {name = "query_text", note = "the search query text"},
        {name = "hit_count", note = "number of documents this retrieval matched"},
        {name = "created_at", note = "timestamp of the retrieval event"},
    },
    knowledge_retrieval_hit = {
        {name = "retrieval_id", note = "FK to knowledge_retrieval.id"},
        {name = "document_id", note = "FK to document.id"},
        {name = "rank", note = "position of this document in the retrieval's results (backtick-quoted in SQL -- a reserved word in MySQL 8.0)"},
        {name = "score", note = "raw retrieval score for this hit"},
        {name = "tier_weight", note = "weight applied for the document's tier at retrieval time"},
        {name = "reinforcement_delta", note = "heat/tier reinforcement this hit produced"},
        {name = "atomicity_status", note = "rule-based review outcome: is this document one coherent idea"},
        {name = "connectivity_status", note = "rule-based review outcome: is this document linked to related documents"},
        {name = "duplication_status", note = "rule-based review outcome: does this document duplicate another"},
        {name = "title_status", note = "rule-based review outcome: is the title specific, not generic"},
        {name = "reviewed_at", note = "when the hit was reviewed (NULL: not reviewed)"},
    },
}

function knowledge.hand_rolled_sql_columns_text(table_name)
    columns = HAND_ROLLED_TABLE_COLUMNS[table_name]
    if columns == nil then
        return nil
    end
    lines = {}
    for _, col in ipairs(columns) do
        table.insert(lines, string.format("%s -- %s", col.name, col.note))
    end
    return table.concat(lines, "\n")
end

-- A document counts as "in the pool" for stats/listing once it's
-- actually been retrieved, or was created as system/agent-derived
-- content in the first place -- distinguishing that from every other
-- ordinary, never-touched document.
KNOWLEDGE_MEMBER_WHERE = "(retrieval_count > 0 OR (source_type IS NOT NULL AND source_type != ''))"

--------------------------------------------------------------------------
-- Documents as the pool's own records
--------------------------------------------------------------------------

function knowledge.get_document(db_path, document_id)
    doc = entity.get(db_path, "document", document_id)
    if doc == nil then
        return nil
    end
    -- Phase 3 cutover (see doc/heat-decay-redesign.md): effective_heat
    -- is now the conserved-pool view, not the old wall-clock decay.
    document.ensure_pool_state(db_path)
    state_rows = db.query(db_path, "SELECT log_pool_scale FROM knowledge_pool_state WHERE id = 1;")
    pool_scale = 1.0
    if state_rows != nil and state_rows[1] != nil then
        pool_scale = math.exp(tonumber(state_rows[1].log_pool_scale))
    end
    doc.effective_heat = document.pool_effective_heat(doc.raw_heat, doc.scale_at_write, pool_scale)
    return doc
end

-- Creates a genuinely new document (chat reasoning, a distilled note)
-- under the Knowledge Pool folder -- there's no existing document to
-- attach this content to, unlike a search hit against a document that
-- already exists. Attributed to the real logged-in user, same as any
-- other document, not a synthetic actor -- the Knowledge Pool folder
-- itself is the only thing authored as "system" (see
-- document.ensure_knowledge_pool_folder).
function knowledge.create_document_note(db_path, author, title, body, source_type, source_id, source_ref)
    folder_id = document.ensure_knowledge_pool_folder(db_path)
    document_id, issues = document.create_page(db_path, author, title, folder_id, body, nil)
    if document_id == nil then
        return nil, issues
    end
    db.exec(db_path, string.format(
        "UPDATE document SET source_type = %s, source_id = %s, source_ref = %s, content_hash = %s WHERE id = %d;",
        db.literal(source_type), db.literal(source_id), db.literal(source_ref),
        db.quote(document.content_hash(body)), document_id
    ))
    return document_id
end

function knowledge.session_document_for(db_path, session_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM document WHERE source_type = 'chat_session' AND source_ref = %s LIMIT 1;",
        db.quote(session_id)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

-- One document per chat session, kept in sync with its own transcript
-- rather than a one-time snapshot -- find-or-create, then update in
-- place on every call (agent.lua's sync_session_document calls this at
-- the end of every real turn). Filed under the Knowledge Pool folder,
-- tagged source_type = 'chat_session' / source_ref = the session's own
-- id (not source_id -- agent_session ids are opaque hex text, not the
-- integer source_id column). See doc/architecture.md's "Whole chat
-- sessions are themselves documents" for the full design and why.
function knowledge.sync_session_document(db_path, author, session_id, title, transcript)
    existing = knowledge.session_document_for(db_path, session_id)
    if existing != nil then
        document.update_page(db_path, author, existing.id, title, existing.parent_id, transcript, nil)
        return existing.id
    end
    folder_id = document.ensure_knowledge_pool_folder(db_path)
    document_id, issues = document.create_page(db_path, author, title, folder_id, transcript, nil)
    if document_id == nil then
        return nil
    end
    db.exec(db_path, string.format(
        "UPDATE document SET source_type = 'chat_session', source_ref = %s WHERE id = %d;",
        db.quote(session_id), document_id
    ))
    return document_id
end

-- The agent-driven counterpart to knowledge.create_document_note's
-- reasoning-note path -- a genuinely new, concise, single-idea document
-- distilled from a source (an existing document, a chat exchange), not
-- a raw mirror of it. Always starts at tier 0 like any new pool
-- document -- earns its way up through the same heat/retrieval
-- mechanism as everything else, never pre-promoted just because an
-- agent wrote it. Flattens entity.create's own {field, severity,
-- message} issues shape into a plain string -- both the CLI and the
-- agent tool dispatch just want a message, not that shape.
function knowledge.distill_document(db_path, author, source_document_id, title, body)
    document_id, issues = knowledge.create_document_note(db_path, author, title, body, "distilled", source_document_id, nil)
    if document_id == nil then
        messages = {}
        if issues != nil then
            for _, issue in ipairs(issues) do
                if issue.severity == "error" then
                    table.insert(messages, tostring(issue.message))
                end
            end
        end
        if #messages == 0 then
            return nil, "failed to create the distilled document"
        end
        return nil, table.concat(messages, "; ")
    end
    return document_id
end

--------------------------------------------------------------------------
-- Retrieval logging
--------------------------------------------------------------------------

-- Same real concurrent-CGI race as ledger.lua's append_create/agent.
-- add_message (see their own comments) -- SELECT MAX(id) can collide
-- with another connection's own insert; db.exec's own connection-scoped
-- second return value can't.
function knowledge.begin_retrieval(db_path, session_id, query_text, hit_count)
    _, retrieval_id = db.exec(db_path, string.format(
        "INSERT INTO knowledge_retrieval (session_id, query_text, hit_count) VALUES (%s, %s, %d);",
        db.literal(session_id), db.literal(query_text), tonumber(hit_count)
    ))
    return tonumber(retrieval_id)
end

-- Bumps the document's heat/retrieval_count by the reinforcement
-- formula and records the per-hit row audit-style (see
-- document.reinforcement_delta). content_hash is refreshed on every hit
-- (not just at creation) so dedup review stays accurate even as a
-- document's content is edited over time.
function knowledge.record_retrieval_hit(db_path, retrieval_id, document_id, tier, rank, score, content_hash)
    delta = document.reinforcement_delta(tier)
    tier_weight = document.tier_weight(tier)
    db.exec(db_path, string.format(
        "UPDATE document SET retrieval_count = retrieval_count + 1, " ..
        "content_hash = %s, updated_at = %s WHERE id = %d;",
        db.quote(content_hash), db.now_expr(db_path), tonumber(document_id)
    ))
    -- Phase 3 cutover (see doc/heat-decay-redesign.md): the conserved
    -- pool is now the only heat model -- the old `heat`/
    -- `last_retrieved_at` wall-clock columns are no longer written.
    document.reinforce_pool_heat(db_path, document_id, delta)
    db.exec(db_path, string.format(
        "%s knowledge_retrieval_hit (retrieval_id, document_id, `rank`, score, tier_weight, reinforcement_delta) " ..
        "VALUES (%d, %d, %d, %.17g, %.17g, %.17g);",
        db.replace_into(db_path),
        tonumber(retrieval_id), tonumber(document_id), tonumber(rank), tonumber(score), tier_weight, delta
    ))
    return delta
end

--------------------------------------------------------------------------
-- Review gates (DB-touching orchestration; see document.lua's pure heuristics)
--------------------------------------------------------------------------

-- Canonical = lowest id sharing the same content hash. Only ever
-- MUTATES duplicate_of/merged_into for a system/agent-derived document
-- (source_type set) -- a real user-authored document is never silently
-- folded into another one just because their content happens to
-- match; the status is still reported either way for visibility.
function knowledge.duplication_status(db_path, document_id, content_hash, source_type)
    if content_hash == nil or content_hash == "" then
        return "unique"
    end
    rows = db.query(db_path, string.format(
        "SELECT id FROM document WHERE content_hash = %s AND id != %d AND (archived_at IS NULL OR archived_at = '') ORDER BY id ASC LIMIT 1;",
        db.quote(content_hash), tonumber(document_id)
    ))
    if rows == nil or rows[1] == nil then
        return "unique"
    end
    canonical_id = tonumber(rows[1].id)
    if canonical_id < tonumber(document_id) then
        if source_type != nil and source_type != "" then
            db.exec(db_path, string.format(
                "UPDATE document SET duplicate_of = %d, merged_into = %d WHERE id = %d;",
                canonical_id, canonical_id, tonumber(document_id)
            ))
            -- See doc/heat-decay-redesign.md: the departing document's
            -- heat gets returned to the survivors rather than just
            -- vanishing from the pool's total.
            document.return_pool_heat(db_path, document_id)
        end
        return "duplicate-of-" .. tostring(canonical_id)
    end
    return "unique"
end

-- Runs once per retrieval, after all hits are logged: for every
-- document this retrieval touched, computes the review gates, applies
-- any resulting mutation (retitle, dedup, tier promotion), and records
-- its review outcome on that document's knowledge_retrieval_hit row. Retitling only ever
-- applies to system/agent-derived documents (source_type set) -- a
-- real user-authored document's title is never rewritten out from under
-- them, even if it happens to look generic ("note", "untitled", ...).
-- `author` attributes any resulting distillation (knowledge.
-- maybe_distill) to the real user whose retrieval actually triggered it
-- -- reactive, tied to real usage, not a synthetic actor.
function knowledge.review_retrieval(db_path, retrieval_id, author)
    rows = db.query(db_path, string.format(
        "SELECT document_id FROM knowledge_retrieval_hit WHERE retrieval_id = %d;", tonumber(retrieval_id)
    ))
    if rows == nil then
        return
    end
    peer_count = #rows - 1
    if peer_count < 0 then
        peer_count = 0
    end

    for _, row in ipairs(rows) do
        doc = knowledge.get_document(db_path, row.document_id)
        if doc != nil then
            is_system = doc.source_type != nil and doc.source_type != ""
            body = doc.content
            if body == nil then
                body = ""
            end
            -- content_shape/duplication/connectivity/title checks stay
            -- unconditional every review -- cheap (regex over an
            -- already-loaded body, or one indexed SELECT). Only the
            -- tier recompute itself (document.was_revised's ledger
            -- round-trip) is gated behind due_for_review -- retrieval_
            -- count/effective_heat no longer decide the tier, only
            -- whether it's worth rechecking at all.
            content_shape = document.content_shape(body)
            duplication = knowledge.duplication_status(db_path, doc.id, doc.content_hash, doc.source_type)
            connectivity = document.connectivity_status(peer_count)
            is_duplicate = string.match(duplication, "^duplicate%-of%-") != nil

            title_status = "ok"
            new_title = doc.title
            if is_system and document.title_is_generic(doc.title) then
                new_title = document.guess_title_from_body(body)
                title_status = "retitled"
            end

            target_tier = tonumber(doc.tier)
            -- doc.effective_heat already comes from knowledge.get_document
            -- (line 390 above) as the conserved-pool view -- no need to
            -- recompute it here. is_duplicate/was_revised stay hardcoded
            -- eligibility gates (see doc/architecture.md's "Agent control:
            -- rule-based by default") -- only the genuinely fuzzy
            -- "how mature is this content" question is handed to the
            -- model, via knowledge.judge_promotion_target, and only once
            -- per distinct content_hash (knowledge.due_for_tier_judgment)
            -- so a document that's merely retrieved again and again
            -- without being edited doesn't re-trigger a model call every
            -- time it comes due for review.
            if knowledge.due_for_review(tonumber(doc.retrieval_count), doc.effective_heat) then
                if not knowledge.can_hold_tier(doc.source_type) then
                    target_tier = 0
                    -- A source in use is curated into a tier-1 note by the
                    -- jobs worker, not here (src/curate.lua).
                    require("curate").queue(db_path, doc)
                end
                -- A document the curation wrote keeps the tier its step
                -- gave it (curate: 1, synthesize: 2). Found 2026-10-29:
                -- the old judge path here would have reset a fresh
                -- tier-1 note to 0 on its second retrieval (never
                -- "revised"), or moved a revised one to any tier.
            end

            db.exec(db_path, string.format(
                "UPDATE document SET tier = %d, title = %s, updated_at = %s WHERE id = %d;",
                target_tier, db.literal(new_title), db.now_expr(db_path), doc.id
            ))
            db.exec(db_path, string.format(
                "UPDATE knowledge_retrieval_hit SET atomicity_status = %s, connectivity_status = %s, duplication_status = %s, title_status = %s, reviewed_at = %s " ..
                "WHERE retrieval_id = %d AND document_id = %d;",
                db.quote(content_shape), db.quote(connectivity), db.quote(duplication), db.quote(title_status), db.now_expr(db_path),
                tonumber(retrieval_id), doc.id
            ))

            -- Reactive distillation -- decoupled from target_tier and
            -- from the source's own revised/tier state, since
            -- distillation cares whether the SOURCE is worth extracting
            -- a card from -- a "developed", multi-section document --
            -- not whether it's been processed itself (see
            -- doc/architecture.md's "Reactive distillation" for the
            -- full design, including a dead-code bug this decoupling
            -- fixed). See knowledge.maybe_distill's own comment for why
            -- this is a direct one-shot model call rather than a full
            -- agent session, and why its own guard keeps this a rare,
            -- at-most-once-per-document cost, not a per-search tax.
            if content_shape == "developed" then
                knowledge.maybe_distill(db_path, author, doc, content_shape)
            end
        end
    end

    -- Co-retrieval -> agent-evaluated explicit link. Needs the *whole
    -- batch* (to form pairs), so this runs once here rather than inside
    -- the per-document loop above like the other gates.
    document_ids = {}
    for _, row in ipairs(rows) do
        table.insert(document_ids, row.document_id)
    end
    knowledge.maybe_link_co_retrieved(db_path, author, document_ids)
end

--------------------------------------------------------------------------
-- Full prompt/reasoning/token persistence + chat evaluation
--------------------------------------------------------------------------

-- Detects a model that leaks its own step-by-step thinking into the
-- visible reply (rather than keeping it internal) instead of a clean
-- final answer. Plain string.find (not a pattern), since none of these
-- markers need pattern matching and a reply's own content is arbitrary
-- text that shouldn't ever be interpreted as one.
function knowledge.reply_has_visible_reasoning(text)
    if text == nil or text == "" then
        return false
    end
    if string.find(text, "<think>", 1, true) != nil then
        return true
    end
    if string.find(text, "</think>", 1, true) != nil then
        return true
    end
    if string.find(text, "Thinking...", 1, true) != nil then
        return true
    end
    return string.find(string.lower(text), "thinking:", 1, true) == 1
end

-- Classifies one reply into (reply_kind, quality_status,
-- reasoning_status): error / reasoning-visible / final / empty.
function knowledge.classify_reply(is_error, text)
    if is_error == true then
        return "error", "error", "none"
    end
    if knowledge.reply_has_visible_reasoning(text) then
        return "reasoning-visible", "review", "visible"
    end
    if text != nil and text != "" then
        return "final", "ok", "none"
    end
    return "empty", "empty", "none"
end


--------------------------------------------------------------------------
-- Reactive distillation, tied to real usage/review activity
--------------------------------------------------------------------------
--
-- Not a periodic full-pool scan on a cron/systemd-timer schedule (this
-- codebase has none anyway -- no in-app background scheduler exists at
-- all) -- distillation falls out of "general usage processing" itself.
-- A document that's frequently retrieved and has been reviewed (crossed
-- into tier 2, "Curated Draft", the same bar knowledge.
-- promotion_target_tier already applies) and doesn't already have a
-- distilled derivative gets one generated right here, inline in the
-- same request that pushed it over that bar -- not queued for a
-- separate process. This fires at most ONCE per source document ever
-- (gated on "no existing distilled derivative"), so the added latency
-- is a rare, one-time cost per document crossing the bar, not a
-- per-search tax. See doc/architecture.md's "Reactive distillation" for
-- the full design.
--
-- Deliberately a single, direct model call (agent_provider.generate),
-- not a full tool-calling agent session/pending-approval flow like
-- knowledge.distill/AGENT_TOOLS.knowledge.distill (still the right
-- shape for an explicitly human- or agent-initiated distillation
-- request) -- this path is a rule-triggered side effect of review, not
-- a model deciding to act, so there's no proposal for a human to
-- approve in the first place. Best-effort like everything else that
-- calls an external API from a save/review path (e.g. document.
-- reindex_embedding) -- a provider hiccup here must never fail the
-- review pass, let alone the search request that triggered it. The
-- model is the deployment's agent_model (a nil model is
-- agent_provider.model()), as for link evaluation and tier judgment.

-- Found live (task: bring back the "hypothesis/definition, not a
-- subject title" lesson from a real curation chat): the model's first
-- pass at candidate ideas came back as topic labels ("Cryopreservation
-- vs. Genetic Fidelity Thresholds", "Bioreactor Parameters for
-- Cacao") -- accurate summaries of what a cluster is ABOUT, but
-- asserting nothing themselves. The human reviewer's own words were
-- "I prefer the atomic record to be more like hypothesis or
-- definition and not a subject title" -- encoded below the same way
-- the reminder/action-item case already is.
DISTILL_SYSTEM_PROMPT = """
Extract the single core idea from the following document into a new, concise, self-contained note in your own words -- not a verbatim copy. Remove anything not essential to that one idea. The core idea is a fact, conclusion, or concept, not an instruction to do something -- if the most prominent content is a to-do, a reminder, or an assignment of who must do what, that is not itself a distillable idea; only extract if there's a genuine underlying fact or concept beneath it worth stating in its own right, otherwise treat it as nothing meaningful to extract. Write it as a real claim -- a hypothesis, finding, or definition that asserts something -- never as a subject/topic label that just names an area (e.g. "media optimization considerations" or "cryopreservation vs. genetic fidelity" asserts nothing; state the actual finding instead). Reply with the distilled note text only: no title, no preamble, no commentary. If the document already covers exactly one focused idea and there is nothing meaningful to extract, reply with exactly: NONE
"""

function knowledge.already_distilled_from(db_path, source_document_id)
    rows = db.query(db_path, string.format(
        "SELECT id FROM document WHERE source_type = 'distilled' AND source_id = %d LIMIT 1;",
        tonumber(source_document_id)
    ))
    return rows != nil and rows[1] != nil
end

-- Called from review_retrieval whenever a document's content_shape comes
-- back "developed" (long, multi-section -- see document.content_shape).
-- Never distills a document that's itself already a distilled note
-- (source_type == 'distilled'), never redistills the same source twice,
-- and only ever fires for "developed" content -- an already-"atomic" or
-- "thin"/"simple" source has nothing worth extracting that isn't already
-- there as-is.
function knowledge.maybe_distill(db_path, author, doc, content_shape)
    if doc.source_type == "distilled" then
        return nil
    end
    if content_shape != "developed" then
        return nil
    end
    if knowledge.already_distilled_from(db_path, doc.id) then
        return nil
    end

    agent_provider = require("agent_provider")
    body = doc.content
    if body == nil then
        body = ""
    end
    distilled, err = agent_provider.generate(nil, DISTILL_SYSTEM_PROMPT, body)
    if distilled == nil then
        return nil
    end
    distilled = (string.gsub(distilled, "^%s*(.-)%s*$", "%1"))
    if distilled == "" or distilled == "NONE" then
        return nil
    end

    title = document.guess_title_from_body(distilled)
    document_id, err = knowledge.distill_document(db_path, author, doc.id, title, distilled)
    return document_id
end

--------------------------------------------------------------------------
-- Co-retrieval -> agent-evaluated explicit link
--------------------------------------------------------------------------
--
-- Retrieval already surfaces an *implicit* similarity signal: documents
-- that keep showing up together in the same search. Once a pair
-- crosses a real, repeated pattern (not a one-off coincidence), it's
-- worth asking whether that's a genuinely meaningful connection --
-- if so, make it an explicit document_link, which then feeds spreading
-- activation (see doc/architecture.md's "Knowledge pool" section) for
-- free, no separate change needed in document.search's own ranking.
--
-- Same shape as knowledge.maybe_distill just above: a deterministic
-- rule (threshold + hub-ratio guard crossed) triggers one direct,
-- scoped agent_provider.generate call -- not an open-ended tool-calling
-- session -- and the resulting document_link write is additive-only
-- (never edits/deletes anything existing), so it doesn't need its own
-- human-approval gate, the same reasoning that already exempts
-- maybe_distill's own write from one.

-- Minimum distinct retrievals two documents must share before
-- evaluation triggers at all.
CO_RETRIEVAL_LINK_THRESHOLD = 3

-- co_count must also be at least this fraction of the *less-retrieved*
-- of the two documents' own retrieval_count -- guards against a hub
-- document (one that matches many different broad queries) racking up
-- links to everything it happens to share a handful of retrievals with:
-- its own retrieval_count is high too, so the ratio stays low even
-- when its absolute co_count with everything is high.
CO_RETRIEVAL_HUB_RATIO = 0.25

-- After a decline, co_count must grow by at least this much again past
-- last_co_count before the same pair is re-evaluated -- otherwise a
-- declined pair would get re-asked on every single subsequent shared
-- retrieval forever.
CO_RETRIEVAL_REEVALUATION_STEP = 3

-- Usage-driven edge strength (doc/link-strength-redesign.md): an
-- already-linked pair that keeps being co-retrieved has its edge's
-- raw_strength reinforced by this flat amount, same trigger as link
-- creation just for the already-linked case. No tier concept for an
-- edge, so this is a flat constant rather than a reinforcement_delta(tier)
-- table -- matches document.reinforcement_delta's own tier-0 floor,
-- which is otherwise unrelated to this value.
LINK_REINFORCEMENT_DELTA = 0.15

LINK_EVALUATION_SYSTEM_PROMPT = """
Two documents from the same knowledge pool have repeatedly been retrieved together in the same searches. Judge whether they describe a genuinely meaningful connection (the same topic, a real dependency, one explains or extends the other) as opposed to just coincidental overlap in unrelated searches. Reply on a single line: YES or NO, a colon, then one sentence. For YES, the sentence states the specific connection in terms of the documents' content (what one says about, uses from, or adds to the other) and names the information both share (the experiment, sample, method, result or decision) -- not merely that they are related, of the same kind ("both are meeting notes") or were retrieved together; if you can't name what they share, answer NO. For NO, the sentence says why the overlap is coincidental. A YES sentence is written into a note that links both documents right before it, so refer to them by what they are, never as "Document A" or "Document B". Example: "YES: the subculture protocol calls for exactly this medium recipe."
"""


-- Whether `co_count`/`retrieval_count_a`/`retrieval_count_b` clear both
-- the absolute threshold and the hub-ratio guard -- pure math, kept
-- separate from the DB/model-calling function below so it's directly
-- unit-testable.
--
-- Ratio is against the *larger* of the two retrieval_counts, not the
-- smaller: a hub document (retrieval_count=50) that happens to share 3
-- retrievals with a rarely-retrieved one (retrieval_count=4) must be
-- rejected (3/50 = 0.06, well under the guard), but checking against
-- the *smaller* count (3/4 = 0.75) would let it straight through --
-- exactly backwards from what the guard is for.
function knowledge.co_retrieval_eligible(co_count, retrieval_count_a, retrieval_count_b)
    if co_count < CO_RETRIEVAL_LINK_THRESHOLD then
        return false
    end
    larger_retrieval_count = retrieval_count_a
    if retrieval_count_b > larger_retrieval_count then
        larger_retrieval_count = retrieval_count_b
    end
    if larger_retrieval_count <= 0 then
        return false
    end
    return (co_count / larger_retrieval_count) >= CO_RETRIEVAL_HUB_RATIO
end

-- Co-occurrence counts for every pair *within* `document_ids` (not a
-- corpus-wide scan) -- one self-join, not one query per pair.
function knowledge.co_retrieval_pairs(db_path, document_ids)
    if document_ids == nil or #document_ids < 2 then
        return {}
    end
    id_list = {}
    for _, id in ipairs(document_ids) do
        table.insert(id_list, tostring(tonumber(id)))
    end
    id_list_sql = table.concat(id_list, ", ")

    rows = db.query(db_path, string.format("""
        SELECT a.document_id AS doc_a, b.document_id AS doc_b, COUNT(DISTINCT a.retrieval_id) AS co_count
        FROM knowledge_retrieval_hit a
        JOIN knowledge_retrieval_hit b ON a.retrieval_id = b.retrieval_id AND a.document_id < b.document_id
        WHERE a.document_id IN (%s) AND b.document_id IN (%s)
        GROUP BY a.document_id, b.document_id;
    """, id_list_sql, id_list_sql))
    if rows == nil then
        return {}
    end
    return rows
end

function knowledge.get_link_review(db_path, document_a_id, document_b_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM knowledge_link_review WHERE document_a_id = %d AND document_b_id = %d;",
        tonumber(document_a_id), tonumber(document_b_id)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

function knowledge.record_link_review(db_path, document_a_id, document_b_id, co_count, decision, reason)
    db.exec(db_path, string.format(
        "%s knowledge_link_review (document_a_id, document_b_id, last_co_count, decision, reason, evaluated_at) VALUES (%d, %d, %d, %s, %s, %s);",
        db.replace_into(db_path), tonumber(document_a_id), tonumber(document_b_id),
        tonumber(co_count), db.quote(decision), db.literal(document.clip_text(reason)), db.now_expr(db_path)
    ))
end

-- A connection document's whole content is its reason: fewer words
-- than this can't say what the two documents share.
LINK_REASON_MIN_WORDS = 8

function knowledge.link_reason_too_thin(reason)
    if reason == nil then
        return true
    end
    words = 0
    for _ in string.gmatch(reason, "%S+") do
        words = words + 1
    end
    return words < LINK_REASON_MIN_WORDS
end

-- "YES: <sentence>" / "NO: <sentence>" -> "YES"/"NO", sentence. Lenient
-- about what models actually send back -- **bold** or quoted verdicts,
-- "-" instead of ":", no reason at all -- since a strict parse would
-- turn a well-meant YES into a silent decline. Anything whose first
-- word isn't YES/NO is nil, which the caller treats as a decline, the
-- same as before reasons existed.
function knowledge.parse_link_judgment(answer)
    if answer == nil then
        return nil, nil
    end
    text = string.gsub(answer, "^%s*(.-)%s*$", "%1")
    text = string.gsub(text, "^[%*\"']+", "")
    word, rest = string.match(text, "^(%a+)(.*)$")
    if word == nil then
        return nil, nil
    end
    word = string.upper(word)
    if word != "YES" and word != "NO" then
        return nil, nil
    end
    rest = string.gsub(rest, "^[%*\"']*%s*[:%-]?%s*", "")
    rest = string.gsub(rest, "^%s*(.-)%s*$", "%1")
    if rest == "" then
        rest = nil
    end
    return word, rest
end

function knowledge.link_pair_prompt(doc_a, doc_b)
    body_a = doc_a.content
    if body_a == nil then
        body_a = ""
    end
    body_b = doc_b.content
    if body_b == nil then
        body_b = ""
    end
    return string.format(
        "Document A -- %s:\n%s\n\nDocument B -- %s:\n%s",
        tostring(doc_a.title), body_a, tostring(doc_b.title), body_b
    )
end

-- Whether two documents are already connected, through content: one
-- links the other (either way), or some third document links both --
-- the shape a connection document has, whoever wrote it. Either way the
-- co-retrieval judgment has nothing to add. Active rows between active
-- documents only; the holder of a two-sided connection must be active
-- too.
function knowledge.documents_connected(db_path, document_a_id, document_b_id)
    a = tonumber(document_a_id)
    b = tonumber(document_b_id)
    rows = db.query(db_path, string.format("""
        SELECT 1 FROM document_link
        WHERE ((from_document_id = %d AND to_document_id = %d) OR (from_document_id = %d AND to_document_id = %d))
          AND (archived_at IS NULL OR archived_at = '')
        LIMIT 1;
    """, a, b, b, a))
    if rows != nil and rows[1] != nil then
        return "direct"
    end
    rows = db.query(db_path, string.format("""
        SELECT 1 FROM document_link la
        JOIN document_link lb ON lb.from_document_id = la.from_document_id
        JOIN document holder ON holder.id = la.from_document_id
        WHERE la.to_document_id = %d AND lb.to_document_id = %d
          AND (la.archived_at IS NULL OR la.archived_at = '') AND (lb.archived_at IS NULL OR lb.archived_at = '')
          AND (holder.archived_at IS NULL OR holder.archived_at = '')
        LIMIT 1;
    """, a, b))
    if rows != nil and rows[1] != nil then
        return "through_document"
    end
    return nil
end

-- Strengthens a directly linked pair's edge(s) on repeated co-retrieval
-- (doc/link-strength-redesign.md). Both directions -- a link's from/to
-- is whichever document's content holds it, not co_retrieval_pairs'
-- doc_a < doc_b ordering -- and every matching active row (a link each
-- way, or two spellings of the same target). One atomic UPDATE, no
-- read-modify-write to race over. Never unarchives: an archived link's
-- markup is gone from content, and retrieval doesn't write content.
function knowledge.reinforce_link_strength(db_path, document_a_id, document_b_id)
    db.exec(db_path, string.format("""
        UPDATE document_link SET raw_strength = raw_strength + %.17g
        WHERE ((from_document_id = %d AND to_document_id = %d) OR (from_document_id = %d AND to_document_id = %d))
          AND (archived_at IS NULL OR archived_at = '');
    """, LINK_REINFORCEMENT_DELTA, tonumber(document_a_id), tonumber(document_b_id), tonumber(document_b_id), tonumber(document_a_id)))
end

-- Whether a document has been retrieved/reinforced enough to be worth
-- spending a ledger round-trip (document.was_revised) rechecking its
-- processing maturity -- retrieval_count/effective_heat no longer
-- decide the tier itself (see document.promotion_target_tier's own
-- comment), only whether it's worth looking again at all. The heat leg
-- exists because knowledge.spread_activation bumps a linked neighbor's
-- heat without ever bumping its retrieval_count -- without it, a
-- document that only ever accrues heat by spreading activation would
-- never become due for review.
DUE_FOR_REVIEW_RETRIEVAL_COUNT = 2
DUE_FOR_REVIEW_HEAT = 1.15

function knowledge.due_for_review(retrieval_count, effective_heat)
    return tonumber(retrieval_count) >= DUE_FOR_REVIEW_RETRIEVAL_COUNT
        or tonumber(effective_heat) >= DUE_FOR_REVIEW_HEAT
end

-- Whether a pair due a fresh look right now -- no prior review at all
-- (first time crossing the threshold), or a prior decline whose
-- co_count has since grown past CO_RETRIEVAL_REEVALUATION_STEP beyond
-- what it was declined at.
function knowledge.due_for_link_review(review, co_count)
    if review == nil then
        return true
    end
    -- "linked": its connection document exists (or existed -- someone
    -- archiving it is an answer too). "unlinkable": a title can't be
    -- written as a link (document.link_ref), which more co-retrieval
    -- won't change.
    if review.decision == "linked" or review.decision == "unlinkable" then
        return false
    end
    return co_count >= (tonumber(review.last_co_count) + CO_RETRIEVAL_REEVALUATION_STEP)
end

-- Called once per retrieval from review_retrieval, given every
-- document_id in that retrieval's own batch -- not per-document like
-- the other review gates, since forming pairs needs the whole batch.
function knowledge.maybe_link_co_retrieved(db_path, author, document_ids)
    pairs_found = knowledge.co_retrieval_pairs(db_path, document_ids)
    for _, pair in ipairs(pairs_found) do
        doc_a_id = tonumber(pair.doc_a)
        doc_b_id = tonumber(pair.doc_b)
        co_count = tonumber(pair.co_count)

        -- Connected through a third document: nothing to do here --
        -- retrieving either end already heats that document by spreading
        -- activation, which is where the pair's shared relevance belongs.
        connected = knowledge.documents_connected(db_path, doc_a_id, doc_b_id)
        if connected == "direct" then
            knowledge.reinforce_link_strength(db_path, doc_a_id, doc_b_id)
        elseif connected == nil then
            review = knowledge.get_link_review(db_path, doc_a_id, doc_b_id)
            if knowledge.due_for_link_review(review, co_count) then
                doc_a = knowledge.get_document(db_path, doc_a_id)
                doc_b = knowledge.get_document(db_path, doc_b_id)
                -- A connection document is never one end of another:
                -- retrieved with its own two ends it was judged connected
                -- to them again, building chains of connections of
                -- connections (found live: celleste-lims, 248 of 672).
                if doc_a != nil and doc_b != nil and not document.is_connection_title(doc_a.title)
                        and not document.is_connection_title(doc_b.title) then
                    if knowledge.co_retrieval_eligible(co_count, tonumber(doc_a.retrieval_count), tonumber(doc_b.retrieval_count)) then
                        knowledge.evaluate_co_retrieval_pair(db_path, author, doc_a, doc_b, co_count)
                    end
                end
            end
        end
    end
end

-- The checkable specifics a link reason asserts: a cited author
-- ("Bargmann et al."), a year in parentheses ("(2000)"), an identifier
-- mixing letters and digits ("Exp141", "CCN51", "TcLEC2"), or a
-- numbered reference ("Experiment 208", "Sample 131", "Chapter 4").
-- Anything else in the reason is paraphrase, which a rule can't check.
CLAIM_REFERENCE_WORDS = {"Experiment", "Exp", "Sample", "Table", "Figure", "Chapter"}

function knowledge.reason_claims(reason)
    claims = {}
    seen = {}
    add = function(kind, value)
        key = kind .. ":" .. string.lower(value)
        if seen[key] == nil then
            seen[key] = true
            table.insert(claims, {kind = kind, value = value})
        end
    end
    if reason == nil then
        return claims
    end
    for surname in string.gmatch(reason, "(%u[%a'%-]+) et al") do
        add("text", surname)
    end
    for group in string.gmatch(reason, "%b()") do
        for year in string.gmatch(group, "%f[%d](1[89]%d%d)%f[%D]") do
            add("text", year)
        end
        for year in string.gmatch(group, "%f[%d](20%d%d)%f[%D]") do
            add("text", year)
        end
    end
    for token in string.gmatch(reason, "[%w]+") do
        -- "Exp141" is a numbered reference (below), matched loosely,
        -- not a literal identifier.
        is_reference = false
        for _, word in ipairs(CLAIM_REFERENCE_WORDS) do
            if string.match(string.lower(token), "^" .. string.lower(word) .. "%d+$") != nil then
                is_reference = true
            end
        end
        if not is_reference and string.len(token) >= 3 and string.find(token, "%a%d") != nil then
            add("text", token)
        end
    end
    for _, word in ipairs(CLAIM_REFERENCE_WORDS) do
        for number in string.gmatch(reason, "%f[%a]" .. word .. "%.? ?#?(%d+)") do
            add("reference", word .. " " .. number)
        end
    end
    return claims
end

-- A claim holds for a document when its title or content contains it
-- (case-insensitive; a numbered reference also matches "Exp. 208",
-- "Experiment #208" and "exp208").
function claim_in_text(claim, text)
    text = string.gsub(string.lower(text), ",", "")
    if claim.kind == "text" then
        return string.find(text, string.lower(claim.value), 1, true) != nil
    end
    word, number = string.match(claim.value, "^(%a+) (%d+)$")
    prefix = string.sub(string.lower(word), 1, 3)
    return string.find(text, "%f[%a]" .. prefix .. "%a*%.?[ #]*0*" .. number .. "%f[%D]") != nil
end

-- The claims of a YES reason that aren't in BOTH documents -- empty when
-- every one is (or the reason makes none). Both, not either: a
-- connection is about what the two share, and "B cites Katz et al."
-- would otherwise pass merely because Katz wrote A. Measured on 100
-- human-reviewed YES verdicts (2026-09-26, 12 accepted): this caught 12
-- of the 88 rejected -- every invented citation and cross-reference --
-- and 1 of the 12 accepted (a sample id only one side mentions), which
-- is re-judged later like any decline rather than lost.
function knowledge.unverified_claims(reason, doc_a, doc_b)
    text_a = tostring(doc_a.title) .. "\n" .. tostring(doc_a.content)
    text_b = tostring(doc_b.title) .. "\n" .. tostring(doc_b.content)
    missing = {}
    for _, claim in ipairs(knowledge.reason_claims(reason)) do
        if not (claim_in_text(claim, text_a) and claim_in_text(claim, text_b)) then
            table.insert(missing, claim.value)
        end
    end
    return missing
end

-- On YES, writes the connection down the way a person would: an
-- ordinary document linking both and saying why (document.
-- connection_draft), created through the same document.create_page any
-- save uses and attributed to the user whose retrieval surfaced it, the
-- same as every other note the pool creates (see
-- knowledge.create_document_note). The links come from its content like
-- any document's; nothing marks it as the agent's.
-- The model's judgment of one pair, checked by rule: "linked" with a
-- reason worth writing down, or why not -- "declined" (NO, or no
-- verdict), "thin" (a YES that doesn't say what both share: the reason
-- IS the note, and a bare YES or "both are meeting notes" made notes
-- holding nothing -- found live on celleste-lims, a flood of them) or
-- "unverified" (a YES naming things the documents don't both contain:
-- an invented connection, not a found one). nil when the model call
-- failed. -> decision, reason
function knowledge.judge_link(doc_a, doc_b)
    agent_provider = require("agent_provider")
    answer, err = agent_provider.generate(nil, LINK_EVALUATION_SYSTEM_PROMPT, knowledge.link_pair_prompt(doc_a, doc_b))
    if answer == nil then
        return nil, err
    end
    verdict, reason = knowledge.parse_link_judgment(answer)
    if verdict != "YES" then
        return "declined", reason
    end
    if knowledge.link_reason_too_thin(reason) then
        return "thin", "no sentence saying what both share: " .. tostring(reason)
    end
    missing = knowledge.unverified_claims(reason, doc_a, doc_b)
    if #missing > 0 then
        return "unverified", "not in both documents: " .. table.concat(missing, ", ") .. " -- " .. tostring(reason)
    end
    return "linked", reason
end

-- How closely two documents share an idea: the best passage pair's
-- cosine (passage.best_pair), over each one's title and content.
-- -> score, passage_a, passage_b; or nil, err when it can't be measured.
-- `every_passage` lifts the per-pair caps (a one-off repair over
-- existing connections, where a slow first look doesn't hold up a page).
function knowledge.link_similarity(db_path, doc_a, doc_b, every_passage)
    passage = require("passage")
    agent_provider = require("agent_provider")
    conf = config.platform_config()
    per_document = conf.link_gate_passages_per_document
    max_new = conf.link_gate_max_embeds
    if every_passage == true then
        per_document = math.huge
        max_new = math.huge
    end
    -- A stub (a page that only links to an experiment view, an empty
    -- index) says too little about itself for any passage to match:
    -- it would score low against everything.
    for _, doc in ipairs({doc_a, doc_b}) do
        content = tostring(doc.content)
        if string.len(content) - document.preamble_end(content) + 1 < conf.passage_min_chars then
            return nil, "too little text to compare in #" .. tostring(doc.id)
        end
    end
    return passage.best_pair(db_path, agent_provider.embedding_model(),
        tostring(doc_a.title) .. "\n\n" .. tostring(doc_a.content),
        tostring(doc_b.title) .. "\n\n" .. tostring(doc_b.content),
        per_document, max_new)
end

-- The passage gate (doc/link-passage-gate.md): a pair whose best passage
-- pair is less similar than link_passage_gate isn't put to the model at
-- all. In the 2026-09-26 human review only 12 of 100 YES verdicts were
-- real connections, and the rest mostly shared a subject, not an idea.
-- It's recorded like a decline ("dissimilar", with the score), so it's
-- looked at again if co-retrieval grows or a document changes. When
-- the score can't be measured (a stub, no embeddings), the model
-- decides as before. -> passed, why, measured, passage_a, passage_b
function knowledge.passes_passage_gate(db_path, doc_a, doc_b, every_passage)
    threshold = config.platform_config().link_passage_gate
    -- Off: no measurement at all (measured is nil, not false).
    if threshold <= 0 then
        return true, nil, nil
    end
    score, pa, pb = knowledge.link_similarity(db_path, doc_a, doc_b, every_passage)
    if score == nil then
        io.write(io.stderr, "link passage gate skipped: " .. tostring(pa) .. "\n")
        return true, tostring(pa), false
    end
    if score < threshold then
        return false, string.format("best passage pair similarity %.3f is below %.3f", score, threshold), true, pa, pb
    end
    return true, nil, true, pa, pb
end

function knowledge.evaluate_co_retrieval_pair(db_path, author, doc_a, doc_b, co_count)
    passed, why = knowledge.passes_passage_gate(db_path, doc_a, doc_b)
    if passed == false then
        knowledge.record_link_review(db_path, doc_a.id, doc_b.id, co_count, "dissimilar", why)
        return
    end
    decision, reason = knowledge.judge_link(doc_a, doc_b)
    if decision == nil then
        return
    end
    -- Anything but "linked" is recorded like a decline, so it's
    -- re-judged if co-retrieval grows.
    if decision != "linked" then
        knowledge.record_link_review(db_path, doc_a.id, doc_b.id, co_count, decision, reason)
        return
    end
    draft = document.connection_draft(db_path, doc_a.id, doc_b.id, reason)
    if draft == nil then
        knowledge.record_link_review(db_path, doc_a.id, doc_b.id, co_count, "unlinkable", reason)
        return
    end
    document.create_page(db_path, author, draft.title, draft.parent_id, draft.content, nil)
    knowledge.record_link_review(db_path, doc_a.id, doc_b.id, co_count, "linked", reason)
end

-- What a connection document says about why its two documents are
-- connected: its content with the [[links]] and the "A and B:" lead-in
-- taken out.
function knowledge.connection_reason(content)
    if content == nil then
        return nil
    end
    reason = string.match(content, "^%s*%[%[.-%]%]%s+and%s+%[%[.-%]%]%s*:%s*(.-)%s*$")
    if reason == nil then
        reason = string.gsub(content, "%[%[.-%]%]", "")
        reason = string.gsub(reason, "^%s*(.-)%s*$", "%1")
    end
    if reason == "" then
        return nil
    end
    return reason
end

-- Archived like any document a person archives: the archive hook
-- takes its links (and its heat, vector, tag places) with it.
function revoke_connection(db_path, connection_id, why)
    archived_id, _ = entity.archive(db_path, "document", tonumber(connection_id), "system", nil, "repair connections: " .. why)
    if archived_id != nil then
        document.on_entity_archived(db_path, "document", archived_id)
    end
end

-- `daat repair connections`: every connection document ("A ↔ B") goes
-- through the pipeline a new pair does (evaluate_co_retrieval_pair),
-- gate first, then the model:
-- - the passage gate, comparing every passage (no per-pair cap): one
--   below link_passage_gate is archived, taking its links with it, and
--   the pair is recorded as 'dissimilar' -- no model call;
-- - then, for one the gate can't measure (a stub), one whose reason is
--   too thin to say what the two share, or (with `all`) every one: the
--   model is asked the same question co-retrieval asks; a reason that
--   passes judge_link replaces the old one, anything else archives it.
-- One whose two ends aren't both still active, or that connects another
-- connection document, is archived without asking. With dry_run, only
-- lists what it would do, with the score and the two passages behind
-- an archive by the gate (embeddings are made and cached; no model
-- calls). -> report lines
function knowledge.repair_connections(db_path, dry_run, all)
    rows = db.query(db_path, string.format(
        "SELECT id FROM document WHERE title LIKE %s AND (archived_at IS NULL OR archived_at = '') ORDER BY id;",
        db.quote("%" .. document.CONNECTION_TITLE_SEPARATOR .. "%")))
    if rows == nil then
        rows = {}
    end
    report = {}
    counts = {explained = 0, revoked = 0, dissimilar = 0, kept = 0, failed = 0}
    function snippet(p)
        return "@" .. tostring(p.offset - 1) .. " " .. string.gsub(string.sub(p.text, 1, 160), "%s+", " ")
    end
    function record(doc_a, doc_b, decision, reason)
        review = knowledge.get_link_review(db_path, doc_a.id, doc_b.id)
        co_count = 0
        if review != nil then
            co_count = tonumber(review.last_co_count)
        end
        knowledge.record_link_review(db_path, doc_a.id, doc_b.id, co_count, decision, reason)
    end
    for _, row in ipairs(rows) do
        connection = entity.get(db_path, "document", tonumber(row.id))
        label = "#" .. tostring(connection.id) .. " " .. tostring(connection.title)
        ends = db.query(db_path, string.format(
            "SELECT DISTINCT l.to_document_id AS id, d.title FROM document_link l JOIN document d ON d.id = l.to_document_id " ..
            "WHERE l.from_document_id = %d AND (l.archived_at IS NULL OR l.archived_at = '') " ..
            "AND (d.archived_at IS NULL OR d.archived_at = '') ORDER BY l.to_document_id;", tonumber(connection.id)))
        if ends == nil then
            ends = {}
        end
        chained = document.connection_title_count(connection.title) > 1
        for _, e in ipairs(ends) do
            if document.is_connection_title(e.title) then
                chained = true
            end
        end
        why = nil
        if chained then
            why = "it connects another connection document"
        elseif #ends != 2 then
            why = "its two documents aren't both active"
        end
        if why != nil then
            if dry_run then
                table.insert(report, "would revoke " .. label .. ": " .. why)
            else
                revoke_connection(db_path, connection.id, why)
                table.insert(report, "revoked " .. label .. ": " .. why)
            end
            counts.revoked = counts.revoked + 1
        else
            doc_a = knowledge.get_document(db_path, tonumber(ends[1].id))
            doc_b = knowledge.get_document(db_path, tonumber(ends[2].id))
            passed, gate_why, measured, pa, pb = knowledge.passes_passage_gate(db_path, doc_a, doc_b, true)
            if passed == false then
                detail = label .. ": " .. gate_why .. " | #" .. tostring(doc_a.id) .. " " .. snippet(pa) .. " | #" .. tostring(doc_b.id) .. " " .. snippet(pb)
                if dry_run then
                    table.insert(report, "would revoke " .. detail)
                else
                    revoke_connection(db_path, connection.id, gate_why)
                    record(doc_a, doc_b, "dissimilar", gate_why)
                    table.insert(report, "revoked " .. detail)
                end
                counts.dissimilar = counts.dissimilar + 1
            elseif all == true or measured == false or knowledge.link_reason_too_thin(knowledge.connection_reason(connection.content)) then
                if dry_run then
                    because = "asked to re-check every one"
                    if measured == false then
                        because = "the gate can't measure it: " .. tostring(gate_why)
                    elseif all != true then
                        because = "its reason doesn't say what both share"
                    end
                    table.insert(report, "would explain or revoke " .. label .. " (" .. because .. ")")
                else
                    decision, reason = knowledge.judge_link(doc_a, doc_b)
                    if decision == nil then
                        counts.failed = counts.failed + 1
                        table.insert(report, "left " .. label .. ": model call failed: " .. tostring(reason))
                    elseif decision == "linked" and document.connection_draft(db_path, doc_a.id, doc_b.id, reason) != nil then
                        draft = document.connection_draft(db_path, doc_a.id, doc_b.id, reason)
                        document.update_page(db_path, "system", tonumber(connection.id), connection.title, connection.parent_id, draft.content, nil)
                        record(doc_a, doc_b, "linked", reason)
                        counts.explained = counts.explained + 1
                        table.insert(report, "explained " .. label .. ": " .. reason)
                    else
                        revoke_connection(db_path, connection.id, decision .. " -- " .. tostring(reason))
                        record(doc_a, doc_b, decision, reason)
                        counts.revoked = counts.revoked + 1
                        table.insert(report, "revoked " .. label .. ": " .. decision .. " -- " .. tostring(reason))
                    end
                end
            else
                counts.kept = counts.kept + 1
            end
        end
    end
    if dry_run then
        table.insert(report, string.format("%d would be revoked by the passage gate, %d kept as they are (dry run: no model calls)",
            counts.dissimilar, counts.kept))
    else
        table.insert(report, string.format("%d explained, %d revoked by the passage gate, %d revoked, %d kept as they are, %d left (model call failed)",
            counts.explained, counts.dissimilar, counts.revoked, counts.kept, counts.failed))
    end
    return report
end

--------------------------------------------------------------------------
-- Agent-gated tier promotion: same shape as co-retrieval linking just
-- above -- rule-based gates (due_for_review, was_revised, is_duplicate,
-- due_for_tier_judgment) decide *when* it's worth asking at all; a
-- single scoped agent_provider.generate call decides *which* tier,
-- rather than document.promotion_target_tier's fixed content_shape
-- mapping. Non-destructive/no-approval for the same reason maybe_distill
-- and maybe_link_co_retrieved already are: a rule-triggered side effect
-- of review, not a model choosing to act, and fully reversible (tier is
-- recomputed fresh, bidirectionally, on every judged review).

-- Found live: a short calibration table and a short, mostly-links
-- experiment note both got judged tier 3 -- both genuinely short and
-- single-topic, so a shape/brevity-only bar was satisfied, but neither
-- is actually a distilled idea; they're raw data and a reference list
-- that just happen to be brief. The added sentences below are the
-- specific, found-live failure mode this prompt now has to rule out,
-- not a generic tightening.
--
-- Found live again: a distilled note reading "X and Y must remove
-- duplicate source entries from three samples" also got judged tier 3
-- -- short, single-topic, prose, not a table or link list, so the first
-- patch above didn't catch it. It's a reminder/action item (who must do
-- what), not a stated fact or concept -- a definition says what
-- something IS, this says what someone should DO. Ruled out explicitly
-- below, same as the table/links case.
--
-- Found live in a real curation chat (brought back from that
-- session, not a synthetic case): the model's own candidate atomic
-- records were bare subject/topic labels ("Cryopreservation vs.
-- Genetic Fidelity Thresholds", "Bioreactor Parameters for Cacao") --
-- accurate names for what a document cluster is about, but asserting
-- nothing. The human reviewer's correction was direct: "I prefer the
-- atomic record to be more like hypothesis or definition and not a
-- subject title." Ruled out below as its own case, alongside
-- reminders and raw data/links -- a title doesn't even claim to be an
-- instruction or a fact, it just names an area.
--
-- Found live checking real Tier 2 documents (task: sharpen Tier 1/2
-- the same way Tier 3 already was): several verbatim academic-paper
-- imports -- author byline, abstract, keywords, even leftover PDF-
-- extraction ligature artifacts ("?avor" for "flavor") still sitting
-- in the text -- were judged Tier 2 "Developed Reference", while other
-- untouched imports of the exact same kind landed at Tier 1 instead.
-- Neither is actually "developed" by anyone here -- they're long and
-- multi-section only because that's the shape of the original
-- published paper, not because someone on this platform organized or
-- synthesized them. A real Tier 2 case, by contrast, is an experiment
-- write-up authored here (objective, design, results) -- not a source
-- document that happens to already read like an article. Same
-- reasoning as progressive summarization's "the raw captured source
-- is always the lowest layer, however long, until someone actually
-- works it" and Wikipedia's own content-assessment scale, where a long
-- dump doesn't clear Start-class without real editorial organization.
TIER_JUDGMENT_SYSTEM_PROMPT = """
You are judging how far a document in a knowledge pool has matured through real editing, not how often it's been looked up. Tiers: 1 = Curated Draft (revised, but not yet a complete reference or a tight standalone definition -- includes a raw source document, however long or well-structured, that hasn't actually been reworked into this platform's own reference material yet), 2 = Developed Reference (a genuinely complete, multi-section article that someone here organized or synthesized as a reference -- e.g. an experiment write-up or a synthesized explainer -- not simply a long external document, like a full academic paper or an OCR'd report, that only reads like an article because that's the shape of its original source), 3 = Atomic Record (a short, self-contained idea stated in prose, like a glossary or flashcard definition -- someone actually distilled a single conclusion or concept down into its own words). Tier 3 requires real synthesis, not just brevity: a short table of raw data (measurements, calibration values, a data grid), a bare list of links or references, a reminder or action item (an instruction to do something, a to-do, an assignment of who must do what), a bare subject/topic label or heading-like phrase that names an area without asserting anything about it (e.g. "Cryopreservation vs. Genetic Fidelity Thresholds", "Bioreactor Scale-Up Considerations"), or a terse note that's mostly structure rather than a written statement of one idea all stay Curated Draft even when they're short and single-topic -- there's no distilled idea being expressed there, just short, listed, directive, or labeled content. Likewise, Tier 2 requires real editorial work, not just length or a multi-section shape: a verbatim imported document (an academic paper's own author/abstract/keywords block, a scraped report, raw extraction artifacts still visible in the text) stays at Curated Draft no matter how long or structured it is, until someone on this platform actually reworks it into a reference. A definition or finding states what something IS or was found to be true; a reminder states what someone should DO; a title just NAMES a subject; a long untouched import is just a big source, not a written reference -- only genuine synthesis earns Tier 2 or 3. If a source document is shown below for comparison, the note under judgment was distilled from it -- check fidelity, not just shape: a distillation that drops, overgeneralizes, or misstates a qualifier, exception, or key detail the source clearly states is not a genuinely distilled idea, however clean and definition-shaped it reads on its own, and should be judged Curated Draft rather than Atomic Record until it's fixed. Read the document below and decide which of these three tiers its CURRENT content genuinely earns -- judge the real editorial maturity and nature of the writing, not just its length. Reply with exactly one character: 1, 2, or 3.
"""

function knowledge.get_tier_review(db_path, document_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM document_tier_judgment WHERE document_id = %d;", tonumber(document_id)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

function knowledge.record_tier_review(db_path, document_id, content_hash, tier)
    db.exec(db_path, string.format(
        "%s document_tier_judgment (document_id, judged_hash, judged_tier, evaluated_at) VALUES (%d, %s, %d, %s);",
        db.replace_into(db_path), tonumber(document_id), db.quote(content_hash), tonumber(tier), db.now_expr(db_path)
    ))
end

-- Whether this document is due a fresh tier judgment -- no prior
-- judgment at all (first time it's eligible), or its content_hash has
-- changed since the last one. Mirrors due_for_link_review's own shape
-- (pure, kept separate from the DB fetch, so it's directly
-- unit-testable) and its "don't re-ask about something that hasn't
-- changed" reasoning, just keyed on content instead of a
-- re-evaluation step count -- an unedited document doesn't get a fresh
-- model call just for coming due for review again.
function knowledge.due_for_tier_judgment(review, content_hash)
    if review == nil then
        return true
    end
    return review.judged_hash != content_hash
end

-- Cap on how much of a distillation's source gets fed alongside it for
-- the fidelity comparison below -- same truncate-with-marker
-- convention as document.lua's ATTACHMENT_TEXT_MAX_CHARS, bounding the
-- cost of a judgment call that would otherwise run against a raw,
-- 200K+ character paper import every time a distilled note comes due
-- for review.
TIER_JUDGMENT_SOURCE_MAX_CHARS = 20000

-- current_tier/content_shape are passed as context/fallback, never the
-- decision itself. Falls back to document.promotion_target_tier's
-- existing deterministic mapping on a model error or an unparseable
-- reply, so a provider outage degrades to today's behavior instead of
-- silently leaving the document's tier stuck.
--
-- Mitigates the single-shot-distillation risk raised alongside
-- Progressive Summarization (task: staged bold/highlight/summary
-- layers would be a bigger structural addition; demotion on the tier
-- ladder daat already has is the cheaper fix): when a document is
-- itself a distillation (source_type == "distilled") its source is
-- fetched and shown alongside it here, so the model can judge fidelity
-- to that source, not just the note's own shape -- a document's tier
-- was already recomputed bidirectionally on every review (task #87);
-- this just gives that recompute something to demote AGAINST besides
-- the note's own drifting content.
-- Tiers 1-3 are earned by curation (doc/tier-curation-ladder.md): only a
-- document the curation wrote can hold one. A source -- a synced file, a
-- page someone wrote, a chat transcript, reasoning, a connection note, a
-- legacy distilled fact -- stays at tier 0 however it's edited or used.
-- Found in production 2026-10-28: a 151k-character chat transcript with
-- raw tool results judged tier 3 on its first look.
CURATED_SOURCE_TYPES = {curated = true, reference = true, record = true}

function knowledge.can_hold_tier(source_type)
    return source_type != nil and CURATED_SOURCE_TYPES[source_type] == true
end

function knowledge.judge_promotion_target(db_path, doc, current_tier, content_shape)
    agent_provider = require("agent_provider")
    body = doc.content
    if body == nil then
        body = ""
    end
    kind = doc.source_type
    if kind == nil or kind == "" then
        kind = "page"
    end
    header = string.format("Title: %s\nKind: %s\n", tostring(doc.title), kind)
    prompt = string.format("%sCurrent tier: %d\n\n%s", header, tonumber(current_tier), body)
    if doc.source_type == "distilled" and doc.source_id != nil then
        source_doc = knowledge.get_document(db_path, tonumber(doc.source_id))
        if source_doc != nil and source_doc.content != nil then
            source_body = source_doc.content
            if string.len(source_body) > TIER_JUDGMENT_SOURCE_MAX_CHARS then
                source_body = string.sub(source_body, 1, TIER_JUDGMENT_SOURCE_MAX_CHARS) ..
                    "\n\n[...source truncated, showing the first " .. tostring(TIER_JUDGMENT_SOURCE_MAX_CHARS) .. " characters...]"
            end
            prompt = header .. string.format(
                "Current tier: %d\n\nDistilled note (judge THIS one):\n%s\n\nSource it was distilled from (shown only for fidelity comparison -- do not judge the source's own maturity):\n%s",
                tonumber(current_tier), body, source_body
            )
        end
    end
    answer, err = agent_provider.generate(nil, TIER_JUDGMENT_SYSTEM_PROMPT, prompt)
    tier = nil
    if answer != nil then
        trimmed = string.gsub(answer, "^%s*(.-)%s*$", "%1")
        if trimmed == "1" or trimmed == "2" or trimmed == "3" then
            tier = tonumber(trimmed)
        end
    end
    if tier == nil then
        tier = document.promotion_target_tier(tonumber(current_tier), false, true, content_shape)
    end
    knowledge.record_tier_review(db_path, doc.id, doc.content_hash, tier)
    return tier
end

--------------------------------------------------------------------------
-- The one integration point every retrieval path goes through
--------------------------------------------------------------------------

-- ACT-R's "spreading activation": folds the existing document_link
-- graph into retrieval/context scoring -- a retrieved document's linked
-- neighbors get a smaller, fan-diluted heat reinforcement too, not just
-- the document that actually matched the query. Skips any neighbor that
-- was ALSO a direct hit this retrieval -- it already got the full
-- direct-hit treatment via record_retrieval_hit, and the two writes
-- would otherwise fight over the same knowledge_retrieval_hit audit
-- row (PRIMARY KEY (retrieval_id, document_id)) for no benefit.
-- retrieval_count is deliberately NOT bumped for a spread neighbor -- it
-- measures direct retrieval hits specifically (promotion_target_tier's
-- thresholds read it that way); only heat/last_retrieved_at, the shared
-- reinforcement signal, moves. If the same neighbor is shared by more
-- than one hit document in the same retrieval, its real heat still
-- accumulates both bumps (that UPDATE is cumulative), but only the
-- last-applied bump writes the audit row -- an accepted, documented
-- imprecision, same category as knowledge.list_documents' own
-- approximate raw-heat ordering.
function knowledge.spread_activation(db_path, retrieval_id, document_id, base_delta, hit_ids)
    neighbors = document.linked_neighbors(db_path, document_id)
    if #neighbors == 0 then
        return
    end
    total_strength = 0
    for _, neighbor in ipairs(neighbors) do
        total_strength = total_strength + tonumber(neighbor.raw_strength)
    end
    for _, neighbor in ipairs(neighbors) do
        neighbor_id = tonumber(neighbor.id)
        if neighbor_id != nil and hit_ids[neighbor_id] == nil then
            neighbor_doc = knowledge.get_document(db_path, neighbor_id)
            if neighbor_doc != nil then
                delta = document.weighted_spreading_delta(base_delta, neighbor.raw_strength, total_strength)
                tier_weight = document.tier_weight(neighbor_doc.tier)
                db.exec(db_path, string.format(
                    "UPDATE document SET updated_at = %s WHERE id = %d;",
                    db.now_expr(db_path), neighbor_id
                ))
                -- Phase 3 cutover (see doc/heat-decay-redesign.md): same
                -- conserved-reinforcement primitive record_retrieval_hit
                -- uses above, so a spread-activation bump is funded by
                -- the pool like any other reinforcement, not a second
                -- place that manufactures heat. The old `heat`/
                -- `last_retrieved_at` wall-clock columns are no longer
                -- written.
                document.reinforce_pool_heat(db_path, neighbor_id, delta)
                db.exec(db_path, string.format(
                    "%s knowledge_retrieval_hit (retrieval_id, document_id, `rank`, score, tier_weight, reinforcement_delta) " ..
                    "VALUES (%d, %d, NULL, NULL, %.17g, %.17g);",
                    db.replace_into(db_path), tonumber(retrieval_id), neighbor_id, tier_weight, delta
                ))
            end
        end
    end
end

-- Wraps document.search rather than modifying it -- document.search
-- stays pure/reusable, knowledge.lua depends on document.lua, never
-- the reverse. Every result IS already the record that accrues
-- heat/tier -- no separate note to create or look up first. `author`
-- is threaded through to review_retrieval, purely for attributing any
-- reactive distillation it triggers.
function knowledge.search_and_log(db_path, query_text, limit, use_semantic, session_id, author)
    results, query_vector, query_model = document.search(db_path, query_text, limit, use_semantic)
    retrieval_id = knowledge.begin_retrieval(db_path, session_id, query_text, #results)
    hit_ids = {}
    for _, r in ipairs(results) do
        hit_ids[tonumber(r.id)] = true
    end
    for rank, r in ipairs(results) do
        tier = tonumber(r.tier)
        if tier == nil then
            tier = 0
        end
        delta = knowledge.record_retrieval_hit(db_path, retrieval_id, r.id, tier, rank, r.score, document.content_hash(r.content))
        knowledge.spread_activation(db_path, retrieval_id, r.id, delta, hit_ids)
    end
    if #results > 0 then
        knowledge.review_retrieval(db_path, retrieval_id, author)
    end
    return results, retrieval_id, query_vector, query_model
end

-- knowledge.search_for_display(db_path, query_text, limit, session_id, author, full)
--   -> {{id, title, created_at, external_id, excerpt, same_title_count}, ...}
-- The one search everything shows -- the agent's document.search tool
-- and the /documents search box alike (doc/architecture.md, "The agent
-- sees what a user sees"): the same documents, the same excerpts, the
-- same usage logging. `excerpt` is the document's best passages when
-- search_passages is on (src/passage.lua), else the keyword window;
-- `full` asks for longer excerpts. `same_title_count` > 1 marks
-- documents sharing a title, so either side can tell them apart.
function knowledge.search_for_display(db_path, query_text, limit, session_id, author, full)
    results, _, query_vector, query_model = knowledge.search_and_log(db_path, query_text, limit, true, session_id, author)
    conf = config.platform_config()
    budget = conf.agent_search_excerpt_length
    if full == true then
        budget = conf.agent_search_excerpt_full_length
    end
    excerpts = {}
    if conf.search_passages == true then
        excerpts = require("passage").excerpts(db_path, results, query_text, query_vector, query_model, budget, full == true)
    end
    title_counts = {}
    for _, r in ipairs(results) do
        current = title_counts[r.title]
        if current == nil then
            current = 0
        end
        title_counts[r.title] = current + 1
    end
    shown = {}
    for _, r in ipairs(results) do
        excerpt = excerpts[tonumber(r.id)]
        if excerpt == nil then
            excerpt = document.search_snippet(r.content, query_text, budget)
        end
        table.insert(shown, {id = tonumber(r.id), title = r.title, created_at = r.created_at, external_id = r.external_id,
            excerpt = excerpt, same_title_count = title_counts[r.title]})
    end
    return shown
end

--------------------------------------------------------------------------
-- Stats -- for the agent's knowledge.stats tool and the /knowledge page
--------------------------------------------------------------------------

function count_rows(db_path, query)
    rows = db.query(db_path, query)
    if rows == nil or rows[1] == nil then
        return 0
    end
    return tonumber(rows[1].n)
end

-- session_count reads agent_session directly (agent.lua's own table)
-- rather than requiring agent.lua -- that would be a require cycle,
-- since agent.lua requires knowledge.lua to route its search tool
-- through search_and_log. Guarded since a fresh/unusual bootstrap
-- order could reach here before agent.init_schema has run.
function knowledge.stats(db_path)
    tier_counts = {}
    for tier = 0, 3 do
        tier_counts[tier] = count_rows(db_path, string.format(
            "SELECT COUNT(*) AS n FROM document WHERE tier = %d AND %s AND (archived_at IS NULL OR archived_at = '');",
            tier, KNOWLEDGE_MEMBER_WHERE
        ))
    end
    session_count = 0
    if db.table_exists(db_path, "agent_session") then
        session_count = count_rows(db_path, "SELECT COUNT(*) AS n FROM agent_session;")
    end
    return {
        tier_counts = tier_counts,
        note_count = count_rows(db_path, string.format(
            "SELECT COUNT(*) AS n FROM document WHERE %s AND (archived_at IS NULL OR archived_at = '');", KNOWLEDGE_MEMBER_WHERE
        )),
        retrieval_count = count_rows(db_path, "SELECT COUNT(*) AS n FROM knowledge_retrieval;"),
        reviewed_note_count = count_rows(db_path, "SELECT COUNT(DISTINCT document_id) AS n FROM knowledge_retrieval_hit WHERE reviewed_at IS NOT NULL;"),
        session_count = session_count,
    }
end

function knowledge.recent_retrievals(db_path, limit)
    if limit == nil then
        limit = 10
    end
    rows = db.query(db_path, string.format(
        "SELECT id, query_text, hit_count, created_at FROM knowledge_retrieval ORDER BY id DESC LIMIT %d;",
        tonumber(limit)
    ))
    if rows == nil then
        return {}
    end
    return rows
end

-- Sorted by raw heat (an index-backed ORDER BY, not a per-row Lua
-- decay computation) -- an approximate, not exact, decayed ordering.
-- Exact enough for a listing command; each row's own effective_heat
-- field (added below) is the exact figure review/promotion decisions
-- actually use. Restricted to documents that are actually "in the
-- pool" (see KNOWLEDGE_MEMBER_WHERE) -- an ordinary, never-retrieved
-- document doesn't show up here just because it exists.
-- Attaches the conserved-pool effective_heat to every row and re-sorts
-- descending by it -- SQL's own ORDER BY can no longer approximate this
-- ranking (unlike the old wall-clock model, raw_heat alone isn't
-- comparable across rows without each one's own scale_at_write, since
-- that's stamped at a different moment per row). No LIMIT on either
-- caller's query, so sorting the full result set in Lua after fetching
-- loses nothing a SQL-side ORDER BY would have preserved.
function attach_and_sort_by_pool_heat(db_path, rows)
    document.ensure_pool_state(db_path)
    state_rows = db.query(db_path, "SELECT log_pool_scale FROM knowledge_pool_state WHERE id = 1;")
    pool_scale = 1.0
    if state_rows != nil and state_rows[1] != nil then
        pool_scale = math.exp(tonumber(state_rows[1].log_pool_scale))
    end
    for _, row in ipairs(rows) do
        row.effective_heat = document.pool_effective_heat(row.raw_heat, row.scale_at_write, pool_scale)
    end
    table.sort(rows, function(a, b)
        return a.effective_heat > b.effective_heat
    end)
    return rows
end

function knowledge.list_documents(db_path, tier)
    query = string.format(
        "SELECT * FROM document WHERE %s AND (archived_at IS NULL OR archived_at = '')", KNOWLEDGE_MEMBER_WHERE
    )
    if tier != nil then
        query = query .. " AND tier = " .. tostring(tonumber(tier))
    end
    query = query .. " ORDER BY retrieval_count DESC;"
    rows = db.query(db_path, query)
    if rows == nil then
        return {}
    end
    return attach_and_sort_by_pool_heat(db_path, rows)
end

-- Documents with at least one review recorded against them (a reviewed
-- knowledge_retrieval_hit) -- backs /knowledge's "reviewed
-- notes" stat, same reused table view as tier documents
-- (html.render_knowledge_documents).
function knowledge.reviewed_documents(db_path)
    rows = db.query(db_path, """
        SELECT * FROM document
        WHERE id IN (SELECT DISTINCT document_id FROM knowledge_retrieval_hit WHERE reviewed_at IS NOT NULL)
          AND (archived_at IS NULL OR archived_at = '')
        ORDER BY retrieval_count DESC;
    """)
    if rows == nil then
        return {}
    end
    rows = attach_and_sort_by_pool_heat(db_path, rows)
    return rows
end

-- An empty table that dkjson encodes as [] rather than {}.
function json_array()
    return setmetatable({}, {__jsontype = "array"})
end

-- Backs /knowledge-graph-data (doc/knowledge-graph-explorer.md, Phase
-- 2): every active document, not just knowledge.list_documents' own
-- narrower "pool member" set (KNOWLEDGE_MEMBER_WHERE -- retrieved at
-- least once, or system/agent-derived). A document can carry real
-- document_link edges (an authored [[title]] reference) without ever
-- having been searched -- the graph explorer's job is to show link
-- structure, the same way Obsidian's own graph view includes every
-- note, not just ones some usage threshold happens to select.
function knowledge.graph_nodes(db_path)
    rows = db.query(db_path, """
        SELECT id, title, tier, raw_heat, scale_at_write FROM document
        WHERE (archived_at IS NULL OR archived_at = '') AND merged_into IS NULL;
    """)
    if rows == nil then
        return {}
    end
    rows = attach_and_sort_by_pool_heat(db_path, rows)
    tags, groups = knowledge.document_tag_labels(db_path)
    nodes = {}
    for _, row in ipairs(rows) do
        node_tags = tags[tonumber(row.id)]
        if node_tags == nil then
            node_tags = json_array()
        end
        node_groups = groups[tonumber(row.id)]
        if node_groups == nil then
            node_groups = json_array()
        end
        table.insert(nodes, {id = tonumber(row.id), title = row.title, tier = tonumber(row.tier), heat = row.effective_heat,
            tags = node_tags, groups = node_groups})
    end
    return nodes
end

-- document id -> its tag labels (doc/structure-layers.md): active
-- memberships a person pinned or the clustering job computed, on
-- active tags -- pinned first, then best score first, so a node's first
-- tag is the one to colour it by. "excluded" memberships count as absent.
-- Second return: document id -> the broader tags (tag.parent) those sit
-- under, same order, each once; a tag with no parent is its own group.
function knowledge.document_tag_labels(db_path)
    rows = db.query(db_path, """
        SELECT dt.document AS document_id, t.label AS label, p.label AS parent_label
        FROM document_tag dt
        JOIN tag t ON t.id = dt.tag
        LEFT JOIN tag p ON p.id = t.parent AND (p.archived_at IS NULL OR p.archived_at = '')
        WHERE dt.decision IN ('computed', 'pinned')
          AND (dt.archived_at IS NULL OR dt.archived_at = '')
          AND (t.archived_at IS NULL OR t.archived_at = '')
        ORDER BY dt.document, CASE WHEN dt.decision = 'pinned' THEN 0 ELSE 1 END, dt.score DESC;
    """)
    labels = {}
    groups = {}
    seen_group = {}
    if rows == nil then
        return labels, groups
    end
    for _, row in ipairs(rows) do
        doc_id = tonumber(row.document_id)
        if labels[doc_id] == nil then
            labels[doc_id] = json_array()
            groups[doc_id] = json_array()
            seen_group[doc_id] = {}
        end
        table.insert(labels[doc_id], row.label)
        group = row.parent_label
        if group == nil or group == "" then
            group = row.label
        end
        if seen_group[doc_id][group] == nil then
            seen_group[doc_id][group] = true
            table.insert(groups[doc_id], group)
        end
    end
    return labels, groups
end

function knowledge.set_tier(db_path, document_id, tier)
    db.exec(db_path, string.format(
        "UPDATE document SET tier = %d, updated_at = %s WHERE id = %d;",
        tonumber(tier), db.now_expr(db_path), tonumber(document_id)
    ))
end

--------------------------------------------------------------------------
-- CLI: `daat knowledge <stats|list|show|promote>`
--------------------------------------------------------------------------

function knowledge.do_knowledge(cmd_args, db_path)
    action = cmd_args[1]

    if action == "stats" then
        s = knowledge.stats(db_path)
        print(string.format("tier0=%d tier1=%d tier2=%d tier3=%d",
            s.tier_counts[0], s.tier_counts[1], s.tier_counts[2], s.tier_counts[3]))
        print("notes=" .. tostring(s.note_count) .. " retrievals=" .. tostring(s.retrieval_count) ..
            " reviewed=" .. tostring(s.reviewed_note_count) .. " sessions=" .. tostring(s.session_count))
        return
    end

    if action == "list" then
        tier = tonumber(cmd_args[2])
        rows = knowledge.list_documents(db_path, tier)
        for _, row in ipairs(rows) do
            print(string.format("#%s [tier %s] %s (raw_heat=%s, effective=%.2f, retrievals=%s)",
                tostring(row.id), tostring(row.tier), tostring(row.title), tostring(row.raw_heat),
                row.effective_heat, tostring(row.retrieval_count)))
        end
        return
    end

    if action == "show" then
        document_id = tonumber(cmd_args[2])
        if document_id == nil then
            print("Usage: daat knowledge show <document_id>")
            return
        end
        doc = knowledge.get_document(db_path, document_id)
        if doc == nil then
            print("Error: no such document #" .. tostring(document_id))
            return
        end
        print("id: " .. tostring(doc.id))
        print("tier: " .. tostring(doc.tier))
        print("title: " .. tostring(doc.title))
        print("raw_heat: " .. tostring(doc.raw_heat) .. " (effective: " .. string.format("%.2f", doc.effective_heat) .. ")")
        print("retrieval_count: " .. tostring(doc.retrieval_count))
        if doc.source_type != nil and doc.source_type != "" then
            print("source: " .. tostring(doc.source_type) .. " #" .. tostring(doc.source_id))
        end
        print("duplicate_of: " .. tostring(doc.duplicate_of))
        print("body:")
        print(tostring(doc.content))
        return
    end

    -- The curate step's queue (src/curate.lua), run by the jobs worker.
    if action == "curate-pending" then
        limit = tonumber(cmd_args[2])
        for _, line in ipairs(require("curate").run_pending(db_path, limit, "system")) do
            print(line)
        end
        return
    end

    if action == "promote" then
        document_id = tonumber(cmd_args[2])
        tier = tonumber(cmd_args[3])
        if document_id == nil or tier == nil then
            print("Usage: daat knowledge promote <document_id> <tier>")
            return
        end
        doc = knowledge.get_document(db_path, document_id)
        if doc == nil then
            print("Error: no document #" .. tostring(document_id))
            return
        end
        if tier != 0 and not knowledge.can_hold_tier(doc.source_type) then
            print("Error: document #" .. tostring(document_id) .. " is a source; only documents the curation wrote hold tiers 1-3 (doc/tier-curation-ladder.md)")
            return
        end
        knowledge.set_tier(db_path, document_id, tier)
        print("Document #" .. tostring(document_id) .. " set to tier " .. tostring(tier))
        return
    end

    -- How the passage gate sees a pair, or (with --pairs) every
    -- "<id> <id>" line of a file, one "<id> <id> <score>" line each.
    if action == "link-score" then
        pairs_file = nil
        wanted = {}
        if cmd_args[2] == "--pairs" and cmd_args[3] != nil then
            pairs_file = io.open(cmd_args[3], "r")
            if pairs_file == nil then
                print("Error: can't read " .. tostring(cmd_args[3]))
                return
            end
            for line in io.lines(cmd_args[3]) do
                a, b = string.match(line, "^%s*(%d+)%s+(%d+)")
                if a != nil then
                    table.insert(wanted, {tonumber(a), tonumber(b)})
                end
            end
            io.close(pairs_file)
        elseif tonumber(cmd_args[2]) != nil and tonumber(cmd_args[3]) != nil then
            table.insert(wanted, {tonumber(cmd_args[2]), tonumber(cmd_args[3])})
        else
            print("Usage: daat knowledge link-score <document_id> <document_id> | --pairs <file>")
            return
        end
        for _, pair in ipairs(wanted) do
            doc_a = knowledge.get_document(db_path, pair[1])
            doc_b = knowledge.get_document(db_path, pair[2])
            score = nil
            pa = nil
            pb = nil
            if doc_a == nil or doc_b == nil then
                pa = "no such document"
            else
                score, pa, pb = knowledge.link_similarity(db_path, doc_a, doc_b)
            end
            if pairs_file != nil then
                shown = "NA"
                if score != nil then
                    shown = string.format("%.4f", score)
                end
                print(string.format("%d %d %s", pair[1], pair[2], shown))
            elseif score == nil then
                print("Can't measure: " .. tostring(pa))
            else
                threshold = config.platform_config().link_passage_gate
                verdict = "stops it"
                if threshold <= 0 or score >= threshold then
                    verdict = "passes"
                end
                print(string.format("best passage pair similarity: %.4f (gate %.3f: %s)", score, threshold, verdict))
                print("#" .. tostring(pair[1]) .. " at character " .. tostring(pa.offset - 1) .. ":\n" .. string.sub(pa.text, 1, 600))
                print("#" .. tostring(pair[2]) .. " at character " .. tostring(pb.offset - 1) .. ":\n" .. string.sub(pb.text, 1, 600))
            end
        end
        return
    end

    print("Usage: daat knowledge <stats|list [tier]|show <document_id>|promote <document_id> <tier>|curate-pending [N]|link-score <id> <id>|distill>")
end

return knowledge
