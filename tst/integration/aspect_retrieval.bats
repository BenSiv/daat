#!/usr/bin/env bats
# Aspects (doc/aspect-retrieval-plan.md): a long document gets a few
# extra vectors from its passages grouped by meaning, so search finds it
# by a subject its own vector doesn't cover.
#
# The test provider's word-based embeddings (AGENT_TEST_EMBEDDINGS=terms)
# hash each word into one of 64 dimensions. The handbook below is two
# long sections of greenhouse filler and one short section about the
# centrifuge. The query "qqqvq" shares no characters with it (so words
# can't find it) but hashes to the same dimension as "centrifuge": only
# the centrifuge passage is close to it in meaning, while the whole
# document's vector, dominated by the filler, falls below the
# similarity floor.

load test_helper.bash

ASPECTS=", search_passages = true, passage_min_chars = 50, aspect_min_chars = 1000"

# A long document: two sections of greenhouse filler, then one short
# section that repeats `word` 30 times.
handbook() {
    local filler spin
    filler=$(printf 'Plants were watered and the greenhouse lights were checked. %.0s' $(seq 1 40))
    spin=$(printf "$2 %.0s" $(seq 1 30))
    "$BIN" document create-json <<< "[{\"title\":\"$1\",\"content\":\"# Greenhouse\\n${filler}\\n\\n# Watering\\n${filler}\\n\\n# $3\\n${spin}\"}]" >/dev/null
}

setup() {
    setup_test_env
    write_platform_config "${ASPECTS}, build_aspects = true, search_aspects = true"
    "$BIN" init >/dev/null
    export AGENT_TEST_EMBEDDINGS=terms
    export AGENT_TEST_EMBEDDINGS_LOG="$TEST_DIR/embeddings.log"
    read session csrf < <(login_test_user "alice" "i")
    COOKIE="session=${session}; csrf=${csrf}"
    handbook "Lab handbook" centrifuge Centrifuge
    DOC_ID=$(sqlite3 "$TEST_DIR/.store/store.db" "SELECT id FROM document WHERE title = 'Lab handbook';")
}

teardown() {
    cleanup_test_env
}

db() {
    sqlite3 "$TEST_DIR/.store/store.db" "$1"
}

# The /documents search box. The page always lists every document in
# its tree, so whether search found one is read from the retrieval log.
page_search() {
    raw_get "/documents" "q=$1" "$COOKIE"
}

# How many searches found the handbook, and through which aspect.
hits() {
    db "SELECT COUNT(*) FROM knowledge_retrieval_hit WHERE document_id = ${DOC_ID};"
}

# Passage embeddings only: every passage here starts with its heading.
embedded_lines() {
    if [ -f "$AGENT_TEST_EMBEDDINGS_LOG" ]; then grep -c '^# ' "$AGENT_TEST_EMBEDDINGS_LOG"; else echo 0; fi
}

@test "a long document gets aspects when saved; a short one gets none" {
    "$BIN" document create-json <<< '[{"title":"Short note","content":"The centrifuge runs at four thousand rpm."}]' >/dev/null
    short_id=$(db "SELECT id FROM document WHERE title = 'Short note';")
    [ "$(db "SELECT COUNT(*) FROM document_aspect WHERE document_id = ${DOC_ID};")" -ge 2 ]
    [ "$(db "SELECT COUNT(*) FROM document_aspect WHERE document_id = ${short_id};")" -eq 0 ]
    # int8: one byte per dimension of the test provider's 64.
    [ "$(db "SELECT MIN(LENGTH(vector_packed)) FROM document_aspect;")" = "64" ]
    # The centrifuge section is an aspect of its own, pointing at where it starts.
    offset=$(db "SELECT instr(content, '# Centrifuge') - 1 FROM document WHERE id = ${DOC_ID};")
    [ "$(db "SELECT COUNT(*) FROM document_aspect WHERE document_id = ${DOC_ID} AND passage_offset = ${offset} AND passage_count = 1;")" -eq 1 ]
}

