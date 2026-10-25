#!/usr/bin/env bats
# Store migrations (src/store.lua, doc/schema-revision.md): each one is
# tested by building the old layout by hand, running the new binary, and
# checking the new layout -- the same way a deployed store meets them.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init >/dev/null
}

teardown() {
    cleanup_test_env
}

store() {
    sqlite3 "$TEST_DIR/.store/store.db" "$1"
}

has_table() {
    [ "$(store "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '$1';")" = "1" ]
}

# Not `! has_table`: bats doesn't fail a test on a negated command.
lacks_table() {
    [ "$(store "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '$1';")" = "0" ]
}

# Puts the store back to "before migration N" so the next command runs it.
rewind_to() {
    store "UPDATE system_state SET number_value = $1 WHERE name = 'store.schema_version';"
}

@test "a fresh store is created at the latest schema version with system_state" {
    has_table system_state
    run store "SELECT number_value >= 1 FROM system_state WHERE name = 'store.schema_version';"
    [ "$output" = "1" ]
    lacks_table schema_sync_state
    lacks_table tag_evidence_state
    lacks_table tag_upkeep_state
}

@test "migration 1 moves the three checkpoint tables into system_state and keeps them as _legacy" {
    store "CREATE TABLE schema_sync_state (id INTEGER PRIMARY KEY, content_signature TEXT); INSERT INTO schema_sync_state VALUES (1, 'sig-abc');"
    store "CREATE TABLE tag_evidence_state (id INTEGER PRIMARY KEY, fingerprint TEXT NOT NULL); INSERT INTO tag_evidence_state VALUES (1, 'fp-123');"
    store "CREATE TABLE tag_upkeep_state (id INTEGER PRIMARY KEY, merge_cosine REAL NOT NULL); INSERT INTO tag_upkeep_state VALUES (1, 0.12345678901234567);"
    store "DELETE FROM system_state WHERE name != 'store.schema_version';"
    rewind_to 0

    run "$BIN" user list
    [ "$status" -eq 0 ]

    [ "$(store "SELECT text_value FROM system_state WHERE name = 'schema.sync_signature';")" = "sig-abc" ]
    [ "$(store "SELECT text_value FROM system_state WHERE name = 'tag.evidence_fingerprint';")" = "fp-123" ]
    # Full precision survives the move.
    [ "$(store "SELECT number_value = (SELECT merge_cosine FROM tag_upkeep_state_legacy) FROM system_state WHERE name = 'tag.upkeep_merge_cosine';")" = "1" ]
    lacks_table schema_sync_state
    has_table schema_sync_state_legacy
    has_table tag_evidence_state_legacy
    has_table tag_upkeep_state_legacy
}

@test "a store that is already current runs no migration again" {
    store "CREATE TABLE schema_sync_state (id INTEGER PRIMARY KEY, content_signature TEXT); INSERT INTO schema_sync_state VALUES (1, 'stale');"
    run "$BIN" user list
    # Version is current, so the stray old table is left alone.
    has_table schema_sync_state
}

@test "the schema sync signature is read from and written to system_state" {
    run raw_get "/login"
    run store "SELECT COUNT(*) FROM system_state WHERE name = 'schema.sync_signature' AND text_value IS NOT NULL;"
    [ "$output" = "1" ]
}

# Builds knowledge_context / knowledge_chat_eval as they were before
# migration 2. With "phase0" the context table has step_kind/step (the
# layout between 2026-10-23 and the migration); without, the older one
# production still had.
old_context_tables() {
    store "DROP TABLE IF EXISTS agent_model_call;"
    extra_cols=""; extra_vals=""
    if [ "${1:-}" = "phase0" ]; then
        extra_cols=", step_kind VARCHAR(32), step INTEGER"
    fi
    store "CREATE TABLE knowledge_context (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, message_id INTEGER, prompt LONGTEXT, model_id TEXT, reasoning_document_id INTEGER, prompt_tokens INTEGER, completion_tokens INTEGER, total_tokens INTEGER, created_at TEXT DEFAULT (datetime('now'))${extra_cols});"
    store "CREATE TABLE knowledge_chat_eval (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, context_id INTEGER, message_id INTEGER, provider TEXT, model TEXT, reply_kind TEXT, quality_status TEXT, reasoning_status TEXT, action_summary TEXT, user_feedback TEXT, feedback_at TEXT, created_at TEXT DEFAULT (datetime('now')));"
    store "INSERT INTO knowledge_context (id, session_id, message_id, prompt, model_id, prompt_tokens, completion_tokens, total_tokens, created_at) VALUES (7, 's1', 70, '[\"history\"]', 'm', 900, 40, 940, '2026-10-01 10:00:00'), (8, 's1', NULL, '[\"compaction\"]', 'm', 300, 20, 320, '2026-10-01 10:05:00');"
    store "INSERT INTO knowledge_chat_eval (session_id, context_id, message_id, provider, model, reply_kind, quality_status, reasoning_status, action_summary, user_feedback, feedback_at) VALUES ('s1', 7, 70, 'vertex', 'm', 'final', 'ok', 'none', 'reply_kind=final', 'up', '2026-10-01 11:00:00');"
    rewind_to 1
}

