#!/usr/bin/env bats
# Deferred retrieval review (doc/tier-curation-ladder.md Phase 2;
# doc/performance.md Option 1.1;): interactive search
# (/documents?q=... and agent document.search) records only the
# lightweight retrieval event + raw hits, while `daat knowledge
# review-pending` applies conserved pool heat, spreading activation,
# curation queueing, and co-retrieval link adjudication asynchronously.

load test_helper.bash

setup() {
    setup_test_env
    # Omit search_review_mode completely so every test here exercises the
    # real deployment default ("deferred") unless explicitly testing an
    # override.
    cat > "$TEST_DIR/config.lua" <<'EOF'
return {agent = {provider = "test", turn_mode = "inline"}, knowledge = {embedding_quiet_minutes = 0, tag_min_text = 0, link_passage_gate = 0}, search = {provider = "test"}}
EOF
    "$BIN" init >/dev/null
    read SESSION CSRF < <(login_test_user "alice" "i")
    COOKIE="session=${SESSION}; csrf=${CSRF}"
}

teardown() {
    cleanup_test_env
}

@test "default search_review_mode is deferred: /documents?q=... and document.search return hits with zero synchronous reinforcement, curation queueing, or link model calls" {
    long_a=$(printf 'Bioreactor cleaning step %s: rinse thoroughly, then autoclave. ' $(seq 1 20))
    long_b=$(printf 'Bioreactor startup step %s: calibrate DO probe before inoculation. ' $(seq 1 20))
    raw_post "/document-save" "csrf_token=${CSRF}&title=Checklist&parent_id=&content=Daily+checklist." "$COOKIE" "" >/dev/null
    raw_post "/document-save" "csrf_token=${CSRF}&title=Bioreactor+Cleaning&parent_id=&content=${long_a// /+}+See+%5B%5BChecklist%5D%5D." "$COOKIE" "" >/dev/null
    raw_post "/document-save" "csrf_token=${CSRF}&title=Bioreactor+Startup&parent_id=&content=${long_b// /+}" "$COOKIE" "" >/dev/null

    # Three searches cross both DUE_FOR_REVIEW_RETRIEVAL_COUNT (2) and
    # CO_RETRIEVAL_LINK_THRESHOLD (3), yet none of them touch document
    # heat/retrieval_count, spread activation, curation, or model calls
    # during the web/tool requests themselves.
    run raw_get "/documents" "q=bioreactor" "$COOKIE"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Bioreactor Cleaning" ]]
    [[ "$output" =~ "Bioreactor Startup" ]]

    raw_get "/documents" "q=bioreactor" "$COOKIE" >/dev/null

    resp=$(raw_post_json "/api/chat-widget-start" '{"title":"Deferred chat"}' "$COOKIE" "$CSRF" "")
    sid=$(json_body "$resp" | jq -r '.session_id')
    scripted="$(tool_call_response "document.search" '{"query":"bioreactor"}')"$'\1'"$(done_response "Found both protocols.")"
    run raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${sid}\",\"message\":\"find bioreactor protocols\"}" "$COOKIE" "$CSRF" "$scripted"
    [[ "$output" =~ "200 OK" ]]

    # All 3 retrievals are queued as pending with raw hits logged, and zero post-search mutations ran inline.
    [ "$(db "SELECT COUNT(*) FROM knowledge_retrieval WHERE status = 'pending' AND author = 'alice';")" = "3" ]
    [ "$(db "SELECT COUNT(*) FROM knowledge_retrieval_hit WHERE reinforcement_delta IS NULL AND reviewed_at IS NULL;")" = "6" ]
    [ "$(db "SELECT SUM(retrieval_count) FROM document;")" = "0" ]
    [ "$(db "SELECT COUNT(*) FROM knowledge_retrieval_hit WHERE rank IS NULL;")" = "0" ]
    [ "$(db "SELECT COUNT(*) FROM knowledge_curation;")" = "0" ]
    [ "$(db "SELECT COUNT(*) FROM knowledge_link_review;")" = "0" ]

    # Now the background worker drains the queue in causal order: only the
    # 3rd retrieval crosses CO_RETRIEVAL_LINK_THRESHOLD (3), triggering one
    # link judgment attributed to alice, spreading activation to Checklist,
    # and queueing both sources for curate-pending.
    run env AGENT_TEST_RESPONSES="YES: both protocols govern sequential cleaning and startup stages of the same bioreactor run." "$BIN" knowledge review-pending 25
    [ "$status" -eq 0 ]
    [[ "$output" =~ "retrieval #1 reviewed (2 hits)" ]]
    [[ "$output" =~ "retrieval #2 reviewed (2 hits)" ]]
    [[ "$output" =~ "retrieval #3 reviewed (2 hits)" ]]

    [ "$(db "SELECT COUNT(*) FROM knowledge_retrieval WHERE status = 'reviewed' AND reviewed_at IS NOT NULL;")" = "3" ]
    [ "$(db "SELECT retrieval_count FROM document WHERE title = 'Bioreactor Cleaning';")" = "3" ]
    [ "$(db "SELECT retrieval_count FROM document WHERE title = 'Bioreactor Startup';")" = "3" ]
    [ "$(db "SELECT retrieval_count FROM document WHERE title = 'Checklist';")" = "0" ]
    # Checklist received 3 spreading-activation hit rows (one per retrieval, rank IS NULL).
    [ "$(db "SELECT COUNT(*) FROM knowledge_retrieval_hit k JOIN document d ON d.id = k.document_id WHERE d.title = 'Checklist' AND k.rank IS NULL AND k.reinforcement_delta > 0;")" = "3" ]
    # Both sources are queued as pending in knowledge_curation for curate-pending in the same jobs cycle.
    [ "$(db "SELECT COUNT(*) FROM knowledge_curation WHERE status = 'pending';")" = "2" ]
    # Connection document created and attributed to alice (the searching user, not a synthetic actor).
    [ "$(db "SELECT decision || '|' || last_co_count FROM knowledge_link_review WHERE document_a_id = 2 AND document_b_id = 3;")" = "linked|3" ]
    [ "$(db "SELECT created_by FROM document WHERE title = 'Bioreactor Cleaning ↔ Bioreactor Startup';")" = "alice" ]

    # Re-running review-pending is an exact no-op.
    run "$BIN" knowledge review-pending 25
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$(db "SELECT retrieval_count FROM document WHERE title = 'Bioreactor Cleaning';")" = "3" ]
}

