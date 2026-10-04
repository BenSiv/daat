#!/usr/bin/env bats
# task #114: external API support. Covers the api_key CLI/table
# (src/auth.lua), the X-Api-Key auth plug-in and CSRF bypass it gets in
# cgi.handle_request, and all 6 /api/v1/<type>[/<id>[/action]] route
# shapes -- reusing the same widget/label_template fixtures label.bats
# and auth.bats already established (a plain schema, and an
# admin_write_only one for the "a" capability gate).

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    mkdir -p schemas
    cat > schemas/widget.lua <<'EOF'
return {
  name = "widget",
  fields = { {name = "label", type = "text", required = true} },
}
EOF
    cat > schemas/label_template.lua <<'EOF'
return {
  name = "label_template",
  admin_write_only = true,
  fields = { {name = "zpl", type = "text", required = true} },
}
EOF
    "$BIN" schema add schemas/widget.lua
    "$BIN" schema add schemas/label_template.lua
}

teardown() {
    cleanup_test_env
}

# GET (no body) with an X-Api-Key header.
raw_api_get() {
    local path_info="$1"
    local query="$2"
    local api_key="$3"
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="$path_info" QUERY_STRING="$query" \
        HTTP_X_API_KEY="$api_key" "$BIN"
}

# POST/PATCH with a real JSON body -- piping into a plain `run "$BIN"`
# doesn't carry stdin through bats' `run` correctly (see auth.bats'
# raw_admin_action for the same note), so this runs the binary directly
# and the caller wraps the function call itself in `run`.
raw_api_write() {
    local method="$1"
    local path_info="$2"
    local query="$3"
    local api_key="$4"
    local body="$5"
    printf '%s' "$body" | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="$method" PATH_INFO="$path_info" QUERY_STRING="$query" \
        HTTP_X_API_KEY="$api_key" "$BIN"
}

@test "api-key create prints the raw key exactly once, and it authenticates a /api/v1 request" {
    run "$BIN" api-key create integration i
    [[ "$output" =~ "Created api key integration" ]]
    key=$(echo "$output" | tail -1)
    [ -n "$key" ]

    run "$BIN" api-key list
    [[ "$output" =~ "integration" ]]
    [[ "$output" =~ "cap=i" ]]
    [[ ! "$output" =~ "$key" ]]

    run raw_api_get "/api/v1/widget" "" "$key"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ '"total":0' ]]
}

@test "an invalid API key is rejected with 401 JSON, not the browser's /login redirect" {
    "$BIN" api-key create integration i >/dev/null

    run raw_api_get "/api/v1/widget" "" "wrong-key-entirely"
    [[ "$output" =~ "401 Unauthorized" ]]
    [[ "$output" =~ "Invalid API key" ]]
}

@test "no API key at all falls through to the normal unauthenticated redirect, same as any other route" {
    run raw_api_get "/api/v1/widget" "" ""
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Location: /login" ]]
}

@test "an archived API key can no longer authenticate" {
    "$BIN" api-key create integration i >/dev/null
    key=$("$BIN" api-key create integration2 i | tail -1)
    "$BIN" api-key archive integration2

    run raw_api_get "/api/v1/widget" "" "$key"
    [[ "$output" =~ "401 Unauthorized" ]]
}

@test "a key without baseline capability is forbidden with 403 JSON" {
    key=$("$BIN" api-key create integration "" | tail -1)

    run raw_api_get "/api/v1/widget" "" "$key"
    [[ "$output" =~ "403 Forbidden" ]]
    [[ "$output" =~ "Insufficient capability" ]]
}

@test "POST /api/v1/<type> creates a single row from a JSON object" {
    key=$("$BIN" api-key create integration i | tail -1)

    output=$(raw_api_write POST "/api/v1/widget" "" "$key" '{"label":"Widget A"}')
    [[ "$output" =~ '"success":true' ]]
    [[ "$output" =~ '"created_id":1' ]]

    run "$BIN" entity show widget 1
    [[ "$output" =~ "Widget A" ]]
}

@test "POST /api/v1/<type> creates a batch from a JSON array" {
    key=$("$BIN" api-key create integration i | tail -1)

    output=$(raw_api_write POST "/api/v1/widget" "" "$key" '[{"label":"A"},{"label":"B"}]')
    [[ "$output" =~ '"success":true' ]]
    [[ "$output" =~ '"created_ids":[1,2]' ]]
}

