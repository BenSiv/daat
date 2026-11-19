-- The store's own bookkeeping: `system_state` (named single values a
-- deployment keeps between requests) and the schema migrations that
-- move an existing store from one table layout to the next.
--
-- Migrations (doc/schema-revision.md) run before any module creates its
-- tables, from every entry point that opens the store: cgi.handle_request,
-- main.lua's CLI dispatch, and `daat init`. They have to run first: the
-- modules' CREATE TABLE IF NOT EXISTS would otherwise create an empty
-- table under a new name before the migration could rename the old one
-- into its place.
--
-- Each migration is idempotent and checks the real schema, so a store
-- in any state -- fresh, old, or half-migrated after a failure -- ends
-- up in the same place. The store's schema version (system_state
-- 'store.schema_version') only lets an up-to-date store skip the checks
-- with one query. On MySQL the whole run holds one named lock and
-- re-reads the version under it: the first requests after a deploy
-- would otherwise migrate concurrently, and DDL isn't transactional.
--
-- Merged or replaced tables are renamed to <name>_legacy, not dropped,
-- so nothing is lost if a migration turns out wrong; a later migration
-- drops them once a release has run on the new layout.

db = require("database")

store = {}

-- SQL expression evaluating to 'YYYY-MM-DD HH:MM:SS' `seconds` in the
-- past, on the exact same clock and timezone basis as `db.now_expr`
-- (`datetime('now', 'localtime')` on SQLite, `NOW()` on MariaDB/MySQL) --
-- avoids both localtime-vs-UTC drift and client-vs-database clock skew.
function store.ago_expr(db_path, seconds)
    secs = math.max(0, math.floor(tonumber(seconds)))
    if db.is_mariadb(db_path) then
        return string.format("DATE_FORMAT(DATE_SUB(NOW(), INTERVAL %d SECOND), '%%Y-%%m-%%d %%H:%%i:%%S')", secs)
    end
    return string.format("datetime('now', 'localtime', '-%d seconds')", secs)
end

SYSTEM_STATE_SCHEMA = """
CREATE TABLE IF NOT EXISTS system_state (
    name VARCHAR(64) PRIMARY KEY,
    text_value LONGTEXT,
    number_value DOUBLE,
    updated_at TEXT DEFAULT (%s)
);
"""

-- An admin's approval of one named thing whose exact content was
-- reviewed: an extension's capabilities (JSON), a saved view's SQL
-- text. Approval holds only while the current content still matches
-- (extension.is_approved, view.is_approved), so an edit after approval
-- needs approving again.
SYSTEM_APPROVAL_SCHEMA = """
CREATE TABLE IF NOT EXISTS system_approval (
    kind VARCHAR(16) NOT NULL,
    name VARCHAR(255) NOT NULL,
    approved_content LONGTEXT NOT NULL,
    approved_by TEXT,
    approved_at TEXT DEFAULT (%s),
    PRIMARY KEY (kind, name)
);
"""

function ensure_system_state(db_path)
    db.exec(db_path, string.format(SYSTEM_STATE_SCHEMA, db.now_expr(db_path)))
end

function store.ensure_system_tables(db_path)
    ensure_system_state(db_path)
    db.exec(db_path, string.format(SYSTEM_APPROVAL_SCHEMA, db.now_expr(db_path)))
end

-- store.approved_content(db_path, kind, name) -> content | nil
function store.approved_content(db_path, kind, name)
    rows = db.query(db_path, string.format("SELECT approved_content FROM system_approval WHERE kind = %s AND name = %s;",
        db.quote(kind), db.quote(name)))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1].approved_content
end

function store.approve(db_path, kind, name, content, approved_by)
    db.exec(db_path, string.format("%s system_approval (kind, name, approved_content, approved_by, approved_at) VALUES (%s, %s, %s, %s, %s);",
        db.replace_into(db_path), db.quote(kind), db.quote(name), db.quote(content), db.literal(approved_by), db.now_expr(db_path)))
end

function store.revoke(db_path, kind, name)
    db.exec(db_path, string.format("DELETE FROM system_approval WHERE kind = %s AND name = %s;", db.quote(kind), db.quote(name)))
end

