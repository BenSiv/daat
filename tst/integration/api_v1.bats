#!/usr/bin/env bats
# Full /api/v1/* coverage: verifies X-Api-Key + session/CSRF parity,
# capability gates (i / s / a), and every domain surface in Daat
# (account, schemas, entities, views, sql, documents, templates,
# knowledge, chat, extensions, and admin/settings).

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    mkdir -p schemas
    cat > schemas/widget.lua <<'EOF'
return {
  name = "widget",
  fields = {
    {name = "label", type = "text", required = true, display = true},
  },
}
EOF
    cat > schemas/part.lua <<'EOF'
return {
  name = "part",
  fields = {
    {name = "code", type = "text", required = true, identifier = true},
    {name = "widget", type = "reference", required = false, entity_type = "widget"},
  },
}
EOF
    cat > schemas/label_template.lua <<'EOF'
return {
  name = "label_template",
  admin_write_only = true,
  fields = {
    {name = "for_entity_type", type = "text", required = true},
    {name = "sql", type = "sql_select", required = true},
    {name = "zpl", type = "text", required = true},
  },
}
EOF
    "$BIN" schema add schemas/widget.lua
    "$BIN" schema add schemas/part.lua
    "$BIN" schema add schemas/label_template.lua
}

teardown() {
    cleanup_test_env
}

raw_api_get() {
    local path_info="$1"
    local query="$2"
    local api_key="$3"
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="$path_info" QUERY_STRING="$query" \
        HTTP_X_API_KEY="$api_key" "$BIN"
}

raw_api_write() {
    local method="$1"
    local path_info="$2"
    local query="$3"
    local api_key="$4"
    local body="$5"
    local extra_resp="${6:-}"
    printf '%s' "$body" | AGENT_TEST_RESPONSES="$extra_resp" \
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

    run raw_api_get "/api/v1/entities/widget" "" "$key"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ '"total":0' ]]
}

@test "an invalid API key is rejected with 401 JSON, not the browser's /login redirect" {
    "$BIN" api-key create integration i >/dev/null

    run raw_api_get "/api/v1/entities/widget" "" "wrong-key-entirely"
    [[ "$output" =~ "401 Unauthorized" ]]
    [[ "$output" =~ "Invalid API key" ]]
}

@test "no API key at all falls through to the normal unauthenticated redirect, same as any other route" {
    run raw_api_get "/api/v1/entities/widget" "" ""
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Location: /login" ]]
}

@test "an archived API key can no longer authenticate" {
    "$BIN" api-key create integration i >/dev/null
    key=$("$BIN" api-key create integration2 i | tail -1)
    "$BIN" api-key archive integration2

    run raw_api_get "/api/v1/entities/widget" "" "$key"
    [[ "$output" =~ "401 Unauthorized" ]]
}

@test "a key without baseline capability is forbidden with 403 JSON" {
    key=$("$BIN" api-key create integration "" | tail -1)

    run raw_api_get "/api/v1/entities/widget" "" "$key"
    [[ "$output" =~ "403 Forbidden" ]]
    [[ "$output" =~ "Insufficient capability" ]]
}

@test "an unknown /api/v1 endpoint returns a structured 404 JSON error" {
    key=$("$BIN" api-key create integration i | tail -1)
    run raw_api_get "/api/v1/does-not-exist" "" "$key"
    [[ "$output" =~ "404 Not Found" ]]
    [[ "$output" =~ "Unknown API endpoint" ]]
}

@test "POST /api/v1/entities/<type> creates single and batch rows" {
    key=$("$BIN" api-key create integration i | tail -1)

    output=$(raw_api_write POST "/api/v1/entities/widget" "" "$key" '{"label":"Widget A"}')
    [[ "$output" =~ '"success":true' ]]
    [[ "$output" =~ '"created_id":1' ]]

    output=$(raw_api_write POST "/api/v1/entities/widget" "" "$key" '[{"label":"B"},{"label":"C"}]')
    [[ "$output" =~ '"success":true' ]]
    [[ "$output" =~ '"created_ids":[2,3]' ]]
}

