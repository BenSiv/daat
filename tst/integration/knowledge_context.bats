#!/usr/bin/env bats
# task #87: full prompt/reasoning/token persistence and chat evaluation.
# Note materialization/agent-driven review (originally covered here too)
# were removed under task #106 -- knowledge_note no longer exists as a
# separate table to materialize out of; every pool record already is a
# real document.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    "$BIN" user add admin secret123 ia
    "$BIN" user add alice secret123 i
}

teardown() {
    cleanup_test_env
}

raw_login() {
    local login="$1"
    local password="$2"
    printf 'login=%s&password=%s' "$login" "$password" | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN"
}

session_for() {
    local login="$1" password="$2"
    local raw session csrf
    raw=$(raw_login "$login" "$password")
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    csrf=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')
    echo "${session} ${csrf}"
}

start_chat() {
    local session="$1" csrf="$2" title="$3"
    printf 'csrf_token=%s&title=%s' "$csrf" "$title" | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/chat-start" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" AGENT_PROVIDER=test "$BIN" \
        | grep -o 'session_id=[a-f0-9]*' | head -1 | sed 's/session_id=//'
}

send_message() {
    local session="$1" csrf="$2" chat_session_id="$3" message="$4" scripted="$5"
    printf 'csrf_token=%s&session_id=%s&message=%s' "$csrf" "$chat_session_id" "$message" | \
        AGENT_PROVIDER=test AGENT_TEST_RESPONSES="$scripted" \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/chat-message" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" "$BIN"
}

@test "a real chat turn persists the exact prompt and real token counts in knowledge_context" {
    read session csrf < <(session_for admin secret123)
    chat_session=$(start_chat "$session" "$csrf" "Test")
    send_message "$session" "$csrf" "$chat_session" "hello" "" > /dev/null

    run sqlite3 .store/store.db "SELECT session_id, model_id, prompt_tokens, completion_tokens FROM knowledge_context;"
    [[ "$output" =~ "$chat_session" ]]
    [[ "$output" =~ "gemini-2.5-flash" ]]
    # Real (estimated-under-test-provider) counts, not nil/empty.
    [[ ! "$output" =~ "||" ]]
}

@test "a real chat turn records a knowledge_chat_eval row classified as 'final'" {
    read session csrf < <(session_for admin secret123)
    chat_session=$(start_chat "$session" "$csrf" "Test")
    send_message "$session" "$csrf" "$chat_session" "hello" "$(done_response "A clean final answer.")" > /dev/null

    run sqlite3 .store/store.db "SELECT session_id, provider, reply_kind, quality_status FROM knowledge_chat_eval;"
    [[ "$output" =~ "$chat_session" ]]
    [[ "$output" =~ "test|final|ok" ]]
}

@test "a reply leaking visible reasoning creates a linked reasoning document under the Knowledge Pool folder" {
    read session csrf < <(session_for admin secret123)
    chat_session=$(start_chat "$session" "$csrf" "Test")
    send_message "$session" "$csrf" "$chat_session" "hi" "$(done_response "<think>internal reasoning</think>")" > /dev/null

    run sqlite3 .store/store.db "SELECT tier, source_type FROM document WHERE source_type='reasoning';"
    [[ "$output" =~ "0|reasoning" ]]

    run sqlite3 .store/store.db "SELECT reply_kind, reasoning_status FROM knowledge_chat_eval ORDER BY id DESC LIMIT 1;"
    [[ "$output" =~ "reasoning-visible|visible" ]]

    run sqlite3 .store/store.db "SELECT context.reasoning_document_id FROM knowledge_context context ORDER BY context.id DESC LIMIT 1;"
    [[ "$output" != "" ]]

    # Lands under the Knowledge Pool folder, not at the top level.
    run sqlite3 .store/store.db "SELECT d.title FROM document d JOIN document parent ON parent.id = d.parent_id WHERE d.source_type = 'reasoning' AND parent.title = 'Knowledge Pool';"
    [[ "$output" =~ "Chat reasoning" ]]
}

@test "a real Gemini thinking block creates a reasoning document, and its content stays out of the visible chat reply" {
    read session csrf < <(session_for admin secret123)
    chat_session=$(start_chat "$session" "$csrf" "Test")
    send_message "$session" "$csrf" "$chat_session" "hi" \
        "$(thinking_response "the user said hi, I should greet them back" "Hello there!")" > /dev/null

    run sqlite3 .store/store.db "SELECT tier, source_type FROM document WHERE source_type='reasoning';"
    [[ "$output" =~ "0|reasoning" ]]

    # The reasoning document's own content is the real thinking text...
    run sqlite3 .store/store.db "SELECT content FROM document WHERE source_type='reasoning';"
    [[ "$output" =~ "the user said hi" ]]

    # ...while the chat transcript only ever shows the clean final answer.
    run env GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/chat" \
        QUERY_STRING="session_id=${chat_session}" HTTP_COOKIE="session=${session}; csrf=${csrf}" "$BIN"
    [[ "$output" =~ "Hello there!" ]]
    [[ ! "$output" =~ "the user said hi" ]]
}

@test "a provider failure still records knowledge_context/knowledge_chat_eval as an error, never reaching a real model call" {
    read session csrf < <(session_for admin secret123)
    chat_session=$(start_chat "$session" "$csrf" "Test")
    printf 'csrf_token=%s&session_id=%s&message=hi' "$csrf" "$chat_session" | \
        AGENT_PROVIDER=nonexistent-provider \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/chat-message" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" "$BIN" > /dev/null

    run sqlite3 .store/store.db "SELECT reply_kind, quality_status FROM knowledge_chat_eval ORDER BY id DESC LIMIT 1;"
    [[ "$output" =~ "error|error" ]]
}

