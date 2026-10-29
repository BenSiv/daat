#!/usr/bin/env bats
# The distill step of the tier ladder (src/distill.lua,
# doc/tier-curation-ladder.md "Tier 3 design"): a tier-2 reference is
# split into tier-3 records, deduplicated by embedding against existing
# records and legacy distilled facts.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    export AGENT_TEST_EMBEDDINGS=terms
}

teardown() {
    unset AGENT_TEST_GENERATE_RESPONSES AGENT_TEST_EMBEDDINGS
    cleanup_test_env
}

db() {
    sqlite3 .store/store.db "$1"
}

# A tier-2 reference on a tag of three curated notes, written by the
# synthesize step; prints its id.
reference() {
    "$BIN" entity create tag label="Medium B" source=computed >/dev/null
    local t
    t=$(db "SELECT id FROM tag WHERE label = 'Medium B';")
    for n in A B C; do
        "$BIN" entity create document title="Run $n" content="Run $n: cocoa cells in medium B reached 12 g/L dry weight." >/dev/null
        local id
        id=$(db "SELECT id FROM document WHERE title = 'Run $n';")
        db "UPDATE document SET source_type = 'curated', tier = 1 WHERE id = $id;"
        db "DELETE FROM document_tag WHERE document = $id;"
        "$BIN" entity create document_tag document="$id" tag="$t" decision=computed score=0.9 >/dev/null
    done
    AGENT_TEST_GENERATE_RESPONSES=$'# Medium B growth\n\nCocoa cells in medium B reached 12 g/L dry weight [[Run A]].'$'\1'"PASS" \
        "$BIN" repair synthesize >/dev/null
    db "SELECT id FROM document WHERE source_type = 'reference';"
}

# An existing document of `type` holding the claim, embedded.
existing() {
    "$BIN" entity create document title="$2" content="$3" >/dev/null
    db "UPDATE document SET source_type = '$1' WHERE title = '$2';"
    "$BIN" document embed-pending >/dev/null
    db "SELECT id FROM document WHERE title = '$2';"
}

CLAIM=$'CLAIM: Cocoa cells in medium B reach 12 g/L dry weight\nTEXT: Cocoa cells in medium B reached 12 g/L dry weight.\nNOTES: Run A'

@test "repair distill --dry-run lists the references not yet distilled, and makes no model call" {
    ref=$(reference)
    run "$BIN" repair distill --dry-run
    [ "${lines[0]}" = "would distill reference #$ref Medium B growth" ]
    [[ "$output" =~ "1 reference(s) due, 1 would be distilled" ]]
    run db "SELECT COUNT(*) FROM knowledge_distillation;"
    [ "$output" -eq 0 ]
}

@test "repair distill writes checked tier-3 records that link their notes; a rerun does nothing" {
    ref=$(reference)
    note=$(db "SELECT id FROM document WHERE title = 'Run A';")
    two="$CLAIM"$'\n\nCLAIM: Medium B needs no kinetin\nTEXT: Medium B grows cocoa cells without kinetin.\nNOTES: Run B'
    export AGENT_TEST_GENERATE_RESPONSES="$two"$'\1'$'1: PASS\n2: PASS'

    run "$BIN" repair distill
    [[ "$output" =~ "reference #$ref distilled: 2 new, 0 updated, 0 already there, 0 rejected, 0 legacy absorbed" ]]
    run db "SELECT COUNT(*) FROM document WHERE source_type = 'record' AND tier = 3 AND source_ref = 'reference:$ref';"
    [ "$output" -eq 2 ]
    record=$(db "SELECT id FROM document WHERE title = 'Cocoa cells in medium B reach 12 g/L dry weight';")
    run db "SELECT COUNT(*) FROM document_link WHERE from_document_id = $record AND to_document_id = $note AND archived_at IS NULL;"
    [ "$output" -eq 1 ]

    run "$BIN" repair distill
    [[ "$output" =~ "0 reference(s) due, 0 run" ]]
}

