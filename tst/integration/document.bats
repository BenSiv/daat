#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    "$BIN" user add alice secret123 i

    raw=$(printf 'login=alice&password=secret123' | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN")
    SESSION=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    CSRF=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')
    COOKIE="session=${SESSION}; csrf=${CSRF}"
}

teardown() {
    cleanup_test_env
}

save_document() {
    local body="$1"
    printf '%s' "$body" | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/document-save" QUERY_STRING="" \
        HTTP_COOKIE="$COOKIE" "$BIN"
}

get_route() {
    local path_info="$1"
    local query_string="$2"
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="$path_info" QUERY_STRING="$query_string" \
        HTTP_COOKIE="$COOKIE" "$BIN"
}

# Piping straight into `run "$BIN"` doesn't carry stdin through bats'
# `run` correctly (same issue auth.bats' raw_admin_action works around)
# -- runs the binary directly, letting the caller wrap the *function
# call* in `run` instead.
raw_document_preview() {
    local body="$1"
    local csrf_header="$2"
    printf '%s' "$body" | GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/document-preview" \
        QUERY_STRING="" HTTP_COOKIE="$COOKIE" HTTP_X_CSRF_TOKEN="$csrf_header" "$BIN"
}

@test "document-save creates a root page and redirects to it" {
    run save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=Welcome."
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Location: document?entity_id=1" ]]

    run "$BIN" entity show document 1
    [[ "$output" =~ "Home" ]]
}

@test "document-save without the matching CSRF token is rejected" {
    run save_document "csrf_token=wrong&title=Home&parent_id=&content=x"
    [[ "$output" =~ "403 Forbidden" ]]

    run "$BIN" entity list document
    [[ "$output" == "" ]]
}

@test "documents nest under a parent, and /documents renders the tree in order" {
    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=" >/dev/null
    save_document "csrf_token=${CSRF}&title=Guides&parent_id=1&content=" >/dev/null
    save_document "csrf_token=${CSRF}&title=Setup&parent_id=2&content=" >/dev/null

    run get_route "/documents" ""
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ 'href="document?entity_id=1">Home' ]]
    # Setup's <li> must be nested inside Guides' <details>, which is
    # nested inside Home's -- not just present anywhere on the page.
    # Collapsible <details>/<summary> nodes now, not a flat always-
    # expanded <ul><li> -- see html.lua's render_document_tree_level.
    [[ "$output" =~ 'Home</a></summary><ul><li><details><summary><a href="document?entity_id=2">Guides</a></summary><ul><li class="fossci-tree-leaf"><a href="document?entity_id=3">Setup' ]]
}

@test "/document shows breadcrumbs from root to self" {
    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=" >/dev/null
    save_document "csrf_token=${CSRF}&title=Guides&parent_id=1&content=" >/dev/null
    save_document "csrf_token=${CSRF}&title=Setup&parent_id=2&content=" >/dev/null

    run get_route "/document" "entity_id=3"
    [[ "$output" =~ 'href="document?entity_id=1">Home</a> / <a href="document?entity_id=2">Guides</a> / Setup' ]]
}

@test "/document embeds PLATFORM_PAGE_CONTEXT with entity_type/entity_id/title for the chat widget" {
    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=" >/dev/null

    run get_route "/document" "entity_id=1"
    # dkjson's key order isn't guaranteed -- assert each field individually.
    [[ "$output" =~ 'window.PLATFORM_PAGE_CONTEXT = {' ]]
    [[ "$output" =~ '"title":"Home"' ]]
    [[ "$output" =~ '"entity_type":"document"' ]]
    [[ "$output" =~ '"entity_id":1' ]]
    [[ "$output" =~ '"page_type":"document"' ]]
    [[ "$output" =~ '"current_user":"alice"' ]]
}

