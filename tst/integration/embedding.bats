#!/usr/bin/env bats

# Embedding upkeep (src/document.lua, DOCUMENT_EMBEDDING_SCHEMA): a save
# queues the document, `daat document embed-pending` embeds it once it
# has been quiet for embedding_quiet_minutes; archiving drops what was
# derived from a document and unarchiving rebuilds it; `daat repair
# knowledge` clears leftovers. The test helper's default config embeds on
# save (embedding_quiet_minutes = 0); tests of the quiet period set it.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
}

teardown() {
    cleanup_test_env
}

db() {
    sqlite3 .store/store.db "$1"
}

new_document() {
    "$BIN" entity create document title="$1" content="$2" >/dev/null
    db "SELECT id FROM document WHERE title = '$1';"
}

# Moves a queued document's last save back past the quiet period.
backdate_queue() {
    db "UPDATE document_embedding_due SET queued_at = '2000-01-01 00:00:00' WHERE document_id = $1;"
}

@test "a save waits for the quiet period, then is embedded once however many saves came before" {
    write_platform_config ", embedding_quiet_minutes = 5"
    id=$(new_document "Fermentation" "first draft")
    "$BIN" entity update document "$id" content="second draft" >/dev/null
    "$BIN" entity update document "$id" content="third draft" >/dev/null
    [ "$(db "SELECT COUNT(*) FROM document_embedding;")" = "0" ]
    [ "$(db "SELECT COUNT(*) FROM document_embedding_due WHERE document_id = $id;")" = "1" ]

    run "$BIN" document embed-pending
    [[ "$output" =~ "Embedded 0, unchanged 0, failed 0, dropped 0 (archived); 1 still waiting" ]]
    [ "$(db "SELECT COUNT(*) FROM document_embedding;")" = "0" ]

    backdate_queue "$id"
    run "$BIN" document embed-pending
    [[ "$output" =~ "Embedded 1, unchanged 0, failed 0, dropped 0 (archived); 0 still waiting" ]]
    [ "$(db "SELECT COUNT(*) FROM document_embedding WHERE document_id = $id AND text_hash IS NOT NULL;")" = "1" ]
    [ "$(db "SELECT COUNT(*) FROM document_embedding_due;")" = "0" ]
}

@test "a queued document whose text came back unchanged isn't re-embedded" {
    id=$(new_document "Cocoa" "same text")
    db "UPDATE document_embedding SET updated_at = '2000-01-01 00:00:00' WHERE document_id = $id;"
    write_platform_config ", embedding_quiet_minutes = 5"
    db "INSERT INTO document_embedding_due (document_id, queued_at) VALUES ($id, '2000-01-01 00:00:00');"

    run "$BIN" document embed-pending
    [[ "$output" =~ "Embedded 0, unchanged 1" ]]
    [ "$(db "SELECT updated_at FROM document_embedding WHERE document_id = $id;")" = "2000-01-01 00:00:00" ]
}

@test "a document archived while queued leaves the queue without an embedding" {
    write_platform_config ", embedding_quiet_minutes = 5"
    id=$(new_document "Draft" "never kept")
    "$BIN" entity archive document "$id" >/dev/null
    db "INSERT INTO document_embedding_due (document_id, queued_at) VALUES ($id, '2000-01-01 00:00:00');"

    run "$BIN" document embed-pending
    [[ "$output" =~ "Embedded 0, unchanged 0, failed 0, dropped 1 (archived)" ]]
    [ "$(db "SELECT COUNT(*) FROM document_embedding;")" = "0" ]
}

@test "archiving drops a document's embedding and references and archives its links; unarchiving rebuilds them" {
    target=$(new_document "Media protocol" "how to make the medium")
    id=$(new_document "Run notes" "followed [[Media protocol]]")
    db "INSERT INTO document_reference (document_id, entity_type, entity_id) VALUES ($id, 'sample', 1);"
    [ "$(db "SELECT COUNT(*) FROM document_embedding WHERE document_id = $id;")" = "1" ]

    "$BIN" entity archive document "$id" >/dev/null
    [ "$(db "SELECT COUNT(*) FROM document_embedding WHERE document_id = $id;")" = "0" ]
    [ "$(db "SELECT COUNT(*) FROM document_reference WHERE document_id = $id;")" = "0" ]
    [ "$(db "SELECT COUNT(*) FROM document_link WHERE from_document_id = $id AND (archived_at IS NULL OR archived_at = '');")" = "0" ]

    "$BIN" entity unarchive document "$id" >/dev/null
    [ "$(db "SELECT COUNT(*) FROM document_embedding WHERE document_id = $id;")" = "1" ]
    [ "$(db "SELECT COUNT(*) FROM document_link WHERE from_document_id = $id AND to_document_id = $target AND (archived_at IS NULL OR archived_at = '');")" = "1" ]
}