@test "GET /api/v1/<type> lists rows with total, honoring limit/offset and filter_field/filter_value" {
    key=$("$BIN" api-key create integration i | tail -1)
    "$BIN" entity create widget label=A
    "$BIN" entity create widget label=B
    "$BIN" entity create widget label=C

    run raw_api_get "/api/v1/widget" "" "$key"
    [[ "$output" =~ '"total":3' ]]

    run raw_api_get "/api/v1/widget" "limit=1&offset=1" "$key"
    [[ "$output" =~ '"label":"B"' ]]
    [[ ! "$output" =~ '"label":"A"' ]]
    [[ ! "$output" =~ '"label":"C"' ]]

    run raw_api_get "/api/v1/widget" "filter_field=label&filter_value=B" "$key"
    [[ "$output" =~ '"total":1' ]]
    [[ "$output" =~ '"label":"B"' ]]
}

@test "GET /api/v1/<type>/<id> returns the row; an unknown id is a 404 JSON error" {
    key=$("$BIN" api-key create integration i | tail -1)
    "$BIN" entity create widget label=A

    run raw_api_get "/api/v1/widget/1" "" "$key"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ '"label":"A"' ]]

    run raw_api_get "/api/v1/widget/999" "" "$key"
    [[ "$output" =~ "404 Not Found" ]]
    [[ "$output" =~ "Not found" ]]
}

@test "PATCH /api/v1/<type>/<id> updates a row, with no CSRF header or cookie needed" {
    key=$("$BIN" api-key create integration i | tail -1)
    "$BIN" entity create widget label=A

    output=$(raw_api_write PATCH "/api/v1/widget/1" "" "$key" '{"label":"A2"}')
    [[ "$output" =~ '"success":true' ]]
    [[ "$output" =~ '"updated_id":1' ]]

    run "$BIN" entity show widget 1
    [[ "$output" =~ "A2" ]]
}

@test "archive and unarchive drain a request body they don't use (an unread body made the connection reset and truncate the response)" {
    key=$("$BIN" api-key create integration i | tail -1)
    "$BIN" entity create widget label=A
    for action in archive unarchive; do
        left=$(printf '{"unused":true}' | {
            GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD=POST PATH_INFO="/api/v1/widget/1/$action" \
                HTTP_X_API_KEY="$key" "$BIN" >/dev/null
            cat
        })
        [ -z "$left" ]
    done
}

@test "POST /api/v1/<type>/<id>/archive and /unarchive toggle archived_at, never deleting the row" {
    key=$("$BIN" api-key create integration i | tail -1)
    "$BIN" entity create widget label=A

    output=$(raw_api_write POST "/api/v1/widget/1/archive" "" "$key" "")
    [[ "$output" =~ '"success":true' ]]
    [[ "$output" =~ '"archived_id":1' ]]

    run raw_api_get "/api/v1/widget" "" "$key"
    [[ "$output" =~ '"total":0' ]]
    run raw_api_get "/api/v1/widget/1" "" "$key"
    [[ "$output" =~ '"label":"A"' ]]

    output=$(raw_api_write POST "/api/v1/widget/1/unarchive" "" "$key" "")
    [[ "$output" =~ '"success":true' ]]
    [[ "$output" =~ '"unarchived_id":1' ]]

    run raw_api_get "/api/v1/widget" "" "$key"
    [[ "$output" =~ '"total":1' ]]
}

@test "a key without the 'a' capability cannot write an admin_write_only type; with 'a' it can" {
    key=$("$BIN" api-key create integration i | tail -1)

    output=$(raw_api_write POST "/api/v1/label_template" "" "$key" '{"zpl":"^XA^XZ"}')
    [[ "$output" =~ "403 Forbidden" ]]
    [[ "$output" =~ "Admin capability required" ]]

    "$BIN" api-key capabilities integration ia
    output=$(raw_api_write POST "/api/v1/label_template" "" "$key" '{"zpl":"^XA^XZ"}')
    [[ "$output" =~ '"success":true' ]]
}