@test "GET /api/v1/entities/<type> lists rows with total, honoring limit/offset and filter_field/filter_value" {
    key=$("$BIN" api-key create integration i | tail -1)
    "$BIN" entity create widget label=A
    "$BIN" entity create widget label=B
    "$BIN" entity create widget label=C

    run raw_api_get "/api/v1/entities/widget" "" "$key"
    [[ "$output" =~ '"total":3' ]]

    run raw_api_get "/api/v1/entities/widget" "limit=1&offset=1" "$key"
    [[ "$output" =~ '"label":"B"' ]]
    [[ ! "$output" =~ '"label":"A"' ]]
    [[ ! "$output" =~ '"label":"C"' ]]

    run raw_api_get "/api/v1/entities/widget" "filter_field=label&filter_value=B" "$key"
    [[ "$output" =~ '"total":1' ]]
    [[ "$output" =~ '"label":"B"' ]]
}

@test "GET and PATCH /api/v1/entities/<type>/<id> fetch and update rows" {
    key=$("$BIN" api-key create integration i | tail -1)
    "$BIN" entity create widget label=A

    run raw_api_get "/api/v1/entities/widget/1" "" "$key"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ '"label":"A"' ]]

    run raw_api_get "/api/v1/entities/widget/999" "" "$key"
    [[ "$output" =~ "404 Not Found" ]]
    [[ "$output" =~ "Not found" ]]

    output=$(raw_api_write PATCH "/api/v1/entities/widget/1" "reason=rename" "$key" '{"label":"A2"}')
    [[ "$output" =~ '"success":true' ]]
    [[ "$output" =~ '"updated_id":1' ]]

    run "$BIN" entity show widget 1
    [[ "$output" =~ "A2" ]]
}

@test "archive and unarchive drain unread request bodies, toggle archived_at, and record unarchive reason" {
    key=$("$BIN" api-key create integration i | tail -1)
    "$BIN" entity create widget label=A
    for action in archive unarchive; do
        left=$(printf '{"unused":true}' | {
            GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD=POST PATH_INFO="/api/v1/entities/widget/1/$action" \
                HTTP_X_API_KEY="$key" "$BIN" >/dev/null
            cat
        })
        [ -z "$left" ]
    done

    output=$(raw_api_write POST "/api/v1/entities/widget/1/archive" "reason=obsolete" "$key" "")
    [[ "$output" =~ '"success":true' ]]
    [[ "$output" =~ '"archived_id":1' ]]

    run raw_api_get "/api/v1/entities/widget" "" "$key"
    [[ "$output" =~ '"total":0' ]]

    output=$(raw_api_write POST "/api/v1/entities/widget/1/unarchive" "reason=restored-for-rerun" "$key" "")
    [[ "$output" =~ '"success":true' ]]
    [[ "$output" =~ '"unarchived_id":1' ]]

    hist=$(json_body "$(raw_api_get "/api/v1/entities/widget/1/history" "" "$key")")
    reasons=$(echo "$hist" | jq -r '[.events[].reason | select(. != null)] | join(",")')
    [[ "$reasons" =~ "obsolete" ]]
    [[ "$reasons" =~ "restored-for-rerun" ]]
}

@test "PATCH /api/v1/entities/document/<id> rejects parent_id cycles just like /document-save" {
    key=$("$BIN" api-key create integration i | tail -1)
    raw_api_write POST "/api/v1/entities/document" "" "$key" '{"title":"Root Doc","content":"top"}' >/dev/null
    raw_api_write POST "/api/v1/entities/document" "" "$key" '{"title":"Child Doc","parent_id":1,"content":"sub"}' >/dev/null

    resp=$(raw_api_write PATCH "/api/v1/entities/document/1" "" "$key" '{"parent_id":2}')
    [[ "$resp" =~ '"success":false' ]]
    [[ "$resp" =~ "own sub-document" ]]
}

