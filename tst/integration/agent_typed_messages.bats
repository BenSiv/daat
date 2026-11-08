#!/usr/bin/env bats
# Typed agent messages and the sub-agent trail (doc/agent-data.md,
# "Storage"): every agent_message row has a data_type and a loop_kind;
# research and background steps are kept under the message that started
# them, out of the main conversation.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    "$BIN" user add admin secret123 ia
}

teardown() {
    cleanup_test_env
}

store() {
    sqlite3 "$TEST_DIR/.store/store.db" "$1"
}

raw_login() {
    printf 'login=%s&password=%s' "$1" "$2" | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN"
}

session_for() {
    local raw session csrf
    raw=$(raw_login "$1" "$2")
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    csrf=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')
    echo "${session} ${csrf}"
}

start_chat() {
    local cookie="session=$1; csrf=$2"
    json_body "$(raw_post_json "/api/chat-widget-start" "{\"title\":\"$3\"}" "$cookie" "$2" "")" | jq -r '.session_id'
}

send_message() {
    local cookie="session=$1; csrf=$2"
    raw_post_json "/api/chat-widget-send" "{\"session_id\":\"$3\",\"message\":\"$4\"}" "$cookie" "$2" "$5"
}

# The assistant message holding the session's research.investigate or
# background.start call.
calling_message() {
    store "SELECT id FROM agent_message WHERE session_id = '$1' AND parent_message_id IS NULL AND role = 'assistant' AND content LIKE '%$2%' ORDER BY id LIMIT 1;"
}

@test "main conversation rows are typed by role, in the chat loop, with no parent" {
    read session csrf < <(session_for admin secret123)
    chat=$(start_chat "$session" "$csrf" "Typed")
    scripted="$(tool_call_response "entity.list_types" "{}")"$'\1'"$(done_response "There are some types.")"
    send_message "$session" "$csrf" "$chat" "what types exist" "$scripted" > /dev/null

    run store "SELECT DISTINCT role || ':' || data_type || ':' || loop_kind || ':' || COALESCE(parent_message_id, '-') FROM agent_message WHERE session_id = '${chat}' ORDER BY role;"
    [[ "$output" =~ "user:request:chat:-" ]]
    [[ "$output" =~ "assistant:answer:chat:-" ]]
    [[ "$output" =~ "tool_result:tool_trace:chat:-" ]]
    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE data_type IS NULL OR loop_kind IS NULL;")" = "0" ]
}

@test "research.investigate keeps every step under the calling message, out of context, typed reasoning then answer" {
    read session csrf < <(session_for admin secret123)
    chat=$(start_chat "$session" "$csrf" "Research")
    scripted="$(tool_call_response "research.investigate" '{"question":"what types exist"}')"$'\1'"$(tool_call_response "entity.list_types" "{}")"$'\1'"$(done_response "Found the types.")"$'\1'"$(done_response "Here are the types.")"
    send_message "$session" "$csrf" "$chat" "look into the types" "$scripted" > /dev/null
    parent=$(calling_message "$chat" "research.investigate")
    [ -n "$parent" ]

    run store "SELECT role || ':' || data_type || ':' || loop_kind || ':' || in_context FROM agent_message WHERE parent_message_id = ${parent} ORDER BY id;"
    [ "${lines[0]}" = "assistant:reasoning:research:0" ]
    [ "${lines[1]}" = "tool_result:tool_trace:research:0" ]
    [ "${lines[2]}" = "assistant:answer:research:0" ]
    [ "${#lines[@]}" -eq 3 ]
    [[ "$(store "SELECT content FROM agent_message WHERE parent_message_id = ${parent} AND data_type = 'answer';")" =~ "Found the types." ]]

    # Each research call names its parent and the step it produced.
    run store "SELECT c.step || ':' || c.parent_message_id || ':' || m.data_type FROM agent_model_call c JOIN agent_message m ON m.id = c.message_id WHERE c.session_id = '${chat}' AND c.kind = 'research' ORDER BY c.id;"
    [ "${lines[0]}" = "1:${parent}:reasoning" ]
    [ "${lines[1]}" = "2:${parent}:answer" ]
}

