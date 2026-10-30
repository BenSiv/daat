#!/usr/bin/env bats
# Distinctive words per tag (src/tag_terms.lua) and the label check that
# uses them (`daat repair tags --relabel`, src/tag_upkeep.lua).

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    # Two tags, three documents each; "cocoa" is in every document.
    "$BIN" entity create tag label="Callus texture" source=computed >/dev/null
    "$BIN" entity create tag label="Spreadsheet data" source=computed >/dev/null
    callus=$(db "SELECT id FROM tag WHERE label = 'Callus texture';")
    sheet=$(db "SELECT id FROM tag WHERE label = 'Spreadsheet data';")
    for i in 1 2 3; do
        add_doc "Callus $i" "Cocoa callus was friable and granular after induction, friable clumps." "$callus" '[1, 0, 0, 0, 0, 0, 0, 0]'
        add_doc "Sheet $i" "Cocoa lipid extract: stearic and palmitic acid, stearic fraction." "$sheet" '[0, 1, 0, 0, 0, 0, 0, 0]'
    done
    "$BIN" repair tags >/dev/null
}

teardown() {
    unset AGENT_TEST_GENERATE_RESPONSES AGENT_TEST_CAPTURE_PROMPT
    cleanup_test_env
}

db() {
    sqlite3 .store/store.db "$1"
}

add_doc() {
    "$BIN" entity create document title="$1" content="$2" >/dev/null
    local id
    id=$(db "SELECT id FROM document WHERE title = '$1';")
    db "DELETE FROM document_tag WHERE document = $id;"
    db "INSERT OR REPLACE INTO document_embedding (document_id, model, vector_json) VALUES ($id, 'test', '$4');"
    "$BIN" entity create document_tag document="$id" tag="$3" decision=computed >/dev/null
}

@test "the label check gets each tag's distinctive words, not the words every tag shares, and its nearest tags" {
    export AGENT_TEST_CAPTURE_PROMPT="$TEST_DIR/prompt.txt"
    export AGENT_TEST_GENERATE_RESPONSES=$'FITS -- describes it\1FITS -- describes it'
    run "$BIN" repair tags --relabel --dry-run
    [[ "$output" =~ "FITS -- describes it" ]]
    # The last call was the second tag's.
    run cat "$TEST_DIR/prompt.txt"
    [[ "$output" =~ "Label: Spreadsheet data" ]]
    words=$(printf '%s\n' "$output" | grep '^Distinctive words: ')
    [[ "$words" =~ "stearic" ]]
    [[ "$words" =~ "palmitic" ]]
    [[ ! "$words" =~ "cocoa" ]]
    [[ ! "$words" =~ "friable" ]]
    [[ "$output" =~ "Nearest tags: Callus texture" ]]
}

@test "repair tags --relabel renames a tag the check finds named by its kind of file; --dry-run writes nothing" {
    export AGENT_TEST_GENERATE_RESPONSES=$'FITS -- describes it\1RENAME -- names the kind of file\nNAME: Cocoa lipid fractions | Stearic and palmitic acid in cocoa lipid extracts.'
    run "$BIN" repair tags --relabel --dry-run
    [[ "$output" =~ "RENAME -- names the kind of file" ]]
    [ "$(db "SELECT COUNT(*) FROM tag WHERE label = 'Spreadsheet data';")" = "1" ]

    run "$BIN" repair tags --relabel
    [ "$(db "SELECT COUNT(*) FROM tag WHERE label = 'Cocoa lipid fractions';")" = "1" ]
    [ "$(db "SELECT COUNT(*) FROM tag WHERE label = 'Callus texture';")" = "1" ]
}
