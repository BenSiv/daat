#!/usr/bin/env bats
# Context by type (doc/agent-data.md, "Context"; #36, #19, #12, #11):
# - sub-agent start context carries conversation requests and confirmed
#   schema, never main-loop tool_trace;
# - observation masking runs on research/background loops, leaving DB
#   rows whole for result.read;
# - compaction carries both requests and final answers verbatim;
# - a new session never injects raw requests or tool_trace rows from
#   earlier sessions (cross-session knowledge flows only through the
#   shared curated document pool).

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init >/dev/null
    mkdir -p "$TEST_DIR/schemas"
    cat > "$TEST_DIR/schemas/sample.lua" <<'EOF'
return {
    name = "sample",
    label = "Sample",
    fields = {
        {name = "code", label = "Code", type = "text", required = true},
    },
}
EOF
    "$BIN" schema add "$TEST_DIR/schemas/sample.lua" >/dev/null
    read alice_sess alice_csrf < <(login_test_user "alice" "i")
    ALICE_COOKIE="session=${alice_sess}; csrf=${alice_csrf}"
    ALICE_CSRF="$alice_csrf"
    DB="$TEST_DIR/.store/store.db"
}

teardown() {
    unset AGENT_TEST_PROMPT_TOKENS AGENT_TEST_GENERATE_RESPONSES
    cleanup_test_env
}

@test "research.investigate and background.start receive conversation requests and confirmed schema, never main-loop tool_trace" {
    chat=$(json_body "$(raw_post_json "/api/v1/chat/sessions" '{"title":"subagent ctx"}' "$ALICE_COOKIE" "$ALICE_CSRF" "")" | jq -r '.session_id')
    "$BIN" entity create sample code=SECRET_MAIN_TRACE_ROW_999 >/dev/null

    # Turn 1: main loop confirms schema (entity.fields) AND runs a
    # non-schema query whose tool_trace holds SECRET_MAIN_TRACE_ROW_999.
    t1="$(tool_call_response "entity.fields" '{"entity_type":"sample"}')"$'\1'"$(tool_call_response "entity.query" '{"sql":"SELECT code FROM sample"}')"$'\1'"$(done_response "Checked sample schema and rows.")"
    raw_post_json "/api/v1/chat/sessions/${chat}/messages" "{\"message\":\"Check sample codes for batch alpha\"}" "$ALICE_COOKIE" "$ALICE_CSRF" "$t1" >/dev/null

    # Turn 2: main loop delegates to research.investigate, which itself
    # runs a query (SECRET_SUBAGENT_TRACE_777) and returns a finding + method.
    "$BIN" entity create sample code=SECRET_SUBAGENT_TRACE_777 >/dev/null
    t2="$(tool_call_response "research.investigate" '{"question":"count samples matching batch"}')"$'\1'"$(tool_call_response "entity.query" '{"sql":"SELECT code FROM sample ORDER BY id DESC LIMIT 1"}')"$'\1'"$(done_response "Finding: 2 samples total.\nMethod & coverage: SELECT COUNT(*) FROM sample; checked all 2 rows.")"$'\1'"$(done_response "There are 2 samples in total.")"
    raw_post_json "/api/v1/chat/sessions/${chat}/messages" "{\"message\":\"Now investigate sample counts\"}" "$ALICE_COOKIE" "$ALICE_CSRF" "$t2" >/dev/null

    # 1. Sub-agent's first model call prompt has the user's requests and
    #    confirmed schema (entity.fields sample), and NOT SECRET_MAIN_TRACE_ROW_999!
    res_prompt=$(sqlite3 "$DB" "SELECT prompt FROM agent_model_call WHERE session_id = '${chat}' AND kind = 'research' AND step = 1 LIMIT 1;" | jq -r '.[0].content')
    [[ "$res_prompt" =~ "Check sample codes for batch alpha" ]]
    [[ "$res_prompt" =~ "Now investigate sample counts" ]]
    [[ "$res_prompt" =~ "Confirmed schema" ]]
    [[ "$res_prompt" =~ 'entity.fields {"entity_type":"sample"}' ]]
    [[ ! "$res_prompt" =~ "SECRET_MAIN_TRACE_ROW_999" ]]

    # 2. Main loop's final chat step saw the sub-agent's finding + method,
    #    and NEVER saw the sub-agent's raw tool_trace (SECRET_SUBAGENT_TRACE_777)!
    main_final_prompt=$(sqlite3 "$DB" "SELECT prompt FROM agent_model_call WHERE session_id = '${chat}' AND kind = 'chat' ORDER BY id DESC LIMIT 1;")
    [[ "$main_final_prompt" =~ "Method & coverage: SELECT COUNT(*) FROM sample" ]]
    [[ ! "$main_final_prompt" =~ "SECRET_SUBAGENT_TRACE_777" ]]

    # 3. Same guarantee for background.start!
    t3="$(tool_call_response "background.start" '{"question":"background audit of samples"}')"$'\1'"$(done_response "Queued background task.")"
    raw_post_json "/api/v1/chat/sessions/${chat}/messages" "{\"message\":\"Run a full background check\"}" "$ALICE_COOKIE" "$ALICE_CSRF" "$t3" >/dev/null
    AGENT_TEST_RESPONSES="$(done_response "Finding: all good. Method & coverage: checked all 2 rows.")" "$BIN" agent run-pending-background >/dev/null

    bg_prompt=$(sqlite3 "$DB" "SELECT prompt FROM agent_model_call WHERE session_id = '${chat}' AND kind = 'background' AND step = 1 LIMIT 1;")
    [[ "$bg_prompt" =~ "Run a full background check" ]]
    [[ "$bg_prompt" =~ "Confirmed schema" ]]
    [[ ! "$bg_prompt" =~ "SECRET_MAIN_TRACE_ROW_999" ]]
    [[ ! "$bg_prompt" =~ "SECRET_SUBAGENT_TRACE_777" ]]
}