@test "a sub-agent's steps stay out of the chat view and the transcript; its finding is there as the call's result" {
    read session csrf < <(session_for admin secret123)
    chat=$(start_chat "$session" "$csrf" "Research")
    scripted="$(tool_call_response "research.investigate" '{"question":"what types exist"}')"$'\1'"$(tool_call_response "entity.list_types" "{}")"$'\1'"$(done_response "Found the types.")"$'\1'"$(done_response "Here are the types.")"
    send_message "$session" "$csrf" "$chat" "look into the types" "$scripted" > /dev/null

    transcript=$(store "SELECT content FROM document WHERE source_type = 'chat_session' AND source_ref = '${chat}';")
    [[ "$transcript" =~ "research.investigate" ]]
    [[ "$transcript" =~ "Found the types." ]]
    [[ ! "$transcript" =~ "entity.list_types" ]]

    run raw_get "/api/chat-widget-history" "session_id=${chat}" "session=${session}; csrf=${csrf}"
    [[ "$output" =~ "Here are the types." ]]
    [[ ! "$output" =~ "entity.list_types" ]]
}

@test "a research loop that runs out of budget leaves its last step and that step's result" {
    write_platform_config ", agent_research_max_turns = 1"
    read session csrf < <(session_for admin secret123)
    chat=$(start_chat "$session" "$csrf" "Budget")
    scripted="$(tool_call_response "research.investigate" '{"question":"what types exist"}')"$'\1'"$(tool_call_response "entity.list_types" "{}")"$'\1'"$(done_response "I could not finish.")"
    send_message "$session" "$csrf" "$chat" "look into the types" "$scripted" > /dev/null
    parent=$(calling_message "$chat" "research.investigate")

    run store "SELECT role || ':' || data_type FROM agent_message WHERE parent_message_id = ${parent} ORDER BY id;"
    [ "${lines[0]}" = "assistant:reasoning" ]
    [ "${lines[1]}" = "tool_result:tool_trace" ]
    [[ "$(store "SELECT content FROM agent_message WHERE parent_message_id = ${parent} AND role = 'assistant';")" =~ "entity.list_types" ]]
}

@test "a background task records its calling message; the worker keeps its steps under it and posts the finding in the background loop" {
    read session csrf < <(session_for admin secret123)
    chat=$(start_chat "$session" "$csrf" "Background")
    scripted="$(tool_call_response "background.start" '{"question":"what types exist"}')"$'\1'"$(done_response "On it.")"
    send_message "$session" "$csrf" "$chat" "dig into the types" "$scripted" > /dev/null
    parent=$(calling_message "$chat" "background.start")
    [ "$(store "SELECT parent_message_id FROM agent_background_task;")" = "$parent" ]

    worker_scripted="$(tool_call_response "entity.list_types" "{}")"$'\1'"$(done_response "The types are listed.")"
    AGENT_TEST_RESPONSES="$worker_scripted" run "$BIN" agent run-pending-background
    [[ "$output" =~ "Ran 1, failed 0" ]]

    run store "SELECT role || ':' || data_type || ':' || loop_kind FROM agent_message WHERE parent_message_id = ${parent} ORDER BY id;"
    [ "${lines[0]}" = "assistant:reasoning:background" ]
    [ "${lines[1]}" = "tool_result:tool_trace:background" ]
    [ "${lines[2]}" = "assistant:answer:background" ]
    # The finding posted to the conversation is the main conversation's own row.
    run store "SELECT data_type || ':' || loop_kind || ':' || in_context FROM agent_message WHERE session_id = '${chat}' AND parent_message_id IS NULL AND content LIKE '%Background research finished%';"
    [ "$output" = "answer:background:1" ]
}