-- store.get_text / store.get_number(db_path, name) -> value | nil
function store.get_text(db_path, name)
    rows = db.query(db_path, string.format("SELECT text_value FROM system_state WHERE name = %s;", db.quote(name)))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1].text_value
end

function store.get_number(db_path, name)
    rows = db.query(db_path, string.format("SELECT number_value FROM system_state WHERE name = %s;", db.quote(name)))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return tonumber(rows[1].number_value)
end

function store.set_text(db_path, name, value)
    db.exec(db_path, string.format("%s system_state (name, text_value, number_value, updated_at) VALUES (%s, %s, NULL, %s);",
        db.replace_into(db_path), db.quote(name), db.literal(value), db.now_expr(db_path)))
end

-- Full precision (%.17g): a value written and read back must compare
-- equal to itself.
function store.set_number(db_path, name, value)
    db.exec(db_path, string.format("%s system_state (name, text_value, number_value, updated_at) VALUES (%s, NULL, %.17g, %s);",
        db.replace_into(db_path), db.quote(name), value, db.now_expr(db_path)))
end

--------------------------------------------------------------------------
-- Migration helpers
--------------------------------------------------------------------------

function exists(db_path, table_name)
    return db.table_exists(db_path, table_name)
end

function columns_of(db_path, table_name)
    have = {}
    for _, name in ipairs(db.get_columns(db_path, table_name)) do
        have[name] = true
    end
    return have
end

function store.has_column(db_path, table_name, column_name)
    return columns_of(db_path, table_name)[column_name] == true
end

-- Race-safe additive column helper across SQLite and MySQL/MariaDB:
-- concurrent workers adding the same column tolerate "Duplicate column name"
-- as long as the column exists afterwards.
function store.ensure_column(db_path, table_name, column_name, column_sql)
    if store.has_column(db_path, table_name, column_name) then
        return false
    end
    ok_col, col_err = pcall(db.exec, db_path, "ALTER TABLE " .. table_name .. " ADD COLUMN " .. column_name .. " " .. column_sql .. ";")
    if ok_col == false and not store.has_column(db_path, table_name, column_name) then
        error(col_err)
    end
    return true
end

function store.ensure_columns(db_path, table_name, specs)
    if not exists(db_path, table_name) then
        return
    end
    have = columns_of(db_path, table_name)
    for _, spec in ipairs(specs) do
        col_name = spec[1]
        col_sql = spec[2]
        if have[col_name] != true then
            ok_col, col_err = pcall(db.exec, db_path, "ALTER TABLE " .. table_name .. " ADD COLUMN " .. col_name .. " " .. col_sql .. ";")
            if ok_col == false and not store.has_column(db_path, table_name, col_name) then
                error(col_err)
            end
            have[col_name] = true
        end
    end
end

function store.ensure_index(db_path, table_name, index_name, index_sql)
    if db.index_exists(db_path, table_name, index_name) then
        return
    end
    ok_idx, idx_err = pcall(db.exec, db_path, index_sql)
    if ok_idx == false and not db.index_exists(db_path, table_name, index_name) then
        error(idx_err)
    end
end

function row_count(db_path, table_name)
    rows = db.query(db_path, "SELECT COUNT(*) AS n FROM " .. table_name .. ";")
    if rows == nil or rows[1] == nil then
        return 0
    end
    return tonumber(rows[1].n)
end

-- Renames `old` to `new` when only `old` exists. When both exist and
-- `new` is empty (created by a run that failed before the rename), the
-- empty one is dropped first. Both present with rows in `new` is a
-- state no migration produces, so it stops rather than guess.
function store.rename_table(db_path, old, new)
    if not exists(db_path, old) then
        return
    end
    if exists(db_path, new) then
        if row_count(db_path, new) > 0 then
            error("cannot rename " .. old .. " to " .. new .. ": both exist and " .. new .. " has rows")
        end
        db.exec(db_path, "DROP TABLE " .. new .. ";")
    end
    db.exec(db_path, "ALTER TABLE " .. old .. " RENAME TO " .. new .. ";")
end

-- Moves a replaced table out of the way, keeping its rows.
function store.retire_table(db_path, old)
    if not exists(db_path, old) then
        return
    end
    legacy = old .. "_legacy"
    if exists(db_path, legacy) then
        db.exec(db_path, "DROP TABLE " .. legacy .. ";")
    end
    db.exec(db_path, "ALTER TABLE " .. old .. " RENAME TO " .. legacy .. ";")
