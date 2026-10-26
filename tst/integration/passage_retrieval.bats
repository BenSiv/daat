#!/usr/bin/env bats
# Passage retrieval (doc/passage-retrieval.md): search shows each found
# document's most relevant passages, chosen by meaning, the same to the
# agent and on /documents. The test provider's word-based embeddings
# (AGENT_TEST_EMBEDDINGS=terms) make texts sharing words similar.

load test_helper.bash

setup() {
    setup_test_env
    write_platform_config ", search_passages = true, passage_min_chars = 50"
    "$BIN" init >/dev/null
    export AGENT_TEST_EMBEDDINGS=terms
    export AGENT_TEST_EMBEDDINGS_LOG="$TEST_DIR/embeddings.log"
    read session csrf < <(login_test_user "alice" "i")
    COOKIE="session=${session}; csrf=${csrf}"
    CSRF="$csrf"
    CHAT=$(json_body "$(raw_post_json "/api/chat-widget-start" '{"title":"x"}' "$COOKIE" "$CSRF" "")" | jq -r '.session_id')
    # A long document whose answer sits in its last section.
    filler=$(printf 'Plants were watered and the greenhouse lights were checked. %.0s' $(seq 1 40))
    late="The incubator held the cultures at twenty five degrees with constant shaking overnight."
    "$BIN" document create-json <<< "[{\"title\":\"Lab handbook\",\"content\":\"# Greenhouse\\n${filler}\\n\\n# Watering\\n${filler}\\n\\n# Incubator\\n${late}\"}]" >/dev/null
    DOC_ID=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT id FROM document WHERE title = 'Lab handbook';")
}

teardown() {
    cleanup_test_env
}

# Each search in a fresh chat: a repeat in the same chat would be
# answered from context (doc/context-management-plan.md, Phase 1).
agent_search() {
    chat=$(json_body "$(raw_post_json "/api/chat-widget-start" '{"title":"s"}' "$COOKIE" "$CSRF" "")" | jq -r '.session_id')
    raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${chat}\",\"message\":\"q\"}" "$COOKIE" "$CSRF" \
        "$(tool_call_response "document.search" "{\"query\":\"$1\"}")"$'\1'"$(done_response "Done.")" >/dev/null
    sqlite3 "$TEST_DIR/.store/store.db" "SELECT content FROM agent_message WHERE session_id = '${chat}' AND role = 'tool_result' ORDER BY id DESC LIMIT 1;"
}

# The /documents search box: the same search (knowledge.search_for_display),
# without a chat transcript document joining the corpus afterwards -- so
# the cache tests below see only the handbook's passages.
page_search() {
    raw_get "/documents" "q=$(printf '%s' "$1" | sed 's/ /+/g')" "$COOKIE"
}

# Passage embeddings only: in these fixtures every passage starts with
# its heading; queries, documents and transcripts don't.
embedded_lines() {
    if [ -f "$AGENT_TEST_EMBEDDINGS_LOG" ]; then grep -c '^# ' "$AGENT_TEST_EMBEDDINGS_LOG"; else echo 0; fi
}

@test "search shows the passage that answers the question, deep in the document, with its position" {
    write_platform_config ", search_passages = true, passage_min_chars = 50, passages_per_document = 1"
    run agent_search "incubator cultures degrees"
    [[ "$output" =~ "[at character " ]]
    [[ "$output" =~ "twenty five degrees" ]]
    [[ ! "$output" =~ "greenhouse lights were checked. Plants were watered and the greenhouse lights were checked. Plants" ]]
}

@test "with search_passages off, search shows today's keyword excerpt" {
    write_platform_config ", search_passages = false"
    run agent_search "incubator cultures degrees"
    [[ ! "$output" =~ "[at character " ]]
    [[ "$output" =~ "twenty five degrees" ]]
}

