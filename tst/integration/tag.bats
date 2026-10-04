#!/usr/bin/env bats

# Tag upkeep in core (src/tag.lua, doc/tag-ontology.md). The test
# provider embeds every document as an 8-number vector; each test creates
# its documents before any tag exists (so nothing is placed yet), then
# overwrites their vectors with chosen ones of the same length.

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

new_document() {
    "$BIN" entity create document title="$1" content="$1" >/dev/null
    db "SELECT id FROM document WHERE title = '$1';"
}

new_tag() {
    "$BIN" entity create tag label="$1" source=computed >/dev/null
    db "SELECT id FROM tag WHERE label = '$1';"
}

embed() {
    db "INSERT OR REPLACE INTO document_embedding (document_id, model, vector_json) VALUES ($1, 'test', '$2');"
}

api_write() {
    printf '%s' "$4" | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="$1" PATH_INFO="$2" QUERY_STRING="" \
        HTTP_X_API_KEY="$3" "$BIN"
}

members() {
    db "SELECT COALESCE((SELECT members FROM tag_centre WHERE tag_id = $1), 0);"
}

@test "a tag's centre follows its memberships: added on create, out on archive, excluded never counted" {
    a=$(new_document "Callus on leaf explants")
    b=$(new_document "Callus on cotyledons")
    c=$(new_document "Unrelated memo")
    embed "$a" '[1, 0, 0, 0, 0, 0, 0, 0]'
    embed "$b" '[0.9, 0.1, 0, 0, 0, 0, 0, 0]'
    embed "$c" '[0, 0, 1, 0, 0, 0, 0, 0]'
    t=$(new_tag "Callus induction")

    "$BIN" entity create document_tag document="$a" tag="$t" decision=computed >/dev/null
    "$BIN" entity create document_tag document="$b" tag="$t" decision=pinned >/dev/null
    "$BIN" entity create document_tag document="$c" tag="$t" decision=excluded >/dev/null
    [ "$(members "$t")" = "2" ]

    m=$(db "SELECT id FROM document_tag WHERE document = $b;")
    "$BIN" entity archive document_tag "$m" >/dev/null
    [ "$(members "$t")" = "1" ]

    # An archived document leaves the centre too, and comes back with it.
    "$BIN" entity archive document "$a" >/dev/null
    [ "$(members "$t")" = "0" ]
    "$BIN" entity unarchive document "$a" >/dev/null
    [ "$(members "$t")" = "1" ]
}

@test "repair tags places a document in its nearest tag, with a close second, never an excluded one" {
    a=$(new_document "Leaf callus")
    b=$(new_document "Suspension culture")
    near=$(new_document "Callus from flowers")
    both=$(new_document "Callus to suspension transfer")
    embed "$a" '[1, 0, 0, 0, 0, 0, 0, 0]'
    embed "$b" '[0, 1, 0, 0, 0, 0, 0, 0]'
    embed "$near" '[0.95, 0.2, 0, 0, 0, 0, 0, 0]'
    embed "$both" '[0.7, 0.7, 0, 0, 0, 0, 0, 0]'
    callus=$(new_tag "Callus induction")
    suspension=$(new_tag "Suspension culture")
    "$BIN" entity create document_tag document="$a" tag="$callus" decision=computed >/dev/null
    "$BIN" entity create document_tag document="$b" tag="$suspension" decision=computed >/dev/null

    # Equally near both centres: within tag_second_within, so it joins both.
    "$BIN" repair tags "$both" >/dev/null
    [ "$(db "SELECT COUNT(*) FROM document_tag WHERE document = $both AND archived_at IS NULL;")" = "2" ]

    run "$BIN" repair tags "$near"
    [[ "$output" =~ "is in tag #${callus}" ]]
    [ "$(db "SELECT tag || ':' || decision FROM document_tag WHERE document = $near AND archived_at IS NULL;")" = "${callus}:computed" ]
    [ "$(members "$callus")" = "3" ]

    # A person excluded it from callus: re-placing moves it, never back.
    "$BIN" entity create document_tag document="$near" tag="$callus" decision=excluded >/dev/null
    old=$(db "SELECT id FROM document_tag WHERE document = $near AND decision = 'computed';")
    "$BIN" entity archive document_tag "$old" >/dev/null
    run "$BIN" repair tags "$near"
    [[ "$output" =~ "is in tag #${suspension}" ]]
    [ "$(db "SELECT COUNT(*) FROM document_tag WHERE document = $near AND tag = $callus AND decision = 'computed' AND archived_at IS NULL;")" = "0" ]
}

