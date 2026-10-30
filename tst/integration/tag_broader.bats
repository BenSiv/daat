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

# An agent reply line block: a NEW AREA with Area<n>'s four tags.
new_area() {
    local out=$'NEW AREA: '"$1"$' | '"$2"$' | nothing in the library fits'
    for t in 1 2 3 4; do out="$out"$'\n- Area'"$3"$' tag '"$t"; done
    printf '%s' "$out"
}
# The same for a library area picked by label.
library_area() {
    local out=$'AREA: '"$1"
    for t in 1 2 3 4; do out="$out"$'\n- Area'"$2"$' tag '"$t"; done
    printf '%s' "$out"
}
NAMES="$(new_area 'Alpha area' 'The first area.' 1)"$'\n'"$(new_area 'Beta area' 'The second.' 2)"$'\n'"$(new_area 'Gamma area' 'The third.' 3)"$'\n'"$(new_area 'Delta area' 'The fourth.' 4)"

@test "with an empty library the agent proposes new areas, each with why; a dry run lists them and writes nothing" {
    export AGENT_TEST_CAPTURE_PROMPT="$TEST_DIR/prompt.txt"
    export AGENT_TEST_GENERATE_RESPONSES="$NAMES"
    run "$BIN" tag broaden --dry-run
    [[ "$output" =~ "NEW Alpha area (4 tags): Area1 tag 1; Area1 tag 2; Area1 tag 3; Area1 tag 4" ]]
    [[ "$output" =~ "    why new: nothing in the library fits" ]]
    [[ "$output" =~ "Dry run: 4 broad tags over 16 tags, nothing written" ]]
    [ "$(db "SELECT COUNT(*) FROM tag WHERE source = 'broader';")" = "0" ]
    run cat "$TEST_DIR/prompt.txt"
    [[ "$output" =~ "(empty: add new areas)" ]]
    [[ "$output" =~ "- Area3 tag 2" ]]
    unset AGENT_TEST_CAPTURE_PROMPT
}

@test "broaden writes the broad tags and points each tag at its own; documents and centres don't change" {
    before=$(db "SELECT COUNT(*) || '|' || SUM(members) FROM tag_centre;")
    export AGENT_TEST_GENERATE_RESPONSES="$NAMES"
    run "$BIN" tag broaden
    [[ "$output" =~ "Wrote 4 broad tags over 16 tags (4 new to the library)" ]]
    beta=$(db "SELECT id FROM tag WHERE label = 'Beta area' AND source = 'broader';")
    [ "$(db "SELECT COUNT(*) FROM tag WHERE parent = '$beta' AND label LIKE 'Area2 %';")" = "4" ]
    [ "$(db "SELECT description FROM tag WHERE id = $beta;")" = "The second." ]
    [ "$(db "SELECT COUNT(*) FROM document_tag WHERE tag = $beta;")" = "0" ]
    [ "$(db "SELECT COUNT(*) || '|' || SUM(members) FROM tag_centre;")" = "$before" ]
}

@test "library areas are picked by label and keep their tag id, from run to run; an unused one is archived, and restored when picked again" {
    run "$BIN" tag library add "Alpha area" "The first area."
    [[ "$output" =~ "Added \"Alpha area\" to the library" ]]
    "$BIN" tag library add "Beta area" "The second." >/dev/null
    run "$BIN" tag library add "beta AREA"
    [[ "$output" =~ "Not added: already in the library: Beta area" ]]
    run "$BIN" tag library
    [[ "$output" =~ "Alpha area (not in use): The first area." ]]
    alpha=$(db "SELECT id FROM tag WHERE label = 'Alpha area';")
    beta=$(db "SELECT id FROM tag WHERE label = 'Beta area';")

    # Alpha takes areas 1 and 2; Beta isn't used; Gamma is new.
    reply="$(library_area 'Alpha area' 1)"$'\n'"$(library_area 'Alpha area' 2 | tail -n 4)"$'\n'"$(new_area 'Gamma area' 'The third.' 3)"$'\n'"$(new_area 'Delta area' 'The fourth.' 4)"
    export AGENT_TEST_GENERATE_RESPONSES="$reply"
    run "$BIN" tag broaden
    [[ "$output" =~ "(2 new to the library)" ]]
    [ "$(db "SELECT COUNT(*) FROM tag WHERE parent = '$alpha';")" = "8" ]
    [ "$(db "SELECT archived_at IS NULL OR archived_at = '' FROM tag WHERE id = $alpha;")" = "1" ]
    [ "$(db "SELECT archived_at IS NULL OR archived_at = '' FROM tag WHERE id = $beta;")" = "0" ]

    # Next run: Beta is picked again -- the same tag, restored; Delta,
    # unused now, is archived.
    reply="$(library_area 'Alpha area' 1)"$'\n'"$(library_area 'Beta area' 2)"$'\n'"$(library_area 'Gamma area' 3)"$'\n'"$(library_area 'Gamma area' 4 | tail -n 4)"
    export AGENT_TEST_GENERATE_RESPONSES="$reply"
    run "$BIN" tag broaden
    [[ "$output" =~ "(0 new to the library)" ]]
    [ "$(db "SELECT archived_at IS NULL OR archived_at = '' FROM tag WHERE id = $beta;")" = "1" ]
    [ "$(db "SELECT COUNT(*) FROM tag WHERE parent = '$beta';")" = "4" ]
    [ "$(db "SELECT archived_at IS NULL OR archived_at = '' FROM tag WHERE label = 'Delta area';")" = "0" ]
    [ "$(db "SELECT COUNT(*) FROM tag WHERE source = 'broader';")" = "4" ]
}

