#!/usr/bin/env bats

# Tag restructuring (src/tag_upkeep.lua, doc/tag-ontology.md phase 3b):
# the data proposes a split, merge or label check, the agent decides.
# Documents get chosen 8-number vectors (the test provider's length);
# `repair tags` builds the centres and the baselines, then memberships
# added afterwards move a tag away from how it was built. The agent's
# answers are scripted through AGENT_TEST_RESPONSES.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
}

teardown() {
    cleanup_test_env
}

db() {
    sqlite3 .store/store.db "$1"
}

# new_document TITLE X Y Z -- a document whose vector points along the
# first three axes by X, Y, Z.
new_document() {
    "$BIN" entity create document title="$1" content="$1" >/dev/null
    id=$(db "SELECT id FROM document WHERE title = '$1';")
    db "INSERT OR REPLACE INTO document_embedding (document_id, model, vector_json) VALUES ($id, 'test-embedding', '[$2, $3, $4, 0, 0, 0, 0, 0]');"
    echo "$id"
}

new_tag() {
    "$BIN" entity create tag label="$1" source="${2:-computed}" >/dev/null
    db "SELECT id FROM tag WHERE label = '$1';"
}

member() {
    "$BIN" entity create document_tag document="$1" tag="$2" decision="${3:-computed}" >/dev/null
}

members_of() {
    db "SELECT COUNT(*) FROM document_tag WHERE tag = $1 AND (archived_at IS NULL OR archived_at = '');"
}

# A tag "Cultures" built on five documents along x, then joined by three
# along y: loose enough to propose a split, B (the smaller half) the y's.
loosened_tag() {
    write_platform_config ", tag_split_min = 4"
    for i in 1 2 3 4 5; do A[$i]=$(new_document "Callus $i" 1 0.0$i 0); done
    for i in 1 2 3; do B[$i]=$(new_document "Bioreactor $i" 0.0$i 1 0); done
    T=$(new_tag "Cultures")
    for i in 1 2 3 4 5; do member "${A[$i]}" "$T"; done
    "$BIN" repair tags >/dev/null
    for i in 1 2 3; do member "${B[$i]}" "$T"; done
}

SPLIT_DIFFERENT=$'DIFFERENT -- callus work and bioreactor runs are separate subjects\nA: Callus induction | Inducing callus on explants.\nB: Bioreactor runs | Running cultures in bioreactors.'

@test "a loosened tag is proposed for a split; a dry run writes nothing, with or without the agent's verdict" {
    loosened_tag
    run "$BIN" repair tags --restructure --dry-run
    [[ "$output" =~ "split #$T \"Cultures\" (8 members" ]]
    [[ "$output" =~ "would ask the agent" ]]

    AGENT_TEST_RESPONSES="$SPLIT_DIFFERENT" run "$BIN" repair tags --restructure --dry-run --judge
    [[ "$output" =~ "DIFFERENT -- callus work and bioreactor runs are separate subjects" ]]
    [[ "$output" =~ "B: Bioreactor runs" ]]
    [ "$(db "SELECT COUNT(*) FROM tag;")" = "1" ]
    [ "$(db "SELECT COUNT(*) FROM tag_judgment;")" = "0" ]
}

@test "a split the agent calls DIFFERENT moves the smaller half to a new tag and names both" {
    loosened_tag
    AGENT_TEST_RESPONSES="$SPLIT_DIFFERENT" run "$BIN" repair tags --restructure
    [[ "$output" =~ "split: 3 documents moved to new tag" ]]
    new=$(db "SELECT id FROM tag WHERE label = 'Bioreactor runs';")
    [ -n "$new" ]
    [ "$(members_of "$new")" = "3" ]
    [ "$(members_of "$T")" = "5" ]
    [ "$(db "SELECT label FROM tag WHERE id = $T;")" = "Callus induction" ]
    [ "$(db "SELECT description FROM tag WHERE id = $new;")" = "Running cultures in bioreactors." ]
    [ "$(db "SELECT COUNT(*) FROM document_tag WHERE tag = $new AND document IN (${B[1]}, ${B[2]}, ${B[3]});")" = "3" ]
    [ "$(db "SELECT verdict FROM tag_judgment WHERE kind = 'split';")" = "DIFFERENT" ]
    # The centres followed the memberships; nothing is left to propose.
    [ "$(db "SELECT members FROM tag_centre WHERE tag_id = $new;")" = "3" ]
    run "$BIN" repair tags --restructure --dry-run
    [[ "$output" =~ "Nothing to restructure" ]]
}

