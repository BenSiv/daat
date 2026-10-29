#!/usr/bin/env bats

# Cold start (src/tag_build.lua, doc/tag-ontology.md phase 3c): tags built
# in daat from its own embeddings. Ninety documents in three clearly
# separate groups (8-number vectors, the test provider's length, along
# three axes with some spread); the build should find three tags, the
# same way every run, and name them through the scripted agent.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    for g in 1 2 3; do
        for i in $(seq 1 30); do
            "$BIN" entity create document title="Group$g doc $i" content="group $g note $i" >/dev/null
        done
    done
    # Vectors: axis g, plus a small spread on axes 4..8 that differs for
    # every document (no two identical, as real embeddings).
    sqlite3 .store/store.db "SELECT id, title FROM document WHERE title LIKE 'Group%';" | while IFS='|' read -r id title; do
        g=${title:5:1}
        i=${title##* }
        v=(0 0 0 0 0 0 0 0)
        v[$((g - 1))]=1
        v[$((3 + i % 5))]=0.2$i
        v[$((3 + (i * 3 + 1) % 5))]=0.1$((i * 7 % 10))
        sqlite3 .store/store.db "INSERT OR REPLACE INTO document_embedding (document_id, model, vector_json) VALUES ($id, 'test-embedding', '[$(IFS=,; echo "${v[*]}")]');"
    done
}

teardown() {
    cleanup_test_env
}

db() {
    sqlite3 .store/store.db "$1"
}

NAMES=$'Alpha notes | Notes of the first group.\1Beta notes | Notes of the second group.\1Gamma notes | Notes of the third group.'

@test "a dry run finds the three groups, the same way every time, and writes nothing" {
    run "$BIN" tag build --dry-run
    [[ "$output" =~ "90 documents with an embedding" ]]
    [[ "$output" =~ "cut: " ]]
    [ "$(printf '%s\n' "$output" | grep -c '^tag [0-9]*: 30 documents')" = "3" ]
    [[ "$output" =~ "Dry run: nothing written" ]]
    [ "$(db "SELECT COUNT(*) FROM tag;")" = "0" ]
    # Same clusters, same order -- only the elapsed seconds may differ.
    first=$(printf '%s\n' "$output" | sed 's/ ([0-9]*s)//')
    run "$BIN" tag build --dry-run
    [ "$(printf '%s\n' "$output" | sed 's/ ([0-9]*s)//')" = "$first" ]
}

@test "the build writes three named tags, each holding one group, and records the upkeep baselines" {
    AGENT_TEST_RESPONSES="$NAMES" run "$BIN" tag build
    [[ "$output" =~ "wrote tag #" ]]
    [ "$(db "SELECT COUNT(*) FROM tag WHERE source = 'computed';")" = "3" ]
    [ "$(db "SELECT GROUP_CONCAT(label, ',') FROM (SELECT label FROM tag ORDER BY label);")" = "Alpha notes,Beta notes,Gamma notes" ]
    [ "$(db "SELECT COUNT(*) FROM document_tag WHERE decision = 'computed';")" = "90" ]
    # Each tag's documents come from a single group.
    [ "$(db "SELECT COUNT(DISTINCT dt.tag || SUBSTR(d.title, 1, 6)) FROM document_tag dt JOIN document d ON d.id = dt.document;")" = "3" ]
    [ "$(db "SELECT COUNT(*) FROM tag_upkeep;")" = "3" ]
    [ "$(db "SELECT SUM(members) FROM tag_centre;")" = "90" ]
    [ -n "$(db "SELECT description FROM tag WHERE label = 'Beta notes';")" ]
}

@test "once tags exist the build is refused, and a dry run reports how it agrees with them" {
    AGENT_TEST_RESPONSES="$NAMES" "$BIN" tag build >/dev/null
    run "$BIN" tag build
    [[ "$output" =~ "Refused: this deployment already has computed tags" ]]
    [ "$(db "SELECT COUNT(*) FROM tag;")" = "3" ]
    run "$BIN" tag build --dry-run
    [[ "$output" =~ "Agreement with the current tags: adjusted Rand 1.000 over 90 documents (3 current tags, 3 built)" ]]
    [[ "$output" =~ "[mostly \"" ]]
}

