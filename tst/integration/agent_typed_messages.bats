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

@test "by default a chat writes no transcript document" {
    read session csrf < <(session_for admin secret123)
    chat=$(start_chat "$session" "$csrf" "No transcript")
    send_message "$session" "$csrf" "$chat" "hello" "$(done_response "Hi.")" > /dev/null
    [ "$(store "SELECT COUNT(*) FROM document WHERE source_type = 'chat_session';")" = "0" ]
}

@test "a sub-agent's steps stay out of the chat view; a kept transcript has its finding and reasoning, never tool output" {
    write_config 'agent = {transcript_documents = "whole"}'
    read session csrf < <(session_for admin secret123)
    chat=$(start_chat "$session" "$csrf" "Research")
    scripted="$(tool_call_response "research.investigate" '{"question":"what types exist"}')"$'\1'"$(tool_call_response "entity.list_types" "{}")"$'\1'"$(done_response "Found the types.")"$'\1'"$(done_response "Here are the types.")"
    send_message "$session" "$csrf" "$chat" "look into the types" "$scripted" > /dev/null

    transcript=$(store "SELECT content FROM document WHERE source_type = 'chat_session' AND source_ref = '${chat}';")
    [[ "$transcript" =~ "User: look into the types" ]]
    [[ "$transcript" =~ "Research finding: Found the types." ]]
    [[ "$transcript" =~ "Assistant: Here are the types." ]]
    [[ ! "$transcript" =~ "entity.list_types" ]]
    [[ ! "$transcript" =~ "Tool result" ]]

    run raw_get "/api/v1/chat/sessions/${chat}" "" "session=${session}; csrf=${csrf}"
    [[ "$output" =~ "Here are the types." ]]
    [[ ! "$output" =~ "entity.list_types" ]]
}