@test "zero-hit searches record status='reviewed' immediately and leave nothing pending for the worker" {
    run raw_get "/documents" "q=nonexistenttermxyz" "$COOKIE"
    [[ "$output" =~ "200 OK" ]]
    [ "$(db "SELECT status || '|' || hit_count || '|' || (reviewed_at IS NOT NULL) FROM knowledge_retrieval;")" = "reviewed|0|1" ]

    run "$BIN" knowledge review-pending
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "fresh running claims are skipped by concurrent workers, while stale crashed claims recover without double-counting already-reinforced hits" {
    "$BIN" entity create document title="Doc One" content="bioreactor oxygen transfer rate" >/dev/null
    "$BIN" entity create document title="Doc Two" content="bioreactor agitation speed" >/dev/null
    raw_get "/documents" "q=bioreactor" "$COOKIE" >/dev/null

    # Simulate another live worker currently holding the claim with a fresh timestamp.
    fresh_ts=$(date -u +"%Y-%m-%d %H:%M:%S")
    db "UPDATE knowledge_retrieval SET status = 'running', claim_token = 'otherworker', claimed_at = '${fresh_ts}' WHERE id = 1;"
    run "$BIN" knowledge review-pending
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$(db "SELECT SUM(retrieval_count) FROM document;")" = "0" ]

    # Now simulate that worker having crashed 20 minutes ago after reinforcing Doc One (#1)
    # before reaching Doc Two (#2) or review_retrieval.
    db "UPDATE document SET retrieval_count = 1 WHERE id = 1;"
    db "UPDATE knowledge_retrieval_hit SET tier_weight = 1.0, reinforcement_delta = 0.2 WHERE retrieval_id = 1 AND document_id = 1;"
    db "UPDATE knowledge_retrieval SET claimed_at = '2020-01-01 00:00:00' WHERE id = 1;"

    run "$BIN" knowledge review-pending
    [ "$status" -eq 0 ]
    [[ "$output" =~ "retrieval #1 reviewed (2 hits)" ]]
    # Doc One stayed at 1 (not double-counted to 2!), and Doc Two caught up to 1!
    [ "$(db "SELECT retrieval_count FROM document WHERE id = 1;")" = "1" ]
    [ "$(db "SELECT retrieval_count FROM document WHERE id = 2;")" = "1" ]
    [ "$(db "SELECT COUNT(*) FROM knowledge_retrieval_hit WHERE retrieval_id = 1 AND reviewed_at IS NOT NULL;")" = "2" ]
    [ "$(db "SELECT status FROM knowledge_retrieval WHERE id = 1;")" = "reviewed" ]
}

@test "a document archived between search and review-pending is skipped cleanly without reinforcing an archived row" {
    "$BIN" entity create document title="Temporary SOP" content="bioreactor temporary draft" >/dev/null
    raw_get "/documents" "q=bioreactor" "$COOKIE" >/dev/null
    "$BIN" entity archive document 1 >/dev/null

    run "$BIN" knowledge review-pending
    [ "$status" -eq 0 ]
    [[ "$output" =~ "retrieval #1 reviewed (1 hits)" ]]
    [ "$(db "SELECT retrieval_count FROM document WHERE id = 1;")" = "0" ]
    [ "$(db "SELECT status FROM knowledge_retrieval WHERE id = 1;")" = "reviewed" ]
}

