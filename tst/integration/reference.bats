#!/usr/bin/env bats

# References (src/reference.lua, doc/tag-ontology.md): an entity's name
# in a document's text, recognised on save into document_reference.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    mkdir -p schemas
    for t in experiment sample product; do
        cat > "schemas/$t.lua" <<EOS
return {name = "$t", fields = {{name = "label", type = "text", required = true, display = true}}}
EOS
        "$BIN" schema add "schemas/$t.lua" >/dev/null
    done
}

teardown() {
    cleanup_test_env
}

db() {
    sqlite3 .store/store.db "$1"
}

new_entity() {
    "$BIN" entity create "$1" label="$2" >/dev/null
    db "SELECT id FROM $1 WHERE label = '$2' ORDER BY id DESC LIMIT 1;"
}

new_document() {
    "$BIN" entity create document title="$1" content="$2" >/dev/null
    db "SELECT id FROM document WHERE title = '$1';"
}

refs_of() {
    db "SELECT entity_type || ':' || entity_id FROM document_reference WHERE document_id = $1 ORDER BY entity_type, entity_id;" | tr '\n' ' '
}

@test "a document references entities named in its text: spacing ignored, a sample yields its experiment too, vague names never" {
    exp=$(new_entity experiment "Exp227")
    smp=$(new_entity sample "Exp227 Sample96")
    vague=$(new_entity product "A")
    d=$(new_document "Day 4" "Moved exp 227 sample 96 to fresh medium; product A looked fine.")
    [ "$(refs_of "$d")" = "experiment:${exp} sample:${smp} " ]
}

@test "a name shared by two entities is ambiguous and references neither" {
    new_entity sample "Sample1X" >/dev/null
    new_entity product "Sample1X" >/dev/null
    d=$(new_document "Day 4" "Checked Sample1X twice.")
    [ "$(refs_of "$d")" = "" ]
}

@test "the name index follows renames and archives; repair references re-reads every document" {
    exp=$(new_entity experiment "Exp185")
    "$BIN" entity update experiment "$exp" label="Exp186" >/dev/null
    [ "$(db "SELECT name_key FROM reference_name WHERE entity_id = $exp;")" = "exp186" ]
    "$BIN" entity archive experiment "$exp" >/dev/null
    [ "$(db "SELECT COUNT(*) FROM reference_name WHERE entity_id = $exp;")" = "0" ]
    "$BIN" entity unarchive experiment "$exp" >/dev/null

    # Written before the entity existed: picked up by the repair.
    d=$(new_document "Plan" "Next: Exp300.")
    later=$(new_entity experiment "Exp300")
    [ "$(refs_of "$d")" = "" ]
    db "DELETE FROM reference_name;"
    run "$BIN" repair references
    [[ "$output" =~ "Indexed 2 entity name(s)" ]]
    [ "$(refs_of "$d")" = "experiment:${later} " ]
}

@test "deployment aliases match how people write names" {
    exp=$(new_entity experiment "Exp185")
    write_platform_config ', reference_aliases = {{"experiment%s*(%d)", "exp%1"}}'
    d=$(new_document "Report" "Results of Experiment 185 are in.")
    [ "$(refs_of "$d")" = "experiment:${exp} " ]
}

@test "documents naming the same entity are evidence between their tags, one kind per entity type" {
    exp=$(new_entity experiment "Exp185")
    a1=$(new_document "Callus day 1" "Exp185 started")
    a2=$(new_document "Callus day 2" "Exp185 continued")
    b1=$(new_document "Suspension day 1" "from Exp185")
    b2=$(new_document "Suspension day 2" "still Exp185")
    "$BIN" entity create tag label="Callus" source=computed >/dev/null
    "$BIN" entity create tag label="Suspension" source=computed >/dev/null
    callus=$(db "SELECT id FROM tag WHERE label = 'Callus';")
    suspension=$(db "SELECT id FROM tag WHERE label = 'Suspension';")
    for d in $a1 $a2; do "$BIN" entity create document_tag document="$d" tag="$callus" decision=computed >/dev/null; done
    for d in $b1 $b2; do "$BIN" entity create document_tag document="$d" tag="$suspension" decision=computed >/dev/null; done

    "$BIN" repair tag-evidence >/dev/null
    lo=$callus; hi=$suspension; if [ "$hi" -lt "$lo" ]; then lo=$suspension; hi=$callus; fi
    [ "$(db "SELECT direction || ':' || support FROM tag_evidence WHERE kind = 'reference:experiment' AND tag_a = $lo AND tag_b = $hi AND archived_at IS NULL;")" = "undirected:1.0" ]
}