@test "labels two tags were given are asked again, together, until distinct" {
    AGENT_TEST_RESPONSES=$'Notes | a\1Notes | b\1Notes | c\1Field notes\nBench notes\nDesk notes' run "$BIN" tag build
    [ "$(db "SELECT COUNT(DISTINCT label) FROM tag;")" = "3" ]
    [ "$(db "SELECT GROUP_CONCAT(label, ',') FROM (SELECT label FROM tag ORDER BY label);")" = "Bench notes,Desk notes,Field notes" ]
}

@test "documents with too little text of their own are left out of the build" {
    for i in 1 2 3 4 5; do "$BIN" entity create document title="Folder $i" content="" >/dev/null; done
    db "UPDATE document_embedding SET body_chars = 0 WHERE document_id IN (SELECT id FROM document WHERE title LIKE 'Folder %');"
    db "INSERT OR IGNORE INTO document_embedding (document_id, model, vector_json, body_chars) SELECT id, 'test-embedding', '[0,0,0,1,1,0,0,0]', 0 FROM document WHERE title LIKE 'Folder %';"
    write_platform_config ", tag_min_text = 200"
    run "$BIN" tag build --dry-run
    [[ "$output" =~ "90 documents with an embedding" ]]
    [[ "$output" =~ "5 left out with under 200 characters of text" ]]
    [ "$(printf '%s\n' "$output" | grep -c '^tag [0-9]*: 30 documents')" = "3" ]
}

@test "--replace archives the computed tags and their memberships, then writes the new build" {
    AGENT_TEST_RESPONSES="$NAMES" "$BIN" tag build >/dev/null
    old=$(db "SELECT GROUP_CONCAT(id) FROM tag;")
    AGENT_TEST_RESPONSES=$'Delta notes | d\1Epsilon notes | e\1Zeta notes | z' run "$BIN" tag build --replace
    [[ "$output" =~ "archived tag #" ]]
    [[ "$output" =~ "wrote tag #" ]]
    [ "$(db "SELECT COUNT(*) FROM tag WHERE archived_at IS NOT NULL AND archived_at != '' AND id IN ($old);")" = "3" ]
    [ "$(db "SELECT GROUP_CONCAT(label, ',') FROM (SELECT label FROM tag WHERE archived_at IS NULL OR archived_at = '' ORDER BY label);")" = "Delta notes,Epsilon notes,Zeta notes" ]
    [ "$(db "SELECT COUNT(*) FROM document_tag WHERE archived_at IS NULL OR archived_at = '';")" = "90" ]
    [ "$(db "SELECT COUNT(*) FROM document_tag WHERE tag IN ($old) AND (archived_at IS NULL OR archived_at = '');")" = "0" ]
    [ "$(db "SELECT SUM(members) FROM tag_centre c JOIN tag t ON t.id = c.tag_id WHERE t.archived_at IS NULL OR t.archived_at = '';")" = "90" ]
}

@test "--replace is refused while a computed tag holds a membership a person pinned" {
    AGENT_TEST_RESPONSES="$NAMES" "$BIN" tag build >/dev/null
    db "UPDATE document_tag SET decision = 'pinned' WHERE id = (SELECT MIN(id) FROM document_tag);"
    run "$BIN" tag build --replace
    [[ "$output" =~ "Refused: 1 membership(s) a person set are on computed tags" ]]
    [ "$(db "SELECT COUNT(*) FROM tag WHERE archived_at IS NULL OR archived_at = '';")" = "3" ]
}

@test "--max-tags, or tag_build_max, caps how many tags the build cuts the pool into" {
    run "$BIN" tag build --dry-run --max-tags 2
    [[ "$output" =~ "cut: 2 tags" ]]
    [[ "$output" =~ "range 2-2)" ]]
    write_platform_config ", tag_build_max = 2"
    run "$BIN" tag build --dry-run
    [[ "$output" =~ "cut: 2 tags" ]]
}