@test "a tag the agent leaves out joins the nearest area" {
    reply="$NAMES"
    reply=$(printf '%s' "$reply" | grep -v '^- Area2 tag 4$')
    export AGENT_TEST_GENERATE_RESPONSES="$reply"
    run "$BIN" tag broaden
    [[ "$output" =~ "\"Area2 tag 4\" was left out; placed in Beta area, the nearest area" ]]
    beta=$(db "SELECT id FROM tag WHERE label = 'Beta area';")
    [ "$(db "SELECT parent FROM tag WHERE label = 'Area2 tag 4';")" = "$beta" ]
}

@test "a person's own nesting stays out of the broad level" {
    "$BIN" entity create tag label="Hand-made group" source=manual >/dev/null
    mine=$(db "SELECT id FROM tag WHERE label = 'Hand-made group';")
    t=$(db "SELECT id FROM tag WHERE label = 'Area3 tag 1';")
    "$BIN" entity update tag "$t" parent="$mine" >/dev/null
    export AGENT_TEST_GENERATE_RESPONSES="$NAMES"
    run "$BIN" tag broaden
    [[ "$output" =~ "over 15 tags" ]]
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

@test "a tag a person placed stays where they put it, and its area stays in use, when broaden runs again" {
    export AGENT_TEST_GENERATE_RESPONSES="$NAMES"
    "$BIN" tag broaden >/dev/null
    alpha=$(db "SELECT id FROM tag WHERE label = 'Alpha area';")
    t=$(db "SELECT id FROM tag WHERE label = 'Area4 tag 1';")
    USER="ben" "$BIN" entity update tag "$t" parent="$alpha" >/dev/null

    # The next run puts every tag elsewhere and leaves Alpha out.
    reply="$(new_area 'Beta area' 'The second.' 2)"
    for a in 1 3 4; do reply="$reply"$'\n'"$(library_area 'Beta area' $a | tail -n 4)"; done
    export AGENT_TEST_GENERATE_RESPONSES="$reply"
    run "$BIN" tag broaden
    [[ "$output" =~ "1 tag(s) placed by a person kept where they are" ]]
    [[ "$output" =~ "over 15 tags" ]]
    [ "$(db "SELECT parent FROM tag WHERE id = $t;")" = "$alpha" ]
    [ "$(db "SELECT archived_at IS NULL OR archived_at = '' FROM tag WHERE id = $alpha;")" = "1" ]
}

@test "tag define --recheck tries a rejected definition again; without it, it stays rejected" {
    t=$(db "SELECT id FROM tag WHERE label = 'Area1 tag 1';")
    export AGENT_TEST_GENERATE_RESPONSES=$'Wrong.\1FAIL: too narrow'
    "$BIN" tag define --limit 1 >/dev/null
    [ "$(db "SELECT status FROM knowledge_tag_definition WHERE tag_id = $t;")" = "rejected" ]

    run "$BIN" tag define --dry-run
    [[ ! "$output" =~ "would define tag #$t " ]]
    run "$BIN" tag define --dry-run --recheck
    [[ "$output" =~ "would define tag #$t Area1 tag 1" ]]
    export AGENT_TEST_GENERATE_RESPONSES=$'Area one tag.\1PASS'
    "$BIN" tag define --recheck --limit 1 >/dev/null
    [ "$(db "SELECT status FROM knowledge_tag_definition WHERE tag_id = $t;")" = "defined" ]
}
