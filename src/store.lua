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

SYSTEM_STATE_SCHEMA = """
CREATE TABLE IF NOT EXISTS system_state (
    name VARCHAR(64) PRIMARY KEY,
    text_value LONGTEXT,
    number_value DOUBLE,
    updated_at TEXT DEFAULT (%s)
);
"""

function ensure_system_state(db_path)
    db.exec(db_path, string.format(SYSTEM_STATE_SCHEMA, db.now_expr(db_path)))
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
-- Row ids are kept, so a reply's evaluation lands on its own call.
-- Older layouts have no step_kind/step; those rows get NULL kind.
table.insert(MIGRATIONS, {version = 2, name = "agent_model_call", run = function(db_path)
    if not exists(db_path, "knowledge_context") then
        return
    end
    require("agent").ensure_model_call_table(db_path)
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
        -- One statement, correlated on the call id: thousands of
        -- per-row UPDATEs would be thousands of round trips on MySQL.
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
    ensure_system_state(db_path)
    target = latest_version()
    if current_version(db_path) >= target then
        return
    end
    locked = db.is_mariadb(db_path)
    if locked then
        db.query(db_path, "SELECT GET_LOCK('daat_store_migrate', 600) AS got;")
    end
    ok, err = pcall(function()
        for _, m in ipairs(MIGRATIONS) do
            if current_version(db_path) < m.version then
                m.run(db_path)
                store.set_number(db_path, "store.schema_version", m.version)
            end
        end
    end)
    if locked then
        db.query(db_path, "SELECT RELEASE_LOCK('daat_store_migrate') AS released;")
    end
    if ok == false then
        error("store migration failed: " .. tostring(err))
    end
end

function store.schema_version(db_path)
    return current_version(db_path)
end

store.latest_schema_version = latest_version

return store
