#!/usr/bin/env bats
# The curate step of the tier ladder (src/curate.lua,
# doc/tier-curation-ladder.md): a used source becomes a checked tier-1
# note that links to it; the source stays at tier 0.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
}

teardown() {
    unset AGENT_TEST_GENERATE_RESPONSES
    cleanup_test_env
}

db() {
    sqlite3 .store/store.db "$1"
}

# A source with enough text to curate, retrieved `uses` times.
used_source() {
    local title="$1" uses="$2"
    local text
    text=$(printf 'Cell suspensions grown in medium B reached %s g/L dry weight. ' $(seq 1 20))
    "$BIN" entity create document title="$title" content="$text" >/dev/null
    local id
    id=$(db "SELECT id FROM document WHERE title = '$title';")
    db "UPDATE document SET retrieval_count = $uses WHERE id = $id;"
    echo "$id"
}

NOTE=$'# Medium B growth\n\nCell suspensions in medium B reached up to 20 g/L dry weight.'

@test "repair curate --dry-run lists the sources in use, most used first, and makes no model call" {
    less=$(used_source "Growth run A" 2)
    more=$(used_source "Growth run B" 5)
    used_source "Barely used" 1 >/dev/null
    "$BIN" entity create document title="Growth run A ↔ Growth run B" content="[[Growth run A]] and [[Growth run B]]: same medium." >/dev/null
    db "UPDATE document SET retrieval_count = 9 WHERE title LIKE '%↔%';"

    run "$BIN" repair curate --dry-run
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "would curate #$more Growth run B (retrieved 5 times)" ]
    [ "${lines[1]}" = "would curate #$less Growth run A (retrieved 2 times)" ]
    [[ ! "$output" =~ "Barely used" ]]
    [[ ! "$output" =~ "↔" ]]
    [[ "$output" =~ "2 source(s) due, 2 would be curated" ]]
    run db "SELECT COUNT(*) FROM knowledge_curation;"
    [ "$output" -eq 0 ]
}

@test "repair curate writes a checked tier-1 note that links to its source; the source stays at tier 0, and a rerun does nothing" {
    source=$(used_source "Growth run A" 3)
    export AGENT_TEST_GENERATE_RESPONSES="$NOTE"$'\1'"PASS"

    run "$BIN" repair curate
    [ "$status" -eq 0 ]
    note=$(db "SELECT id FROM document WHERE source_type = 'curated' AND source_id = $source;")
    [ -n "$note" ]
    [[ "$output" =~ "#$source curated -> note #$note" ]]

    run db "SELECT title || '|' || tier FROM document WHERE id = $note;"
    [ "$output" = "Medium B growth|1" ]
    run db "SELECT content FROM document WHERE id = $note;"
    [[ "$output" =~ "reached up to 20 g/L dry weight" ]]
    [[ "$output" =~ "Source: [[Growth run A]]" ]]
    run db "SELECT to_document_id FROM document_link WHERE from_document_id = $note AND archived_at IS NULL;"
    [ "$output" -eq "$source" ]
    run db "SELECT tier FROM document WHERE id = $source;"
    [ "$output" -eq 0 ]
    run db "SELECT status || '|' || note_id FROM knowledge_curation WHERE document_id = $source;"
    [ "$output" = "curated|$note" ]

    run "$BIN" repair curate
    [[ "$output" =~ "0 source(s) due, 0 run" ]]
}

@test "a source with nothing worth keeping, or a note that fails the check, leaves no note and records why" {
    empty=$(used_source "Small talk" 4)
    wrong=$(used_source "Growth run A" 3)
    export AGENT_TEST_GENERATE_RESPONSES="NOTHING"$'\1'"$NOTE"$'\1'"FAIL: the source never says 20 g/L"

    run "$BIN" repair curate
    run db "SELECT status FROM knowledge_curation WHERE document_id = $empty;"
    [ "$output" = "nothing" ]
    run db "SELECT status || '|' || reason FROM knowledge_curation WHERE document_id = $wrong;"
    [ "$output" = "rejected|the source never says 20 g/L" ]
    run db "SELECT COUNT(*) FROM document WHERE source_type = 'curated';"
    [ "$output" -eq 0 ]
}

@test "an edited source is curated again, and its note is rewritten in place" {
    source=$(used_source "Growth run A" 3)
    export AGENT_TEST_GENERATE_RESPONSES="$NOTE"$'\1'"PASS"
    "$BIN" repair curate >/dev/null
    note=$(db "SELECT note_id FROM knowledge_curation WHERE document_id = $source;")

    "$BIN" entity update document "$source" content="$(printf 'Medium C doubled growth to %s g/L. ' $(seq 1 30))" >/dev/null
    export AGENT_TEST_GENERATE_RESPONSES=$'# Medium C growth\n\nMedium C doubled growth.'$'\1'"PASS"
    run "$BIN" repair curate
    [[ "$output" =~ "#$source curated -> note #$note" ]]
    run db "SELECT title FROM document WHERE id = $note;"
    [ "$output" = "Medium C growth" ]
    run db "SELECT COUNT(*) FROM document WHERE source_type = 'curated';"
    [ "$output" -eq 1 ]
}

