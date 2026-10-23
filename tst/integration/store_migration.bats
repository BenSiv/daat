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
