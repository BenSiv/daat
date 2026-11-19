#!/usr/bin/env bats
# Retention strategies per data type, tool-trace stubs, model_input_days,
# lean knowledge rule, and context-report stored characters by type
# (doc/agent-data.md, "Retention"; #35).

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    "$BIN" user add admin secret123 isa
}

teardown() {
    cleanup_test_env
}

@test "standard strategy stubs old tool traces, keeps pairing intact for resumed turns, and is idempotent" {
    cat > schemas/sample.lua <<'EOF'
return {name = "sample", fields = {{name = "label", type = "text", required = true, display = true}}}
EOF
    "$BIN" schema add schemas/sample.lua >/dev/null
    "$BIN" entity create sample label="Alpha-1" >/dev/null

    read session csrf < <(session_for admin secret123)
    chat=$(start_chat "$session" "$csrf" "Standard retention")
    scripted="$(tool_call_response "entity.list_types" "{}")"$'\1'"$(done_response "Found sample.")"
    send_message "$session" "$csrf" "$chat" "list the entity types" "$scripted" > /dev/null

    orig_len=$(store "SELECT json_extract(content, '$.text') FROM agent_message WHERE session_id = '${chat}' AND role = 'tool_result' LIMIT 1;" | wc -c)
    # Age both the tool trace (>90 days) and model calls (>30 days).
    store "UPDATE agent_message SET created_at = '2020-01-01 00:00:00' WHERE session_id = '${chat}';"
    store "UPDATE agent_model_call SET created_at = '2020-01-01 00:00:00' WHERE session_id = '${chat}';"

    run "$BIN" agent context-report
    [ "$status" -eq 0 ]
    [[ "$output" =~ "## Stored characters by type" ]]
    before_trace_chars=$(printf '%s\n' "$output" | awk -F'\t' '$1 == "tool_trace" {print $3}')
    before_input_chars=$(printf '%s\n' "$output" | awk -F'\t' '$1 == "model_input" {print $3}')
    [ "$before_input_chars" -gt 0 ]

    run "$BIN" store prune
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Retention strategy: standard" ]]
    [[ "$output" =~ "tool_trace: Stubbed 1 tool results older than 90 days" ]]
    [[ "$output" =~ "knowledge: Removed 0 raw knowledge rows (kept forever)" ]]

    stub_text=$(store "SELECT json_extract(content, '$.text') FROM agent_message WHERE session_id = '${chat}' AND role = 'tool_result' LIMIT 1;")
    [[ "$stub_text" =~ ^\[result\ pruned\ after\ 90\ days:\ entity\.list_types,\ [0-9]+\ characters\]$ ]]
    # Arguments on the assistant toolCall block stay untouched.
    [[ "$(store "SELECT content FROM agent_message WHERE session_id = '${chat}' AND role = 'assistant' ORDER BY id LIMIT 1;")" =~ "entity.list_types" ]]

    # Idempotent: a second prune stubs 0 and clears 0, leaving the stub unchanged.
    run "$BIN" store prune
    [ "$status" -eq 0 ]
    [[ "$output" =~ "model_input: Cleared 0 stored prompts" ]]
    [[ "$output" =~ "tool_trace: Stubbed 0 tool results" ]]
    [ "$(store "SELECT json_extract(content, '$.text') FROM agent_message WHERE session_id = '${chat}' AND role = 'tool_result' LIMIT 1;")" = "$stub_text" ]

    # Resuming the conversation pairs the stubbed toolResult cleanly AND
    # re-runs entity.list_types fresh rather than answering from a pruned stub.
    resumed="$(tool_call_response "entity.list_types" "{}")"$'\1'"$(done_response "Still sample.")"
    run send_message "$session" "$csrf" "$chat" "check types again" "$resumed"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Still sample." ]]
    latest_tool_text=$(store "SELECT json_extract(content, '$.text') FROM agent_message WHERE session_id = '${chat}' AND role = 'tool_result' ORDER BY id DESC LIMIT 1;")
    [[ "$latest_tool_text" =~ "sample" ]]
    [[ ! "$latest_tool_text" =~ "Same call as one earlier" ]]

    run "$BIN" agent context-report
    [ "$status" -eq 0 ]
    [[ "$output" =~ "## Stored characters by type" ]]
}