@test "knowledge curate-pending runs queued sources only" {
    queued=$(used_source "Growth run A" 3)
    used_source "Growth run B" 3 >/dev/null
    db "INSERT INTO knowledge_curation (document_id, source_hash, status) VALUES ($queued, 'x', 'pending');"
    export AGENT_TEST_GENERATE_RESPONSES="$NOTE"$'\1'"PASS"

    run "$BIN" knowledge curate-pending
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" =~ "#$queued curated" ]]
}

@test "the curate prompt carries the deployment's own description of its work, and an unrelated source is skipped with a reason" {
    cat > theme.lua <<'THEME'
return {system_prompt_extra = "A cocoa plant cell culture lab."}
THEME
    source=$(used_source "Computational Neuroscience Meeting proceedings" 41)
    export AGENT_TEST_CAPTURE_SYSTEM_PROMPT="$TEST_DIR/curate-prompt.txt"
    export AGENT_TEST_GENERATE_RESPONSES="NOTHING: neuroscience conference abstracts, unrelated to cell culture"

    run "$BIN" repair curate
    [[ "$output" =~ "#$source nothing" ]]
    run cat "$TEST_DIR/curate-prompt.txt"
    [[ "$output" =~ "A cocoa plant cell culture lab." ]]
    [[ "$output" =~ "published papers, books, protocols and reviews on its subjects are worth curating" ]]
    run db "SELECT status || '|' || reason FROM knowledge_curation WHERE document_id = $source;"
    [ "$output" = "nothing|neuroscience conference abstracts, unrelated to cell culture" ]
    unset AGENT_TEST_CAPTURE_SYSTEM_PROMPT
}

@test "repair curate --recheck tries again a source that came to nothing, and leaves curated ones alone" {
    skipped=$(used_source "Cacao breeding" 39)
    done=$(used_source "Growth run A" 3)
    export AGENT_TEST_GENERATE_RESPONSES="NOTHING: no lab data"$'\1'"$NOTE"$'\1'"PASS"
    "$BIN" repair curate >/dev/null
    [ "$(db "SELECT status FROM knowledge_curation WHERE document_id = $skipped;")" = "nothing" ]

    run "$BIN" repair curate --dry-run
    [[ "$output" =~ "0 source(s) due" ]]
    run "$BIN" repair curate --dry-run --recheck
    [[ "$output" =~ "would curate #$skipped Cacao breeding" ]]
    [[ ! "$output" =~ "Growth run A" ]]

    export AGENT_TEST_GENERATE_RESPONSES=$'# Cacao breeding\n\nBreeding history and strategies.'$'\1'"PASS"
    run "$BIN" repair curate --recheck
    [[ "$output" =~ "#$skipped curated" ]]
}

@test "the check sees a long source cut where the writer's was, with the line that says so" {
    "$BIN" entity create document title="Cacao breeding" content="$(printf 'Breeding cycle %s selected for yield and flavour. ' $(seq 1 1200))" >/dev/null
    db "UPDATE document SET retrieval_count = 39 WHERE title = 'Cacao breeding';"
    export AGENT_TEST_CAPTURE_PROMPT="$TEST_DIR/check-prompt.txt"
    export AGENT_TEST_GENERATE_RESPONSES=$'# Cacao breeding\n\nBreeding cycles selected for yield and flavour.'$'\1'"PASS"

    run "$BIN" repair curate
    [[ "$output" =~ "curated" ]]
    run cat "$TEST_DIR/check-prompt.txt"
    [[ "$output" =~ "Note:" ]]
    [[ "$output" =~ "[...source cut here, showing the first 40000 characters...]" ]]
    unset AGENT_TEST_CAPTURE_PROMPT
}

@test "a source another runner already took is left to it, so no source gets two notes" {
    taken=$(used_source "Growth run A" 3)
    free=$(used_source "Growth run B" 3)
    db "INSERT INTO knowledge_curation (document_id, source_hash, status, reason) VALUES ($taken, 'x', 'running', 'other-runner');"
    db "INSERT INTO knowledge_curation (document_id, source_hash, status) VALUES ($free, 'x', 'pending');"
    export AGENT_TEST_GENERATE_RESPONSES="$NOTE"$'\1'"PASS"

    run "$BIN" knowledge curate-pending
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" =~ "#$free curated" ]]
    run db "SELECT status || '|' || reason FROM knowledge_curation WHERE document_id = $taken;"
    [ "$output" = "running|other-runner" ]
    run db "SELECT COUNT(*) FROM document WHERE source_type = 'curated';"
    [ "$output" -eq 1 ]
}