end

--------------------------------------------------------------------------
-- Migrations, in order. Never edit one that has shipped; add a new one.
--------------------------------------------------------------------------

MIGRATIONS = {}

-- 1. Checkpoint values that each had a one-row table move to system_state.
table.insert(MIGRATIONS, {version = 1, name = "checkpoints into system_state", run = function(db_path)
    if exists(db_path, "schema_sync_state") then
        rows = db.query(db_path, "SELECT content_signature FROM schema_sync_state WHERE id = 1;")
        if rows != nil and rows[1] != nil and rows[1].content_signature != nil then
            store.set_text(db_path, "schema.sync_signature", rows[1].content_signature)
        end
        store.retire_table(db_path, "schema_sync_state")
    end
    if exists(db_path, "tag_evidence_state") then
        rows = db.query(db_path, "SELECT fingerprint FROM tag_evidence_state WHERE id = 1;")
        if rows != nil and rows[1] != nil and rows[1].fingerprint != nil then
            store.set_text(db_path, "tag.evidence_fingerprint", rows[1].fingerprint)
        end
        store.retire_table(db_path, "tag_evidence_state")
    end
    if exists(db_path, "tag_upkeep_state") then
        rows = db.query(db_path, "SELECT merge_cosine FROM tag_upkeep_state WHERE id = 1;")
        if rows != nil and rows[1] != nil and tonumber(rows[1].merge_cosine) != nil then
            store.set_number(db_path, "tag.upkeep_merge_cosine", tonumber(rows[1].merge_cosine))
        end
        store.retire_table(db_path, "tag_upkeep_state")
    end
end})

-- 2. knowledge_context (one row per model call) and knowledge_chat_eval
-- (one row per chat reply, keyed to its call) become agent_model_call.
-- Frozen self-contained SQL (never calls live require("agent") methods).
table.insert(MIGRATIONS, {version = 2, name = "agent_model_call", run = function(db_path)
    if not exists(db_path, "knowledge_context") then
        return
    end
    db.exec(db_path, string.format("""
        CREATE TABLE IF NOT EXISTS agent_model_call (
            id INTEGER PRIMARY KEY %s,
            session_id VARCHAR(255) NOT NULL,
            message_id INTEGER,
            kind VARCHAR(32),
            step INTEGER,
            provider VARCHAR(64),
            model_id TEXT,
            prompt LONGTEXT,
            reasoning_document_id INTEGER,
            prompt_tokens INTEGER,
            completion_tokens INTEGER,
            total_tokens INTEGER,
            reply_kind VARCHAR(32),
            quality_status VARCHAR(32),
            reasoning_status VARCHAR(32),
            action_summary TEXT,
            user_feedback VARCHAR(16),
            feedback_at TEXT,
            created_at TEXT DEFAULT (%s)
        );
    """, db.autoincrement_keyword(db_path), db.now_expr(db_path)))
    store.ensure_index(db_path, "agent_model_call", "agent_model_call_message_idx",
        "CREATE INDEX agent_model_call_message_idx ON agent_model_call(message_id);")
    if row_count(db_path, "agent_model_call") > 0 then
        error("agent_model_call already has rows; not copying knowledge_context over them")
    end
    have = columns_of(db_path, "knowledge_context")
    kind_expr = "NULL"
    if have["step_kind"] == true then
        kind_expr = "step_kind"
    end
    step_expr = "NULL"
    if have["step"] == true then
        step_expr = "step"
    end
    db.exec(db_path, "INSERT INTO agent_model_call (id, session_id, message_id, kind, step, model_id, prompt, reasoning_document_id, " ..
        "prompt_tokens, completion_tokens, total_tokens, created_at) " ..
        "SELECT id, session_id, message_id, " .. kind_expr .. ", " .. step_expr .. ", model_id, prompt, reasoning_document_id, " ..
        "prompt_tokens, completion_tokens, total_tokens, created_at FROM knowledge_context;")
    if exists(db_path, "knowledge_chat_eval") then
        sets = {}
        for _, pair in ipairs({{"provider", "provider"}, {"reply_kind", "reply_kind"}, {"quality_status", "quality_status"},
                {"reasoning_status", "reasoning_status"}, {"action_summary", "action_summary"},
                {"user_feedback", "user_feedback"}, {"feedback_at", "feedback_at"}}) do
            table.insert(sets, pair[1] .. " = (SELECT e." .. pair[2] .. " FROM knowledge_chat_eval e WHERE e.context_id = agent_model_call.id ORDER BY e.id DESC LIMIT 1)")
        end
        db.exec(db_path, "UPDATE agent_model_call SET " .. table.concat(sets, ", ") ..
            " WHERE id IN (SELECT context_id FROM knowledge_chat_eval WHERE context_id IS NOT NULL);")
        store.retire_table(db_path, "knowledge_chat_eval")
    end
    store.retire_table(db_path, "knowledge_context")
end})