@test "a key without the 'a' capability cannot write an admin_write_only type; with 'a' it can" {
    key=$("$BIN" api-key create integration i | tail -1)
    payload='{"for_entity_type":"widget","sql":"SELECT label FROM widget WHERE id = ?","zpl":"^XA^FD{{label}}^FS^XZ"}'

    output=$(raw_api_write POST "/api/v1/entities/label_template" "" "$key" "$payload")
    [[ "$output" =~ "403 Forbidden" ]]
    [[ "$output" =~ "Admin capability required" ]]

    "$BIN" api-key capabilities integration ia
    output=$(raw_api_write POST "/api/v1/entities/label_template" "" "$key" "$payload")
    [[ "$output" =~ '"success":true' ]]
}

@test "an unregistered entity type is a 404 JSON error, and an invalid type name is a 400 JSON error" {
    key=$("$BIN" api-key create integration i | tail -1)

    run raw_api_get "/api/v1/entities/no_such_type" "" "$key"
    [[ "$output" =~ "404 Not Found" ]]
    [[ "$output" =~ "Unknown type" ]]

    run raw_api_get "/api/v1/entities/Not-Valid" "" "$key"
    [[ "$output" =~ "400 Bad Request" ]]
    [[ "$output" =~ "Invalid type" ]]
}

@test "a write made via an API key is recorded on the ledger with api:<label> as the author" {
    key=$("$BIN" api-key create nightly-sync-job i | tail -1)
    raw_api_write POST "/api/v1/entities/widget" "" "$key" '{"label":"A"}' >/dev/null

    run "$BIN" ledger show 1
    [[ "$output" =~ "by api:nightly-sync-job" ]]
}

@test "schemas, entity search, dry-run validate, autocomplete, history, related, preview, and label work via /api/v1" {
    key=$("$BIN" api-key create integration ia | tail -1)
    raw_api_write POST "/api/v1/entities/widget" "" "$key" '{"label":"Reactor Alpha"}' >/dev/null
    raw_api_write POST "/api/v1/entities/part" "" "$key" '{"code":"PRT-01","widget":1}' >/dev/null
    raw_api_write POST "/api/v1/entities/label_template" "" "$key" \
        '{"for_entity_type":"widget","sql":"SELECT label FROM widget WHERE id = ?","zpl":"^XA^FD{{label}}^FS^XZ"}' >/dev/null

    schemas_json=$(json_body "$(raw_api_get "/api/v1/schemas" "" "$key")")
    [ "$(echo "$schemas_json" | jq -r '.schemas | map(select(.name=="widget"))[0].count')" = "1" ]
    [ "$(echo "$schemas_json" | jq -r '.relationships | map(select(.from_type=="part" and .to_type=="widget")) | length')" = "1" ]

    schema_detail=$(json_body "$(raw_api_get "/api/v1/schemas/widget" "" "$key")")
    [ "$(echo "$schema_detail" | jq -r '.has_label_template')" = "true" ]
    [ "$(echo "$schema_detail" | jq -r '.layout.fields[0].name')" = "label" ]

    search_raw=$(raw_api_get "/api/v1/entities" "query=Reactor" "$key")
    [[ "$search_raw" =~ '"label":"Reactor Alpha"' ]]

    val_bad=$(json_body "$(raw_api_write POST "/api/v1/entities/widget/validate" "" "$key" '[{"label":""}]')")
    [ "$(echo "$val_bad" | jq -r '.valid')" = "false" ]
    val_ok=$(json_body "$(raw_api_write POST "/api/v1/entities/widget/validate" "" "$key" '[{"label":"Valid"}]')")
    [ "$(echo "$val_ok" | jq -r '.valid')" = "true" ]

    auto_raw=$(raw_api_get "/api/v1/entities/part/autocomplete" "query=PRT" "$key")
    [[ "$auto_raw" =~ '"name":"PRT-01"' ]]

    related_json=$(json_body "$(raw_api_get "/api/v1/entities/widget/1/related" "" "$key")")
    [ "$(echo "$related_json" | jq -r '.related[0].from_type')" = "part" ]
    [ "$(echo "$related_json" | jq -r '.related[0].total')" = "1" ]

    preview_json=$(json_body "$(raw_api_get "/api/v1/entities/part/2/preview" "" "$key")")
    [[ "$(echo "$preview_json" | jq -r '.html')" =~ "Reactor Alpha" ]]

    label_json=$(json_body "$(raw_api_get "/api/v1/entities/widget/1/label" "" "$key")")
    [[ "$(echo "$label_json" | jq -r '.zpl')" =~ "Reactor Alpha" ]]
}