@test "migration 2 merges knowledge_context and knowledge_chat_eval into agent_model_call, keeping ids" {
    old_context_tables
    run "$BIN" user list
    [ "$status" -eq 0 ]
    [ "$(store "SELECT id || '|' || message_id || '|' || prompt_tokens || '|' || COALESCE(kind, 'null') || '|' || reply_kind || '|' || provider || '|' || user_feedback FROM agent_model_call WHERE id = 7;")" = "7|70|900|null|final|vertex|up" ]
    # The compaction row had no evaluation.
    [ "$(store "SELECT COALESCE(reply_kind, 'none') || '|' || total_tokens FROM agent_model_call WHERE id = 8;")" = "none|320" ]
    lacks_table knowledge_context
    lacks_table knowledge_chat_eval
    has_table knowledge_context_legacy
    has_table knowledge_chat_eval_legacy
    # New calls continue after the copied ids.
    [ "$(store "SELECT COUNT(*) FROM agent_model_call;")" = "2" ]
}

@test "migration 2 carries step_kind and step from the Phase 0 layout" {
    old_context_tables phase0
    store "UPDATE knowledge_context SET step_kind = 'chat', step = 3 WHERE id = 7;"
    run "$BIN" user list
    [ "$(store "SELECT kind || ':' || step FROM agent_model_call WHERE id = 7;")" = "chat:3" ]
}

@test "after migration 2, chat feedback and new calls use agent_model_call" {
    old_context_tables
    run "$BIN" user list
    [ "$(store "SELECT MAX(id) FROM agent_model_call;")" = "8" ]
    "$BIN" user add admin secret123 ia >/dev/null
    read session csrf < <(login_test_user "carol" "i")
    cookie="session=${session}; csrf=${csrf}"
    chat=$(json_body "$(raw_post_json "/api/chat-widget-start" '{"title":"x"}' "$cookie" "$csrf" "")" | jq -r '.session_id')
    raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${chat}\",\"message\":\"hi\"}" "$cookie" "$csrf" "$(done_response "Hello.")" >/dev/null
    [ "$(store "SELECT MIN(id) > 8 FROM agent_model_call WHERE session_id = '${chat}';")" = "1" ]
}