@test "a repeated search embeds no passage again, and refreshes when the cache was used" {
    page_search "incubator cultures degrees" >/dev/null
    first=$(embedded_lines)
    [ "$first" -gt 1 ]
    sqlite3 "$TEST_DIR/.store/store.db" "UPDATE document_passage_cache SET last_used_at = '2020-01-01 00:00:00';"
    page_search "incubator cultures degrees" >/dev/null
    # No passage was embedded again.
    [ "$(embedded_lines)" -eq "$first" ]
    [ "$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM document_passage_cache WHERE last_used_at > '2020-01-01 00:00:00';")" -gt 0 ]
}

@test "an edited document's changed passages are embedded fresh, its unchanged ones come from the cache" {
    page_search "incubator cultures degrees" >/dev/null
    before=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM document_passage_cache;")
    content=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT content FROM document WHERE id = ${DOC_ID};")
    sqlite3 "$TEST_DIR/.store/store.db" "UPDATE document SET content = replace(content, 'twenty five', 'thirty') WHERE id = ${DOC_ID};"
    lines_before=$(embedded_lines)
    run page_search "incubator cultures degrees"
    [[ "$output" =~ "thirty degrees" ]]
    # Only the one changed passage.
    [ "$(embedded_lines)" -eq $((lines_before + 1)) ]
    [ "$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM document_passage_cache;")" -eq $((before + 1)) ]
}

@test "if embeddings fail, search still answers with the keyword excerpt" {
    export AGENT_TEST_EMBEDDINGS_FAIL=1
    run agent_search "incubator cultures degrees"
    [[ "$output" =~ "Lab handbook" ]]
    [[ "$output" =~ "twenty five degrees" ]]
    [[ ! "$output" =~ "[at character " ]]
}

@test "passage_max_embeds_per_search caps new embeddings in one search" {
    write_platform_config ", search_passages = true, passage_min_chars = 50, passage_max_embeds_per_search = 1"
    page_search "incubator cultures degrees" >/dev/null
    [ "$(embedded_lines)" -eq 1 ]
}

@test "store prune deletes passage embeddings unused past passage_cache_days, and keeps recent ones" {
    agent_search "incubator cultures degrees" >/dev/null
    total=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM document_passage_cache;")
    sqlite3 "$TEST_DIR/.store/store.db" "UPDATE document_passage_cache SET last_used_at = '2020-01-01 00:00:00' WHERE rowid = (SELECT MIN(rowid) FROM document_passage_cache);"
    run "$BIN" store prune
    [[ "$output" =~ "Deleted 1 passage embeddings unused for 30 days" ]]
    [[ "$output" =~ "stored prompts" ]]
    [ "$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM document_passage_cache;")" -eq $((total - 1)) ]

    write_platform_config ", passage_cache_days = 0"
    sqlite3 "$TEST_DIR/.store/store.db" "UPDATE document_passage_cache SET last_used_at = '2020-01-01 00:00:00';"
    run "$BIN" store prune
    [[ "$output" =~ "Deleted 0 passage embeddings" ]]
    run "$BIN" agent prune-prompts
    [[ "$output" =~ "Cleared 0 stored prompts" ]]
}

@test "the /documents search box shows the same passages the agent gets" {
    agent_output=$(agent_search "incubator cultures degrees")
    run raw_get "/documents" "q=incubator+cultures+degrees" "$COOKIE"
    [[ "$output" =~ "documents match <strong>incubator cultures degrees</strong>" ]]
    [[ "$output" =~ "twenty five degrees" ]]
    [[ "$output" =~ "[at character " ]]
    [[ "$output" =~ "document?entity_id=${DOC_ID}" ]]
    # A person's search counts as usage too.
    [ "$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM knowledge_retrieval WHERE session_id IS NULL;")" = "1" ]
}

@test "the agent can't query the passage cache; entity.fields describes nothing secret there" {
    raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${CHAT}\",\"message\":\"q\"}" "$COOKIE" "$CSRF" \
        "$(tool_call_response "entity.query" '{"sql":"SELECT * FROM document_passage_cache"}')"$'\1'"$(done_response "Done.")" >/dev/null
    run latest_tool_result "$CHAT"
    [[ "$output" =~ "refusing to run" ]]
}
