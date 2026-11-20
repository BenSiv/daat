-- Low-level Knowledge Pool schema, document-note store helpers, and review
-- threshold shared by knowledge, curate, synthesize, and distill without
-- circular module dependencies.

const db = require("database")
const document = require("document")
const entity = require("entity")
const store = require("store")

const knowledge_store = {}

const KNOWLEDGE_SCHEMA = """
CREATE TABLE IF NOT EXISTS knowledge_retrieval (
    id INTEGER PRIMARY KEY {{AUTOINC}},
    session_id TEXT,
    author VARCHAR(255),
    query_text TEXT,
    hit_count INTEGER NOT NULL DEFAULT 0,
    status VARCHAR(32) NOT NULL DEFAULT 'reviewed',
    claim_token VARCHAR(64),
    claimed_at TEXT,
    reviewed_at TEXT,
    created_at TEXT DEFAULT ({{NOW}})
);

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
    aspect INTEGER DEFAULT NULL,
    PRIMARY KEY (retrieval_id, document_id)
);

CREATE TABLE IF NOT EXISTS knowledge_link_review (
    document_a_id INTEGER NOT NULL,
    document_b_id INTEGER NOT NULL,
    last_co_count INTEGER NOT NULL,
    decision VARCHAR(32) NOT NULL,
    reason TEXT DEFAULT NULL,
    evaluated_at TEXT DEFAULT ({{NOW}}),
    PRIMARY KEY (document_a_id, document_b_id)
);

CREATE TABLE IF NOT EXISTS document_tier_judgment (
    document_id INTEGER PRIMARY KEY,
    judged_hash TEXT NOT NULL,
    judged_tier INTEGER NOT NULL,
    evaluated_at TEXT DEFAULT ({{NOW}})
);

CREATE TABLE IF NOT EXISTS knowledge_curation (
    document_id INTEGER PRIMARY KEY,
    source_hash VARCHAR(64) NOT NULL,
    status VARCHAR(32) NOT NULL,
    note_id INTEGER,
    reason TEXT,
    queued_at TEXT DEFAULT ({{NOW}})
);

CREATE TABLE IF NOT EXISTS knowledge_aspect_curation (
    document_id INTEGER NOT NULL,
    aspect INTEGER NOT NULL,
    source_hash VARCHAR(64) NOT NULL,
    status VARCHAR(32) NOT NULL,
    note_id INTEGER,
    reason TEXT,
    queued_at TEXT DEFAULT ({{NOW}}),
    PRIMARY KEY (document_id, aspect)
);

CREATE TABLE IF NOT EXISTS knowledge_conversation_curation (
    session_id VARCHAR(255) PRIMARY KEY,
    source_hash VARCHAR(64) NOT NULL,
    status VARCHAR(32) NOT NULL,
    note_id INTEGER,
    reason TEXT,
    queued_at TEXT DEFAULT ({{NOW}}),
    checked_at TEXT
);

CREATE TABLE IF NOT EXISTS knowledge_distillation (
    reference_id INTEGER PRIMARY KEY,
    reference_hash VARCHAR(64) NOT NULL,
    status VARCHAR(32) NOT NULL,
    reason TEXT,
    queued_at TEXT DEFAULT ({{NOW}})
);

CREATE TABLE IF NOT EXISTS knowledge_tag_definition (
    tag_id INTEGER PRIMARY KEY,
    input_hash VARCHAR(64) NOT NULL,
    status VARCHAR(32) NOT NULL,
    document_id INTEGER,
    reason TEXT,
    defined_at TEXT DEFAULT ({{NOW}})
);

CREATE TABLE IF NOT EXISTS knowledge_reference (
    tag_id INTEGER PRIMARY KEY,
    notes_hash VARCHAR(64) NOT NULL,
    status VARCHAR(32) NOT NULL,
    document_id INTEGER,
    reason TEXT,
    queued_at TEXT DEFAULT ({{NOW}})
);
"""
knowledge_store.KNOWLEDGE_SCHEMA = KNOWLEDGE_SCHEMA

function knowledge_schema_sql(db_path)
    sql = string.gsub(KNOWLEDGE_SCHEMA, "{{AUTOINC}}", db.autoincrement_keyword(db_path))
    sql = string.gsub(sql, "{{NOW}}", db.now_expr(db_path))
    return sql
end

function ensure_knowledge_indexes(db_path)
    store.ensure_index(db_path, "knowledge_retrieval_hit", "knowledge_retrieval_document_document_idx",
        "CREATE INDEX knowledge_retrieval_document_document_idx ON knowledge_retrieval_hit(document_id);")
    store.ensure_index(db_path, "knowledge_retrieval", "knowledge_retrieval_status_id_idx",
        "CREATE INDEX knowledge_retrieval_status_id_idx ON knowledge_retrieval(status, id);")
end

