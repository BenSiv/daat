#!/usr/bin/env bats
# The broader tag level (src/tag_broader.lua, doc/tag-ontology.md):
# specific tags grouped into broad ones by their centres, named by the
# agent; the specific tags and their documents stay as they are.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    # Sixteen tags in four clear areas: each tag holds one document whose
    # vector lies along its area's axis, with a small offset of its own.
    for a in 1 2 3 4; do
        for t in 1 2 3 4; do
            "$BIN" entity create document title="Area$a doc $t" content="area $a tag $t" >/dev/null
            id=$(db "SELECT id FROM document WHERE title = 'Area$a doc $t';")
            v=(0 0 0 0 0 0 0 0)
            v[$((a - 1))]=1
            v[$((3 + t))]=0.1$t
            db "INSERT OR REPLACE INTO document_embedding (document_id, model, vector_json) VALUES ($id, 'test', '[$(IFS=,; echo "${v[*]}")]');"
            db "DELETE FROM document_tag WHERE document = $id;"
            "$BIN" entity create tag label="Area$a tag $t" source=computed >/dev/null
            tg=$(db "SELECT id FROM tag WHERE label = 'Area$a tag $t';")
            "$BIN" entity create document_tag document="$id" tag="$tg" decision=computed >/dev/null
        done
    done
    "$BIN" repair tags >/dev/null
}

teardown() {
    unset AGENT_TEST_GENERATE_RESPONSES
    cleanup_test_env
}

db() {
    sqlite3 .store/store.db "$1"
}

NAMES=$'GROUP 1: Alpha area | The first area.\nGROUP 2: Beta area | The second.\nGROUP 3: Gamma area | The third.\nGROUP 4: Delta area | The fourth.'

@test "a dry run groups the tags into their four areas, named by the agent, and writes nothing" {
    export AGENT_TEST_GENERATE_RESPONSES="$NAMES"
    run "$BIN" tag broaden --dry-run
    [[ "$output" =~ "Alpha area (4 tags): Area1 tag 1; Area1 tag 2; Area1 tag 3; Area1 tag 4" ]]
    [[ "$output" =~ "Delta area (4 tags): Area4 tag 1; Area4 tag 2; Area4 tag 3; Area4 tag 4" ]]
    [[ "$output" =~ "Dry run: 4 broad tags over 16 tags, nothing written" ]]
    [ "$(db "SELECT COUNT(*) FROM tag WHERE source = 'broader';")" = "0" ]
}

@test "broaden writes the broad tags and points each tag at its own; documents and centres don't change" {
    before=$(db "SELECT COUNT(*) || '|' || SUM(members) FROM tag_centre;")
    export AGENT_TEST_GENERATE_RESPONSES="$NAMES"
    run "$BIN" tag broaden
    [[ "$output" =~ "Wrote 4 broad tags over 16 tags" ]]
    beta=$(db "SELECT id FROM tag WHERE label = 'Beta area' AND source = 'broader';")
    [ "$(db "SELECT COUNT(*) FROM tag WHERE parent = '$beta' AND label LIKE 'Area2 %';")" = "4" ]
    [ "$(db "SELECT description FROM tag WHERE id = $beta;")" = "The second." ]
    [ "$(db "SELECT COUNT(*) FROM document_tag WHERE tag = $beta;")" = "0" ]
    [ "$(db "SELECT COUNT(*) || '|' || SUM(members) FROM tag_centre;")" = "$before" ]
}

@test "the agent can move a tag that doesn't fit its group" {
    export AGENT_TEST_GENERATE_RESPONSES="$NAMES"$'\nMOVE Area1 tag 4 -> 2'
    run "$BIN" tag broaden
    [[ "$output" =~ "moved \"Area1 tag 4\" from group 1 to 2" ]]
    beta=$(db "SELECT id FROM tag WHERE label = 'Beta area';")
    [ "$(db "SELECT parent FROM tag WHERE label = 'Area1 tag 4';")" = "$beta" ]
}

@test "broad tags are refused a second time unless --replace, which archives the old ones; a person's own nesting stays" {
    export AGENT_TEST_GENERATE_RESPONSES="$NAMES"
    "$BIN" tag broaden >/dev/null
    old=$(db "SELECT GROUP_CONCAT(id) FROM tag WHERE source = 'broader';")
    "$BIN" entity create tag label="Hand-made group" source=manual >/dev/null
    mine=$(db "SELECT id FROM tag WHERE label = 'Hand-made group';")
    t=$(db "SELECT id FROM tag WHERE label = 'Area3 tag 1';")
    "$BIN" entity update tag "$t" parent="$mine" >/dev/null

    run "$BIN" tag broaden
    [[ "$output" =~ "Refused: broad tags exist" ]]
    export AGENT_TEST_GENERATE_RESPONSES="$NAMES"
    run "$BIN" tag broaden --replace
    [[ "$output" =~ "over 15 tags" ]]
    [ "$(db "SELECT COUNT(*) FROM tag WHERE id IN ($old) AND archived_at IS NOT NULL AND archived_at != '';")" = "4" ]
    [ "$(db "SELECT parent FROM tag WHERE id = $t;")" = "$mine" ]
}

