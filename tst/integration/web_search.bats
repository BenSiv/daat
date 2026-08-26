#!/usr/bin/env bats
# tst/integration/web_search.bats
# Integration tests for the internet_search.search agent tool
# (src/web_search.lua, dispatched from src/agent.lua): the destructive-
# tool approval flow around it, and WEB_SEARCH_TEST_RESULTS (mirrors
# AGENT_TEST_RESPONSES, but scoped to this one tool's own external side
# effect -- see src/web_search.lua's own header for why this is the
# first tool needing that).

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    "$BIN" user add alice secret123 i

    raw=$(printf 'login=alice&password=secret123' | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN")
    SESSION=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    CSRF=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')
    COOKIE="session=${SESSION}; csrf=${CSRF}"
}

teardown() {
    cleanup_test_env
}

start_chat() {
    local cookie="$1"
    local csrf="$2"
    local title="$3"
    local resp sid
    resp=$(raw_post_json "/api/chat-widget-start" "{\"title\":\"${title}\"}" "$cookie" "$csrf" "")
    sid=$(json_body "$resp" | jq -r '.session_id')
    printf 'session_id=%s' "$sid"
}

@test "internet_search.search is destructive: pauses for approval instead of executing" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "internet_search.search" '{"query":"celleste bio"}')"
    run raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${session_id}\",\"message\":\"search for celleste bio\"}" "$COOKIE" "$CSRF" "$scripted"
    [[ "$output" =~ "200 OK" ]]
    [[ "$(json_body "$output" | jq -r '.pending.tool')" = "internet_search" ]]
    [[ "$(json_body "$output" | jq -r '.pending.method')" = "search" ]]
    # The query itself is already visible to whoever approves -- the
    # generic pending-action arg renderer (src/html.lua) shows every
    # arg verbatim, no tool-specific UI work needed.
    [[ "$(json_body "$output" | jq -r '.pending.args.query')" = "celleste bio" ]]
}

@test "approving a search runs the fake backend (WEB_SEARCH_TEST_RESULTS) and the result cites the source URL" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "internet_search.search" '{"query":"celleste bio"}')"
    send_resp=$(raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${session_id}\",\"message\":\"search for celleste bio\"}" "$COOKIE" "$CSRF" "$scripted")
    pending_id=$(json_body "$send_resp" | jq -r '.pending.id')

    export WEB_SEARCH_TEST_RESULTS='{"items":[{"title":"Celleste Bio","link":"https://celleste-bio.example/","snippet":"Celleste Bio official site."}]}'
    run raw_post_json "/api/chat-widget-approve" "{\"pending_id\":${pending_id},\"session_id\":\"${session_id}\"}" "$COOKIE" "$CSRF" "$(done_response "Found it, see the link.")"
    unset WEB_SEARCH_TEST_RESULTS
    [[ "$output" =~ "200 OK" ]]

    run latest_tool_result "$session_id"
    [[ "$output" =~ "Celleste Bio (https://celleste-bio.example/)" ]]
    [[ "$output" =~ "Celleste Bio official site." ]]
}

@test "denying a search never calls the backend, and records the denial" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "internet_search.search" '{"query":"celleste bio"}')"
    send_resp=$(raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${session_id}\",\"message\":\"search for celleste bio\"}" "$COOKIE" "$CSRF" "$scripted")
    pending_id=$(json_body "$send_resp" | jq -r '.pending.id')

    # Deliberately no WEB_SEARCH_TEST_RESULTS set -- if the backend were
    # ever called on a denial, and no real credentials exist in this
    # test environment, that would surface as a credentials error
    # instead of the plain denial message below, making this a real
    # (not just asserted) check that denial short-circuits before
    # web_search.search runs at all.
    run raw_post_json "/api/chat-widget-deny" "{\"pending_id\":${pending_id},\"session_id\":\"${session_id}\"}" "$COOKIE" "$CSRF" "$(done_response "Understood.")"
    [[ "$output" =~ "200 OK" ]]

    run latest_tool_result "$session_id"
    [[ "$output" =~ "denied" ]]
}

@test "approving a search with no credentials and no test results configured surfaces a clean error, not a crash" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "internet_search.search" '{"query":"celleste bio"}')"
    send_resp=$(raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${session_id}\",\"message\":\"search for celleste bio\"}" "$COOKIE" "$CSRF" "$scripted")
    pending_id=$(json_body "$send_resp" | jq -r '.pending.id')

    run raw_post_json "/api/chat-widget-approve" "{\"pending_id\":${pending_id},\"session_id\":\"${session_id}\"}" "$COOKIE" "$CSRF" "$(done_response "Handled.")"
    [[ "$output" =~ "200 OK" ]]

    run latest_tool_result "$session_id"
    [[ "$output" =~ "GOOGLE_SEARCH_API_KEY is not set" ]]
}
