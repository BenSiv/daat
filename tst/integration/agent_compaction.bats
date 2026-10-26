#!/usr/bin/env bats
# Compaction on real token counts, mid-turn, with an anchored summary
# (doc/context-management-plan.md, Phase 3).

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init >/dev/null
    read session csrf < <(login_test_user "alice" "i")
    COOKIE="session=${session}; csrf=${csrf}"
    CSRF="$csrf"
    CHAT=$(json_body "$(raw_post_json "/api/chat-widget-start" '{"title":"x"}' "$COOKIE" "$CSRF" "")" | jq -r '.session_id')
    DB="$TEST_DIR/.store/store.db"
    # Summaries get their own scripted replies, so a compaction never
    # takes one meant for the chat.
    export AGENT_TEST_GENERATE_RESPONSES="## Established facts
Sample S-17 is the control.
## Decisions
none
## Open questions and next step
none"
}

teardown() {
    unset AGENT_TEST_PROMPT_TOKENS AGENT_TEST_GENERATE_RESPONSES
    cleanup_test_env
}

send() {
    raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${CHAT}\",\"message\":\"$1\"}" "$COOKIE" "$CSRF" "$2" >/dev/null
}

summaries() {
    sqlite3 "$DB" "SELECT COUNT(*) FROM agent_message WHERE session_id = '${CHAT}' AND role = 'compaction_summary' AND in_context = ${1:-1};"
}

# One turn: a tool call, its result, then an answer (4 messages).
one_turn() {
    send "$1" "$(tool_call_response "entity.fields" "{\"entity_type\":\"$2\"}")"$'\1'"$(done_response "Listed $2.")"
}

@test "the trigger uses the last call's recorded prompt tokens" {
    write_platform_config ", agent_compaction_threshold = 20000"
    AGENT_TEST_PROMPT_TOKENS=50000 one_turn "fields of document" "document"
    send "and tags?" "$(done_response "ok")"
    run summaries
    [ "$output" -eq 1 ]
}

@test "a small recorded count doesn't compact, whatever the history's length" {
    write_platform_config ", agent_compaction_threshold = 20000, agent_context_fixed_tokens = 100000"
    AGENT_TEST_PROMPT_TOKENS=100 one_turn "fields of document" "document"
    send "and tags?" "$(done_response "ok")"
    run summaries
    [ "$output" -eq 0 ]
}

@test "without a recorded count, the estimate is the fixed overhead plus history characters" {
    for i in 1 2 3; do
        sqlite3 "$DB" "INSERT INTO agent_message (session_id, role, content) VALUES ('${CHAT}', 'user', 'question ${i}');"
        sqlite3 "$DB" "INSERT INTO agent_message (session_id, role, content) VALUES ('${CHAT}', 'assistant', '{\"blocks\":[{\"type\":\"text\",\"text\":\"answer ${i}\"}]}');"
    done
    write_platform_config ", agent_compaction_threshold = 48000, agent_context_fixed_tokens = 0"
    send "next" "$(done_response "ok")"
    run summaries
    [ "$output" -eq 0 ]

    # With that turn's recorded count cleared, the estimate decides
    # again.
    sqlite3 "$DB" "UPDATE agent_model_call SET prompt_tokens = NULL WHERE session_id = '${CHAT}';"
    write_platform_config ", agent_compaction_threshold = 48000, agent_context_fixed_tokens = 100000"
    send "next again" "$(done_response "ok")"
    run summaries
    [ "$output" -eq 1 ]
}