@test "search finds a long document by a subject past its start through an aspect, and records which" {
    page_search "qqqvq" >/dev/null
    [ "$(hits)" -eq 1 ]
    aspect=$(db "SELECT aspect FROM knowledge_retrieval_hit WHERE document_id = ${DOC_ID};")
    [ -n "$aspect" ]
    [ "$(db "SELECT COUNT(*) FROM document_aspect WHERE document_id = ${DOC_ID} AND aspect = ${aspect} AND passage_count = 1;")" -eq 1 ]
}

@test "with search_aspects off, the same search doesn't find it, and hits record no aspect" {
    write_platform_config "${ASPECTS}, build_aspects = true, search_aspects = false"
    page_search "qqqvq" >/dev/null
    [ "$(hits)" -eq 0 ]
    page_search "greenhouse" >/dev/null
    [ "$(hits)" -eq 1 ]
    [ "$(db "SELECT COUNT(*) FROM knowledge_retrieval_hit WHERE document_id = ${DOC_ID} AND aspect IS NULL;")" -eq 1 ]
}

@test "a document found by its words or its own vector records no aspect" {
    page_search "greenhouse" >/dev/null
    [ "$(db "SELECT COUNT(*) FROM knowledge_retrieval_hit WHERE document_id = ${DOC_ID} AND aspect IS NULL;")" -eq 1 ]
}

@test "with build_aspects off nothing is built on save; repair aspects builds them, then finds them unchanged" {
    write_platform_config "${ASPECTS}, build_aspects = false, search_aspects = true"
    handbook "Second handbook" rotor Rotor
    second=$(db "SELECT id FROM document WHERE title = 'Second handbook';")
    [ "$(db "SELECT COUNT(*) FROM document_aspect WHERE document_id = ${second};")" -eq 0 ]
    run "$BIN" repair aspects
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Built aspects for 1 document(s)" ]]
    [[ "$output" =~ "1 unchanged" ]]
    [[ "$output" =~ "0 failed" ]]
    [ "$(db "SELECT COUNT(*) FROM document_aspect WHERE document_id = ${second};")" -ge 2 ]
    run "$BIN" repair aspects
    [[ "$output" =~ "Built aspects for 0 document(s) (0 aspects), 2 unchanged" ]]
    run "$BIN" repair aspects "$second"
    [[ "$output" =~ "Document #${second}: unchanged" ]]
}

@test "repair aspects --limit builds at most that many documents" {
    write_platform_config "${ASPECTS}, build_aspects = false"
    db "DELETE FROM document_aspect;"
    handbook "Second handbook" rotor Rotor
    run "$BIN" repair aspects --limit 1
    [[ "$output" =~ "Built aspects for 1 document(s)" ]]
    run "$BIN" repair aspects
    [[ "$output" =~ "Built aspects for 1 document(s)" ]]
}

@test "editing a document rebuilds its aspects, embedding only the passage that changed" {
    before=$(embedded_lines)
    "$BIN" entity update document "$DOC_ID" content="$(db "SELECT replace(content, 'centrifuge centrifuge', 'centrifuge pellet') FROM document WHERE id = ${DOC_ID};")" >/dev/null
    [ "$(embedded_lines)" -eq $((before + 1)) ]
    [ "$(db "SELECT COUNT(*) FROM document_aspect WHERE document_id = ${DOC_ID};")" -ge 2 ]
}

@test "changing an aspect setting makes the aspects stale" {
    run "$BIN" repair aspects "$DOC_ID"
    [[ "$output" =~ "unchanged" ]]
    write_platform_config "${ASPECTS}, build_aspects = true, search_aspects = true, aspect_dims = 16"
    run "$BIN" repair aspects "$DOC_ID"
    [[ "$output" =~ "built" ]]
    [ "$(db "SELECT MIN(LENGTH(vector_packed)) FROM document_aspect;")" = "16" ]
    page_search "qqqvq" >/dev/null
    [ "$(db "SELECT COUNT(*) FROM knowledge_retrieval_hit WHERE document_id = ${DOC_ID} AND aspect IS NOT NULL;")" -eq 1 ]
}

@test "a document edited down to a short one loses its aspects" {
    "$BIN" entity update document "$DOC_ID" content="The centrifuge is in room two." >/dev/null
    [ "$(db "SELECT COUNT(*) FROM document_aspect WHERE document_id = ${DOC_ID};")" -eq 0 ]
}