-- 3. extension_approval and view_approval become system_approval rows.
table.insert(MIGRATIONS, {version = 3, name = "system_approval", run = function(db_path)
    store.ensure_system_tables(db_path)
    for _, old in ipairs({{"extension_approval", "extension", "capabilities_json"}, {"view_approval", "view", "sql_text"}}) do
        if exists(db_path, old[1]) then
            db.exec(db_path, "INSERT INTO system_approval (kind, name, approved_content, approved_by, approved_at) SELECT " ..
                db.quote(old[2]) .. ", name, " .. old[3] .. ", approved_by, approved_at FROM " .. old[1] .. ";")
            store.retire_table(db_path, old[1])
        end
    end
end})

-- 4. dropdown_list (names only) and dropdown_value become
-- entity_dropdown_value. Frozen self-contained SQL.
table.insert(MIGRATIONS, {version = 4, name = "entity_dropdown_value", run = function(db_path)
    db.exec(db_path, """
        CREATE TABLE IF NOT EXISTS entity_dropdown_value (
            list_name VARCHAR(255) NOT NULL,
            value VARCHAR(255) NOT NULL,
            value_order INTEGER NOT NULL,
            PRIMARY KEY (list_name, value)
        );
    """)
    if exists(db_path, "dropdown_value") then
        db.exec(db_path, "INSERT INTO entity_dropdown_value (list_name, value, value_order) SELECT list_name, value, value_order FROM dropdown_value;")
        store.retire_table(db_path, "dropdown_value")
    end
    store.retire_table(db_path, "dropdown_list")
end})

-- 5. One prefix per domain (doc/schema-revision.md, "Naming proposal").
-- Plain renames: same columns, same rows, same index names.
STORE_RENAMES = {
    {"user", "auth_user"},
    {"api_key", "auth_api_key"},
    {"password_reset", "auth_email_link"},
    {"entity_source", "entity_ref"},
    {"reference_name", "entity_name_index"},
    {"reference_prefix", "entity_name_prefix"},
    {"document_reference", "document_mention"},
    {"extension_job", "system_job"},
    {"knowledge_tier_review", "document_tier_judgment"},
}
store.RENAMED_TABLES = {}
for _, pair in ipairs(STORE_RENAMES) do
    store.RENAMED_TABLES[pair[1]] = pair[2]
end
table.insert(MIGRATIONS, {version = 5, name = "domain table names", run = function(db_path)
    for _, pair in ipairs(STORE_RENAMES) do
        store.rename_table(db_path, pair[1], pair[2])
    end
end})

