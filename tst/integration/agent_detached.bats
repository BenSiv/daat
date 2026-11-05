#!/usr/bin/env bats

# Detached chat turns (agent.lua, "Detached turns"): the send request
# records the message and starts a `daat agent continue` worker; the
# widget polls until the session is no longer running. These run real
# worker processes against the scripted test provider -- the worker
# inherits AGENT_TEST_RESPONSES from the request that spawned it.

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
    write_platform_config ', agent_turn_mode = "detached"'
    # The worker is started with the CGI's own binary (SCRIPT_FILENAME).
    export SCRIPT_FILENAME="$BIN"
}

teardown() {
    cleanup_test_env
}

# A busy timeout: the worker writes the store while the test polls it.
store() {
    sqlite3 -cmd ".timeout 5000" "$TEST_DIR/.store/store.db" "$1"
}

new_session() {
    json_body "$(raw_post_json "/api/chat-widget-start" '{"title":"Chat"}' "$COOKIE" "$CSRF" "")" | jq -r '.session_id'
}

# Waits (up to 10 s) for the worker to set the session idle.
wait_idle() {
    local i
    for i in $(seq 1 50); do
        [ "$(store "SELECT turn_state FROM agent_session WHERE id = '$1';")" = "idle" ] && return 0
        sleep 0.2
    done
    cat "$TEST_DIR/.store/agent-worker.log" >&2
    return 1
}

@test "a send answers at once with running, and a worker writes the reply" {
    sid=$(new_session)
    run raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${sid}\",\"message\":\"What is 2+2?\"}" "$COOKIE" "$CSRF" "$(done_response "2+2 is 4.")"
    [[ "$output" =~ "200 OK" ]]
    [ "$(json_body "$output" | jq -r '.running')" = "true" ]
    [ "$(json_body "$output" | jq -r '.messages[-1].role')" = "user" ]

    wait_idle "$sid"
    run raw_get "/api/chat-widget-history" "session_id=${sid}" "$COOKIE"
    [ "$(json_body "$output" | jq -r '.running')" = "false" ]
    [[ "$(json_body "$output" | jq -r '.messages[-1].content')" =~ "2+2 is 4." ]]
    [ -n "$(store "SELECT turn_heartbeat_at FROM agent_session WHERE id = '${sid}';")" ]
}

@test "a second message while a turn is running is refused" {
    sid=$(new_session)
    store "UPDATE agent_session SET turn_state = 'running', turn_heartbeat_at = '$(date -u '+%Y-%m-%d %H:%M:%S')' WHERE id = '${sid}';"
    run raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${sid}\",\"message\":\"again\"}" "$COOKIE" "$CSRF" "$(done_response "x")"
    [[ "$output" =~ "409 Conflict" ]]
    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${sid}';")" = "0" ]
}

@test "a running turn with no heartbeat for too long is reported once, as an error row, and the session freed" {
    sid=$(new_session)
    store "UPDATE agent_session SET turn_state = 'running', turn_heartbeat_at = '2000-01-01 00:00:00' WHERE id = '${sid}';"
    run raw_get "/api/chat-widget-history" "session_id=${sid}" "$COOKIE"
    [ "$(json_body "$output" | jq -r '.running')" = "false" ]
    [[ "$(json_body "$output" | jq -r '.messages[-1].content')" =~ "stopped before finishing" ]]
    run raw_get "/api/chat-widget-history" "session_id=${sid}" "$COOKIE"
    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${sid}' AND role = 'error';")" = "1" ]
    [ "$(store "SELECT turn_state FROM agent_session WHERE id = '${sid}';")" = "idle" ]
}