@test "archiving a document drops its aspects, and repair knowledge clears leftovers" {
    "$BIN" entity archive document "$DOC_ID" >/dev/null
    [ "$(db "SELECT COUNT(*) FROM document_aspect WHERE document_id = ${DOC_ID};")" -eq 0 ]
    db "INSERT INTO document_aspect (document_id, model, aspect, vector_packed, passage_offset, passage_count, member_offsets, text_hash) VALUES (${DOC_ID}, 'test-embedding', 1, X'01', 0, 1, '0', 'x');"
    run "$BIN" repair knowledge
    [[ "$output" =~ "aspects of archived or missing documents" ]]
    [ "$(db "SELECT COUNT(*) FROM document_aspect;")" -eq 0 ]
}

@test "if the aspect build fails, the document stays queued and the next run retries" {
    write_platform_config "${ASPECTS}, build_aspects = true, embedding_quiet_minutes = 5"
    db "DELETE FROM document_aspect; DELETE FROM document_passage_cache;"
    db "INSERT INTO document_embedding_due (document_id, queued_at) VALUES (${DOC_ID}, '2020-01-01 00:00:00');"
    AGENT_TEST_EMBEDDINGS_FAIL=1 run "$BIN" document embed-pending
    [[ "$output" =~ "failed 1" ]]
    [ "$(db "SELECT COUNT(*) FROM document_embedding_due WHERE document_id = ${DOC_ID};")" -eq 1 ]
    run "$BIN" document embed-pending
    [ "$(db "SELECT COUNT(*) FROM document_embedding_due WHERE document_id = ${DOC_ID};")" -eq 0 ]
    [ "$(db "SELECT COUNT(*) FROM document_aspect WHERE document_id = ${DOC_ID};")" -ge 2 ]
}

# Curation from aspects (src/curate.lua): a part of a long source that
# searches keep finding through its aspect gets a note of its own.

# A source longer than the curate input cap (40,000 characters), its
# centrifuge section past it: 18 sections of filler, then the section.
long_source() {
    local filler spin body=""
    filler=$(printf 'Plants were watered and the greenhouse lights were checked. %.0s' $(seq 1 40))
    spin=$(printf 'centrifuge %.0s' $(seq 1 60))
    for i in $(seq 1 18); do
        body="${body}# Greenhouse ${i}\\n${filler}\\n\\n"
    done
    "$BIN" document create-json <<< "[{\"title\":\"Long manual\",\"content\":\"${body}# Centrifuge\\n${spin}\"}]" >/dev/null
    db "SELECT id FROM document WHERE title = 'Long manual';"
}

ASPECT_NOTE=$'# Centrifuge use\n\nThe manual repeats the word centrifuge in its last section.'
SOURCE_NOTE=$'# Greenhouse routine\n\nPlants were watered and the lights checked.'

@test "a second search through the same aspect queues that part for curation; one search doesn't" {
    page_search "qqqvq" >/dev/null
    [ "$(db "SELECT COUNT(*) FROM knowledge_aspect_curation;")" -eq 0 ]
    page_search "qqqvq" >/dev/null
    aspect=$(db "SELECT aspect FROM knowledge_retrieval_hit WHERE document_id = ${DOC_ID} LIMIT 1;")
    [ "$(db "SELECT status FROM knowledge_aspect_curation WHERE document_id = ${DOC_ID} AND aspect = ${aspect};")" = "pending" ]
    [ "$(db "SELECT COUNT(*) FROM knowledge_aspect_curation;")" -eq 1 ]
}

@test "with curate_aspects off, aspect hits queue nothing" {
    write_platform_config "${ASPECTS}, build_aspects = true, search_aspects = true, curate_aspects = false"
    page_search "qqqvq" >/dev/null
    page_search "qqqvq" >/dev/null
    [ "$(hits)" -eq 2 ]
    [ "$(db "SELECT COUNT(*) FROM knowledge_aspect_curation;")" -eq 0 ]
}