@test "a pinned tag isn't duplicated by placement, and repair tags rebuilds every centre" {
    a=$(new_document "Leaf callus")
    embed "$a" '[1, 0, 0, 0, 0, 0, 0, 0]'
    t=$(new_tag "Callus induction")
    "$BIN" entity create document_tag document="$a" tag="$t" decision=pinned >/dev/null

    "$BIN" repair tags "$a" >/dev/null
    [ "$(db "SELECT COUNT(*) FROM document_tag WHERE document = $a AND archived_at IS NULL;")" = "1" ]

    db "DELETE FROM tag_centre;"
    run "$BIN" repair tags
    [[ "$output" =~ "Rebuilt 1 tag centre(s) from 1 membership(s)" ]]
    [ "$(members "$t")" = "1" ]
}

@test "with no tags or no embedding, placement does nothing" {
    a=$(new_document "Leaf callus")
    run "$BIN" repair tags "$a"
    [[ "$output" =~ "not placed" ]]
    [ "$(db "SELECT COUNT(*) FROM document_tag;")" = "0" ]
}

@test "saving a document places it: a new one joins the nearest tag, an edit swaps its vector without counting it twice" {
    a=$(new_document "Leaf callus")
    t=$(new_tag "Callus induction")
    "$BIN" entity create document_tag document="$a" tag="$t" decision=computed >/dev/null
    [ "$(members "$t")" = "1" ]

    # Created after the tag exists: placed on save, with the test
    # provider's own vector -- the only tag is the nearest.
    b=$(new_document "Callus from flowers")
    [ "$(db "SELECT tag || ':' || decision FROM document_tag WHERE document = $b AND archived_at IS NULL;")" = "${t}:computed" ]
    [ "$(members "$t")" = "2" ]

    "$BIN" entity update document "$b" content="Callus from flowers, second attempt" >/dev/null
    [ "$(members "$t")" = "2" ]
    [ "$(db "SELECT COUNT(*) FROM document_tag WHERE document = $b AND archived_at IS NULL;")" = "1" ]
}

@test "repair tag-evidence lifts links and connection documents onto tags, and archives pairs that are gone" {
    b=$(new_document "Suspension culture")
    "$BIN" entity create document title="Leaf callus" content="moved on to [[Suspension culture]]" >/dev/null
    a=$(db "SELECT id FROM document WHERE title = 'Leaf callus';")
    c=$(new_document "Cell growth")
    callus=$(new_tag "Callus induction")
    suspension=$(new_tag "Suspension culture")
    "$BIN" entity create document_tag document="$a" tag="$callus" decision=computed >/dev/null
    "$BIN" entity create document_tag document="$b" tag="$suspension" decision=computed >/dev/null
    "$BIN" entity create document_tag document="$c" tag="$suspension" decision=computed >/dev/null

    # A connection document is one undirected edge, never two links.
    "$BIN" entity create document title="Leaf callus ↔ Cell growth" content="[[Leaf callus]] and [[Cell growth]]: same media" >/dev/null

    run "$BIN" repair tag-evidence
    [[ "$output" =~ "row(s) written" ]]
    [ "$(db "SELECT tag_a || '>' || tag_b || ':' || direction || ':' || weight || ':' || support FROM tag_evidence WHERE kind = 'link' AND producer = 'core' AND archived_at IS NULL;")" = "${callus}>${suspension}:directed:1.0:1.0" ]
    lo=$callus; hi=$suspension; if [ "$hi" -lt "$lo" ]; then lo=$suspension; hi=$callus; fi
    [ "$(db "SELECT tag_a || '-' || tag_b || ':' || direction FROM tag_evidence WHERE kind = 'connection' AND archived_at IS NULL;")" = "${lo}-${hi}:undirected" ]

    # Nothing changed: nothing written.
    run "$BIN" repair tag-evidence
    [[ "$output" =~ ": 0 row(s) written" ]]

    "$BIN" entity update document "$a" content="no links any more" >/dev/null
    "$BIN" repair tag-evidence >/dev/null
    [ "$(db "SELECT COUNT(*) FROM tag_evidence WHERE kind = 'link' AND archived_at IS NULL;")" = "0" ]
}