@test "a long research.investigate keeps the turn's heartbeat alive -- it isn't settled as stalled mid-investigation" {
    # Stale after 3 s; every model call takes 1 s. The investigation
    # makes three of them inside one tool call (4+ s without a beat of
    # its own); elsewhere at most two calls run back to back (the final
    # answer and its self-check, ~2 s).
    write_platform_config ', agent_turn_mode = "detached", agent_turn_stale_seconds = 3'
    export AGENT_TEST_CONVERSE_DELAY=1
    sid=$(new_session)
    scripted="$(tool_call_response "research.investigate" '{"question":"what types exist"}')"$'\1'"$(tool_call_response "entity.list_types" "{}")"$'\1'"$(tool_call_response "entity.list_types" "{}")"$'\1'"$(done_response "There is a task type.")"$'\1'"$(done_response "Found it: task.")"
    raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${sid}\",\"message\":\"investigate the types\"}" "$COOKIE" "$CSRF" "$scripted" >/dev/null

    # Poll the way the widget does -- each read settles a stale turn.
    for i in $(seq 1 60); do
        run raw_get "/api/chat-widget-history" "session_id=${sid}" "$COOKIE"
        [ "$(json_body "$output" | jq -r '.running')" = "false" ] && break
        sleep 0.25
    done
    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${sid}' AND role = 'error';")" = "0" ]
    [[ "$(json_body "$output" | jq -r '.messages[-1].content')" =~ "Found it: task." ]]
}

@test "denying a pending action hands the rest of the turn to a worker" {
    sid=$(new_session)
    scripted="$(tool_call_response "document.create" '{"title":"Denied Page","content":"hello"}')"
    send_resp=$(raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${sid}\",\"message\":\"create a page\"}" "$COOKIE" "$CSRF" "$scripted")
    wait_idle "$sid"
    pending_id=$(json_body "$(raw_get "/api/chat-widget-history" "session_id=${sid}" "$COOKIE")" | jq -r '.pending.id')
    [ "$pending_id" != "null" ]

    run raw_post_json "/api/chat-widget-deny" "{\"pending_id\":${pending_id},\"session_id\":\"${sid}\"}" "$COOKIE" "$CSRF" "$(done_response "Understood, not creating it.")"
    [[ "$output" =~ "200 OK" ]]
    wait_idle "$sid"
    [ "$(store "SELECT COUNT(*) FROM document WHERE title = 'Denied Page';")" = "0" ]
    run raw_get "/api/chat-widget-history" "session_id=${sid}" "$COOKIE"
    [[ "$(json_body "$output" | jq -r '.messages[-1].content')" =~ "Understood, not creating it." ]]
}

@test "a MALFORMED_FUNCTION_CALL reply is retried once before it's an error" {
    write_platform_config ''
    sid=$(new_session)
    malformed='{"content":[],"stopReason":"error","errorMessage":"Vertex AI stopped generating (finishReason: MALFORMED_FUNCTION_CALL)"}'
    scripted="${malformed}"$'\1'"$(done_response "Recovered.")"
    run raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${sid}\",\"message\":\"hi\"}" "$COOKIE" "$CSRF" "$scripted"
    [[ "$(json_body "$output" | jq -r '.messages[-1].content')" =~ "Recovered." ]]
    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${sid}' AND role = 'error';")" = "0" ]
    # Both attempts were real calls, so both are recorded for step 1.
    [ "$(store "SELECT COUNT(*) FROM agent_model_call WHERE session_id = '${sid}' AND kind = 'chat' AND step = 1;")" = "2" ]
    # The retry says what went wrong (resending the same request failed
    # the same way on daat-test); the stored history doesn't carry it.
    [[ "$(store "SELECT prompt FROM agent_model_call WHERE session_id = '${sid}' AND kind = 'chat' AND step = 1 ORDER BY id DESC LIMIT 1;")" =~ "could not be parsed (MALFORMED_FUNCTION_CALL / MALFORMED_RESPONSE)" ]]
    [[ ! "$(store "SELECT prompt FROM agent_model_call WHERE session_id = '${sid}' AND kind = 'chat' AND step = 1 ORDER BY id ASC LIMIT 1;")" =~ "could not be parsed" ]]
    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${sid}' AND content LIKE '%could not be parsed%';")" = "0" ]
}

@test "a MALFORMED_RESPONSE reply is retried once too" {
    write_platform_config ''
    sid=$(new_session)
    malformed='{"content":[],"stopReason":"error","errorMessage":"empty response (finishReason: MALFORMED_RESPONSE)"}'
    scripted="${malformed}"$'\1'"$(done_response "Recovered.")"
    run raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${sid}\",\"message\":\"hi\"}" "$COOKIE" "$CSRF" "$scripted"
    [[ "$(json_body "$output" | jq -r '.messages[-1].content')" =~ "Recovered." ]]
    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${sid}' AND role = 'error';")" = "0" ]
}