@test "/api/v1/views and /api/v1/sql enforce view approval and Setup/Admin SQL capability" {
    mkdir -p views
    cat > views/parts_for_widget.lua <<'EOF'
return {
  name = "parts_for_widget",
  label = "Parts for widget",
  description = "Parts linked to a widget",
  param = {name = "widget_id", type = "number", label = "Widget"},
  columns = {{name = "code", label = "Code"}},
  sql = "SELECT code FROM part WHERE widget = ?",
}
EOF
    key_basic=$("$BIN" api-key create basic-key i | tail -1)
    key_setup=$("$BIN" api-key create sql-key is | tail -1)
    "$BIN" entity create widget label="W1" >/dev/null
    "$BIN" entity create part code="P-100" widget=1 >/dev/null

    views_list=$(json_body "$(raw_api_get "/api/v1/views" "" "$key_basic")")
    [ "$(echo "$views_list" | jq -r '.views[0].name')" = "parts_for_widget" ]
    [ "$(echo "$views_list" | jq -r '.views[0].approved')" = "false" ]

    run raw_api_get "/api/v1/views/parts_for_widget" "widget_id=1" "$key_basic"
    [[ "$output" =~ "403 Forbidden" ]]

    "$BIN" view approve parts_for_widget
    view_res=$(json_body "$(raw_api_get "/api/v1/views/parts_for_widget" "widget_id=1" "$key_basic")")
    [ "$(echo "$view_res" | jq -r '.rows[0].code')" = "P-100" ]

    run raw_api_get "/api/v1/sql" "q=SELECT+code+FROM+part" "$key_basic"
    [[ "$output" =~ "403 Forbidden" ]]

    sql_res=$(json_body "$(raw_api_write POST "/api/v1/sql" "" "$key_setup" '{"q":"SELECT code FROM part"}')")
    [ "$(echo "$sql_res" | jq -r '.rows[0].code')" = "P-100" ]

    sql_bad=$(raw_api_write POST "/api/v1/sql" "" "$key_setup" '{"q":"DELETE FROM part"}')
    [[ "$sql_bad" =~ "400 Bad Request" ]]
}