@test "a long turn compacts between steps, and keeps every tool result with its call" {
    write_platform_config ", agent_compaction_threshold = 20000"
    scripted="$(tool_call_response "entity.fields" '{"entity_type":"document"}')"$'\1'"$(tool_call_response "entity.fields" '{"entity_type":"tag"}')"$'\1'"$(tool_call_response "entity.fields" '{"entity_type":"document_tag"}')"$'\1'"$(done_response "All listed.")"
    AGENT_TEST_PROMPT_TOKENS=50000 send "list the fields of three types" "$scripted"

    run summaries
    [ "$output" -eq 1 ]
    run sqlite3 "$DB" "SELECT content FROM agent_message WHERE session_id = '${CHAT}' AND role = 'assistant' ORDER BY id DESC LIMIT 1;"
    [[ "$output" =~ "All listed." ]]
    # The compacted request is carried verbatim.
    run sqlite3 "$DB" "SELECT content FROM agent_message WHERE session_id = '${CHAT}' AND role = 'compaction_summary';"
    [[ "$output" =~ "- list the fields of three types" ]]
    # Every result in context has its call in context.
    calls=$(sqlite3 "$DB" "SELECT content FROM agent_message WHERE session_id = '${CHAT}' AND in_context = 1 AND role = 'assistant';")
    for id in $(sqlite3 "$DB" "SELECT json_extract(content, '$.tool_call_id') FROM agent_message WHERE session_id = '${CHAT}' AND in_context = 1 AND role = 'tool_result';"); do
        [[ "$calls" =~ "\"id\":\"${id}\"" ]]
    done
}

@test "with agent_compaction_mid_turn = false, a turn only compacts when it starts" {
    write_platform_config ", agent_compaction_threshold = 20000, agent_compaction_mid_turn = false"
    scripted="$(tool_call_response "entity.fields" '{"entity_type":"document"}')"$'\1'"$(tool_call_response "entity.fields" '{"entity_type":"tag"}')"$'\1'"$(tool_call_response "entity.fields" '{"entity_type":"document_tag"}')"$'\1'"$(done_response "All listed.")"
    AGENT_TEST_PROMPT_TOKENS=50000 send "list the fields of three types" "$scripted"
    run summaries
    [ "$output" -eq 0 ]
}

@test "a second compaction updates the first summary instead of summarizing it, and only one stays in context" {
    write_platform_config ", agent_compaction_threshold = 20000"
    AGENT_TEST_PROMPT_TOKENS=50000 one_turn "which sample is the control?" "document"
    AGENT_TEST_PROMPT_TOKENS=50000 one_turn "and the tags?" "tag"
    AGENT_TEST_PROMPT_TOKENS=50000 one_turn "and document_tag?" "document_tag"

    run summaries 1
    [ "$output" -eq 1 ]
    run summaries 0
    [ "$output" -ge 1 ]
    # The update prompt starts from the previous summary's prose...
    run sqlite3 "$DB" "SELECT prompt FROM agent_model_call WHERE session_id = '${CHAT}' AND kind = 'compaction' ORDER BY id DESC LIMIT 1;"
    [[ "$output" =~ "Summary so far:" ]]
    [[ "$output" =~ "Sample S-17 is the control." ]]
    [[ "$output" =~ "## Open questions and next step" ]]
    # ...without re-summarizing the parts code carries.
    [[ ! "$output" =~ "Earlier user messages (verbatim" ]]
    [[ ! "$output" =~ "Confirmed schema" ]]
    # The first request survives both compactions verbatim, and the
    # pinned schema from the first is still there.
    run sqlite3 "$DB" "SELECT content FROM agent_message WHERE session_id = '${CHAT}' AND role = 'compaction_summary' AND in_context = 1;"
    [[ "$output" =~ "- which sample is the control?" ]]
    [[ "$output" =~ "### entity.fields {\"entity_type\":\"document\"}" ]]
}

@test "the summary comes first in the history sent to the model" {
    write_platform_config ", agent_compaction_threshold = 20000"
    AGENT_TEST_PROMPT_TOKENS=50000 one_turn "fields of document" "document"
    send "and tags?" "$(done_response "ok")"
    run sqlite3 "$DB" "SELECT prompt FROM agent_model_call WHERE session_id = '${CHAT}' AND kind = 'chat' ORDER BY id DESC LIMIT 1;"
    first=$(printf '%s' "$output" | jq -r '.[0].content')
    [[ "$first" =~ ^"[COMPACTED HISTORY SUMMARY]" ]]
}