@test "a page with no entity-specific context still gets a baseline PLATFORM_PAGE_CONTEXT" {
    run get_route "/data" ""
    [[ "$output" =~ 'window.PLATFORM_PAGE_CONTEXT = {' ]]
    [[ "$output" =~ '"title":"Data"' ]]
    [[ "$output" =~ '"page_type":"data"' ]]
    [[ "$output" =~ '"current_user":"alice"' ]]
}

@test "a [[title]] link resolves to a real page and renders as a link; an unknown one renders as a dangling marker" {
    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=" >/dev/null
    save_document "csrf_token=${CSRF}&title=Guides&parent_id=1&content=Back+to+%5B%5BHome%5D%5D+and+%5B%5BNowhere%5D%5D." >/dev/null

    run get_route "/document" "entity_id=2"
    [[ "$output" =~ 'Back to <a href="document?entity_id=1">Home</a>' ]]
    [[ "$output" =~ '<em>Nowhere</em> <em>(not created yet)</em>' ]]
}

@test "a resolved link creates a backlink shown on the target page" {
    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=" >/dev/null
    save_document "csrf_token=${CSRF}&title=Guides&parent_id=&content=Back+to+%5B%5BHome%5D%5D." >/dev/null

    run get_route "/document" "entity_id=1"
    [[ "$output" =~ "Linked from" ]]
    [[ "$output" =~ 'href="document?entity_id=2">Guides' ]]
}

setup_lookup_view_fixture() {
    mkdir -p schemas views
    cat > schemas/reagent.lua <<'EOF'
return {
  name = "reagent",
  fields = { {name = "lot_number", type = "text", required = true} },
}
EOF
    "$BIN" schema add schemas/reagent.lua >/dev/null
    "$BIN" entity create reagent lot_number=LOT-1 >/dev/null
    "$BIN" entity create reagent lot_number=LOT-2 >/dev/null

    cat > views/by_id.lua <<'EOF'
return {
    name = "by_id",
    sql = "SELECT lot_number FROM reagent WHERE id = ?",
    columns = {{name = "lot_number", label = "Lot"}},
    param = {name = "entity_id", type = "integer"},
}
EOF
}

@test "a document embedding an approved view renders a real inline table (task: inline lookup tables)" {
    setup_lookup_view_fixture
    "$BIN" view approve by_id

    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=Reagents%3A+%7B%7Bview%3Aby_id%3A1%7D%7D" >/dev/null

    # entity_id is a single sequence shared across every entity type, not
    # per-table -- the fixture's 2 reagents take ids 1/2, so this document
    # (the 3rd entity created overall) lands at id 3, not 1.
    run get_route "/document" "entity_id=3"
    [[ "$output" =~ "LOT-1" ]]
    [[ ! "$output" =~ "LOT-2" ]]
    [[ "$output" =~ "fossci-view-table" ]]
    [[ ! "$output" =~ "{{view:" ]]
}

@test "a document embedding an unapproved view renders nothing -- silent, not an error or a name-leaking message" {
    setup_lookup_view_fixture
    # Deliberately not approved.

    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=Reagents%3A+%7B%7Bview%3Aby_id%3A1%7D%7D" >/dev/null

    run get_route "/document" "entity_id=3"
    [[ ! "$output" =~ "LOT-1" ]]
    [[ ! "$output" =~ "by_id" ]]
    [[ ! "$output" =~ "not approved" ]]
    [[ ! "$output" =~ "Internal Server Error" ]]
}

@test "a malformed embed marker (non-numeric param) passes through completely literal, unexpanded" {
    setup_lookup_view_fixture
    "$BIN" view approve by_id

    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=Reagents%3A+%7B%7Bview%3Aby_id%3Aabc%7D%7D" >/dev/null

    run get_route "/document" "entity_id=3"
    [[ "$output" =~ "{{view:by_id:abc}}" ]]
    [[ ! "$output" =~ "LOT-1" ]]
}

