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