@test "lean strategy omits storing model_input, keeps uncurated knowledge, and removes curated knowledge past 30 days" {
    write_config 'agent = {retention = "lean", curate_quiet_minutes = 0}'
    read session csrf < <(session_for admin secret123)

    # 1. Curated conversation (note exists) -> raw knowledge removed once curation is >30 days old.
    curated_chat=$(start_chat "$session" "$csrf" "Curated protocol")
    long_q=$(printf 'Record our validated incubator protocol for strain C-12 across forty-eight hour shaker flasks at 28.5 degrees Celsius with 180 rpm agitation. %.0s' $(seq 1 5))
    long_a=$(printf 'Confirmed: strain C-12 shaker flasks run 48 hours at 28.5 C and 180 rpm with baffle plates, dissolved oxygen stays above 35 percent, OD600 6.4. %.0s' $(seq 1 5))
    send_message "$session" "$csrf" "$curated_chat" "$long_q" "$(done_response "$long_a")" > /dev/null

    # Under lean, model_input_days = 0: no prompt was stored on agent_model_call!
    [ "$(store "SELECT COUNT(*) FROM agent_model_call WHERE prompt IS NOT NULL;")" -eq 0 ]
    [ "$(store "SELECT COUNT(*) FROM agent_model_call WHERE prompt_tokens IS NOT NULL;")" -ge 1 ]

    # 2. Short conversation curated as NOTHING -> also eligible past 30 days.
    nothing_chat=$(start_chat "$session" "$csrf" "Quick hello")
    send_message "$session" "$csrf" "$nothing_chat" "hi" "$(done_response "hello")" > /dev/null

    # 3. Uncurated conversation -> raw knowledge MUST stay even when old.
    uncurated_chat=$(start_chat "$session" "$csrf" "Uncurated draft")
    send_message "$session" "$csrf" "$uncurated_chat" "Draft note not yet curated" "$(done_response "Draft reply.")" > /dev/null

    # Curate curated_chat and nothing_chat, leaving uncurated_chat uncurated.
    store "UPDATE agent_session SET updated_at = '2026-01-01 00:00:00';"
    AGENT_TEST_GENERATE_RESPONSES=$'# Strain C-12 shaker protocol\n\n48 h at 28.5 C, 180 rpm.\x01PASS' \
        "$BIN" knowledge curate-pending 10 > /dev/null
    store "DELETE FROM knowledge_conversation_curation WHERE session_id = '${uncurated_chat}';"
    [ "$(store "SELECT status FROM knowledge_conversation_curation WHERE session_id = '${curated_chat}';")" = "curated" ]
    [ "$(store "SELECT status FROM knowledge_conversation_curation WHERE session_id = '${nothing_chat}';")" = "nothing" ]
    note_id=$(store "SELECT note_id FROM knowledge_conversation_curation WHERE session_id = '${curated_chat}';")
    [ -n "$note_id" ]

    # Age messages on all chats to 2020, while checked_at is still recent -> nothing removed yet!
    store "UPDATE agent_message SET created_at = '2020-01-01 00:00:00';"
    run "$BIN" store prune
    [ "$status" -eq 0 ]
    [[ "$output" =~ "knowledge: Removed 0 raw knowledge rows" ]]
    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${curated_chat}' AND data_type IN ('request', 'answer', 'reasoning');")" -ge 2 ]

    # Now age curated_chat and nothing_chat checked_at past 30 days -> both pruned, uncurated_chat stays!
    store "UPDATE knowledge_conversation_curation SET checked_at = '2020-01-02 00:00:00' WHERE session_id IN ('${curated_chat}', '${nothing_chat}');"
    run "$BIN" store prune
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Retention strategy: lean" ]]
    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${curated_chat}' AND data_type IN ('request', 'answer', 'reasoning');")" -eq 0 ]
    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${nothing_chat}' AND data_type IN ('request', 'answer', 'reasoning');")" -eq 0 ]
    [ "$(store "SELECT COUNT(*) FROM agent_message WHERE session_id = '${uncurated_chat}' AND data_type IN ('request', 'answer', 'reasoning');")" -ge 2 ]
    # The curated note itself stays active in the Knowledge Pool, and curate-pending does not clobber it.
    [ "$(store "SELECT COALESCE(archived_at, '') FROM document WHERE id = ${note_id};")" = "" ]
    AGENT_TEST_GENERATE_RESPONSES="NOTHING" "$BIN" knowledge curate-pending 10 > /dev/null
    [ "$(store "SELECT status FROM knowledge_conversation_curation WHERE session_id = '${curated_chat}';")" = "curated" ]
}

@test "full strategy keeps everything and writes transcript documents; overrides apply per key" {
    write_config 'agent = {retention = "full"}'
    read session csrf < <(session_for admin secret123)
    chat=$(start_chat "$session" "$csrf" "Full dev")
    send_message "$session" "$csrf" "$chat" "hello full" "$(done_response "kept whole")" > /dev/null

    # full sets transcript_documents = "whole" automatically.
    [ "$(store "SELECT COUNT(*) FROM document WHERE source_type = 'chat_session' AND source_ref = '${chat}';")" -eq 1 ]

    store "UPDATE agent_message SET created_at = '2020-01-01 00:00:00';"
    store "UPDATE agent_model_call SET created_at = '2020-01-01 00:00:00';"
    run "$BIN" store prune
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Retention strategy: full" ]]
    [[ "$output" =~ "model_input: Cleared 0 stored prompts (kept forever)" ]]
    [[ "$output" =~ "tool_trace: Stubbed 0 tool results (kept forever)" ]]
    [[ "$output" =~ "metrics: Removed 0 metrics and control rows (kept forever)" ]]

    # Override metrics_days and model_input_days on top of full.
    write_config 'agent = {retention = "full", retention_override = {model_input_days = 10, metrics_days = 365}}'
    run "$BIN" store prune
    [ "$status" -eq 0 ]
    [ "$(store "SELECT COUNT(*) FROM agent_model_call;")" -eq 0 ]
}