@test "an aspect past the curate input cap is curated from its own passages into a tier-1 note that says where the part starts" {
    # Only the long source is found, so the scripted replies are its own.
    "$BIN" entity archive document "$DOC_ID" >/dev/null
    long=$(long_source)
    offset=$(db "SELECT instr(content, '# Centrifuge') - 1 FROM document WHERE id = ${long};")
    [ "$offset" -gt 40000 ]
    page_search "qqqvq" >/dev/null
    page_search "qqqvq" >/dev/null
    aspect=$(db "SELECT aspect FROM knowledge_aspect_curation WHERE document_id = ${long} AND status = 'pending';")
    [ -n "$aspect" ]

    # The whole source is due too and runs first: its note, then the aspect's.
    export AGENT_TEST_GENERATE_RESPONSES="$SOURCE_NOTE"$'\1'"PASS"$'\1'"$ASPECT_NOTE"$'\1'"PASS"
    export AGENT_TEST_CAPTURE_PROMPT="$TEST_DIR/prompt.txt"
    export AGENT_TEST_CAPTURE_SYSTEM_PROMPT="$TEST_DIR/system.txt"
    run "$BIN" knowledge curate-pending 5
    [ "$status" -eq 0 ]
    note=$(db "SELECT note_id FROM knowledge_aspect_curation WHERE document_id = ${long} AND aspect = ${aspect};")
    [ -n "$note" ]
    [[ "$output" =~ "#${long} aspect ${aspect} curated -> note #${note}" ]]
    [ "$(db "SELECT status FROM knowledge_aspect_curation WHERE document_id = ${long} AND aspect = ${aspect};")" = "curated" ]

    # The check (the last call) saw the centrifuge section, not the filler.
    prompt=$(cat "$TEST_DIR/prompt.txt")
    [[ "$prompt" =~ "# Centrifuge" ]]
    [[ ! "$prompt" =~ "greenhouse lights" ]]
    [[ "$(cat "$TEST_DIR/system.txt")" =~ "one part of a longer document" ]]

    [ "$(db "SELECT title || '|' || tier || '|' || source_type || '|' || source_id || '|' || source_ref FROM document WHERE id = ${note};")" = "Centrifuge use|1|curated|${long}|aspect ${aspect}" ]
    [[ "$(db "SELECT content FROM document WHERE id = ${note};")" =~ "Source: [[Long manual]], the part at character ${offset}" ]]
    # Next to the whole source's own note, not in its place.
    [ "$(db "SELECT COUNT(*) FROM document WHERE source_type = 'curated' AND source_id = ${long};")" -eq 2 ]

    # Found again through the same, unchanged part: nothing new to do.
    page_search "qqqvq" >/dev/null
    [ "$(db "SELECT status FROM knowledge_aspect_curation WHERE document_id = ${long} AND aspect = ${aspect};")" = "curated" ]
}

@test "a queued aspect gone by the time it runs comes to nothing; an archived source leaves the queue" {
    page_search "qqqvq" >/dev/null
    page_search "qqqvq" >/dev/null
    db "DELETE FROM knowledge_curation;"
    db "DELETE FROM document_aspect;"
    run "$BIN" knowledge curate-pending 5
    [[ "$output" =~ "aspect" ]] && [[ "$output" =~ "nothing" ]]
    [ "$(db "SELECT reason FROM knowledge_aspect_curation WHERE document_id = ${DOC_ID};")" = "the aspect no longer exists" ]

    db "UPDATE knowledge_aspect_curation SET status = 'pending';"
    "$BIN" entity archive document "$DOC_ID" >/dev/null
    run "$BIN" knowledge curate-pending 5
    [[ "$output" =~ "skipped" ]]
    [ "$(db "SELECT COUNT(*) FROM knowledge_aspect_curation;")" -eq 0 ]
}

@test "repair aspects counts a document whose build fails, says why, and goes on to the rest" {
    write_platform_config "${ASPECTS}, build_aspects = false"
    db "DELETE FROM document_aspect; DELETE FROM document_passage_cache;"
    AGENT_TEST_EMBEDDINGS_FAIL=1 run "$BIN" repair aspects
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1 failed" ]]
    [[ "$output" =~ "document ${DOC_ID}: aspects failed:" ]]
    run "$BIN" repair aspects
    [[ "$output" =~ "Built aspects for 1 document(s)" ]]
}