@test "knowledge.distill proposes a new distilled document, gated behind approval, then creates it under the Knowledge Pool folder once approved" {
    # Created via the real entity path (not a raw SQL insert) -- document
    # rows get their id from ledger.append_create's own auto-increment
    # sequence, so a hand-inserted row with an explicit id would collide
    # with the next entity.create call's id.
    "$BIN" entity create document title="Sprawling page" content="Long unfocused content."
    source_id=$(sqlite3 .store/store.db "SELECT id FROM document WHERE title = 'Sprawling page';")

    read session csrf < <(session_for admin secret123)
    chat_session=$(start_chat "$session" "$csrf" "Test")
    scripted="$(tool_call_response "knowledge.distill" "{\"title\":\"Core idea\",\"content\":\"The one core idea, distilled.\",\"source_document_id\":${source_id}}")"
    send_message "$session" "$csrf" "$chat_session" "distill the sprawling page" "$scripted" > /dev/null

    run sqlite3 .store/store.db "SELECT status, tool, method FROM agent_pending_action;"
    [[ "$output" =~ "pending|knowledge|distill" ]]
    # Nothing written yet -- still just a pending action.
    run sqlite3 .store/store.db "SELECT COUNT(*) FROM document WHERE title = 'Core idea';"
    [ "$output" -eq 0 ]

    pending_id=$(sqlite3 .store/store.db "SELECT id FROM agent_pending_action;")
    printf 'csrf_token=%s&pending_id=%s&session_id=%s' "$csrf" "$pending_id" "$chat_session" | \
        AGENT_PROVIDER=test AGENT_TEST_RESPONSES="$(done_response "Distilled.")" \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/chat-approve" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" "$BIN" > /dev/null

    run sqlite3 .store/store.db "SELECT tier, source_type, source_id FROM document WHERE title = 'Core idea';"
    [[ "$output" =~ "0|distilled|${source_id}" ]]

    # Lands under the Knowledge Pool folder, not at the top level.
    run sqlite3 .store/store.db "SELECT d.title FROM document d JOIN document parent ON parent.id = d.parent_id WHERE d.title = 'Core idea' AND parent.title = 'Knowledge Pool';"
    [[ "$output" =~ "Core idea" ]]
}

@test "platform knowledge distill runs an agent turn that proposes distill, gated behind approval" {
    # Created via the real entity path (not a raw SQL insert) -- document
    # rows get their id from ledger.append_create's own auto-increment
    # sequence, so a hand-inserted row with an explicit id would collide
    # with the next entity.create call's id.
    "$BIN" entity create document title="Sprawling page" content="Long unfocused content."
    source_id=$(sqlite3 .store/store.db "SELECT id FROM document WHERE title = 'Sprawling page';")

    USER=admin AGENT_PROVIDER=test \
        AGENT_TEST_RESPONSES="$(tool_call_response "knowledge.distill" "{\"title\":\"Core idea\",\"content\":\"The one core idea, distilled.\",\"source_document_id\":${source_id}}")" \
        run "$BIN" knowledge distill
    [[ "$output" =~ "Status: pending_approval" ]]
    [[ "$output" =~ "knowledge.distill" ]]

    # Nothing written yet -- still just a pending action, same as any
    # other destructive tool call.
    run sqlite3 .store/store.db "SELECT COUNT(*) FROM document WHERE title = 'Core idea';"
    [ "$output" -eq 0 ]
    run sqlite3 .store/store.db "SELECT status FROM agent_pending_action;"
    [[ "$output" == "pending" ]]
}

@test "chat feedback is recorded for the owning user and rejected for anyone else" {
    read session csrf < <(session_for admin secret123)
    chat_session=$(start_chat "$session" "$csrf" "Test")
    send_message "$session" "$csrf" "$chat_session" "hi" "" > /dev/null
    message_id=$(sqlite3 .store/store.db "SELECT id FROM agent_message WHERE role='assistant' ORDER BY id DESC LIMIT 1;")

    output=$(printf '{"message_id":%s,"feedback":"up"}' "$message_id" | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/chat-widget-feedback" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" HTTP_X_CSRF_TOKEN="${csrf}" AGENT_PROVIDER=test "$BIN")
    [[ "$output" =~ '"ok":true' ]]
    run sqlite3 .store/store.db "SELECT user_feedback FROM knowledge_chat_eval WHERE message_id = ${message_id};"
    [[ "$output" == "up" ]]

    read alice_session alice_csrf < <(session_for alice secret123)
    output=$(printf '{"message_id":%s,"feedback":"down"}' "$message_id" | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/chat-widget-feedback" QUERY_STRING="" \
        HTTP_COOKIE="session=${alice_session}; csrf=${alice_csrf}" HTTP_X_CSRF_TOKEN="${alice_csrf}" AGENT_PROVIDER=test "$BIN")
    [[ "$output" =~ "404 Not Found" ]]
    run sqlite3 .store/store.db "SELECT user_feedback FROM knowledge_chat_eval WHERE message_id = ${message_id};"
    [[ "$output" == "up" ]]
}

@test "chat feedback buttons get an immediate pressed state and a real error message on failure, not silent no-op (task #115)" {
    read session csrf < <(session_for admin secret123)
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" run "$BIN"
    [[ "$output" =~ "e.target.classList.add('fossci-feedback-pressed')" ]]
    [[ "$output" =~ "b.disabled = true" ]]
    [[ "$output" =~ "showFeedbackError" ]]
    [[ "$output" =~ "Couldn\\'t record feedback." ]]
}