@test "a queued source that was archived meanwhile leaves the queue" {
    gone=$(used_source "Growth run A" 3)
    db "INSERT INTO knowledge_curation (document_id, source_hash, status) VALUES ($gone, 'x', 'pending');"
    db "UPDATE document SET archived_at = '2026-10-29' WHERE id = $gone;"

    run "$BIN" knowledge curate-pending
    run db "SELECT COUNT(*) FROM knowledge_curation WHERE document_id = $gone;"
    [ "$output" -eq 0 ]
}

# A chat session last active long ago, with typed rows. `rows` are
# "role|data_type|content" lines; a row's parent, when it is a
# sub-agent's step, is the session's first assistant row.
old_chat() {
    local id="$1" title="$2" rows="$3"
    db "INSERT INTO agent_session (id, login, title, updated_at) VALUES ('$id', 'admin', '$title', '2026-01-01 00:00:00');"
    while IFS='|' read -r role type content parent; do
        [ -z "$role" ] && continue
        local parent_sql="NULL"
        if [ "$parent" = "sub" ]; then
            parent_sql="(SELECT MIN(id) FROM agent_message WHERE session_id = '$id' AND role = 'assistant')"
        fi
        db "INSERT INTO agent_message (session_id, role, content, data_type, loop_kind, parent_message_id, in_context) VALUES ('$id', '$role', '$content', '$type', 'chat', $parent_sql, 1);"
    done <<< "$rows"
    db "UPDATE agent_session SET updated_at = '2026-01-01 00:00:00' WHERE id = '$id';"
}

LONG_ASK="which medium for cotyledons? $(printf 'context %s ' $(seq 1 80))"
CHAT_NOTE=$'# Cotyledon medium\n\nM9, per the protocol.'