@test "a split the agent calls SAME changes nothing and isn't proposed again" {
    loosened_tag
    AGENT_TEST_RESPONSES="SAME -- all of it is culture work" run "$BIN" repair tags --restructure
    [[ "$output" =~ "kept as one tag" ]]
    [ "$(db "SELECT COUNT(*) FROM tag;")" = "1" ]
    [ "$(members_of "$T")" = "8" ]
    run "$BIN" repair tags --restructure --dry-run
    [[ "$output" =~ "Nothing to restructure" ]]
}

@test "a pinned membership stays on its tag through a split, and a manual tag is never proposed" {
    loosened_tag
    db "UPDATE document_tag SET decision = 'pinned' WHERE document = ${B[1]} AND tag = $T;"
    AGENT_TEST_RESPONSES="$SPLIT_DIFFERENT" run "$BIN" repair tags --restructure
    new=$(db "SELECT id FROM tag WHERE label = 'Bioreactor runs';")
    [ "$(members_of "$new")" = "2" ]
    [ "$(db "SELECT COUNT(*) FROM document_tag WHERE document = ${B[1]} AND tag = $T AND decision = 'pinned';")" = "1" ]

    M=$(new_tag "Hand made" manual)
    for i in 1 2 3; do member "${A[$i]}" "$M"; done
    "$BIN" repair tags >/dev/null
    for i in 2 3; do member "${B[$i]}" "$M"; done
    run "$BIN" repair tags --restructure --dry-run
    [[ ! "$output" =~ "Hand made" ]]
}

@test "a proposed label another tag already has is not applied" {
    loosened_tag
    new_tag "Bioreactor runs" >/dev/null
    AGENT_TEST_RESPONSES="$SPLIT_DIFFERENT" run "$BIN" repair tags --restructure
    [[ "$output" =~ "not split: a proposed label is already another tag's" ]]
    [ "$(db "SELECT COUNT(*) FROM tag WHERE label = 'Bioreactor runs';")" = "1" ]
    [ "$(members_of "$T")" = "8" ]
}

# Three tags built apart (x, y, z), then four x documents join "Beta":
# Alpha and Beta now share a direction, closer than any pair at build.
converged_tags() {
    write_platform_config ", tag_split_min = 100"
    for i in 1 2 3 4; do X[$i]=$(new_document "Alpha doc $i" 1 0.0$i 0); done
    for i in 1 2 3; do Y[$i]=$(new_document "Beta doc $i" 0.0$i 1 0); done
    for i in 1 2 3; do Z[$i]=$(new_document "Gamma doc $i" 0 0.0$i 1); done
    for i in 1 2 3 4; do W[$i]=$(new_document "Late doc $i" 1 0 0.0$i); done
    ALPHA=$(new_tag "Alpha"); BETA=$(new_tag "Beta"); GAMMA=$(new_tag "Gamma")
    for i in 1 2 3 4; do member "${X[$i]}" "$ALPHA"; done
    for i in 1 2 3; do member "${Y[$i]}" "$BETA"; done
    for i in 1 2 3; do member "${Z[$i]}" "$GAMMA"; done
    "$BIN" repair tags >/dev/null
    for i in 1 2 3 4; do member "${W[$i]}" "$BETA"; done
}