@test "agent continue with no session id prints its usage" {
    run "$BIN" agent continue
    [[ "$output" =~ "Usage: daat agent continue <session_id>" ]]
}

# No-tools calls (a progress note, the closing status update) don't take
# from AGENT_TEST_RESPONSES: the test provider answers them with
# AGENT_TEST_SELF_CHECK_RESPONSE (provider/agent_test.lua).

@test "a detached turn that spends its step budget goes on by itself, with a progress note, and finishes" {
    write_platform_config ', agent_turn_mode = "detached", agent_max_turns = 1, agent_auto_continue_max = 2'
    export AGENT_TEST_SELF_CHECK_RESPONSE="$(done_response "Listed the types; checking fields next.")"
    sid=$(new_session)
    scripted="$(tool_call_response "entity.list_types" '{}')"$'\1'"$(done_response "Final answer.")"
    raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${sid}\",\"message\":\"what types are there?\"}" "$COOKIE" "$CSRF" "$scripted" >/dev/null
    wait_idle "$sid"
    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${sid}' AND role = 'progress';")" = "1" ]
    run raw_get "/api/chat-widget-history" "session_id=${sid}" "$COOKIE"
    [ "$(json_body "$output" | jq -r '.messages[-1].is_final')" = "true" ]
    [[ "$(json_body "$output" | jq -r '.messages[-1].content')" =~ "Final answer." ]]
    [[ "$(json_body "$output" | jq -r '[.messages[] | select(.role == "progress")][0].content')" =~ "checking fields next" ]]
}

@test "auto-continue stops at agent_auto_continue_max and reports where it got to" {
    write_platform_config ', agent_turn_mode = "detached", agent_max_turns = 1, agent_auto_continue_max = 1'
    export AGENT_TEST_SELF_CHECK_RESPONSE="$(done_response "Status: still looking.")"
    sid=$(new_session)
    # One scripted tool call, repeated: every step budget ends unanswered.
    raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${sid}\",\"message\":\"dig\"}" "$COOKIE" "$CSRF" "$(tool_call_response "entity.list_types" '{}')" >/dev/null
    wait_idle "$sid"
    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${sid}' AND role = 'progress';")" = "1" ]
    run raw_get "/api/chat-widget-history" "session_id=${sid}" "$COOKIE"
    [ "$(json_body "$output" | jq -r '.messages[-1].role')" = "assistant" ]
    [[ "$(json_body "$output" | jq -r '.messages[-1].content')" =~ "Status: still looking." ]]
}

@test "an inline turn never auto-continues" {
    write_platform_config ', agent_turn_mode = "inline", agent_max_turns = 1, agent_auto_continue_max = 3'
    export AGENT_TEST_SELF_CHECK_RESPONSE="$(done_response "Status: out of steps.")"
    sid=$(new_session)
    run raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${sid}\",\"message\":\"dig\"}" "$COOKIE" "$CSRF" "$(tool_call_response "entity.list_types" '{}')"
    [[ "$(json_body "$output" | jq -r '.messages[-1].content')" =~ "Status: out of steps." ]]
    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${sid}' AND role = 'progress';")" = "0" ]
}

@test "auto-continue also stops at agent_auto_continue_minutes, with budgets still left" {
    # No time at all: the first budget's end is already past the limit,
    # so the turn stops there although agent_auto_continue_max allows 5.
    write_platform_config ', agent_turn_mode = "detached", agent_max_turns = 1, agent_auto_continue_max = 5, agent_auto_continue_minutes = 0'
    export AGENT_TEST_SELF_CHECK_RESPONSE="$(done_response "Status: out of time.")"
    sid=$(new_session)
    raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${sid}\",\"message\":\"dig\"}" "$COOKIE" "$CSRF" "$(tool_call_response "entity.list_types" '{}')" >/dev/null
    wait_idle "$sid"
    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${sid}' AND role = 'progress';")" = "0" ]
    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${sid}' AND role = 'tool_result';")" = "1" ]
    run raw_get "/api/chat-widget-history" "session_id=${sid}" "$COOKIE"
    [ "$(json_body "$output" | jq -r '.messages[-1].role')" = "assistant" ]
    [[ "$(json_body "$output" | jq -r '.messages[-1].content')" =~ "Status: out of time." ]]
}