@test "/api/v1/documents, /api/v1/templates, and /api/v1/knowledge cover all document & pool surfaces" {
    mkdir -p templates
    cat > templates/run_note.lua <<'EOF'
return {
  name = "run_note",
  label = "Run Note",
  description = "Standard run template",
  default_path = "Runs/New Run",
  sections = {
    {type = "heading", text = "Goal"},
    {type = "text", text = "Document the run."},
  },
}
EOF
    key=$("$BIN" api-key create knowledge-key i | tail -1)
    raw_api_write POST "/api/v1/entities/document" "" "$key" '{"title":"Media Prep","content":"Autoclave at 121C."}' >/dev/null
    raw_api_write POST "/api/v1/entities/document" "" "$key" '{"title":"Subculture SOP","parent_id":1,"content":"Use [[Media Prep]] first."}' >/dev/null

    tree_json=$(json_body "$(raw_api_get "/api/v1/documents/tree" "" "$key")")
    [ "$(echo "$tree_json" | jq '.documents | length')" = "2" ]

    search_json=$(json_body "$(raw_api_get "/api/v1/documents/search" "q=Autoclave" "$key")")
    [ "$(echo "$search_json" | jq -r '.results[0].title')" = "Media Prep" ]

    doc_view=$(json_body "$(raw_api_get "/api/v1/documents/2" "" "$key")")
    [ "$(echo "$doc_view" | jq -r '.document.title')" = "Subculture SOP" ]
    [ "$(echo "$doc_view" | jq '.breadcrumbs | length')" = "2" ]
    [ "$(echo "$doc_view" | jq '.links | length')" -ge 1 ]

    draft_json=$(json_body "$(raw_api_get "/api/v1/documents/connection-draft" "connect_a=1&connect_b=2" "$key")")
    [[ "$(echo "$draft_json" | jq -r '.draft.title')" =~ "Media Prep" ]]

    tpl_list=$(json_body "$(raw_api_get "/api/v1/templates" "" "$key")")
    [ "$(echo "$tpl_list" | jq -r '.templates[0].name')" = "run_note" ]
    tpl_one=$(json_body "$(raw_api_get "/api/v1/templates/run_note" "" "$key")")
    [ "$(echo "$tpl_one" | jq -r '.default_path')" = "Runs/New Run" ]
    [[ "$(echo "$tpl_one" | jq -r '.content')" =~ "## Goal" ]]

    stats_json=$(json_body "$(raw_api_get "/api/v1/knowledge/stats" "" "$key")")
    [ "$(echo "$stats_json" | jq '.note_count')" -ge 1 ]
    [ "$(echo "$stats_json" | jq '.tier_counts["0"]')" -ge 1 ]

    kdocs_json=$(json_body "$(raw_api_get "/api/v1/knowledge/documents" "tier=0" "$key")")
    [ "$(echo "$kdocs_json" | jq '.documents | length')" -ge 1 ]

    rets_json=$(json_body "$(raw_api_get "/api/v1/knowledge/retrievals" "limit=5" "$key")")
    [ "$(echo "$rets_json" | jq '.retrievals | length')" -ge 1 ]
}