@test "a claim a record already states is not written again" {
    ref=$(reference)
    existing record "Medium B reaches 12 g/L" "Cocoa cells in medium B reached 12 g/L dry weight." >/dev/null
    export AGENT_TEST_GENERATE_RESPONSES="$CLAIM"$'\1'"SAME 1"

    run "$BIN" repair distill
    [[ "$output" =~ "0 new, 0 updated, 1 already there" ]]
    run db "SELECT COUNT(*) FROM document WHERE source_type = 'record';"
    [ "$output" -eq 1 ]
}

@test "a more exact claim rewrites the record that states it, in place" {
    ref=$(reference)
    old=$(existing record "Medium B reaches 12 g/L" "Cocoa cells in medium B reached 12 g/L dry weight.")
    export AGENT_TEST_GENERATE_RESPONSES="$CLAIM"$'\1'"UPDATE 1"$'\1'"1: PASS"

    run "$BIN" repair distill
    [[ "$output" =~ "0 new, 1 updated" ]]
    run db "SELECT title FROM document WHERE id = $old;"
    [ "$output" = "Cocoa cells in medium B reach 12 g/L dry weight" ]
    run db "SELECT COUNT(*) FROM document WHERE source_type = 'record';"
    [ "$output" -eq 1 ]
}

@test "a legacy distilled fact the new record covers is archived into it" {
    ref=$(reference)
    legacy=$(existing distilled "Medium B 12 g/L" "Cocoa cells in medium B reached 12 g/L dry weight.")
    export AGENT_TEST_GENERATE_RESPONSES="$CLAIM"$'\1'"SAME 1"$'\1'"1: PASS"

    run "$BIN" repair distill
    [[ "$output" =~ "1 new, 0 updated, 0 already there, 0 rejected, 1 legacy absorbed" ]]
    record=$(db "SELECT id FROM document WHERE source_type = 'record';")
    run db "SELECT (archived_at IS NOT NULL AND archived_at != '') || '|' || merged_into FROM document WHERE id = $legacy;"
    [ "$output" = "1|$record" ]
}

@test "a record that fails the check is dropped and counted" {
    ref=$(reference)
    export AGENT_TEST_GENERATE_RESPONSES="$CLAIM"$'\1'"1: FAIL: no note says dry weight"

    run "$BIN" repair distill
    [[ "$output" =~ "0 new, 0 updated, 0 already there, 1 rejected" ]]
    run db "SELECT COUNT(*) FROM document WHERE source_type = 'record';"
    [ "$output" -eq 0 ]
}

@test "the extract reply is read into claims, notes split, at most 12" {
    reply=""
    for i in $(seq 1 14); do
        reply="$reply"$'CLAIM: Claim '"$i"$'\nTEXT: Text '"$i"$'.\nNOTES: [[Run A]]; Run B\n\n'
    done
    ref=$(reference)
    export AGENT_TEST_GENERATE_RESPONSES="$reply"$'\1'"$(for i in $(seq 1 12); do printf '%d: PASS\n' "$i"; done)"
    run "$BIN" repair distill
    [[ "$output" =~ "12 new" ]]
    record=$(db "SELECT id FROM document WHERE title = 'Claim 1';")
    run db "SELECT COUNT(*) FROM document_link WHERE from_document_id = $record AND archived_at IS NULL;"
    [ "$output" -eq 2 ]
}

@test "a legacy fact two new records both match is absorbed once, into the first" {
    ref=$(reference)
    legacy=$(existing distilled "Medium B 12 g/L" "Cocoa cells in medium B reached 12 g/L dry weight.")
    second=$'CLAIM: Cocoa cells in medium B reach 12 g/L dry weight in culture\nTEXT: Cocoa cells in medium B reached 12 g/L dry weight in culture.\nNOTES: Run B'
    # Extract; the first candidate's judge; the second's, which sees the
    # first candidate nearest and the fact second, and names the fact;
    # the check.
    export AGENT_TEST_GENERATE_RESPONSES="$CLAIM"$'\n\n'"$second"$'\1'"SAME 1"$'\1'"SAME 2"$'\1'$'1: PASS\n2: PASS'

    run "$BIN" repair distill
    [[ "$output" =~ "1 legacy absorbed" ]]
    first=$(db "SELECT id FROM document WHERE title = 'Cocoa cells in medium B reach 12 g/L dry weight';")
    run db "SELECT merged_into FROM document WHERE id = $legacy;"
    [ "$output" = "$first" ]
}
