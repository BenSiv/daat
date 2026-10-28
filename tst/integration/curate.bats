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
