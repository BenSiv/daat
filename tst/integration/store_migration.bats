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