@test "/api/document-preview also expands an embedded view (both of document.render_html's call sites are covered)" {
    setup_lookup_view_fixture
    "$BIN" view approve by_id

    run raw_document_preview '{"content":"Reagents: {{view:by_id:1}}"}' "$CSRF"
    [[ "$output" =~ "LOT-1" ]]
    [[ ! "$output" =~ "LOT-2" ]]
    [[ ! "$output" =~ "{{view:" ]]
}

@test "editing a document updates it in place instead of creating a duplicate" {
    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=Original." >/dev/null

    run save_document "csrf_token=${CSRF}&entity_id=1&title=Home+Base&parent_id=&content=Renamed."
    [[ "$output" =~ "Location: document?entity_id=1" ]]

    run "$BIN" entity list document
    [[ "$output" =~ "#1" ]]
    [[ ! "$output" =~ "#2" ]]

    run "$BIN" ledger history 1
    [[ "$output" =~ "create" ]]
    [[ "$output" =~ "update" ]]
    [[ "$output" =~ "Home Base" ]]
}

@test "moving a page underneath its own descendant is rejected with a clear error, not silently applied" {
    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=" >/dev/null
    save_document "csrf_token=${CSRF}&title=Guides&parent_id=1&content=" >/dev/null

    run save_document "csrf_token=${CSRF}&entity_id=1&title=Home&parent_id=2&content="
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Can" ]]
    [[ "$output" =~ "own sub-page" ]]

    run "$BIN" entity show document 1
    [[ ! "$output" =~ "parent_id             2" ]]
}

@test "api/document-preview renders Markdown, and requires the CSRF header" {
    body='{"content": "# Title\n\nSome **bold** text."}'

    run raw_document_preview "$body" "wrong"
    [[ "$output" =~ "403 Forbidden" ]]

    run raw_document_preview "$body" "$CSRF"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "<h1>Title</h1>" ]]
    [[ "$output" =~ "<strong>bold</strong>" ]]
}

@test "Markdown GFM tables and strikethrough render as real HTML, not raw pipe/tilde text (task #117)" {
    body='{"content": "| A | B |\n|---|---|\n| 1 | 2 |\n\n~~struck~~ text."}'

    run raw_document_preview "$body" "$CSRF"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "<table>" ]]
    [[ "$output" =~ "<th>A</th>" ]]
    [[ "$output" =~ "<td>1</td>" ]]
    [[ "$output" =~ "<del>struck</del>" ]]
    [[ ! "$output" =~ '|---|---|' ]]
}

@test "archiving a document (via the generic /api/archive route) removes it from the /documents tree" {
    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=" >/dev/null

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/archive" QUERY_STRING="type=document&entity_id=1" \
        HTTP_COOKIE="$COOKIE" HTTP_X_CSRF_TOKEN="$CSRF" run "$BIN"
    [[ "$output" =~ '"success":true' ]]

    run get_route "/documents" ""
    [[ "$output" =~ "No pages yet" ]]
}

save_document_as() {
    local provider="$1" body="$2"
    printf '%s' "$body" | AGENT_PROVIDER="$provider" \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/document-save" QUERY_STRING="" \
        HTTP_COOKIE="$COOKIE" "$BIN"
}

@test "creating and updating a page auto-computes its embedding (task #105)" {
    save_document_as "test" "csrf_token=${CSRF}&title=Home&parent_id=&content=hello" >/dev/null
    run bash -c "cd '$TEST_DIR' && sqlite3 .store/store.db 'SELECT COUNT(*) FROM document_embedding;'"
    [ "$output" = "1" ]

    # Updating recomputes it too, not just create -- still exactly one
    # row (REPLACE INTO document_embedding, keyed on document_id), not a
    # second stale one left behind.
    save_document_as "test" "csrf_token=${CSRF}&entity_id=1&title=Home&parent_id=&content=updated content" >/dev/null
    run bash -c "cd '$TEST_DIR' && sqlite3 .store/store.db 'SELECT COUNT(*) FROM document_embedding;'"
    [ "$output" = "1" ]
}