-- 6. knowledge_retrieval_document (one row per document a retrieval
-- returned) becomes knowledge_retrieval_hit and takes in
-- knowledge_review's outcome for the same (retrieval, document); the
-- review's unused action_summary isn't carried over.
table.insert(MIGRATIONS, {version = 6, name = "knowledge_retrieval_hit", run = function(db_path)
    if exists(db_path, "knowledge_retrieval_document") then
        store.rename_table(db_path, "knowledge_retrieval_document", "knowledge_retrieval_hit")
    end
    if not exists(db_path, "knowledge_retrieval_hit") then
        return
    end
    have = columns_of(db_path, "knowledge_retrieval_hit")
    for _, column in ipairs({"atomicity_status", "connectivity_status", "duplication_status", "title_status"}) do
        if have[column] != true then
            db.exec(db_path, "ALTER TABLE knowledge_retrieval_hit ADD COLUMN " .. column .. " VARCHAR(32) DEFAULT NULL;")
        end
    end
    if have["reviewed_at"] != true then
        db.exec(db_path, "ALTER TABLE knowledge_retrieval_hit ADD COLUMN reviewed_at TEXT DEFAULT NULL;")
    end
    if exists(db_path, "knowledge_review") then
        -- The latest review per (retrieval, document), in one statement.
        latest = "(SELECT %s FROM knowledge_review r WHERE r.retrieval_id = knowledge_retrieval_hit.retrieval_id " ..
            "AND r.document_id = knowledge_retrieval_hit.document_id ORDER BY r.id DESC LIMIT 1)"
        sets = {}
        for _, pair in ipairs({{"atomicity_status", "r.atomicity_status"}, {"connectivity_status", "r.connectivity_status"},
                {"duplication_status", "r.duplication_status"}, {"title_status", "r.title_status"}, {"reviewed_at", "r.created_at"}}) do
            table.insert(sets, pair[1] .. " = " .. string.format(latest, pair[2]))
        end
        db.exec(db_path, "UPDATE knowledge_retrieval_hit SET " .. table.concat(sets, ", ") ..
            " WHERE EXISTS (SELECT 1 FROM knowledge_review r WHERE r.retrieval_id = knowledge_retrieval_hit.retrieval_id AND r.document_id = knowledge_retrieval_hit.document_id);")
        store.retire_table(db_path, "knowledge_review")
    end
end})

-- 7. Tiers restart from 0 (doc/tier-curation-ladder.md): every document
-- above tier 0 in production was an unprocessed source, labelled by a
-- judge that saw only its body. Only documents the curation writes can
-- hold a tier from here on; old judgments are cleared so they're made
-- again under the new rule. Content is untouched.
table.insert(MIGRATIONS, {version = 7, name = "tier reset for the curation ladder", run = function(db_path)
    if exists(db_path, "document") then
        db.exec(db_path, "UPDATE document SET tier = 0 WHERE tier IS NOT NULL AND tier != 0;")
    end
    if exists(db_path, "document_tier_judgment") then
        db.exec(db_path, "DELETE FROM document_tier_judgment;")
    end
end})

-- 8. Agent messages are typed (doc/agent-data.md, "Storage";
-- doc/chat-history-migration.md, step 1). Frozen self-contained SQL.
table.insert(MIGRATIONS, {version = 8, name = "typed agent messages", run = function(db_path)
    if not exists(db_path, "agent_message") then
        return
    end
    store.ensure_columns(db_path, "agent_message", {
        {"data_type", "VARCHAR(16)"},
        {"loop_kind", "VARCHAR(16)"},
        {"parent_message_id", "INTEGER"},
    })
    store.ensure_columns(db_path, "agent_model_call", {{"parent_message_id", "INTEGER"}})
    store.ensure_columns(db_path, "agent_background_task", {{"parent_message_id", "INTEGER"}})
    db.exec(db_path, """
        UPDATE agent_message SET data_type = CASE role
            WHEN 'user' THEN 'request'
            WHEN 'assistant' THEN 'answer'
            WHEN 'progress' THEN 'answer'
            WHEN 'tool_result' THEN 'tool_trace'
            WHEN 'compaction_summary' THEN 'reasoning'
            WHEN 'self_check' THEN 'reasoning'
            WHEN 'decision' THEN 'request'
            WHEN 'error' THEN 'control'
            ELSE 'control'
        END WHERE data_type IS NULL;
    """)
    db.exec(db_path, """
        UPDATE agent_message SET loop_kind = CASE role
            WHEN 'compaction_summary' THEN 'compaction'
            WHEN 'self_check' THEN 'self_check'
            ELSE 'chat'
        END WHERE loop_kind IS NULL;
    """)
end})