@test "observation masking stubs older large tool results in research while keeping stored rows readable via result.read" {
    write_config "agent = {masking_keep_last = 1, masking_min_chars = 100, masking_batch_tokens = 0}"
    long_code=$(printf 'Z%.0s' $(seq 1 250))
    "$BIN" entity create sample "code=${long_code}" >/dev/null

    chat=$(json_body "$(raw_post_json "/api/v1/chat/sessions" '{"title":"masking"}' "$ALICE_COOKIE" "$ALICE_CSRF" "")" | jq -r '.session_id')
    scripted="$(tool_call_response "research.investigate" '{"question":"check twice"}')"$'\1'"$(tool_call_response "entity.query" '{"sql":"SELECT code FROM sample"}')"$'\1'"$(tool_call_response "entity.query" '{"sql":"SELECT code, id FROM sample"}')"$'\1'"$(done_response "Finding: 1 sample. Method & coverage: queried sample.")"$'\1'"$(done_response "Done.")"
    raw_post_json "/api/v1/chat/sessions/${chat}/messages" "{\"message\":\"run research\"}" "$ALICE_COOKIE" "$ALICE_CSRF" "$scripted" >/dev/null

    # On research step 3, the first query result is older than keep_last=1,
    # so the prompt sent to the model has the stub, while the DB row keeps long_code!
    step3_prompt=$(sqlite3 "$DB" "SELECT prompt FROM agent_model_call WHERE session_id = '${chat}' AND kind = 'research' AND step = 3 LIMIT 1;")
    [[ "$step3_prompt" =~ "earlier tool result masked: entity.query" ]]
    [[ "$step3_prompt" =~ "result.read(result_id=" ]]

    stored_first=$(sqlite3 "$DB" "SELECT content FROM agent_message WHERE session_id = '${chat}' AND loop_kind = 'research' AND role = 'tool_result' ORDER BY id ASC LIMIT 1;")
    [[ "$stored_first" =~ "$long_code" ]]
}