function knowledge_store.ensure_retrieval_review_columns(db_path)
    store.ensure_columns(db_path, "knowledge_retrieval", {
        {"author", "VARCHAR(255) DEFAULT NULL"},
        {"status", "VARCHAR(32) NOT NULL DEFAULT 'reviewed'"},
        {"claim_token", "VARCHAR(64) DEFAULT NULL"},
        {"claimed_at", "TEXT DEFAULT NULL"},
        {"reviewed_at", "TEXT DEFAULT NULL"},
    })
end

function knowledge_store.init_schema(db_path)
    db.exec(db_path, knowledge_schema_sql(db_path))
    knowledge_store.ensure_retrieval_review_columns(db_path)
    store.ensure_column(db_path, "knowledge_link_review", "reason", "TEXT DEFAULT NULL")
    store.ensure_column(db_path, "knowledge_retrieval_hit", "aspect", "INTEGER DEFAULT NULL")
    ensure_knowledge_indexes(db_path)
end

const HAND_ROLLED_TABLE_COLUMNS = {
    knowledge_retrieval = {
        {name = "id", note = "primary key"},
        {name = "session_id", note = "agent_session.id this retrieval happened within"},
        {name = "author", note = "login whose search triggered this retrieval"},
        {name = "query_text", note = "the search query text"},
        {name = "hit_count", note = "number of documents this retrieval matched"},
        {name = "status", note = "deferred review state: pending, running, or reviewed"},
        {name = "claim_token", note = "worker token claiming a running deferred review (NULL unless status = 'running')"},
        {name = "claimed_at", note = "when the running review was claimed (NULL unless status = 'running')"},
        {name = "reviewed_at", note = "when reinforcement and review finished (NULL while pending)"},
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
        {name = "aspect", note = "which of the document's aspects found it (document_aspect.aspect; NULL: its own vector or its words)"},
    },
}
knowledge_store.HAND_ROLLED_TABLE_COLUMNS = HAND_ROLLED_TABLE_COLUMNS

function knowledge_store.hand_rolled_sql_columns_text(table_name)
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

const KNOWLEDGE_MEMBER_WHERE = "(retrieval_count > 0 OR (source_type IS NOT NULL AND source_type != ''))"
knowledge_store.KNOWLEDGE_MEMBER_WHERE = KNOWLEDGE_MEMBER_WHERE

const DUE_FOR_REVIEW_RETRIEVAL_COUNT = 2
const DUE_FOR_REVIEW_HEAT = 1.15
knowledge_store.DUE_FOR_REVIEW_RETRIEVAL_COUNT = DUE_FOR_REVIEW_RETRIEVAL_COUNT
knowledge_store.DUE_FOR_REVIEW_HEAT = DUE_FOR_REVIEW_HEAT

function knowledge_store.due_for_review(retrieval_count, effective_heat)
    return tonumber(retrieval_count) >= DUE_FOR_REVIEW_RETRIEVAL_COUNT
        or tonumber(effective_heat) >= DUE_FOR_REVIEW_HEAT
end

function knowledge_store.get_document(db_path, document_id)
    doc = entity.get(db_path, "document", document_id)
    if doc == nil then
        return nil
    end
    document.ensure_pool_state(db_path)
    state_rows = db.query(db_path, "SELECT log_pool_scale FROM knowledge_pool_state WHERE id = 1;")
    log_pool_scale = 0.0
    if state_rows != nil and state_rows[1] != nil then
        log_pool_scale = tonumber(state_rows[1].log_pool_scale)
    end
    doc.effective_heat = document.pool_effective_heat(doc.raw_heat, doc.log_scale_at_write, log_pool_scale)
    return doc
end

function knowledge_store.create_document_note(db_path, author, title, body, source_type, source_id, source_ref)
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

function knowledge_store.session_document_for(db_path, session_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM document WHERE source_type = 'chat_session' AND source_ref = %s LIMIT 1;",
        db.quote(session_id)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

function knowledge_store.sync_session_document(db_path, author, session_id, title, transcript)
    existing = knowledge_store.session_document_for(db_path, session_id)
    if existing != nil then
        document.update_page(db_path, author, existing.id, title, existing.parent_id, transcript, nil)
        return existing.id
    end
    function create_or_update_session_doc()
        locked_existing = knowledge_store.session_document_for(db_path, session_id)
        if locked_existing != nil then
            document.update_page(db_path, author, locked_existing.id, title, locked_existing.parent_id, transcript, nil)
            return locked_existing.id
        end
        folder_id = document.ensure_knowledge_pool_folder(db_path)
        document_id, _ = document.create_page(db_path, author, title, folder_id, transcript, nil)
        if document_id == nil then
            return nil
        end
        db.exec(db_path, string.format(
            "UPDATE document SET source_type = 'chat_session', source_ref = %s WHERE id = %d;",
            db.quote(session_id), document_id
        ))
        return document_id
    end
    return db.with_lock(db_path, "daat_session_doc_" .. tostring(session_id), 30, create_or_update_session_doc)
end

function knowledge_store.set_tier(db_path, document_id, tier)
    db.exec(db_path, string.format(
        "UPDATE document SET tier = %d, updated_at = %s WHERE id = %d;",
        tonumber(tier), db.now_expr(db_path), tonumber(document_id)
    ))
end

return knowledge_store