@test "a chat is curated from its requests, answers and reasoning, never its tool results, into a note that links to the chat" {
    old_chat s1 media "user|request|${LONG_ASK}
assistant|answer|{\"blocks\":[{\"type\":\"text\",\"text\":\"Looking.\"},{\"type\":\"toolCall\",\"id\":\"c1\",\"name\":\"research.investigate\",\"arguments\":{}}]}
assistant|reasoning|{\"blocks\":[{\"type\":\"text\",\"text\":\"Checked the protocol list.\"}]}|sub
tool_result|tool_trace|raw search output #12 #13
assistant|answer|{\"blocks\":[{\"type\":\"text\",\"text\":\"M9, per the protocol.\"}]}"
    export AGENT_TEST_CAPTURE_PROMPT="$TEST_DIR/check-prompt.txt"
    export AGENT_TEST_GENERATE_RESPONSES="${CHAT_NOTE}"$'\1'"PASS"

    run "$BIN" knowledge curate-pending
    [[ "$output" =~ "chat s1 curated -> note #" ]]
    run cat "$TEST_DIR/check-prompt.txt"
    [[ "$output" =~ "User: which medium for cotyledons?" ]]
    [[ "$output" =~ "Research step: Checked the protocol list." ]]
    [[ "$output" =~ "Assistant: M9, per the protocol." ]]
    [[ ! "$output" =~ "raw search output" ]]
    [[ ! "$output" =~ "research.investigate" ]]
    unset AGENT_TEST_CAPTURE_PROMPT

    run db "SELECT source_type || '|' || source_ref || '|' || tier FROM document WHERE title = 'Cotyledon medium';"
    [ "$output" = "curated|s1|1" ]
    [[ "$(db "SELECT content FROM document WHERE title = 'Cotyledon medium';")" =~ "Source: [Chat: media](chat?session_id=s1)" ]]
    [ "$(db "SELECT status FROM knowledge_conversation_curation WHERE session_id = 's1';")" = "curated" ]
}

@test "a chat waits until it has been quiet; an unchanged one isn't curated again; a changed one rewrites its note in place" {
    old_chat s1 media "user|request|${LONG_ASK}
assistant|answer|{\"blocks\":[{\"type\":\"text\",\"text\":\"M9, per the protocol.\"}]}"
    db "UPDATE agent_session SET updated_at = '2999-01-01 00:00:00' WHERE id = 's1';"
    export AGENT_TEST_GENERATE_RESPONSES="${CHAT_NOTE}"$'\1'"PASS"
    run "$BIN" knowledge curate-pending
    [[ ! "$output" =~ "chat s1" ]]

    db "UPDATE agent_session SET updated_at = '2026-01-01 00:00:00' WHERE id = 's1';"
    "$BIN" knowledge curate-pending >/dev/null
    note=$(db "SELECT note_id FROM knowledge_conversation_curation WHERE session_id = 's1';")
    [ -n "$note" ]

    # Touched but not changed: not curated again.
    db "UPDATE agent_session SET updated_at = '2026-01-02 00:00:00' WHERE id = 's1';"
    db "UPDATE knowledge_conversation_curation SET checked_at = '2026-01-01 00:00:00' WHERE session_id = 's1';"
    run "$BIN" knowledge curate-pending
    [[ ! "$output" =~ "chat s1" ]]

    # Changed: curated again, into the same note.
    db "INSERT INTO agent_message (session_id, role, content, data_type, loop_kind) VALUES ('s1', 'user', 'and for hypocotyls?', 'request', 'chat');"
    db "UPDATE agent_session SET updated_at = '2026-01-03 00:00:00' WHERE id = 's1';"
    db "UPDATE knowledge_conversation_curation SET checked_at = '2026-01-02 00:00:00' WHERE session_id = 's1';"
    export AGENT_TEST_GENERATE_RESPONSES=$'# Cotyledon and hypocotyl media\n\nM9 for both.'$'\1'"PASS"
    run "$BIN" knowledge curate-pending
    [[ "$output" =~ "chat s1 curated -> note #${note}" ]]
    [ "$(db "SELECT title FROM document WHERE id = ${note};")" = "Cotyledon and hypocotyl media" ]
}

@test "a transcript document is no longer a source; its chat's note is taken over by the conversation's" {
    chat=$(used_source "Chat: media" 3)
    db "UPDATE document SET source_type = 'chat_session', source_ref = 's1' WHERE id = $chat;"
    run "$BIN" repair curate --dry-run
    [[ ! "$output" =~ "Chat: media" ]]

    # A note from when the transcript was curated, rewritten in place.
    "$BIN" entity create document title="Old chat note" content="old" >/dev/null
    old_note=$(db "SELECT id FROM document WHERE title = 'Old chat note';")
    db "INSERT INTO knowledge_curation (document_id, source_hash, status, note_id) VALUES ($chat, 'x', 'curated', $old_note);"
    old_chat s1 media "user|request|${LONG_ASK}
assistant|answer|{\"blocks\":[{\"type\":\"text\",\"text\":\"M9, per the protocol.\"}]}"
    export AGENT_TEST_GENERATE_RESPONSES="${CHAT_NOTE}"$'\1'"PASS"
    run "$BIN" knowledge curate-pending
    [[ "$output" =~ "chat s1 curated -> note #${old_note}" ]]
    [ "$(db "SELECT title FROM document WHERE id = ${old_note};")" = "Cotyledon medium" ]
}

@test "a chat from before decision rows reads its decided actions; a long chat keeps its newest requests and answers whole" {
    old_chat s1 media "user|request|${LONG_ASK}
assistant|answer|{\"blocks\":[{\"type\":\"text\",\"text\":\"M9, per the protocol.\"}]}"
    db "INSERT INTO agent_pending_action (session_id, tool, method, args_json, status) VALUES ('s1', 'document', 'archive', '{\"id\":7}', 'denied');"
    db "INSERT INTO agent_pending_action (session_id, tool, method, args_json, status) VALUES ('s1', 'document', 'update', '{\"id\":8}', 'pending');"
    big=$(printf 'reasoning %s ' $(seq 1 1200))
    for i in 1 2 3; do
        db "INSERT INTO agent_message (session_id, role, content, data_type, loop_kind) VALUES ('s1', 'compaction_summary', 'summary $i $big', 'reasoning', 'compaction');"
    done
    db "INSERT INTO agent_message (session_id, role, content, data_type, loop_kind) VALUES ('s1', 'user', 'last question about M9', 'request', 'chat');"
    db "UPDATE agent_session SET updated_at = '2026-01-01 00:00:00' WHERE id = 's1';"
    export AGENT_TEST_CAPTURE_PROMPT="$TEST_DIR/check-prompt.txt"
    export AGENT_TEST_GENERATE_RESPONSES="${CHAT_NOTE}"$'\1'"PASS"
    "$BIN" knowledge curate-pending >/dev/null
    run cat "$TEST_DIR/check-prompt.txt"
    [[ "$output" =~ "Decision: Denied document.archive (pending action #1): {\"id\":7}" ]]
    [[ ! "$output" =~ "document.update" ]]
    [[ "$output" =~ "User: which medium for cotyledons?" ]]
    [[ "$output" =~ "User: last question about M9" ]]
    [[ "$output" =~ "[...conversation shortened to fit" ]]
    [[ "$output" =~ "Summary of earlier conversation: summary 3" ]]
    [[ ! "$output" =~ "Summary of earlier conversation: summary 1" ]]
    unset AGENT_TEST_CAPTURE_PROMPT
}
