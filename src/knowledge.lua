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
-- Retrieval/review bookkeeping (knowledge_retrieval, knowledge_
-- retrieval_document, knowledge_review) stays in its own hand-rolled
-- tables here -- these are event logs (one row per retrieval/review
-- event), not pool content, so they don't belong on `document` itself.

db = require("db")
document = require("document")
entity = require("entity")

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
CREATE TABLE IF NOT EXISTS knowledge_retrieval_document (
    retrieval_id INTEGER NOT NULL,
    document_id INTEGER NOT NULL,
    `rank` INTEGER,
    score REAL,
    tier_weight REAL,
    reinforcement_delta REAL,
    PRIMARY KEY (retrieval_id, document_id)
);

CREATE TABLE IF NOT EXISTS knowledge_review (
    id INTEGER PRIMARY KEY %s,
    retrieval_id INTEGER NOT NULL,
    document_id INTEGER NOT NULL,
    atomicity_status TEXT,
    connectivity_status TEXT,
    duplication_status TEXT,
    title_status TEXT,
    action_summary TEXT,
    created_at TEXT DEFAULT (%s)
);

-- The actual prompt/reasoning/token record per chat turn (see
-- doc/architecture.md's "Knowledge pool" section, "Full prompt/
-- reasoning/token persistence"). Linked to `agent_message` (the
-- assistant response this context produced) -- platform-wip's own
-- immutable, append-only chat log is the natural anchor here.
-- `reasoning_document_id` points at a document (source_type='reasoning')
-- rather than storing reasoning text inline -- reasoning goes through
-- the exact same tiering/retrieval/decay pipeline as everything else,
-- not a second parallel log.
CREATE TABLE IF NOT EXISTS knowledge_context (
    id INTEGER PRIMARY KEY %s,
    session_id TEXT NOT NULL,
    message_id INTEGER,
    -- LONGTEXT, not TEXT -- this column stores the full JSON-encoded
    -- message history sent to the model, which routinely exceeds
    -- MariaDB's plain TEXT's 65,535-byte cap (same bug class as
    -- document.content/entity_event.field_changes -- see schema.lua's
    -- SQL_TYPE.text).
    prompt LONGTEXT,
    model_id TEXT,
    reasoning_document_id INTEGER,
    prompt_tokens INTEGER,
    completion_tokens INTEGER,
    total_tokens INTEGER,
    created_at TEXT DEFAULT (%s)
);