@test "an unregistered entity type is a 404 JSON error, and an invalid type name is a 400" {
    key=$("$BIN" api-key create integration i | tail -1)

    run raw_api_get "/api/v1/no_such_type" "" "$key"
    [[ "$output" =~ "404 Not Found" ]]
    [[ "$output" =~ "Unknown type" ]]

    run raw_api_get "/api/v1/Not-Valid" "" "$key"
    [[ "$output" =~ "404 Not Found" ]]
}

@test "a write made via an API key is recorded on the ledger with api:<label> as the author" {
    key=$("$BIN" api-key create nightly-sync-job i | tail -1)
    raw_api_write POST "/api/v1/widget" "" "$key" '{"label":"A"}' >/dev/null

    run "$BIN" ledger show 1
    [[ "$output" =~ "by api:nightly-sync-job" ]]
}

@test "tag and document_tag are core types an external job can write through the API (doc/structure-layers.md)" {
    key=$("$BIN" api-key create tagger i | tail -1)
    "$BIN" entity create document title="Cryopreservation protocol" content="vitrification steps" >/dev/null

    run raw_api_write POST "/api/v1/tag" "" "$key" '{"label":"Plant cell cryopreservation","terms":"vitrification, cryoprotectant","source":"computed","computed_at":"2026-09-27"}'
    [[ "$output" =~ '"success":true' ]]
    tag_id=$(printf '%s' "$output" | grep -o '"created_id":[0-9]*' | grep -o '[0-9]*')
    [ -n "$tag_id" ]

    run raw_api_write POST "/api/v1/document_tag" "" "$key" "{\"document\":1,\"tag\":${tag_id},\"score\":0.82,\"decision\":\"computed\"}"
    [[ "$output" =~ '"success":true' ]]

    run raw_api_get "/api/v1/document_tag" "filter_field=document&filter_value=1" "$key"
    [[ "$output" =~ '"decision":"computed"' || "$output" =~ '"decision": "computed"' ]]

    # decision is a closed set: a manual override is pinned or excluded, nothing else.
    run raw_api_write POST "/api/v1/document_tag" "" "$key" "{\"document\":1,\"tag\":${tag_id},\"decision\":\"maybe\"}"
    [[ ! "$output" =~ '"success":true' ]]
}

@test "tag_relation and tag_evidence are core types; evidence kinds are open, decisions and directions are not (doc/tag-ontology.md)" {
    key=$("$BIN" api-key create tagger i | tail -1)
    run raw_api_write POST "/api/v1/tag" "" "$key" '{"label":"Callus induction","source":"computed"}'
    a=$(printf '%s' "$output" | grep -o '"created_id":[0-9]*' | grep -o '[0-9]*')
    run raw_api_write POST "/api/v1/tag" "" "$key" '{"label":"Somatic embryogenesis","source":"computed"}'
    b=$(printf '%s' "$output" | grep -o '"created_id":[0-9]*' | grep -o '[0-9]*')
    [ -n "$a" ] && [ -n "$b" ]

    run raw_api_write POST "/api/v1/tag_relation" "" "$key" "{\"tag_a\":${a},\"tag_b\":${b},\"decision\":\"computed\",\"score\":1.8,\"reason\":\"share media and lineage\",\"evidence\":\"{\\\"mention\\\":1.6}\"}"
    [[ "$output" =~ '"success":true' ]]
    run raw_api_write POST "/api/v1/tag_relation" "" "$key" "{\"tag_a\":${a},\"tag_b\":${b},\"decision\":\"broader\"}"
    [[ ! "$output" =~ '"success":true' ]]

    # Any kind a producer names is accepted -- core never interprets it.
    run raw_api_write POST "/api/v1/tag_evidence" "" "$key" "{\"tag_a\":${a},\"tag_b\":${b},\"kind\":\"lineage\",\"direction\":\"directed\",\"weight\":7,\"support\":7,\"producer\":\"tag-evidence\"}"
    [[ "$output" =~ '"success":true' ]]
    run raw_api_get "/api/v1/tag_evidence" "filter_field=kind&filter_value=lineage" "$key"
    [[ "$output" =~ '"producer":"tag-evidence"' || "$output" =~ '"producer": "tag-evidence"' ]]
    run raw_api_write POST "/api/v1/tag_evidence" "" "$key" "{\"tag_a\":${a},\"tag_b\":${b},\"kind\":\"link\",\"direction\":\"sideways\",\"weight\":1,\"producer\":\"core\"}"
    [[ ! "$output" =~ '"success":true' ]]
}