@test "migration 3 moves extension and view approvals into system_approval" {
    store "CREATE TABLE extension_approval (name VARCHAR(255) PRIMARY KEY, capabilities_json TEXT NOT NULL, approved_by TEXT, approved_at TEXT);"
    store "CREATE TABLE view_approval (name VARCHAR(255) PRIMARY KEY, sql_text TEXT NOT NULL, approved_by TEXT, approved_at TEXT);"
    store "INSERT INTO extension_approval VALUES ('task', '{\"ui\":true}', 'admin', '2026-09-01 00:00:00');"
    store "INSERT INTO view_approval VALUES ('stock', 'SELECT 1', 'admin', '2026-09-02 00:00:00');"
    rewind_to 2
    run "$BIN" user list
    [ "$status" -eq 0 ]
    [ "$(store "SELECT kind || '|' || name || '|' || approved_content || '|' || approved_by FROM system_approval ORDER BY kind;")" = "extension|task|{\"ui\":true}|admin
view|stock|SELECT 1|admin" ]
    lacks_table extension_approval
    lacks_table view_approval
    has_table extension_approval_legacy
}

@test "migration 4 moves dropdown values into entity_dropdown_value and new lists still register" {
    store "DROP TABLE IF EXISTS entity_dropdown_value;"
    store "CREATE TABLE dropdown_list (name VARCHAR(255) PRIMARY KEY, created_at TEXT);"
    store "CREATE TABLE dropdown_value (list_name VARCHAR(255) NOT NULL, value VARCHAR(255) NOT NULL, value_order INTEGER NOT NULL, PRIMARY KEY (list_name, value), FOREIGN KEY (list_name) REFERENCES dropdown_list(name));"
    store "INSERT INTO dropdown_list (name) VALUES ('colour'); INSERT INTO dropdown_value VALUES ('colour', 'red', 1), ('colour', 'green', 2);"
    rewind_to 3
    run "$BIN" user list
    [ "$status" -eq 0 ]
    [ "$(store "SELECT group_concat(value, ',') FROM (SELECT value FROM entity_dropdown_value WHERE list_name = 'colour' ORDER BY value_order);")" = "red,green" ]
    lacks_table dropdown_list
    lacks_table dropdown_value
    has_table dropdown_list_legacy

    mkdir -p dropdowns
    printf 'return {name = "texture", values = {"soft", "hard"}}\n' > dropdowns/texture.lua
    run raw_get "/login"
    [ "$(store "SELECT COUNT(*) FROM entity_dropdown_value WHERE list_name = 'texture';")" = "2" ]
}

@test "migration 5 renames tables to their domain names, keeping their rows" {
    "$BIN" user add olduser secret123 i >/dev/null
    # Put the auth tables back under their old names, as an old store has them.
    store "ALTER TABLE auth_user RENAME TO user; ALTER TABLE auth_api_key RENAME TO api_key; ALTER TABLE auth_email_link RENAME TO password_reset;"
    rewind_to 4
    run "$BIN" user list
    [ "$status" -eq 0 ]
    [[ "$output" =~ "olduser" ]]
    has_table auth_user
    has_table auth_api_key
    has_table auth_email_link
    lacks_table user
    lacks_table password_reset
    # And the renamed table is the live one: login works.
    run login_test_user "newone" "i"
    [ "$(store "SELECT COUNT(*) FROM auth_user WHERE login IN ('olduser', 'newone');")" = "2" ]
}

@test "a rename that finds an empty new table from a failed run replaces it; one with rows stops" {
    store "ALTER TABLE entity_ref RENAME TO entity_source;" 2>/dev/null || store "CREATE TABLE entity_source (id INTEGER PRIMARY KEY, from_type TEXT);"
    store "CREATE TABLE IF NOT EXISTS entity_ref (id INTEGER PRIMARY KEY, from_type TEXT);"
    rewind_to 4
    run "$BIN" user list
    [ "$status" -eq 0 ]
    lacks_table entity_source
    has_table entity_ref

    store "CREATE TABLE system_job_x (id INTEGER);"
    store "ALTER TABLE system_job RENAME TO extension_job; CREATE TABLE system_job (job_id INTEGER PRIMARY KEY); INSERT INTO system_job VALUES (1);"
    rewind_to 4
    run "$BIN" user list
    [[ "$output" =~ "both exist and system_job has rows" ]]
}

@test "migration 6 renames the retrieval hit table and folds each hit's review into it" {
    store "DROP TABLE IF EXISTS knowledge_retrieval_hit;"
    store "CREATE TABLE knowledge_retrieval_document (retrieval_id INTEGER NOT NULL, document_id INTEGER NOT NULL, \`rank\` INTEGER, score REAL, tier_weight REAL, reinforcement_delta REAL, PRIMARY KEY (retrieval_id, document_id));"
    store "CREATE TABLE knowledge_review (id INTEGER PRIMARY KEY AUTOINCREMENT, retrieval_id INTEGER NOT NULL, document_id INTEGER NOT NULL, atomicity_status TEXT, connectivity_status TEXT, duplication_status TEXT, title_status TEXT, action_summary TEXT, created_at TEXT);"
    store "INSERT INTO knowledge_retrieval_document VALUES (1, 10, 1, 0.9, 1.0, 0.5), (1, 11, 2, 0.4, 1.0, 0.2);"
    store "INSERT INTO knowledge_review (retrieval_id, document_id, atomicity_status, connectivity_status, duplication_status, title_status, created_at) VALUES (1, 10, 'atomic', 'linked', 'unique', 'ok', '2026-10-01 12:00:00');"
    rewind_to 5
    run "$BIN" user list
    [ "$status" -eq 0 ]
    [ "$(store "SELECT atomicity_status || '|' || title_status || '|' || reviewed_at FROM knowledge_retrieval_hit WHERE document_id = 10;")" = "atomic|ok|2026-10-01 12:00:00" ]
    [ "$(store "SELECT COALESCE(reviewed_at, 'none') || '|' || score FROM knowledge_retrieval_hit WHERE document_id = 11;")" = "none|0.4" ]
    lacks_table knowledge_retrieval_document
    lacks_table knowledge_review
    has_table knowledge_review_legacy
}

@test "SQL written with an old table name is refused with its new name" {
    "$BIN" user add admin secret123 ia >/dev/null
    read session csrf < <(login_test_user "dora" "i")
    cookie="session=${session}; csrf=${csrf}"
    chat=$(json_body "$(raw_post_json "/api/chat-widget-start" '{"title":"x"}' "$cookie" "$csrf" "")" | jq -r '.session_id')
    scripted="$(tool_call_response "entity.query" '{"sql":"SELECT * FROM entity_source"}')"$'\1'"$(done_response "Done.")"
    raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${chat}\",\"message\":\"lineage\"}" "$cookie" "$csrf" "$scripted" >/dev/null
    run latest_tool_result "$chat"
    [[ "$output" =~ "'entity_source' was renamed to 'entity_ref'" ]]
}