-- Per-reply classification + user feedback (see doc/architecture.md's
-- "Chat-reply evaluation + user feedback"). `message_id` is denormalized
-- here (also reachable via context_id -> knowledge_context.message_id)
-- so the feedback route can look a row up directly from what the chat
-- widget already has rendered, without a join.
CREATE TABLE IF NOT EXISTS knowledge_chat_eval (
    id INTEGER PRIMARY KEY %s,
    session_id TEXT NOT NULL,
    context_id INTEGER,
    message_id INTEGER,
    provider TEXT,
    model TEXT,
    reply_kind TEXT,
    quality_status TEXT,
    reasoning_status TEXT,
    action_summary TEXT,
    user_feedback TEXT,
    feedback_at TEXT,
    created_at TEXT DEFAULT (%s)
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

"""

function knowledge_schema_sql(db_path)
    return string.format(KNOWLEDGE_SCHEMA,
        db.autoincrement_keyword(db_path), db.now_expr(db_path),
        db.autoincrement_keyword(db_path), db.now_expr(db_path),
        db.autoincrement_keyword(db_path), db.now_expr(db_path),
        db.autoincrement_keyword(db_path), db.now_expr(db_path),
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
        {name = "knowledge_retrieval_document_document_idx", table = "knowledge_retrieval_document",
         sql = "CREATE INDEX knowledge_retrieval_document_document_idx ON knowledge_retrieval_document(document_id);"},
        {name = "knowledge_context_message_idx", table = "knowledge_context",
         sql = "CREATE INDEX knowledge_context_message_idx ON knowledge_context(message_id);"},
        {name = "knowledge_chat_eval_message_idx", table = "knowledge_chat_eval",
         sql = "CREATE INDEX knowledge_chat_eval_message_idx ON knowledge_chat_eval(message_id);"},
    }
    for _, idx in ipairs(indexes) do
        if db.index_exists(db_path, idx.table, idx.name) == false then
            db.exec(db_path, idx.sql)
        end
    end
end

function knowledge.init_schema(db_path)
    db.exec(db_path, knowledge_schema_sql(db_path))
    ensure_knowledge_indexes(db_path)
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
    state_rows = db.query(db_path, "SELECT pool_scale FROM knowledge_pool_state WHERE id = 1;")
    pool_scale = 1.0
    if state_rows != nil and state_rows[1] != nil then
        pool_scale = state_rows[1].pool_scale
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
        "%s knowledge_retrieval_document (retrieval_id, document_id, `rank`, score, tier_weight, reinforcement_delta) " ..
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
-- one knowledge_review row per document for audit. Retitling only ever
-- applies to system/agent-derived documents (source_type set) -- a
-- real user-authored document's title is never rewritten out from under
-- them, even if it happens to look generic ("note", "untitled", ...).
-- `author` attributes any resulting distillation (knowledge.
-- maybe_distill) to the real user whose retrieval actually triggered it
-- -- reactive, tied to real usage, not a synthetic actor.
function knowledge.review_retrieval(db_path, retrieval_id, author)
    rows = db.query(db_path, string.format(
        "SELECT document_id FROM knowledge_retrieval_document WHERE retrieval_id = %d;", tonumber(retrieval_id)
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
            -- recompute it here.
            if knowledge.due_for_review(tonumber(doc.retrieval_count), doc.effective_heat) then
                maturity = document.processing_maturity(db_path, doc.id, body, doc.source_type)
                target_tier = document.promotion_target_tier(tonumber(doc.tier), is_duplicate, maturity.revised, content_shape)
            end

            db.exec(db_path, string.format(
                "UPDATE document SET tier = %d, title = %s, updated_at = %s WHERE id = %d;",
                target_tier, db.literal(new_title), db.now_expr(db_path), doc.id
            ))
            db.exec(db_path, string.format(
                "INSERT INTO knowledge_review (retrieval_id, document_id, atomicity_status, connectivity_status, duplication_status, title_status) " ..
                "VALUES (%d, %d, %s, %s, %s, %s);",
                tonumber(retrieval_id), doc.id, db.quote(content_shape), db.quote(connectivity), db.quote(duplication), db.quote(title_status)
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

-- Persists the exact prompt (system_prompt .. history, verbatim, not
-- reconstructed later from agent_message rows) plus real token counts
-- for one model call. `reasoning_document_id` is optional -- filled in
-- by the caller only when the reply's own reasoning was split out into
-- its own document (source_type='reasoning'), not every turn. `usage`
-- is the {prompt_tokens, completion_tokens, total_tokens} table
-- agent_provider.generate's third return value now carries (real
-- counts from Vertex, estimated-but-present under the test provider) --
-- every field is nil-safe since a provider without usage metadata at
-- all shouldn't fail this call over accounting.
function knowledge.record_context(db_path, session_id, message_id, prompt, model_id, reasoning_document_id, usage)
    if usage == nil then
        usage = {}
    end
    _, context_id = db.exec(db_path, string.format(
        "INSERT INTO knowledge_context (session_id, message_id, prompt, model_id, reasoning_document_id, prompt_tokens, completion_tokens, total_tokens) " ..
        "VALUES (%s, %s, %s, %s, %s, %s, %s, %s);",
        db.quote(session_id), db.literal(tonumber(message_id)), db.quote(prompt), db.quote(model_id),
        db.literal(tonumber(reasoning_document_id)), db.literal(usage.prompt_tokens), db.literal(usage.completion_tokens),
        db.literal(usage.total_tokens)
    ))
    return context_id
end

-- Records one chat-reply evaluation row -- classification is rule-based
-- today (knowledge.classify_reply); nothing here requires an extra
-- model call.
function knowledge.record_chat_eval(db_path, session_id, context_id, message_id, provider, model, is_error, reply_text)
    reply_kind, quality_status, reasoning_status = knowledge.classify_reply(is_error, reply_text)
    action_summary = string.format("reply_kind=%s; quality=%s; reasoning=%s", reply_kind, quality_status, reasoning_status)
    _, eval_id = db.exec(db_path, string.format(
        "INSERT INTO knowledge_chat_eval (session_id, context_id, message_id, provider, model, reply_kind, quality_status, reasoning_status, action_summary) " ..
        "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s);",
        db.quote(session_id), db.literal(tonumber(context_id)), db.literal(tonumber(message_id)),
        db.quote(provider), db.quote(model), db.quote(reply_kind), db.quote(quality_status),
        db.quote(reasoning_status), db.quote(action_summary)
    ))
    return eval_id
end

-- The user-feedback half of chat evaluation -- looked up by message_id
-- (what the chat widget already has rendered for each reply), not an
-- eval id the frontend was never told about. Checks existence with a
-- real SELECT first, not db.exec's own return value -- sqlite_update
-- and mariadb_update disagree on what their first return value even
-- means (plain `true` vs. a real affected-row count), which is exactly
-- why every other UPDATE call site in this codebase already ignores it
-- too.
function knowledge.record_chat_feedback(db_path, message_id, feedback)
    rows = db.query(db_path, string.format(
        "SELECT id FROM knowledge_chat_eval WHERE message_id = %d;", tonumber(message_id)
    ))
    if rows == nil or rows[1] == nil then
        return false
    end
    db.exec(db_path, string.format(
        "UPDATE knowledge_chat_eval SET user_feedback = %s, feedback_at = %s WHERE message_id = %d;",
        db.quote(feedback), db.now_expr(db_path), tonumber(message_id)
    ))
    return true
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
-- review pass, let alone the search request that triggered it.
DISTILL_MODEL = "gemini-2.5-flash"

DISTILL_SYSTEM_PROMPT = """
Extract the single core idea from the following document into a new, concise, self-contained note in your own words -- not a verbatim copy. Remove anything not essential to that one idea. Reply with the distilled note text only: no title, no preamble, no commentary. If the document already covers exactly one focused idea and there is nothing meaningful to extract, reply with exactly: NONE
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
    distilled, err = agent_provider.generate(DISTILL_MODEL, DISTILL_SYSTEM_PROMPT, body)
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

LINK_EVALUATION_MODEL = DISTILL_MODEL

LINK_EVALUATION_SYSTEM_PROMPT = """
Two documents from the same knowledge pool have repeatedly been retrieved together in the same searches. Judge whether they describe a genuinely meaningful connection (the same topic, a real dependency, one explains or extends the other) as opposed to just coincidental overlap in unrelated searches. Reply with exactly one word: YES if they are genuinely related enough to link explicitly, or NO if not.
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
        FROM knowledge_retrieval_document a
        JOIN knowledge_retrieval_document b ON a.retrieval_id = b.retrieval_id AND a.document_id < b.document_id
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

function knowledge.record_link_review(db_path, document_a_id, document_b_id, co_count, decision)
    db.exec(db_path, string.format(
        "%s knowledge_link_review (document_a_id, document_b_id, last_co_count, decision, evaluated_at) VALUES (%d, %d, %d, %s, %s);",
        db.replace_into(db_path), tonumber(document_a_id), tonumber(document_b_id),
        tonumber(co_count), db.quote(decision), db.now_expr(db_path)
    ))
end

function knowledge.document_link_exists(db_path, document_a_id, document_b_id)
    rows = db.query(db_path, string.format("""
        SELECT 1 FROM document_link
        WHERE (from_document_id = %d AND to_document_id = %d) OR (from_document_id = %d AND to_document_id = %d)
        LIMIT 1;
    """, tonumber(document_a_id), tonumber(document_b_id), tonumber(document_b_id), tonumber(document_a_id)))
    return rows != nil and rows[1] != nil
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
    if review.decision == "linked" then
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

        if knowledge.document_link_exists(db_path, doc_a_id, doc_b_id) == false then
            review = knowledge.get_link_review(db_path, doc_a_id, doc_b_id)
            if knowledge.due_for_link_review(review, co_count) then
                doc_a = knowledge.get_document(db_path, doc_a_id)
                doc_b = knowledge.get_document(db_path, doc_b_id)
                if doc_a != nil and doc_b != nil then
                    if knowledge.co_retrieval_eligible(co_count, tonumber(doc_a.retrieval_count), tonumber(doc_b.retrieval_count)) then
                        knowledge.evaluate_co_retrieval_pair(db_path, doc_a, doc_b, co_count)
                    end
                end
            end
        end
    end
end

function knowledge.evaluate_co_retrieval_pair(db_path, doc_a, doc_b, co_count)
    agent_provider = require("agent_provider")
    body_a = doc_a.content
    if body_a == nil then
        body_a = ""
    end
    body_b = doc_b.content
    if body_b == nil then
        body_b = ""
    end
    prompt = string.format(
        "Document A -- %s:\n%s\n\nDocument B -- %s:\n%s",
        tostring(doc_a.title), body_a, tostring(doc_b.title), body_b
    )
    answer, err = agent_provider.generate(LINK_EVALUATION_MODEL, LINK_EVALUATION_SYSTEM_PROMPT, prompt)
    if answer == nil then
        return
    end
    answer = string.upper(string.gsub(answer, "^%s*(.-)%s*$", "%1"))

    if answer == "YES" then
        db.exec(db_path, string.format(
            "%s document_link (from_document_id, to_document_id, link_text, source) VALUES (%d, %d, %s, 'co-retrieval');",
            db.insert_ignore(db_path), doc_a.id, doc_b.id, db.quote(doc_b.title)
        ))
        knowledge.record_link_review(db_path, doc_a.id, doc_b.id, co_count, "linked")
    else
        knowledge.record_link_review(db_path, doc_a.id, doc_b.id, co_count, "declined")
    end
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
-- would otherwise fight over the same knowledge_retrieval_document audit
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
    delta = document.spreading_delta(base_delta, #neighbors)
    for _, neighbor in ipairs(neighbors) do
        neighbor_id = tonumber(neighbor.id)
        if neighbor_id != nil and hit_ids[neighbor_id] == nil then
            neighbor_doc = knowledge.get_document(db_path, neighbor_id)
            if neighbor_doc != nil then
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
                    "%s knowledge_retrieval_document (retrieval_id, document_id, `rank`, score, tier_weight, reinforcement_delta) " ..
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
    results = document.search(db_path, query_text, limit, use_semantic)
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
    return results, retrieval_id
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
        reviewed_note_count = count_rows(db_path, "SELECT COUNT(DISTINCT document_id) AS n FROM knowledge_review;"),
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
    state_rows = db.query(db_path, "SELECT pool_scale FROM knowledge_pool_state WHERE id = 1;")
    pool_scale = 1.0
    if state_rows != nil and state_rows[1] != nil then
        pool_scale = state_rows[1].pool_scale
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

-- Documents with at least one review recorded against them (distinct
-- document_id in knowledge_review) -- backs /knowledge's "reviewed
-- notes" stat, same reused table view as tier documents
-- (html.render_knowledge_documents).
function knowledge.reviewed_documents(db_path)
    rows = db.query(db_path, """
        SELECT * FROM document
        WHERE id IN (SELECT DISTINCT document_id FROM knowledge_review)
          AND (archived_at IS NULL OR archived_at = '')
        ORDER BY retrieval_count DESC;
    """)
    if rows == nil then
        return {}
    end
    rows = attach_and_sort_by_pool_heat(db_path, rows)
    return rows
end

function knowledge.set_tier(db_path, document_id, tier)
    db.exec(db_path, string.format(
        "UPDATE document SET tier = %d, updated_at = %s WHERE id = %d;",
        tonumber(tier), db.now_expr(db_path), tonumber(document_id)
    ))
end

--------------------------------------------------------------------------
-- CLI: `platform knowledge <stats|list|show|promote>`
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
            print("Usage: platform knowledge show <document_id>")
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

    if action == "promote" then
        document_id = tonumber(cmd_args[2])
        tier = tonumber(cmd_args[3])
        if document_id == nil or tier == nil then
            print("Usage: platform knowledge promote <document_id> <tier>")
            return
        end
        knowledge.set_tier(db_path, document_id, tier)
        print("Document #" .. tostring(document_id) .. " set to tier " .. tostring(tier))
        return
    end

    print("Usage: platform knowledge <stats|list [tier]|show <document_id>|promote <document_id> <tier>|distill>")
end

return knowledge