@test "a research loop that runs out of budget leaves its last step and that step's result" {
    write_config "agent = {research_max_turns = 1}"
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

# A proposed document.create waiting for approval; prints the pending id.
propose_create() {
    local cookie="session=$1; csrf=$2"
    local resp
    resp=$(raw_post_json "/api/v1/chat/sessions/$3/messages" "{\"message\":\"create a page\"}" "$cookie" "$2" "$(tool_call_response "document.create" "$4")")
    json_body "$resp" | jq -r '.pending.id'
}

@test "an approval is a decision row, a request out of context, between the call and its result" {
    read session csrf < <(session_for admin secret123)
    chat=$(start_chat "$session" "$csrf" "Decide")
    pending=$(propose_create "$session" "$csrf" "$chat" '{"title":"Approved Page","content":"hello"}')
    raw_post_json "/api/v1/chat/sessions/${chat}/approve" "{\"pending_id\":${pending}}" "session=${session}; csrf=${csrf}" "$csrf" "$(done_response "Created.")" > /dev/null

    run store "SELECT role || ':' || COALESCE(data_type, '') || ':' || in_context FROM agent_message WHERE session_id = '${chat}' AND role IN ('assistant', 'decision', 'tool_result') ORDER BY id LIMIT 3;"
    [ "${lines[0]}" = "assistant:answer:1" ]
    [ "${lines[1]}" = "decision:request:0" ]
    [ "${lines[2]}" = "tool_result:tool_trace:1" ]
    run store "SELECT content FROM agent_message WHERE session_id = '${chat}' AND role = 'decision';"
    [[ "$output" =~ "Approved document.create (pending action #${pending}): " ]]
    [[ "$output" =~ "Approved Page" ]]
    [[ ! "$output" =~ "Reason:" ]]

    # Shown in the conversation, labelled as a decision.
    run raw_get "/api/v1/chat/sessions/${chat}" "" "session=${session}; csrf=${csrf}"
    [[ "$output" =~ "Approved document.create" ]]

    # A second approval loses the claim and writes nothing more.
    raw_post_json "/api/v1/chat/sessions/${chat}/approve" "{\"pending_id\":${pending}}" "session=${session}; csrf=${csrf}" "$csrf" "$(done_response "Again.")" > /dev/null
    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${chat}' AND role = 'decision';")" = "1" ]
}

@test "a denial's reason goes into the decision row and the result the model reads; without one, neither has a reason" {
    read session csrf < <(session_for admin secret123)
    cookie="session=${session}; csrf=${csrf}"
    chat=$(start_chat "$session" "$csrf" "Deny")
    pending=$(propose_create "$session" "$csrf" "$chat" '{"title":"Denied Page","content":"hello"}')
    raw_post_json "/api/v1/chat/sessions/${chat}/deny" "{\"pending_id\":${pending},\"reason\":\"  still in use for Exp412  \"}" "$cookie" "$csrf" "$(done_response "Understood.")" > /dev/null

    run store "SELECT content FROM agent_message WHERE session_id = '${chat}' AND role = 'decision';"
    [[ "$output" =~ "Denied document.create (pending action #${pending}): " ]]
    [[ "$output" =~ ". Reason: still in use for Exp412" ]]
    run latest_tool_result "$chat"
    [[ "$output" =~ "User denied execution of this action. Reason: still in use for Exp412" ]]

    chat2=$(start_chat "$session" "$csrf" "Deny again")
    pending2=$(propose_create "$session" "$csrf" "$chat2" '{"title":"Other Page","content":"hello"}')
    raw_post_json "/api/v1/chat/sessions/${chat2}/deny" "{\"pending_id\":${pending2},\"reason\":\"   \"}" "$cookie" "$csrf" "$(done_response "Understood.")" > /dev/null
    run store "SELECT content FROM agent_message WHERE session_id = '${chat2}' AND role = 'decision';"
    [[ "$output" =~ "Denied document.create" ]]
    [[ ! "$output" =~ "Reason:" ]]
    run latest_tool_result "$chat2"
    [[ ! "$output" =~ "Reason:" ]]
}

@test "a decision row cuts long arguments" {
    read session csrf < <(session_for admin secret123)
    chat=$(start_chat "$session" "$csrf" "Long")
    long=$(printf 'x%.0s' $(seq 1 2000))
    pending=$(propose_create "$session" "$csrf" "$chat" "{\"title\":\"Long Page\",\"content\":\"${long}\"}")
    raw_post_json "/api/v1/chat/sessions/${chat}/deny" "{\"pending_id\":${pending}}" "session=${session}; csrf=${csrf}" "$csrf" "$(done_response "Ok.")" > /dev/null
    length=$(store "SELECT LENGTH(content) FROM agent_message WHERE session_id = '${chat}' AND role = 'decision';")
    [ "$length" -lt 400 ]
}

@test "agent_thinking defaults to summary, honors off/full, and captures thinking across chat, research, background, self-check, compaction and wrapup" {
    read session csrf < <(session_for admin secret123)

    # Explicit agent_thinking = "off" disables thinking capture.
    write_config 'agent = {thinking = "off"}'
    off_chat=$(start_chat "$session" "$csrf" "Off")
    AGENT_TEST_THINKING="should not appear" send_message "$session" "$csrf" "$off_chat" "hello" "$(done_response "Plain reply.")" > /dev/null
    run store "SELECT content FROM agent_message WHERE session_id = '${off_chat}';"
    [[ ! "$output" =~ "should not appear" ]]

    # Unset (and unrecognized values falling back to default) uses "summary": thinking is captured in agent_message across loops and never creates pool documents.
    write_config 'agent = {thinking = "bogus"}'
    bogus_chat=$(start_chat "$session" "$csrf" "Bogus")
    AGENT_TEST_THINKING="default-summary-thought" send_message "$session" "$csrf" "$bogus_chat" "hello" "$(done_response "Plain reply.")" > /dev/null
    run store "SELECT content FROM agent_message WHERE session_id = '${bogus_chat}';"
    [[ "$output" =~ "default-summary-thought" ]]

    write_config
    chat=$(start_chat "$session" "$csrf" "Thinking")
    scripted="$(tool_call_response "research.investigate" '{"question":"what types exist"}')"$'\1'"$(done_response "Sub-agent synthesis.")"$'\1'"$(tool_call_response "background.start" '{"question":"background question"}')"$'\1'"$(done_response "Final chat answer.")"
    AGENT_TEST_THINKING="step-monologue" send_message "$session" "$csrf" "$chat" "check everything" "$scripted" > /dev/null

    # Sub-agent tool_result gets clean finding text (not raw thinking), while child row keeps thinking.
    research_parent=$(calling_message "$chat" "research.investigate")
    run store "SELECT content FROM agent_message WHERE session_id = '${chat}' AND role = 'tool_result' AND parent_message_id IS NULL ORDER BY id LIMIT 1;"
    [[ "$output" =~ "Sub-agent synthesis." ]]
    [[ ! "$output" =~ "step-monologue" ]]
    [[ "$(store "SELECT content FROM agent_message WHERE parent_message_id = ${research_parent} AND loop_kind = 'research';")" =~ "step-monologue" ]]

    # Confirm self-check keeps its thinking as an out-of-context child reasoning row under the checked answer.
    final_id=$(store "SELECT id FROM agent_message WHERE session_id = '${chat}' AND role = 'assistant' AND parent_message_id IS NULL ORDER BY id DESC LIMIT 1;")
    run store "SELECT role || ':' || data_type || ':' || loop_kind || ':' || in_context FROM agent_message WHERE parent_message_id = ${final_id} AND loop_kind = 'self_check';"
    [ "$output" = "assistant:reasoning:self_check:0" ]
    run store "SELECT content FROM agent_message WHERE parent_message_id = ${final_id} AND loop_kind = 'self_check';"
    [[ "$output" =~ "step-monologue" ]]
    [[ ! "$output" =~ "CONFIRM" ]]

    # Background worker captures thinking under the calling message too.
    bg_parent=$(calling_message "$chat" "background.start")
    AGENT_TEST_THINKING="bg-monologue" AGENT_TEST_RESPONSES="$(done_response "Background synthesis.")" run "$BIN" agent run-pending-background
    [[ "$output" =~ "Ran 1, failed 0" ]]
    [[ "$(store "SELECT content FROM agent_message WHERE parent_message_id = ${bg_parent} AND loop_kind = 'background';")" =~ "bg-monologue" ]]

    # Compaction captures generate() thinking as a child reasoning row under the summary.
    write_config 'agent = {thinking = "summary", compaction_threshold = 10}'
    for i in 1 2 3; do
        AGENT_TEST_THINKING="turn-thought-$i" AGENT_TEST_GENERATE_RESPONSES="## Established facts
fact $i
## Decisions
none
## Open questions and next step
none" AGENT_TEST_GENERATE_THINKING="compaction-monologue" \
            send_message "$session" "$csrf" "$chat" "follow up $i" "$(done_response "Reply $i.")" > /dev/null
    done
    summary_id=$(store "SELECT id FROM agent_message WHERE session_id = '${chat}' AND role = 'compaction_summary' ORDER BY id DESC LIMIT 1;")
    [ -n "$summary_id" ]
    run store "SELECT role || ':' || data_type || ':' || loop_kind || ':' || in_context FROM agent_message WHERE parent_message_id = ${summary_id};"
    [ "$output" = "assistant:reasoning:compaction:0" ]
    [[ "$(store "SELECT content FROM agent_message WHERE parent_message_id = ${summary_id};")" =~ "compaction-monologue" ]]

    # Turn-limit wrapup preserves structured thinking blocks on the wrapup assistant row.
    write_config 'agent = {thinking = "full", max_turns = 1}'
    wrap_chat=$(start_chat "$session" "$csrf" "Wrapup")
    printf '{"session_id":"%s","message":"keep calling tools"}' "$wrap_chat" | \
        AGENT_TEST_THINKING="wrapup-monologue" \
        AGENT_TEST_RESPONSES="$(tool_call_response "entity.list_types" "{}")" \
        AGENT_TEST_SELF_CHECK_RESPONSE="$(done_response "Stopped after 1 step; reply to continue.")" \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/v1/chat/sessions/$wrap_chat/messages" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" HTTP_X_CSRF_TOKEN="${csrf}" "$BIN" > /dev/null
    wrap_content=$(store "SELECT content FROM agent_message WHERE session_id = '${wrap_chat}' AND role = 'assistant' AND parent_message_id IS NULL ORDER BY id DESC LIMIT 1;")
    [[ "$wrap_content" =~ "wrapup-monologue" ]]
    [[ "$wrap_content" =~ "Stopped after 1 step" ]]

    # Every model call recorded provider and model_id, and zero reasoning pool documents were created.
    [ "$(store "SELECT COUNT(*) FROM agent_model_call WHERE provider IS NULL OR model_id IS NULL;")" = "0" ]
    [ "$(store "SELECT COUNT(*) FROM document WHERE source_type = 'reasoning';")" = "0" ]
}