-- 9. Widens agent_message.content (and pending_action/background_task
-- payload columns) from TEXT (65,535 bytes on MariaDB/MySQL) to
-- LONGTEXT. Frozen self-contained SQL.
table.insert(MIGRATIONS, {version = 9, name = "agent payload columns longtext", run = function(db_path)
    if not db.is_mariadb(db_path) then
        return
    end
    for _, spec in ipairs({
        {"agent_message", "MODIFY COLUMN content LONGTEXT NOT NULL"},
        {"agent_pending_action", "MODIFY COLUMN args_json LONGTEXT NOT NULL"},
        {"agent_background_task", "MODIFY COLUMN question LONGTEXT NOT NULL, MODIFY COLUMN last_error LONGTEXT, MODIFY COLUMN result LONGTEXT"},
    }) do
        if exists(db_path, spec[1]) then
            db.exec(db_path, "ALTER TABLE " .. spec[1] .. " " .. spec[2] .. ";")
        end
    end
end})

-- 10. Deferred retrieval review (doc/tier-curation-ladder.md, Phase 2).
-- Frozen self-contained SQL.
table.insert(MIGRATIONS, {version = 10, name = "deferred retrieval review queue", run = function(db_path)
    if not exists(db_path, "knowledge_retrieval") then
        return
    end
    store.ensure_columns(db_path, "knowledge_retrieval", {
        {"author", "VARCHAR(255) DEFAULT NULL"},
        {"status", "VARCHAR(32) NOT NULL DEFAULT 'reviewed'"},
        {"claim_token", "VARCHAR(64) DEFAULT NULL"},
        {"claimed_at", "TEXT DEFAULT NULL"},
        {"reviewed_at", "TEXT DEFAULT NULL"},
    })
    store.ensure_index(db_path, "knowledge_retrieval", "knowledge_retrieval_status_id_idx",
        "CREATE INDEX knowledge_retrieval_status_id_idx ON knowledge_retrieval(status, id);")
end})

-- 11. Full log-space per-document heat scale (`log_scale_at_write`,
-- backfilled from `LN(scale_at_write)`) plus atomic active-pool
-- membership flag (`pool_active`), and resyncing `document_count`.
-- Frozen self-contained SQL.
function migrate_pool_conservation_columns(db_path)
    if not exists(db_path, "document") then
        return
    end
    active_where = "(archived_at IS NULL OR archived_at = '') AND merged_into IS NULL"
    have = columns_of(db_path, "document")
    if have["merged_into"] != true then
        store.ensure_column(db_path, "document", "merged_into", "INTEGER")
    end
    if have["log_scale_at_write"] != true then
        store.ensure_column(db_path, "document", "log_scale_at_write", "REAL NOT NULL DEFAULT 0.0")
        if have["scale_at_write"] == true then
            db.exec(db_path, "UPDATE document SET log_scale_at_write = LN(scale_at_write) WHERE scale_at_write IS NOT NULL AND scale_at_write > 0 AND scale_at_write != 1.0;")
        end
    end
    if have["pool_active"] != true then
        store.ensure_column(db_path, "document", "pool_active", "INTEGER NOT NULL DEFAULT 0")
        db.exec(db_path, "UPDATE document SET pool_active = 1 WHERE " .. active_where .. ";")
    end
    if exists(db_path, "knowledge_pool_state") then
        db.exec(db_path, "UPDATE document SET pool_active = CASE WHEN " .. active_where .. " THEN 1 ELSE 0 END;")
        crows = db.query(db_path, "SELECT COUNT(*) AS n FROM document WHERE pool_active = 1;")
        cnt = 0
        if crows != nil and crows[1] != nil then
            cnt = tonumber(crows[1].n)
        end
        db.exec(db_path, string.format("UPDATE knowledge_pool_state SET document_count = %d WHERE id = 1;", cnt))
    end
end

table.insert(MIGRATIONS, {version = 11, name = "log_scale_at_write and pool_active conservation columns", run = migrate_pool_conservation_columns})