@test "an unconfigured/failing embedding provider never fails the page save itself (best-effort)" {
    # No AGENT_PROVIDER set -> defaults to vertex -> VERTEX_PROJECT is
    # unset in this test environment -> agent_provider_vertex.embeddings
    # returns nil, err gracefully (never throws) -- document.
    # create_page must still succeed and never propagate that failure.
    run save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=hello"
    [[ "$output" =~ "302 Found" ]]

    run "$BIN" entity list document
    [[ "$output" =~ "#1" ]]
    run bash -c "cd '$TEST_DIR' && sqlite3 .store/store.db 'SELECT COUNT(*) FROM document_embedding;'"
    [ "$output" = "0" ]
}

@test "document create-json bulk-creates pages with full document.create_page side effects (wikilinks, embeddings)" {
    # Deliberately NOT the generic `entity create-json` action -- that
    # skips document.create_page's own side effects entirely (a bulk
    # import task surfaced this: pages existed but were unfindable by
    # semantic search and had no backlinks, silently).
    payload='[{"title": "Source Page", "content": "hello"}, {"title": "Linking Page", "content": "See [[Source Page]] for details"}]'
    run bash -c "printf '%s' '$payload' | AGENT_PROVIDER=test '$BIN' document create-json"
    [[ "$output" =~ '"created_ids":[1,2]' ]] || [[ "$output" =~ '"created_ids":[' ]]
    [[ "$output" =~ '"failed":[]' ]]

    run "$BIN" entity list document
    [[ "$output" =~ "#1" ]]
    [[ "$output" =~ "#2" ]]

    # wikilink sync ran (document_link populated), not just a raw insert
    run bash -c "cd '$TEST_DIR' && sqlite3 .store/store.db \"SELECT from_document_id, to_document_id FROM document_link;\""
    [[ "$output" =~ "2|1" ]]

    # embedding reindex ran too (a real provider was configured)
    run bash -c "cd '$TEST_DIR' && sqlite3 .store/store.db 'SELECT COUNT(*) FROM document_embedding;'"
    [ "$output" = "2" ]
}

@test "document create-json reports per-row failures without blocking the rest of the batch" {
    # A real bulk import is heterogeneous (hundreds of files of
    # unpredictable quality) -- one bad row (missing the required
    # title field here) must not block every other row, unlike the
    # generic entity create-json/create_batch's own all-or-nothing
    # validate-everything-first gate.
    payload='[{"title": "Good Page 1", "content": "ok"}, {"content": "no title here"}, {"title": "Good Page 2", "content": "ok"}]'
    run bash -c "printf '%s' '$payload' | AGENT_PROVIDER=test '$BIN' document create-json"
    [[ "$output" =~ '"row_index":2' ]]

    run "$BIN" entity list document
    [[ "$output" =~ "#1" ]]
    [[ "$output" =~ "#2" ]]
    # only the two good rows actually got created (not 3)
    [ "$(echo "$output" | wc -l)" -eq 2 ]
}

@test "document reindex-embeddings CLI still exists, for bulk backfill after a save-time provider failure" {
    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=hello" >/dev/null
    # The save above ran with no configured provider, so it never got
    # an embedding (see the previous test) -- reindex-embeddings is how
    # a store backfills those after the fact, or after a provider
    # outage silently dropped some best-effort saves.
    run bash -c "cd '$TEST_DIR' && sqlite3 .store/store.db 'SELECT COUNT(*) FROM document_embedding;'"
    [ "$output" = "0" ]

    AGENT_PROVIDER=test run "$BIN" document reindex-embeddings
    [[ "$output" =~ "Reindexed 1 page(s), 0 failed" ]]

    run bash -c "cd '$TEST_DIR' && sqlite3 .store/store.db 'SELECT COUNT(*) FROM document_embedding;'"
    [ "$output" = "1" ]
}
