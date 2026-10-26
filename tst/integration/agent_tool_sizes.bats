#!/usr/bin/env bats
# Tool result sizes (doc/context-management-plan.md, Phase 2).

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

send() {
    raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${CHAT}\",\"message\":\"$1\"}" "$COOKIE" "$CSRF" "$2"$'\1'"$(done_response "Done.")" >/dev/null
}

first_tool_result() {
    sqlite3 "$TEST_DIR/.store/store.db" "SELECT content FROM agent_message WHERE session_id = '${CHAT}' AND role = 'tool_result' ORDER BY id LIMIT 1;"
}

@test "knowledge.list returns one page with a footer naming the next offset" {
    "$BIN" document create-json <<< '[{"title":"A","content":"alpha"},{"title":"B","content":"beta"},{"title":"C","content":"gamma"}]' >/dev/null
    # Pool members are documents with a source or a retrieval.
    sqlite3 "$TEST_DIR/.store/store.db" "UPDATE document SET source_type = 'distilled';"
    write_platform_config ", agent_knowledge_list_page = 2"
    send "list the pool" "$(tool_call_response "knowledge.list" '{}')"
    run first_tool_result
    [[ "$output" =~ "(documents 1-2 of " ]]
    [[ "$output" =~ "next page: offset = 2" ]]
}

@test "entity.query stops at its size limit and says how many rows it showed" {
    "$BIN" document create-json <<< '[{"title":"One","content":"x"},{"title":"Two","content":"y"},{"title":"Three","content":"z"}]' >/dev/null
    write_platform_config ", agent_query_char_cap = 8"
    send "titles" "$(tool_call_response "entity.query" '{"sql":"SELECT title FROM document WHERE archived_at IS NULL"}')"
    run first_tool_result
    [[ "$output" =~ "the result reached its size limit" ]]
}

@test "entity.get previews a long text field, and reads on from an offset" {
    long=$(printf 'line %s of the protocol. ' $(seq 1 400))
    "$BIN" document create-json <<< "[{\"title\":\"Long\",\"content\":\"# Intro\\n${long}\\n## Method\\nend\"}]" >/dev/null
    id=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT id FROM document WHERE title = 'Long';")
    write_platform_config ", agent_get_field_chars = 200"
    send "read it" "$(tool_call_response "entity.get" "{\"entity_type\":\"document\",\"entity_id\":${id}}")"
    run first_tool_result
    [[ "$output" =~ "of " ]]
    [[ "$output" =~ "characters shown; headings: # Intro | ## Method; read on with entity.get field=content offset=200" ]]

    send "more" "$(tool_call_response "entity.get" "{\"entity_type\":\"document\",\"entity_id\":${id},\"field\":\"content\",\"offset\":200,\"length\":50}")"
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT content FROM agent_message WHERE session_id = '${CHAT}' AND role = 'tool_result' ORDER BY id DESC LIMIT 1;"
    [[ "$output" =~ "document #${id} content, characters 200-250 of " ]]
    [[ "$output" =~ "[read on with offset=250]" ]]
}

@test "a long tool result is cut when shown to the model, stored whole, and readable with result.read" {
    long=$(printf 'word%s ' $(seq 1 300))
    "$BIN" document create-json <<< "[{\"title\":\"Big\",\"content\":\"${long}\"}]" >/dev/null
    id=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT id FROM document WHERE title = 'Big';")
    write_platform_config ", agent_tool_result_cap = 100, agent_get_field_chars = 100000"
    send "read it" "$(tool_call_response "entity.get" "{\"entity_type\":\"document\",\"entity_id\":${id}}")"
    result_id=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT id FROM agent_message WHERE session_id = '${CHAT}' AND role = 'tool_result' ORDER BY id LIMIT 1;")
    # Stored whole...
    run first_tool_result
    [[ "$output" =~ "word300" ]]
    # ...but the model's next prompt carried only the cut version.
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT prompt FROM agent_model_call WHERE session_id = '${CHAT}' AND kind = 'chat' AND step = 2;"
    [[ "$output" =~ "read on with result.read result_id=${result_id} offset=100" ]]
    [[ ! "$output" =~ "word300" ]]

    send "more" "$(tool_call_response "result.read" "{\"result_id\":${result_id},\"offset\":100,\"length\":40}")"
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT content FROM agent_message WHERE session_id = '${CHAT}' AND role = 'tool_result' ORDER BY id DESC LIMIT 1;"
    [[ "$output" =~ "result #${result_id}, characters 100-140 of " ]]
}

@test "result.read only reads this conversation's results" {
    send "read" "$(tool_call_response "result.read" '{"result_id":999999,"offset":0}')"
    run first_tool_result
    [[ "$output" =~ "no tool result #999999 in this conversation" ]]
}

@test "document.search's full detail gives a longer excerpt than the default" {
    long=$(printf 'incubator note %s. ' $(seq 1 600))
    "$BIN" document create-json <<< "[{\"title\":\"Incubator\",\"content\":\"${long}\"}]" >/dev/null
    write_platform_config ", agent_search_excerpt_length = 100, agent_search_excerpt_full_length = 2000"
    send "short" "$(tool_call_response "document.search" '{"query":"incubator"}')"
    short_len=$(first_tool_result | wc -c)
    send "long" "$(tool_call_response "document.search" '{"query":"incubator","detail":"full"}')"
    long_len=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT content FROM agent_message WHERE session_id = '${CHAT}' AND role = 'tool_result' ORDER BY id DESC LIMIT 1;" | wc -c)
    [ "$long_len" -gt $((short_len + 1000)) ]
}