@test "a stop clicked while the worker is mid-turn ends the turn at the next step, with a wrap-up" {
    # Every model call takes 2 s. The stop lands about 1 s in, while
    # step 1's call is under way: step 1 still runs its tool, and the
    # check before step 2 consumes the flag.
    export AGENT_TEST_CONVERSE_DELAY=2
    export AGENT_TEST_SELF_CHECK_RESPONSE="$(done_response "Stopped after listing the types.")"
    sid=$(new_session)
    scripted="$(tool_call_response "entity.list_types" '{}')"$'\1'"$(tool_call_response "entity.relationships" '{}')"$'\1'"$(done_response "Never reached.")"
    raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${sid}\",\"message\":\"dig\"}" "$COOKIE" "$CSRF" "$scripted" >/dev/null
    sleep 1
    run raw_post_json "/api/chat-widget-stop" "{\"session_id\":\"${sid}\"}" "$COOKIE" "$CSRF"
    [[ "$output" =~ "200 OK" ]]
    wait_idle "$sid"

    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${sid}' AND role = 'tool_result';")" = "1" ]
    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${sid}' AND content LIKE '%entity.relationships%';")" = "0" ]
    run raw_get "/api/chat-widget-history" "session_id=${sid}" "$COOKIE"
    [[ "$(json_body "$output" | jq -r '.messages[-1].content')" =~ "Stopped after listing the types." ]]
    [[ ! "$output" =~ "Never reached." ]]
    [ "$(store "SELECT cancel_requested FROM agent_session WHERE id = '${sid}';")" = "0" ]
}

@test "approving a pending action hands the rest of the turn to a worker, which runs the write once and answers" {
    sid=$(new_session)
    scripted="$(tool_call_response "document.create" '{"title":"Approved Page","content":"hello"}')"
    raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${sid}\",\"message\":\"create a page\"}" "$COOKIE" "$CSRF" "$scripted" >/dev/null
    wait_idle "$sid"
    pending_id=$(json_body "$(raw_get "/api/chat-widget-history" "session_id=${sid}" "$COOKIE")" | jq -r '.pending.id')
    [ "$pending_id" != "null" ]

    run raw_post_json "/api/chat-widget-approve" "{\"pending_id\":${pending_id},\"session_id\":\"${sid}\"}" "$COOKIE" "$CSRF" "$(done_response "Created it.")"
    [[ "$output" =~ "200 OK" ]]
    wait_idle "$sid"
    [ "$(store "SELECT COUNT(*) FROM document WHERE title = 'Approved Page';")" = "1" ]
    page_id=$(store "SELECT id FROM document WHERE title = 'Approved Page';")
    run "$BIN" entity show document "$page_id"
    [[ "$output" =~ created_by[[:space:]]+alice ]]
    [ "$(store "SELECT status FROM agent_pending_action WHERE id = ${pending_id};")" = "approved" ]
    run raw_get "/api/chat-widget-history" "session_id=${sid}" "$COOKIE"
    [ "$(json_body "$output" | jq -r '.pending')" = "null" ]
    [[ "$(json_body "$output" | jq -r '.messages[-1].content')" =~ "Created it." ]]
}

@test "a second malformed reply in a row isn't retried again: the turn ends in a visible error" {
    write_platform_config ''
    for reason in MALFORMED_FUNCTION_CALL MALFORMED_RESPONSE; do
        sid=$(new_session)
        malformed="{\"content\":[],\"stopReason\":\"error\",\"errorMessage\":\"stopped generating (finishReason: ${reason})\"}"
        scripted="${malformed}"$'\1'"${malformed}"$'\1'"$(done_response "Never reached.")"
        run raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${sid}\",\"message\":\"hi\"}" "$COOKIE" "$CSRF" "$scripted"
        [ "$(json_body "$output" | jq -r '.messages[-1].role')" = "error" ]
        [[ "$(json_body "$output" | jq -r '.messages[-1].content')" =~ "$reason" ]]
        [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${sid}' AND role = 'error';")" = "1" ]
        [ "$(store "SELECT COUNT(*) FROM agent_model_call WHERE session_id = '${sid}' AND kind = 'chat';")" = "2" ]
        [[ ! "$output" =~ "Never reached." ]]
    done
}