-- 12. Consolidates scattered module-level additive columns into one
-- versioned, race-safe migration pass across existing core tables.
table.insert(MIGRATIONS, {version = 12, name = "consolidate core module columns", run = function(db_path)
    store.ensure_columns(db_path, "entity_event", {{"reason", "TEXT"}})
    store.ensure_columns(db_path, "entity_type", {
        {"require_reason_on_update", "INTEGER DEFAULT 0"},
        {"require_reason_on_archive", "INTEGER DEFAULT 0"},
        {"admin_write_only", "INTEGER DEFAULT 0"},
    })
    store.ensure_columns(db_path, "entity_field", {
        {"display", "INTEGER DEFAULT 0"},
        {"allowed_entity_types", "LONGTEXT"},
        {"identifier", "INTEGER DEFAULT 0"},
    })
    store.ensure_columns(db_path, "auth_user", {
        {"email", "VARCHAR(255) DEFAULT NULL"},
        {"email_verified_at", "INTEGER DEFAULT NULL"},
        {"session_version", "INTEGER NOT NULL DEFAULT 0"},
    })
    store.ensure_columns(db_path, "auth_email_link", {
        {"purpose", "VARCHAR(16) NOT NULL DEFAULT 'reset'"},
        {"email", "VARCHAR(255) DEFAULT NULL"},
    })
    store.ensure_columns(db_path, "document", {
        {"tier", "INTEGER DEFAULT 0"},
        {"heat", "REAL DEFAULT 1.0"},
        {"retrieval_count", "INTEGER DEFAULT 0"},
        {"last_retrieved_at", "TEXT"},
        {"source_type", "TEXT"},
        {"source_id", "INTEGER"},
        {"source_ref", "TEXT"},
        {"content_hash", "TEXT"},
        {"duplicate_of", "INTEGER"},
        {"merged_into", "INTEGER"},
        {"raw_heat", "REAL DEFAULT 1.0"},
        {"scale_at_write", "REAL DEFAULT 1.0"},
        {"log_scale_at_write", "REAL NOT NULL DEFAULT 0.0"},
        {"pool_active", "INTEGER NOT NULL DEFAULT 0"},
    })
    store.ensure_columns(db_path, "document_embedding", {
        {"vector_packed", "BLOB"},
        {"text_hash", "VARCHAR(64)"},
        {"body_chars", "INTEGER"},
    })
    if exists(db_path, "knowledge_pool_state") and not store.has_column(db_path, "knowledge_pool_state", "log_pool_scale") then
        store.ensure_column(db_path, "knowledge_pool_state", "log_pool_scale", "REAL NOT NULL DEFAULT 0.0")
        prows = db.query(db_path, "SELECT pool_scale FROM knowledge_pool_state WHERE id = 1;")
        if prows != nil and prows[1] != nil and tonumber(prows[1].pool_scale) != nil and tonumber(prows[1].pool_scale) > 0 then
            db.exec(db_path, string.format(
                "UPDATE knowledge_pool_state SET log_pool_scale = %.17g WHERE id = 1;",
                math.log(tonumber(prows[1].pool_scale))))
        end
    end
    store.ensure_columns(db_path, "knowledge_retrieval_hit", {{"aspect", "INTEGER DEFAULT NULL"}})
    store.ensure_columns(db_path, "knowledge_link_review", {{"reason", "TEXT DEFAULT NULL"}})
    store.ensure_columns(db_path, "entity_name_index", {{"distinctive", "INTEGER NOT NULL DEFAULT 1"}})
end})

function latest_version()
    latest = 0
    for _, m in ipairs(MIGRATIONS) do
        if m.version > latest then
            latest = m.version
        end
    end
    return latest
end

function current_version(db_path)
    version = store.get_number(db_path, "store.schema_version")
    if version == nil then
        return 0
    end
    return version
end

-- store.migrate(db_path): brings the store's tables to the current
-- layout. Cheap when already current: one query.
function store.migrate(db_path)
    target = latest_version()
    ok_ver, ver = pcall(current_version, db_path)
    if ok_ver == true and ver >= target then
        return
    end
    store.ensure_system_tables(db_path)
    if current_version(db_path) >= target then
        return
    end
    function run_pending_migrations()
        ran_migration = false
        for _, m in ipairs(MIGRATIONS) do
            if current_version(db_path) < m.version then
                m.run(db_path)
                store.set_number(db_path, "store.schema_version", m.version)
                ran_migration = true
            end
        end
        if ran_migration then
            store.set_text(db_path, "web.builtin_schema_signature", nil)
        end
    end
    ok, err = pcall(db.with_lock, db_path, "daat_store_migrate", 600, run_pending_migrations)
    if ok == false then
        error("store migration failed: " .. tostring(err))
    end
end

function store.schema_version(db_path)
    return current_version(db_path)
end

store.latest_schema_version = latest_version

return store