@test "/api/v1/chat supports session listing, messaging, tool approval/denial, and feedback via X-Api-Key" {
    key=$("$BIN" api-key create agent-bot i | tail -1)

    created=$(json_body "$(raw_api_write POST "/api/v1/chat/sessions" "" "$key" '{"title":"API Session"}')")
    sid=$(echo "$created" | jq -r '.session_id')
    [ -n "$sid" ] && [ "$sid" != "null" ]

    sessions=$(json_body "$(raw_api_get "/api/v1/chat/sessions" "" "$key")")
    [ "$(echo "$sessions" | jq -r '.sessions[0].id')" = "$sid" ]

    propose=$(tool_call_response "document.create" '{"title":"Bot Note","content":"Written via API chat"}')
    turn1=$(json_body "$(raw_api_write POST "/api/v1/chat/sessions/${sid}/messages" "" "$key" '{"message":"make a note"}' "$propose")")
    pid=$(echo "$turn1" | jq -r '.pending.id')
    [ "$pid" != "null" ]

    turn2=$(json_body "$(raw_api_write POST "/api/v1/chat/sessions/${sid}/approve" "" "$key" "{\"pending_id\":${pid}}" "$(done_response "Created **Bot Note**.")")")
    [ "$(echo "$turn2" | jq -r '.pending')" = "null" ]
    [ "$(echo "$turn2" | jq -r '.messages[-1].content')" = "Created **Bot Note**." ]
    [[ "$(echo "$turn2" | jq -r '.messages[-1].content_html')" =~ "<strong>Bot Note</strong>" ]]
    mid=$(echo "$turn2" | jq -r '.messages[-1].id')

    fb=$(json_body "$(raw_api_write POST "/api/v1/chat/messages/${mid}/feedback" "" "$key" '{"feedback":"up"}')")
    [ "$(echo "$fb" | jq -r '.ok')" = "true" ]
}

@test "/api/v1/extensions, /api/v1/admin/*, and /api/v1/account cover extensions, approvals, users, keys, and settings" {
    mkdir -p extensions/demo-ext views
    cat > views/v_demo.lua <<'EOF'
return {
  name = "v_demo",
  label = "Demo View",
  columns = {{name = "label", label = "Label"}},
  sql = "SELECT label FROM widget",
}
EOF
    cat > extensions/demo-ext/manifest.lua <<'EOF'
return {
  name = "demo-ext",
  events = {},
  entity_types = {},
  capabilities = {
    read = {"entity"},
    write = {"entity"},
    ui = {label = "Demo Ext", icon = "puzzle"},
    manual_triggers = {{name = "seed", label = "Seed widget", description = "Seed a demo widget"}},
  },
}
EOF
    cat > extensions/demo-ext/main.lua <<'EOF'
return {
  render = function(ctx, params)
    return {elements = {{type = "heading", text = "Hello Ext"}}}
  end,
  actions = {
    ping = function(ctx, args)
      return {elements = {{type = "text", text = "Pong: " .. tostring(args.msg)}}}
    end,
  },
  manual_triggers = {
    seed = function(ctx, meta)
      ctx.create_entity("widget", {label = "Seeded by " .. tostring(meta.triggered_by)})
      return {message = "Seeded OK"}
    end,
  },
}
EOF

    key_basic=$("$BIN" api-key create basic i | tail -1)
    key_admin=$("$BIN" api-key create ops-admin ia | tail -1)

    # /api/v1/account introspection & session password change
    acct_key=$(json_body "$(raw_api_get "/api/v1/account" "" "$key_basic")")
    [ "$(echo "$acct_key" | jq -r '.author')" = "api:basic" ]
    [ "$(echo "$acct_key" | jq -r '.via_api_key')" = "true" ]

    read u_sess u_csrf < <(login_test_user "selfuser" "i")
    pw_res=$(raw_post_json "/api/v1/account/password" '{"current_password":"testpass123","new_password":"updatedpass456"}' \
        "session=${u_sess}; csrf=${u_csrf}" "${u_csrf}")
    [[ "$pw_res" =~ '"success":true' ]]
    [[ "$pw_res" =~ "Set-Cookie: session=" ]]

    # Non-admin is blocked from /api/v1/admin/*
    run raw_api_get "/api/v1/admin/status" "" "$key_basic"
    [[ "$output" =~ "403 Forbidden" ]]

    # Admin status + view/extension approve & revoke + schema sync
    status_json=$(json_body "$(raw_api_get "/api/v1/admin/status" "" "$key_admin")")
    [ "$(echo "$status_json" | jq -r '.ok')" != "null" ]

    sync_json=$(json_body "$(raw_api_write POST "/api/v1/admin/schemas/sync" "" "$key_admin" "")")
    [ "$(echo "$sync_json" | jq -r '.success')" = "true" ]

    raw_api_write POST "/api/v1/admin/views/v_demo/approve" "" "$key_admin" "" >/dev/null
    [ "$(json_body "$(raw_api_get "/api/v1/views" "" "$key_basic")" | jq -r '.views[0].approved')" = "true" ]
    raw_api_write POST "/api/v1/admin/views/v_demo/revoke" "" "$key_admin" "" >/dev/null
    [ "$(json_body "$(raw_api_get "/api/v1/views" "" "$key_basic")" | jq -r '.views[0].approved')" = "false" ]

    raw_api_write POST "/api/v1/admin/extensions/demo-ext/approve" "" "$key_admin" "" >/dev/null

    # Extension list, render, action, and manual trigger via API
    ext_list=$(json_body "$(raw_api_get "/api/v1/extensions" "" "$key_basic")")
    [ "$(echo "$ext_list" | jq -r '.extensions[0].name')" = "demo-ext" ]

    ext_render=$(json_body "$(raw_api_get "/api/v1/extensions/demo-ext" "" "$key_basic")")
    [ "$(echo "$ext_render" | jq -r '.elements[0].text')" = "Hello Ext" ]

    ext_act=$(json_body "$(raw_api_write POST "/api/v1/extensions/demo-ext/actions" "" "$key_basic" '{"action":"ping","args":{"msg":"42"}}')")
    [ "$(echo "$ext_act" | jq -r '.elements[0].text')" = "Pong: 42" ]

    trig_list=$(json_body "$(raw_api_get "/api/v1/admin/triggers" "" "$key_admin")")
    [ "$(echo "$trig_list" | jq -r '.extensions[0].name')" = "demo-ext" ]
    trig_run=$(json_body "$(raw_api_write POST "/api/v1/admin/triggers/demo-ext/seed" "" "$key_admin" "")")
    [ "$(echo "$trig_run" | jq -r '.message')" = "Seeded OK" ]

    # Admin users CRUD + archive/unarchive
    raw_api_write POST "/api/v1/admin/users" "" "$key_admin" '{"login":"carol","password":"carolpassword123","cap":"i"}' >/dev/null
    raw_api_write PATCH "/api/v1/admin/users/carol" "" "$key_admin" '{"cap":"is"}' >/dev/null
    users_json=$(json_body "$(raw_api_get "/api/v1/admin/users" "" "$key_admin")")
    [ "$(echo "$users_json" | jq -r '.users[] | select(.login=="carol") | .cap')" = "is" ]
    [[ ! "$users_json" =~ "password_hash" ]]
    raw_api_write POST "/api/v1/admin/users/carol/archive" "" "$key_admin" "" >/dev/null
    raw_api_write POST "/api/v1/admin/users/carol/unarchive" "" "$key_admin" "" >/dev/null

    # Admin API keys CRUD (including label with spaces)
    created_key_json=$(json_body "$(raw_api_write POST "/api/v1/admin/api-keys" "" "$key_admin" '{"label":"nightly sync","cap":"i"}')")
    new_raw=$(echo "$created_key_json" | jq -r '.raw_key')
    [ -n "$new_raw" ] && [ "$new_raw" != "null" ]
    raw_api_write PATCH "/api/v1/admin/api-keys/nightly%20sync" "" "$key_admin" '{"cap":"is"}' >/dev/null
    raw_api_write POST "/api/v1/admin/api-keys/nightly%20sync/archive" "" "$key_admin" "" >/dev/null
    raw_api_write POST "/api/v1/admin/api-keys/nightly%20sync/unarchive" "" "$key_admin" "" >/dev/null

    # Admin settings read/patch + PNG upload
    settings_patched=$(json_body "$(raw_api_write PATCH "/api/v1/admin/settings" "" "$key_admin" '{"site_name":"Celleste Lab","hide_home_heading":true,"colors":{"accent":"#0f766e"}}')")
    [ "$(echo "$settings_patched" | jq -r '.settings.site_name')" = "Celleste Lab" ]
    [ "$(echo "$settings_patched" | jq -r '.settings.colors.accent')" = "#0f766e" ]

    python3 -c 'import sys; sys.stdout.buffer.write(b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR")' | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="PUT" PATH_INFO="/api/v1/admin/settings/assets/logo.png" \
        QUERY_STRING="" HTTP_X_API_KEY="$key_admin" "$BIN" > "$TEST_DIR/asset_resp.txt"
    grep -q '"success":true' "$TEST_DIR/asset_resp.txt"
    [ -f "$TEST_DIR/theme-assets/logo.png" ]
}

@test "tag, document_tag, tag_relation, and tag_evidence work through /api/v1/entities/<type>" {
    key=$("$BIN" api-key create tagger i | tail -1)
    "$BIN" entity create document title="Cryopreservation protocol" content="vitrification steps" >/dev/null

    run raw_api_write POST "/api/v1/entities/tag" "" "$key" '{"label":"Plant cell cryopreservation","terms":"vitrification, cryoprotectant","source":"computed","computed_at":"2026-09-27"}'
    [[ "$output" =~ '"success":true' ]]
    tag_id=$(printf '%s' "$output" | grep -o '"created_id":[0-9]*' | grep -o '[0-9]*')

    run raw_api_write POST "/api/v1/entities/document_tag" "" "$key" "{\"document\":1,\"tag\":${tag_id},\"score\":0.82,\"decision\":\"computed\"}"
    [[ "$output" =~ '"success":true' ]]

    run raw_api_get "/api/v1/entities/document_tag" "filter_field=document&filter_value=1" "$key"
    [[ "$output" =~ '"decision":"computed"' || "$output" =~ '"decision": "computed"' ]]

    run raw_api_write POST "/api/v1/entities/tag" "" "$key" '{"label":"Somatic embryogenesis","source":"computed"}'
    b=$(printf '%s' "$output" | grep -o '"created_id":[0-9]*' | grep -o '[0-9]*')

    run raw_api_write POST "/api/v1/entities/tag_relation" "" "$key" "{\"tag_a\":${tag_id},\"tag_b\":${b},\"decision\":\"computed\",\"score\":1.8,\"reason\":\"share media and lineage\",\"evidence\":\"{\\\"mention\\\":1.6}\"}"
    [[ "$output" =~ '"success":true' ]]

    run raw_api_write POST "/api/v1/entities/tag_evidence" "" "$key" "{\"tag_a\":${tag_id},\"tag_b\":${b},\"kind\":\"lineage\",\"direction\":\"directed\",\"weight\":7,\"support\":7,\"producer\":\"tag-evidence\"}"
    [[ "$output" =~ '"success":true' ]]
}

@test "GET /api/v1/entities/<type>?since_event=<n> returns only rows changed after watermark (including archives) and reports max_event_id" {
    key=$("$BIN" api-key create sync-worker i | tail -1)
    "$BIN" entity create widget label=Alpha >/dev/null
    "$BIN" entity create widget label=Beta >/dev/null

    run raw_api_get "/api/v1/entities/widget" "" "$key"
    [[ "$output" =~ '"total":2' ]]
    wm1=$(printf '%s' "$output" | grep -o '"max_event_id":[0-9]*' | grep -o '[0-9]*')
    [ -n "$wm1" ] && [ "$wm1" -gt 0 ]

    # Idle delta poll returns 0 rows.
    run raw_api_get "/api/v1/entities/widget" "since_event=${wm1}" "$key"
    [[ "$output" =~ '"total":0' ]]

    # Update widget 1 and archive widget 2; delta poll returns both (including archived_at on widget 2).
    raw_api_write PATCH "/api/v1/entities/widget/1" "" "$key" '{"label":"Alpha-v2"}' >/dev/null
    raw_api_write POST "/api/v1/entities/widget/2/archive" "" "$key" "" >/dev/null

    run raw_api_get "/api/v1/entities/widget" "since_event=${wm1}" "$key"
    [[ "$output" =~ '"total":2' ]]
    [[ "$output" =~ '"Alpha-v2"' ]]
    [[ "$output" =~ '"archived_at":"' ]]
}

@test "GET /api/v1/documents/search searches Knowledge Pool and records a retrieval under api:<label>" {
    key=$("$BIN" api-key create cli-search i | tail -1)
    "$BIN" entity create document title="Vitrification Medium" content="Glycerol and DMSO cryoprotectant protocol." >/dev/null

    run raw_api_get "/api/v1/documents/search" "q=cryoprotectant&limit=5" "$key"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ '"Vitrification Medium"' ]]

    ret_cnt=$(sqlite3 .store/store.db "SELECT COUNT(*) FROM knowledge_retrieval WHERE query_text='cryoprotectant';")
    [ "$ret_cnt" -eq 1 ]
}
