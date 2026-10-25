#!/usr/bin/env bats
# Keep what's known (doc/context-management-plan.md, Phase 1): exact
# repeat calls answered from context, schema carried through compaction.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init >/dev/null
    read session csrf < <(login_test_user "alice" "i")
    COOKIE="session=${session}; csrf=${csrf}"
    CSRF="$csrf"
    CHAT=$(json_body "$(raw_post_json "/api/chat-widget-start" '{"title":"x"}' "$COOKIE" "$CSRF" "")" | jq -r '.session_id')
}

teardown() {
    cleanup_test_env
}

tool_results() {
    sqlite3 "$TEST_DIR/.store/store.db" "SELECT content FROM agent_message WHERE session_id = '${CHAT}' AND role = 'tool_result' ORDER BY id;"
}

send() {
    raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${CHAT}\",\"message\":\"$1\"}" "$COOKIE" "$CSRF" "$2" >/dev/null
}

@test "an exact repeat of a schema lookup is answered with a pointer, not a second copy" {
    fields="$(tool_call_response "entity.fields" '{"entity_type":"document"}')"
    send "what fields does document have" "${fields}"$'\1'"${fields}"$'\1'"$(done_response "Listed.")"
    run tool_results
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[0]}" =~ "title" ]]
    [[ "${lines[1]}" =~ "Same call as one earlier in this conversation" ]]
    [[ ! "${lines[1]}" =~ "title" ]]
}

@test "different arguments, or the setting turned off, run the call again" {
    send "fields" "$(tool_call_response "entity.fields" '{"entity_type":"document"}')"$'\1'"$(tool_call_response "entity.fields" '{"entity_type":"tag"}')"$'\1'"$(done_response "Listed.")"
    run tool_results
    [[ ! "${lines[1]}" =~ "Same call as one earlier" ]]

    write_platform_config ", agent_dedupe_repeat_calls = false"
    fields="$(tool_call_response "entity.fields" '{"entity_type":"document"}')"
    send "again" "${fields}"$'\1'"$(done_response "Listed.")"
    run tool_results
    [[ ! "${lines[2]}" =~ "Same call as one earlier" ]]
}

@test "compaction carries schema lookups verbatim, and drops other tool results into the prose" {
    send "fields of document" "$(tool_call_response "entity.fields" '{"entity_type":"document"}')"$'\1'"$(tool_call_response "entity.query" '{"sql":"SELECT COUNT(*) AS n FROM document"}')"$'\1'"$(done_response "Document has a title field.")"
    write_platform_config ", agent_compaction_threshold = 1"
    send "and now?" "$(done_response "Still here.")"
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT content FROM agent_message WHERE session_id = '${CHAT}' AND role = 'compaction_summary' ORDER BY id DESC LIMIT 1;"
    [[ "$output" =~ "Confirmed schema (exact earlier tool results" ]]
    [[ "$output" =~ "### entity.fields {\"entity_type\":\"document\"}" ]]
    [[ "$output" =~ "title" ]]
    [[ ! "$output" =~ "### entity.query" ]]
}

@test "with agent_pin_schema = false, compaction pins nothing" {
    write_platform_config ", agent_pin_schema = false"
    send "fields of document" "$(tool_call_response "entity.fields" '{"entity_type":"document"}')"$'\1'"$(done_response "Listed.")"
    write_platform_config ", agent_pin_schema = false, agent_compaction_threshold = 1"
    send "and now?" "$(done_response "Still here.")"
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT content FROM agent_message WHERE session_id = '${CHAT}' AND role = 'compaction_summary' ORDER BY id DESC LIMIT 1;"
    [ -n "$output" ]
    [[ ! "$output" =~ "Confirmed schema" ]]
}