@test "two tags that converged merge into the larger when the agent calls them SAME" {
    converged_tags
    run "$BIN" repair tags --restructure --dry-run
    [[ "$output" =~ "merge #$BETA \"Beta\" (7) and #$ALPHA \"Alpha\" (4)" ]]
    [[ ! "$output" =~ "Gamma" ]]

    AGENT_TEST_RESPONSES=$'SAME -- both are about the same cultures\nNAME: Cacao cultures | Cultures of cacao cells.' run "$BIN" repair tags --restructure
    [[ "$output" =~ "merged #$ALPHA into #$BETA" ]]
    [ -n "$(db "SELECT archived_at FROM tag WHERE id = $ALPHA;")" ]
    [ "$(members_of "$BETA")" = "11" ]
    [ "$(db "SELECT label FROM tag WHERE id = $BETA;")" = "Cacao cultures" ]
    [ "$(db "SELECT members FROM tag_centre WHERE tag_id = $BETA;")" = "11" ]
}

@test "a merge the agent calls DIFFERENT stays apart and isn't asked again while the tags hold" {
    converged_tags
    AGENT_TEST_RESPONSES="DIFFERENT -- distinct subjects" run "$BIN" repair tags --restructure
    [[ "$output" =~ "kept apart" ]]
    AGENT_TEST_RESPONSES=$'SAME -- would merge\nNAME: Merged | x' run "$BIN" repair tags --restructure
    [[ "$output" =~ "kept -- judged DIFFERENT before" ]]
    [ -z "$(db "SELECT archived_at FROM tag WHERE id = $ALPHA;")" ]
    [ "$(db "SELECT COUNT(*) FROM tag_judgment;")" = "1" ]
}

@test "a tag that grew is re-checked: RENAME relabels it, and the next check waits for more growth" {
    write_platform_config ", tag_split_min = 100"
    for i in 1 2 3 4 5 6; do D[$i]=$(new_document "Media $i" 1 0.0$i 0); done
    T=$(new_tag "Media")
    for i in 1 2 3 4 5; do member "${D[$i]}" "$T"; done
    "$BIN" repair tags >/dev/null
    run "$BIN" repair tags --restructure --dry-run
    [[ "$output" =~ "Nothing to restructure" ]]

    member "${D[6]}" "$T"
    AGENT_TEST_RESPONSES=$'RENAME -- now about media recipes\nNAME: Media recipes | Recipes for culture media.' run "$BIN" repair tags --restructure
    [[ "$output" =~ "fit #$T \"Media\" (6 members, 5 when its label was last judged)" ]]
    [[ "$output" =~ "renamed" ]]
    [ "$(db "SELECT label FROM tag WHERE id = $T;")" = "Media recipes" ]
    [ "$(db "SELECT fit_members FROM tag_upkeep WHERE tag_id = $T;")" = "6" ]
    run "$BIN" repair tags --restructure --dry-run
    [[ "$output" =~ "Nothing to restructure" ]]
}

@test "with tag_restructure on, embed-pending runs the upkeep after embedding" {
    loosened_tag
    write_platform_config ", tag_split_min = 4, tag_restructure = true, embedding_quiet_minutes = 5"
    "$BIN" entity create document title="Late note" content="a late note" >/dev/null
    db "UPDATE document_embedding_due SET queued_at = '2000-01-01 00:00:00';"
    AGENT_TEST_RESPONSES="$SPLIT_DIFFERENT" run "$BIN" document embed-pending
    [[ "$output" =~ "Embedded 1" ]]
    [[ "$output" =~ "tag upkeep: split #$T" ]]
    [ -n "$(db "SELECT id FROM tag WHERE label = 'Bioreactor runs';")" ]
}

@test "with tag_restructure off (the default), embed-pending leaves the tags alone" {
    loosened_tag
    write_platform_config ", tag_split_min = 4, embedding_quiet_minutes = 5"
    "$BIN" entity create document title="Late note" content="a late note" >/dev/null
    db "UPDATE document_embedding_due SET queued_at = '2000-01-01 00:00:00';"
    AGENT_TEST_RESPONSES="$SPLIT_DIFFERENT" run "$BIN" document embed-pending
    [[ "$output" =~ "Embedded 1" ]]
    [[ ! "$output" =~ "tag upkeep" ]]
    [ "$(db "SELECT COUNT(*) FROM tag;")" = "1" ]
}