@test "tag define writes a checked tier-3 definition per tag, from its broader tag and siblings; rewritten only when those change" {
    export AGENT_TEST_GENERATE_RESPONSES="$NAMES"
    "$BIN" tag broaden >/dev/null
    export AGENT_TEST_CAPTURE_PROMPT="$TEST_DIR/define-prompt.txt"
    # 16 specific tags and 4 broad ones: a definition and PASS each.
    responses=""
    for i in $(seq 1 20); do responses="$responses"$'Defined area tag.\1PASS\1'; done
    export AGENT_TEST_GENERATE_RESPONSES="$responses"

    run "$BIN" tag define
    [[ "$output" =~ "20 tag(s) due, 20 run" ]]
    t=$(db "SELECT id FROM tag WHERE label = 'Area2 tag 1';")
    run db "SELECT title || '|' || tier || '|' || source_type || '|' || content FROM document WHERE source_ref = 'tag:$t';"
    [ "$output" = "Definition: Area2 tag 1|3|record|Defined area tag." ]
    # The last call checked the last tag: it saw its broader tag or sub-tags.
    run cat "$TEST_DIR/define-prompt.txt"
    [[ "$output" =~ "Definition:" ]]
    [[ "$output" =~ "Sub-tags:" || "$output" =~ "Broader tag:" ]]
    unset AGENT_TEST_CAPTURE_PROMPT

    run "$BIN" tag define
    [[ "$output" =~ "0 tag(s) due" ]]
    "$BIN" entity update tag "$t" label="Area2 renamed" >/dev/null
    export AGENT_TEST_GENERATE_RESPONSES=$'Renamed tag.\1PASS\1Renamed sibling.\1PASS\1Renamed sibling.\1PASS\1Renamed sibling.\1PASS\1Beta again.\1PASS'
    run "$BIN" tag define
    # The tag itself, its three siblings and its broader tag.
    [[ "$output" =~ "5 tag(s) due, 5 run" ]]
    [ "$(db "SELECT COUNT(*) FROM document WHERE source_ref = 'tag:$t';")" = "1" ]
}

@test "a definition that fails the check is not written, and a definition of an archived tag is archived" {
    t=$(db "SELECT id FROM tag WHERE label = 'Area1 tag 1';")
    export AGENT_TEST_GENERATE_RESPONSES=$'Wrong.\1FAIL: names an organism the documents never mention'
    "$BIN" tag define --limit 1 >/dev/null
    run db "SELECT status || '|' || reason FROM knowledge_tag_definition WHERE tag_id = $t;"
    [ "$output" = "rejected|names an organism the documents never mention" ]

    export AGENT_TEST_GENERATE_RESPONSES=$'Area one tag.\1PASS'
    db "DELETE FROM knowledge_tag_definition WHERE tag_id = $t;"
    "$BIN" tag define --limit 1 >/dev/null
    record=$(db "SELECT document_id FROM knowledge_tag_definition WHERE tag_id = $t;")
    "$BIN" entity archive tag "$t" >/dev/null
    run "$BIN" tag define --limit 0
    [[ "$output" =~ "1 definition(s) of archived tags archived" ]]
    run db "SELECT archived_at IS NOT NULL AND archived_at != '' FROM document WHERE id = $record;"
    [ "$output" = "1" ]
}

@test "the agent can add a subject group and move tags into it; groups left empty are dropped" {
    moves=$'\nGROUP 5: Epsilon subject | Gathered by subject.\nMOVE Area1 tag 1 -> 5\nMOVE Area2 tag 1 -> 5'
    for t in 1 2 3 4; do moves="$moves"$'\nMOVE Area4 tag '"$t"$' -> 5'; done
    export AGENT_TEST_GENERATE_RESPONSES="$NAMES$moves"
    run "$BIN" tag broaden
    [[ "$output" =~ "Wrote 4 broad tags over 16 tags" ]]
    epsilon=$(db "SELECT id FROM tag WHERE label = 'Epsilon subject' AND source = 'broader';")
    [ "$(db "SELECT COUNT(*) FROM tag WHERE parent = '$epsilon';")" = "6" ]
    [ "$(db "SELECT COUNT(*) FROM tag WHERE label = 'Delta area';")" = "0" ]
}