@test "new sessions never inject raw requests or tool_trace from earlier sessions" {
    read bob_sess bob_csrf < <(login_test_user "bob" "i")
    bob_cookie="session=${bob_sess}; csrf=${bob_csrf}"

    "$BIN" entity create sample code=ALICE_OLDER_TRACE_SECRET >/dev/null

    bob_chat=$(json_body "$(raw_post_json "/api/v1/chat/sessions" '{"title":"bob"}' "$bob_cookie" "$bob_csrf" "")" | jq -r '.session_id')
    raw_post_json "/api/v1/chat/sessions/${bob_chat}/messages" "{\"message\":\"BOB_UNRELATED_REQUEST_42\"}" "$bob_cookie" "$bob_csrf" "$(done_response "Noted.")" >/dev/null

    alice_c1=$(json_body "$(raw_post_json "/api/v1/chat/sessions" '{"title":"alice 1"}' "$ALICE_COOKIE" "$ALICE_CSRF" "")" | jq -r '.session_id')
    t_alice1="$(tool_call_response "entity.query" '{"sql":"SELECT code FROM sample"}')"$'\1'"$(done_response "Checked.")"
    raw_post_json "/api/v1/chat/sessions/${alice_c1}/messages" "{\"message\":\"ALICE_EARLIER_UNRELATED_TOPIC_99\"}" "$ALICE_COOKIE" "$ALICE_CSRF" "$t_alice1" >/dev/null

    alice_c2=$(json_body "$(raw_post_json "/api/v1/chat/sessions" '{"title":"alice 2"}' "$ALICE_COOKIE" "$ALICE_CSRF" "")" | jq -r '.session_id')
    raw_post_json "/api/v1/chat/sessions/${alice_c2}/messages" "{\"message\":\"hello\"}" "$ALICE_COOKIE" "$ALICE_CSRF" "$(done_response "Hi.")" >/dev/null

    c2_prompt=$(sqlite3 "$DB" "SELECT prompt FROM agent_model_call WHERE session_id = '${alice_c2}' AND kind = 'chat' ORDER BY id DESC LIMIT 1;")
    [[ ! "$c2_prompt" =~ "ALICE_EARLIER_UNRELATED_TOPIC_99" ]]
    [[ ! "$c2_prompt" =~ "BOB_UNRELATED_REQUEST_42" ]]
    [[ ! "$c2_prompt" =~ "ALICE_OLDER_TRACE_SECRET" ]]
}

@test "compaction carries both user requests and final assistant answers verbatim" {
    export AGENT_TEST_GENERATE_RESPONSES="## Established facts
none
## Decisions
none
## Open questions and next step
none"
    write_config "agent = {compaction_threshold = 20000}"
    chat=$(json_body "$(raw_post_json "/api/v1/chat/sessions" '{"title":"compact"}' "$ALICE_COOKIE" "$ALICE_CSRF" "")" | jq -r '.session_id')

    s1="$(tool_call_response "entity.fields" '{"entity_type":"sample"}')"$'\1'"$(done_response "Exact conclusion: medium M9 gave 2.76 h doubling time.")"
    raw_post_json "/api/v1/chat/sessions/${chat}/messages" "{\"message\":\"What was the M9 doubling time?\"}" "$ALICE_COOKIE" "$ALICE_CSRF" "$s1" >/dev/null
    s2="$(tool_call_response "entity.fields" '{"entity_type":"document"}')"$'\1'"$(done_response "Listed document fields.")"
    AGENT_TEST_PROMPT_TOKENS=50000 raw_post_json "/api/v1/chat/sessions/${chat}/messages" "{\"message\":\"And document fields?\"}" "$ALICE_COOKIE" "$ALICE_CSRF" "$s2" >/dev/null
    raw_post_json "/api/v1/chat/sessions/${chat}/messages" "{\"message\":\"continue\"}" "$ALICE_COOKIE" "$ALICE_CSRF" "$(done_response "Continuing.")" >/dev/null

    summary=$(sqlite3 "$DB" "SELECT content FROM agent_message WHERE session_id = '${chat}' AND role = 'compaction_summary' AND in_context = 1;")
    [[ "$summary" =~ "- What was the M9 doubling time?" ]]
    [[ "$summary" =~ "- Exact conclusion: medium M9 gave 2.76 h doubling time." ]]
}