@test "#tags in a document's text are pinned memberships kept while the text has them, created with the tag if new" {
    t=$(new_tag "Cocoa bean fermentation")
    "$BIN" entity create document title="Fermentation trial" content="Day 3 of #cocoa-bean-fermentation, see also #pod-storage." >/dev/null
    d=$(db "SELECT id FROM document WHERE title = 'Fermentation trial';")

    [ "$(db "SELECT decision || ':' || via FROM document_tag WHERE document = $d AND tag = $t AND archived_at IS NULL;")" = "pinned:text" ]
    new=$(db "SELECT id FROM tag WHERE label = 'Pod storage' AND source = 'manual';")
    [ -n "$new" ]
    [ "$(db "SELECT COUNT(*) FROM document_tag WHERE document = $d AND tag = $new AND via = 'text' AND archived_at IS NULL;")" = "1" ]

    "$BIN" entity update document "$d" content="Day 3 of #cocoa-bean-fermentation." >/dev/null
    [ "$(db "SELECT COUNT(*) FROM document_tag WHERE document = $d AND tag = $new AND archived_at IS NULL;")" = "0" ]
    [ "$(db "SELECT COUNT(*) FROM document_tag WHERE document = $d AND tag = $t AND archived_at IS NULL;")" = "1" ]
}

@test "a #tag in the text wins over a person's removal elsewhere" {
    d=$(new_document "Fermentation trial")
    t=$(new_tag "Cocoa bean fermentation")
    "$BIN" entity create document_tag document="$d" tag="$t" decision=excluded >/dev/null

    "$BIN" entity update document "$d" content="Back to #cocoa-bean-fermentation after all." >/dev/null
    [ "$(db "SELECT decision || ':' || via FROM document_tag WHERE document = $d AND tag = $t AND archived_at IS NULL;")" = "pinned:text" ]
}

@test "a #tag renders as a chip linking to its tag, never as a document link" {
    "$BIN" user add alice secret123 i
    raw=$(printf 'login=alice&password=secret123' | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN")
    SESSION=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')

    t=$(new_tag "Cocoa bean fermentation")
    "$BIN" entity create document title="Fermentation trial" content='Day 3 of #cocoa-bean-fermentation; `#not-a-tag` in code.' >/dev/null
    d=$(db "SELECT id FROM document WHERE title = 'Fermentation trial';")

    run env GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/document" QUERY_STRING="entity_id=$d" \
        HTTP_COOKIE="session=${SESSION}" "$BIN"
    [[ "$output" =~ "class=\"platform-tag-chip\" href=\"detail?type=tag&amp;entity_id=${t}\">#cocoa-bean-fermentation</a>" ]]
    [[ "$output" =~ "<code>#not-a-tag</code>" ]]
    [ "$(db "SELECT COUNT(*) FROM document_link WHERE from_document_id = $d;")" = "0" ]
}

@test "#tags a program wrote (an import, a sync) aren't synced, and a person's edit asserts only the #tags it adds" {
    key=$("$BIN" api-key create sharepoint-sync i | tail -1)
    run api_write POST "/api/v1/document" "$key" '{"title":"Imported sheet","content":"Totals #pending-review"}'
    [[ "$output" =~ '"success":true' ]]
    d=$(db "SELECT id FROM document WHERE title = 'Imported sheet';")
    [ "$(db "SELECT COUNT(*) FROM document_tag WHERE document = $d;")" = "0" ]
    [ "$(db "SELECT COUNT(*) FROM tag;")" = "0" ]

    # A person's edit asserts only the #tags it adds: the import's
    # #pending-review was already there, #checked is theirs.
    "$BIN" entity update document "$d" content="Totals #pending-review, #checked" >/dev/null
    [ "$(db "SELECT t.label FROM document_tag dt JOIN tag t ON t.id = dt.tag WHERE dt.document = $d AND dt.via = 'text' AND dt.archived_at IS NULL;")" = "Checked" ]
}
