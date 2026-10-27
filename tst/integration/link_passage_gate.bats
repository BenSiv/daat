#!/usr/bin/env bats
# The co-retrieval link gate (doc/link-passage-gate.md): a pair whose most
# similar passages score below link_passage_gate isn't put to the model.
# The test provider's word-based embeddings (AGENT_TEST_EMBEDDINGS=terms)
# make texts sharing words similar: "cleaning" vs "startup" steps of the
# same procedure score 0.667, a cleaning procedure vs an invoice 0.567.

load test_helper.bash

setup() {
    setup_test_env
    # Test documents are short: a stub is under 20 characters here.
    write_platform_config ", link_passage_gate = 0.6, passage_min_chars = 20"
    "$BIN" init >/dev/null
    "$BIN" user add alice secret123 i >/dev/null
    export AGENT_TEST_EMBEDDINGS=terms
    export AGENT_TEST_EMBEDDINGS_LOG="$TEST_DIR/embeddings.log"
    raw=$(printf 'login=alice&password=secret123' | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN")
    SESSION=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    CSRF=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')
    COOKIE="session=${SESSION}; csrf=${CSRF}"
    "$BIN" entity create document title="Bioreactor Cleaning" content="cleaning steps for the bioreactor procedure" >/dev/null
}

teardown() {
    unset AGENT_TEST_EMBEDDINGS AGENT_TEST_EMBEDDINGS_LOG AGENT_TEST_EMBEDDINGS_FAIL
    cleanup_test_env
}

# One chat search for "bioreactor"; `extra` is the link judgment's reply,
# scripted between the search call and the final answer (see
# knowledge.bats' search_for_bioreactor_extra).
search() {
    local extra="${1:-}"
    session_id=$(json_body "$(raw_post_json "/api/chat-widget-start" '{"title":"Chat"}' "$COOKIE" "$CSRF" "")" | jq -r '.session_id')
    scripted="$(tool_call_response "document.search" '{"query":"bioreactor"}')"
    if [ -n "$extra" ]; then
        scripted="${scripted}"$'\1'"${extra}"
    fi
    scripted="${scripted}"$'\1'"$(done_response "Found it.")"
    raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${session_id}\",\"message\":\"find bioreactor pages\"}" "$COOKIE" "$CSRF" "$scripted" >/dev/null
    # The chat's own transcript is searchable too; set aside so only the
    # documents under test are retrieved together.
    sqlite3 "$TEST_DIR/.store/store.db" "UPDATE document SET archived_at = '2026-01-01 00:00:00' WHERE source_type = 'chat_session';"
}

embeddings() {
    if [ -f "$AGENT_TEST_EMBEDDINGS_LOG" ]; then wc -l < "$AGENT_TEST_EMBEDDINGS_LOG"; else echo 0; fi
}

review() {
    sqlite3 "$TEST_DIR/.store/store.db" "SELECT decision || '|' || reason FROM knowledge_link_review WHERE document_a_id = 1 AND document_b_id = 2;"
}

last_reply() {
    sqlite3 "$TEST_DIR/.store/store.db" "SELECT content FROM agent_message WHERE session_id = '${session_id}' AND role = 'assistant' ORDER BY id DESC LIMIT 1;"
}

connections() {
    sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM document WHERE title LIKE '%↔%';"
}

@test "a pair whose passages share too little is recorded as dissimilar, without asking the model" {
    "$BIN" entity create document title="Bioreactor Invoice" content="bioreactor invoice paid to the vendor, quarterly budget approval and finance signature" >/dev/null
    search
    search
    # The 3rd shared retrieval makes the pair due; no judgment reply is
    # scripted, so a model call would take the final answer instead.
    search
    run review
    [[ "$output" =~ ^"dissimilar|best passage pair similarity 0.567 is below 0.600" ]]
    run last_reply
    [[ "$output" =~ "Found it." ]]
    run connections
    [ "$output" -eq 0 ]
}

@test "a pair that passes the gate is judged by the model as before" {
    "$BIN" entity create document title="Bioreactor Startup" content="startup steps for the bioreactor procedure" >/dev/null
    search
    search
    search "YES: both are steps of the same bioreactor procedure."
    run review
    [[ "$output" == "linked|both are steps of the same bioreactor procedure." ]]
    run connections
    [ "$output" -eq 1 ]
}

@test "with link_passage_gate = 0, every due pair goes to the model" {
    write_platform_config ", link_passage_gate = 0"
    "$BIN" entity create document title="Bioreactor Invoice" content="bioreactor invoice paid to the vendor, quarterly budget approval and finance signature" >/dev/null
    search
    search
    search "NO: an invoice and a procedure."
    run review
    [[ "$output" =~ ^"declined|" ]]
}

@test "when the similarity can't be measured, the model decides" {
    "$BIN" entity create document title="Bioreactor Invoice" content="bioreactor invoice paid to the vendor, quarterly budget approval and finance signature" >/dev/null
    export AGENT_TEST_EMBEDDINGS_FAIL=1
    search
    search
    search "NO: an invoice and a procedure."
    run review
    [[ "$output" =~ ^"declined|" ]]

    # Within a cap too small to embed both sides, likewise.
    unset AGENT_TEST_EMBEDDINGS_FAIL
    write_platform_config ", link_passage_gate = 0.6, passage_min_chars = 20, link_gate_max_embeds = 1"
    run "$BIN" knowledge link-score 1 2
    [[ "$output" =~ "Can't measure: no passages embedded" ]]
}

@test "daat knowledge link-score shows the score, the verdict and both passages, and scores a list of pairs" {
    "$BIN" entity create document title="Bioreactor Startup" content="startup steps for the bioreactor procedure" >/dev/null
    run "$BIN" knowledge link-score 1 2
    [[ "${lines[0]}" == "best passage pair similarity: 0.6667 (gate 0.600: passes)" ]]
    [[ "$output" =~ "#1 at character 0:" ]]
    [[ "$output" =~ "startup steps for the bioreactor procedure" ]]

    # Scored again from the cache: no new embeddings.
    before=$(embeddings)
    printf '1 2\n1 9\n' > "$TEST_DIR/pairs.txt"
    run "$BIN" knowledge link-score --pairs "$TEST_DIR/pairs.txt"
    [ "${lines[0]}" = "1 2 0.6667" ]
    [ "${lines[1]}" = "1 9 NA" ]
    [ "$(embeddings)" -eq "$before" ]
}

@test "a long document compares only its passages sharing the most words with the other" {
    filler=$(printf 'Plants were watered and the greenhouse lights were checked. %.0s' $(seq 1 40))
    "$BIN" entity create document title="Greenhouse log" content="# Week 1
${filler}
# Week 2
${filler} greenhouse
# Bioreactor
The cleaning steps for the bioreactor procedure were repeated.
# Week 3
${filler} lights" >/dev/null
    write_platform_config ", link_passage_gate = 0.6, link_gate_passages_per_document = 1, passage_min_chars = 30"
    before=$(embeddings)
    run "$BIN" knowledge link-score 1 2
    [[ "$output" =~ "The cleaning steps for the bioreactor procedure were repeated." ]]
    # One passage each side: two embeddings, not the whole log.
    [ "$(( $(embeddings) - before ))" -eq 2 ]
}

@test "daat repair connections puts existing connections through the gate first: lists, then archives, those whose documents share too little" {
    "$BIN" entity create document title="Bioreactor Invoice" content="bioreactor invoice paid to the vendor, quarterly budget approval and finance signature" >/dev/null
    "$BIN" entity create document title="Bioreactor Startup" content="startup steps for the bioreactor procedure" >/dev/null
    "$BIN" entity create document title="Bioreactor Cleaning ↔ Bioreactor Invoice" content="[[Bioreactor Cleaning]] and [[Bioreactor Invoice]]: both mention the bioreactor in the same facility." >/dev/null
    "$BIN" entity create document title="Bioreactor Cleaning ↔ Bioreactor Startup" content="[[Bioreactor Cleaning]] and [[Bioreactor Startup]]: both are steps of the same bioreactor procedure." >/dev/null

    run "$BIN" repair connections --dry-run
    [[ "$output" =~ "would revoke #4 Bioreactor Cleaning ↔ Bioreactor Invoice: best passage pair similarity 0.567 is below 0.600 | #1 @0 Bioreactor Cleaning" ]]
    [[ ! "$output" =~ "#5 Bioreactor Cleaning ↔ Bioreactor Startup" ]]
    [[ "$output" =~ "1 would be revoked by the passage gate, 1 kept as they are" ]]
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM document WHERE id = 4 AND (archived_at IS NULL OR archived_at = '');"
    [ "$output" -eq 1 ]

    # No model reply is scripted: the gate decides alone.
    run "$BIN" repair connections
    [[ "$output" =~ "0 explained, 1 revoked by the passage gate, 0 revoked, 1 kept as they are" ]]
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT id FROM document WHERE title LIKE '%↔%' AND (archived_at IS NULL OR archived_at = '');"
    [ "$output" = "5" ]
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT decision FROM knowledge_link_review WHERE document_a_id = 1 AND document_b_id = 2;"
    [ "$output" = "dissimilar" ]
}

@test "a stub the gate can't measure goes to the model, in co-retrieval and in repair" {
    "$BIN" entity create document title="Bioreactor Log" content="bioreactor" >/dev/null
    run "$BIN" knowledge link-score 1 2
    [[ "$output" =~ "Can't measure: too little text to compare in #2" ]]

    "$BIN" entity create document title="Bioreactor Cleaning ↔ Bioreactor Log" content="[[Bioreactor Cleaning]] and [[Bioreactor Log]]: the log records each run of the bioreactor cleaning procedure." >/dev/null
    run "$BIN" repair connections --dry-run
    [[ "$output" =~ "would explain or revoke #3 Bioreactor Cleaning ↔ Bioreactor Log (the gate can't measure it: too little text to compare in #2)" ]]
    AGENT_TEST_RESPONSES="YES: the log records each run of the bioreactor cleaning procedure." run "$BIN" repair connections
    [[ "$output" =~ "1 explained" ]]
}