@test "repair knowledge clears rows left by archived or missing documents and tags, once; a dry run writes nothing" {
    id=$(new_document "Kept" "active document")
    gone=$(new_document "Gone" "archived before drop_derived existed")
    db "UPDATE document SET archived_at = '2026-01-01 00:00:00' WHERE id = $gone;"
    db "INSERT INTO document_embedding (document_id, model, vector_json) VALUES (999, 'test-embedding', '[1]');"
    db "INSERT INTO document_reference (document_id, entity_type, entity_id) VALUES (999, 'sample', 1);"
    db "INSERT INTO document_link (from_document_id, to_document_id, link_text, link_hash) VALUES ($gone, $id, 'Kept', 'h1');"
    db "INSERT INTO tag_centre (tag_id, members, sum_json) VALUES (999, 1, '[1]');"

    run "$BIN" repair knowledge --dry-run
    [[ "$output" =~ "2 embeddings of archived or missing documents: would be deleted" ]]
    [[ "$output" =~ "1 references from archived or missing documents: would be deleted" ]]
    [[ "$output" =~ "1 live links from archived or missing documents: would be archived" ]]
    [[ "$output" =~ "1 centres of archived or missing tags: would be deleted" ]]
    [ "$(db "SELECT COUNT(*) FROM document_embedding;")" = "3" ]

    run "$BIN" repair knowledge
    [[ "$output" =~ "2 embeddings of archived or missing documents: deleted" ]]
    [ "$(db "SELECT COUNT(*) FROM document_embedding;")" = "1" ]
    [ "$(db "SELECT COUNT(*) FROM document_reference;")" = "0" ]
    [ "$(db "SELECT COUNT(*) FROM tag_centre;")" = "0" ]
    [ "$(db "SELECT COUNT(*) FROM document_link WHERE from_document_id = $gone AND (archived_at IS NULL OR archived_at = '');")" = "0" ]

    run "$BIN" repair knowledge
    [[ "$output" =~ "0 embeddings of archived or missing documents: deleted" ]]
    [[ "$output" =~ "0 live links from archived or missing documents: archived" ]]
}

@test "repair knowledge counts embeddings from another model but keeps them" {
    id=$(new_document "Old vector" "embedded by a previous model")
    db "UPDATE document_embedding SET model = 'older-model' WHERE document_id = $id;"

    run "$BIN" repair knowledge
    [[ "$output" =~ "1 embeddings from another model than test-embedding" ]]
    [ "$(db "SELECT COUNT(*) FROM document_embedding WHERE document_id = $id;")" = "1" ]
}

@test "repair embeddings only redoes what's missing, from another model or of changed text; --all redoes everything" {
    a=$(new_document "Alpha" "one")
    b=$(new_document "Beta" "two")
    c=$(new_document "Gamma" "three")
    d=$(new_document "Delta" "four")
    db "DELETE FROM document_embedding WHERE document_id = $a;"
    # Text changed behind the hooks' back (a raw SQL write).
    db "UPDATE document SET content = 'four, revised' WHERE id = $d;"
    db "UPDATE document_embedding SET model = 'older-model' WHERE document_id = $b;"
    # Made before text_hash existed: taken as current.
    db "UPDATE document_embedding SET text_hash = NULL WHERE document_id = $c;"

    run "$BIN" repair embeddings
    [[ "$output" =~ "Reindexed 3 document(s), 0 failed, 1 unchanged" ]]
    run "$BIN" repair embeddings
    [[ "$output" =~ "Reindexed 0 document(s), 0 failed, 4 unchanged" ]]
    run "$BIN" repair embeddings --all
    [[ "$output" =~ "Reindexed 4 document(s), 0 failed, 0 unchanged" ]]
}

@test "embedding_skip leaves a sync's header lines out of the embedded text, not the content" {
    write_platform_config ', embedding_quiet_minutes = 0, embedding_skip = {"^> %*%*Source:", "^>%s*$", "^%-%-%-%s*$", "([", 5}'
    content=$'> **Source:** [Lab/Media/M9.xlsx](https://example.org/M9)\n>\n---\n\nM9 medium recipe for cotyledon cultures'
    id=$(new_document "M9" "$content")
    run "$BIN" document embedding-text "$id"
    [ "$output" = $'M9\nM9 medium recipe for cotyledon cultures' ]
    # The document itself keeps its header.
    [[ "$(db "SELECT content FROM document WHERE id = $id;")" =~ "Source:" ]]
}

@test "a chat transcript is embedded from what was said, without tool calls or tool results" {
    id=$(new_document "Chat: media" "placeholder")
    db "INSERT INTO agent_session (id, login, title) VALUES ('s1', 'admin', 'media');"
    db "INSERT INTO agent_message (session_id, role, content) VALUES ('s1', 'user', 'which medium for cotyledons?');"
    db "INSERT INTO agent_message (session_id, role, content) VALUES ('s1', 'tool_result', 'raw search output #12 #13');"
    db "INSERT INTO agent_message (session_id, role, content) VALUES ('s1', 'assistant', 'M9, per the protocol.');"
    db "UPDATE document SET source_type = 'chat_session', source_ref = 's1' WHERE id = $id;"
    run "$BIN" document embedding-text "$id"
    [[ "$output" =~ "User: which medium for cotyledons?" ]]
    [[ "$output" =~ "Assistant: M9, per the protocol." ]]
    [[ ! "$output" =~ "raw search output" ]]
    [[ ! "$output" =~ "placeholder" ]]
}

@test "repair embeddings fills in a legacy row's hash when its text is unchanged, and re-embeds it when the rules changed its text" {
    plain=$(new_document "Plain" "nothing to skip here")
    synced=$(new_document "Synced" $'> **Source:** somewhere\nthe real content')
    db "UPDATE document_embedding SET text_hash = NULL, updated_at = '2000-01-01 00:00:00';"
    write_platform_config ', embedding_quiet_minutes = 0, embedding_skip = {"^> %*%*Source:"}'
    run "$BIN" repair embeddings
    [[ "$output" =~ "Reindexed 1 document(s), 0 failed, 1 unchanged" ]]
    [ "$(db "SELECT updated_at FROM document_embedding WHERE document_id = $plain;")" = "2000-01-01 00:00:00" ]
    [ -n "$(db "SELECT text_hash FROM document_embedding WHERE document_id = $plain;")" ]
    [ "$(db "SELECT updated_at FROM document_embedding WHERE document_id = $synced;")" != "2000-01-01 00:00:00" ]
}
