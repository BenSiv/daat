#!/usr/bin/env bats
# The synthesize step of the tier ladder (src/synthesize.lua,
# doc/tier-curation-ladder.md): a tag's curated notes become one checked
# tier-2 reference that links to each of them.

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

new_tag() {
    "$BIN" entity create tag label="$1" source=computed >/dev/null
    db "SELECT id FROM tag WHERE label = '$1';"
}

# A tier-1 curated note in a tag.
note_in() {
    local tag="$1" title="$2"
    "$BIN" entity create document title="$title" content="$title: medium B gave 12 g/L dry weight." >/dev/null
    local id
    id=$(db "SELECT id FROM document WHERE title = '$title';")
    db "UPDATE document SET source_type = 'curated', tier = 1 WHERE id = $id;"
    # Only the tag the test names: drop placement on save.
    db "DELETE FROM document_tag WHERE document = $id;"
    "$BIN" entity create document_tag document="$id" tag="$tag" decision=computed score=0.9 >/dev/null
    echo "$id"
}

REFERENCE=$'# Medium B growth\n\nMedium B gave 12 g/L dry weight [[Run A]].'

@test "repair synthesize --dry-run lists tags with three or more notes, most notes first, and makes no model call" {
    big=$(new_tag "Medium B")
    small=$(new_tag "Callus")
    for n in A B C D; do note_in "$big" "Run $n" >/dev/null; done
    for n in E F; do note_in "$small" "Run $n" >/dev/null; done

    run "$BIN" repair synthesize --dry-run
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "would write a reference for tag #$big Medium B (4 notes)" ]
    [[ ! "$output" =~ "Callus" ]]
    [[ "$output" =~ "1 tag(s) due, 1 would get a reference" ]]
    run db "SELECT COUNT(*) FROM knowledge_reference;"
    [ "$output" -eq 0 ]
}

@test "repair synthesize writes a checked tier-2 reference that links every note; the notes stay at tier 1, and a rerun does nothing" {
    t=$(new_tag "Medium B")
    a=$(note_in "$t" "Run A"); b=$(note_in "$t" "Run B"); c=$(note_in "$t" "Run C")
    export AGENT_TEST_GENERATE_RESPONSES="$REFERENCE"$'\1'"PASS"

    run "$BIN" repair synthesize
    [ "$status" -eq 0 ]
    ref=$(db "SELECT id FROM document WHERE source_type = 'reference';")
    [ -n "$ref" ]
    [[ "$output" =~ "tag #$t referenced -> reference #$ref" ]]
    run db "SELECT title || '|' || tier || '|' || source_ref FROM document WHERE id = $ref;"
    [ "$output" = "Medium B growth|2|tag:$t" ]
    run db "SELECT COUNT(*) FROM document_link WHERE from_document_id = $ref AND to_document_id IN ($a, $b, $c) AND archived_at IS NULL;"
    [ "$output" -eq 3 ]
    run db "SELECT COUNT(*) FROM document WHERE id IN ($a, $b, $c) AND tier = 1;"
    [ "$output" -eq 3 ]

    run "$BIN" repair synthesize
    [[ "$output" =~ "0 tag(s) due, 0 run" ]]
}

@test "a tag whose notes don't make one subject comes to nothing, and a failed check leaves no reference; both record why" {
    loose=$(new_tag "Misc")
    for n in A B C; do note_in "$loose" "Loose $n" >/dev/null; done
    wrong=$(new_tag "Medium B")
    for n in A B C; do note_in "$wrong" "Run $n" >/dev/null; done
    export AGENT_TEST_GENERATE_RESPONSES="NOTHING: unrelated notes"$'\1'"$REFERENCE"$'\1'"FAIL: no note says 12 g/L"

    run "$BIN" repair synthesize
    run db "SELECT status || '|' || reason FROM knowledge_reference WHERE tag_id = $loose;"
    [ "$output" = "nothing|unrelated notes" ]
    run db "SELECT status || '|' || reason FROM knowledge_reference WHERE tag_id = $wrong;"
    [ "$output" = "rejected|no note says 12 g/L" ]
    run db "SELECT COUNT(*) FROM document WHERE source_type = 'reference';"
    [ "$output" -eq 0 ]
}

@test "a tag that gains a note gets its reference rewritten in place" {
    t=$(new_tag "Medium B")
    for n in A B C; do note_in "$t" "Run $n" >/dev/null; done
    export AGENT_TEST_GENERATE_RESPONSES="$REFERENCE"$'\1'"PASS"
    "$BIN" repair synthesize >/dev/null
    ref=$(db "SELECT document_id FROM knowledge_reference WHERE tag_id = $t;")

    d=$(note_in "$t" "Run D")
    export AGENT_TEST_GENERATE_RESPONSES=$'# Medium B growth, four runs\n\nFour runs [[Run D]].'$'\1'"PASS"
    run "$BIN" repair synthesize
    [[ "$output" =~ "tag #$t referenced -> reference #$ref" ]]
    run db "SELECT title FROM document WHERE id = $ref;"
    [ "$output" = "Medium B growth, four runs" ]
    run db "SELECT COUNT(*) FROM document WHERE source_type = 'reference';"
    [ "$output" -eq 1 ]
    run db "SELECT COUNT(*) FROM document_link WHERE from_document_id = $ref AND to_document_id = $d AND archived_at IS NULL;"
    [ "$output" -eq 1 ]
}

@test "the writer gets the tag, the notes and the deployment's description of its work" {
    cat > theme.lua <<'THEME'
return {system_prompt_extra = "A cocoa plant cell culture lab."}
THEME
    t=$(new_tag "Medium B")
    for n in A B C; do note_in "$t" "Run $n" >/dev/null; done
    export AGENT_TEST_CAPTURE_SYSTEM_PROMPT="$TEST_DIR/system.txt"
    export AGENT_TEST_CAPTURE_PROMPT="$TEST_DIR/prompt.txt"
    export AGENT_TEST_GENERATE_RESPONSES="NOTHING: off-field"

    "$BIN" repair synthesize >/dev/null
    run cat "$TEST_DIR/system.txt"
    [[ "$output" =~ "A cocoa plant cell culture lab." ]]
    run cat "$TEST_DIR/prompt.txt"
    [[ "$output" =~ "Tag: Medium B" ]]
    [[ "$output" =~ "### Note: Run A" ]]
    [[ "$output" =~ "### Note: Run C" ]]
    unset AGENT_TEST_CAPTURE_SYSTEM_PROMPT AGENT_TEST_CAPTURE_PROMPT
}

@test "a tag another runner already took is left to it" {
    taken=$(new_tag "Medium B")
    for n in A B C; do note_in "$taken" "Run $n" >/dev/null; done
    db "INSERT INTO knowledge_reference (tag_id, notes_hash, status, reason) VALUES ($taken, 'x', 'running', 'other-runner');"
    export AGENT_TEST_GENERATE_RESPONSES="$REFERENCE"$'\1'"PASS"

    run "$BIN" repair synthesize
    run db "SELECT status || '|' || reason FROM knowledge_reference WHERE tag_id = $taken;"
    [ "$output" = "running|other-runner" ]
    run db "SELECT COUNT(*) FROM document WHERE source_type = 'reference';"
    [ "$output" -eq 0 ]
}
