#!/usr/bin/env bats
# task #73: label printing. label_template is a real, ledgered entity
# type (not a config file) -- created/edited through the normal
# /register -> entity.create / /detail -> entity.update flows, gated by
# the generic admin_write_only schema flag (not special-cased to this
# one entity type's name). Rendering (src/label.lua) reuses view.lua's
# select-only safety check and its dual-backend parameterized query
# runner (view.run_sql) -- a label_template row's `sql` field is
# structurally just a single-parameter view.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    mkdir -p schemas
    cat > schemas/experiment.lua <<'EOF'
return {
  name = "experiment",
  fields = { {name = "title", type = "text", required = true} },
}
EOF
    cat > schemas/sample.lua <<'EOF'
return {
  name = "sample",
  fields = {
    {name = "lab_name", type = "text", required = false},
    {name = "experiment", type = "reference", required = false, entity_type = "experiment"},
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
    "$BIN" schema add schemas/experiment.lua
    "$BIN" schema add schemas/sample.lua
    "$BIN" schema add schemas/label_template.lua
}

teardown() {
    cleanup_test_env
}

@test "creating a label_template row requires Admin capability -- rejected for a plain user" {
    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "plainuser" "i")
    payload='[{"for_entity_type":"sample","sql":"SELECT lab_name FROM sample WHERE id = ?","zpl":"^XA^FD{{lab_name}}^FS^XZ"}]'
    output=$(printf '%s' "$payload" | GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/submit" QUERY_STRING="type=label_template" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" HTTP_X_CSRF_TOKEN="${TEST_CSRF_TOKEN}" "$BIN")
    [[ "$output" =~ "403 Forbidden" ]]
    [[ "$output" =~ "Admin capability required" ]]
}

@test "creating a label_template row succeeds for an Admin user" {
    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "admin1" "ia")
    payload='[{"for_entity_type":"sample","sql":"SELECT lab_name FROM sample WHERE id = ?","zpl":"^XA^FD{{lab_name}}^FS^XZ"}]'
    output=$(printf '%s' "$payload" | GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/submit" QUERY_STRING="type=label_template" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" HTTP_X_CSRF_TOKEN="${TEST_CSRF_TOKEN}" "$BIN")
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ '"success":true' ]]
}

@test "a non-SELECT sql value is rejected at save time, even for an Admin user" {
    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "admin2" "ia")
    payload='[{"for_entity_type":"sample","sql":"DELETE FROM sample WHERE id = ?","zpl":"^XA^XZ"}]'
    output=$(printf '%s' "$payload" | GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/submit" QUERY_STRING="type=label_template" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" HTTP_X_CSRF_TOKEN="${TEST_CSRF_TOKEN}" "$BIN")
    [[ "$output" =~ "must be a single, plain SELECT statement" ]]
    [[ ! "$output" =~ '"success":true' ]]
}

@test "GET /label renders correct ZPL for a real entity, including a cross-entity value from the template's own JOIN" {
    "$BIN" entity create experiment title="Exp One"
    "$BIN" entity create sample lab_name="Sample A" experiment=1
    "$BIN" entity create-json label_template <<'EOF'
[{"for_entity_type": "sample", "sql": "SELECT s.lab_name AS lab_name, e.title AS experiment_title FROM sample s LEFT JOIN experiment e ON e.id = s.experiment WHERE s.id = ?", "zpl": "^XA\n^FD{{lab_name}}^FS\n^FD{{experiment_title}}^FS\n^XZ"}]
EOF

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "viewer1" "i")
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/label" QUERY_STRING="type=sample&entity_id=2" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" run "$BIN"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Sample A" ]]
    [[ "$output" =~ "Exp One" ]]
}

@test "a field value containing ZPL command-prefix characters is stripped, not left to corrupt the label" {
    "$BIN" entity create sample lab_name='Weird^Name~Here'
    "$BIN" entity create-json label_template <<'EOF'
[{"for_entity_type": "sample", "sql": "SELECT lab_name FROM sample WHERE id = ?", "zpl": "^XA^FD{{lab_name}}^FS^XZ"}]
EOF

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "viewer2" "i")
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/label" QUERY_STRING="type=sample&entity_id=1" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" run "$BIN"
    [[ "$output" =~ "WeirdNameHere" ]]
    [[ ! "$output" =~ "Weird^Name" ]]
    [[ ! "$output" =~ "Name~Here" ]]
}

@test "GET /label 404s when no label template exists for the entity type" {
    "$BIN" entity create experiment title="Exp Alone"

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "viewer3" "i")
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/label" QUERY_STRING="type=experiment&entity_id=1" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" run "$BIN"
    [[ "$output" =~ "404 Not Found" ]]
}

@test "/detail shows the Print Label button only when a template exists for that entity type" {
    "$BIN" entity create experiment title="Exp Two"
    "$BIN" entity create sample lab_name="Sample B" experiment=1
    "$BIN" entity create-json label_template <<'EOF'
[{"for_entity_type": "sample", "sql": "SELECT lab_name FROM sample WHERE id = ?", "zpl": "^XA^FD{{lab_name}}^FS^XZ"}]
EOF

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "viewer4" "i")
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/detail" QUERY_STRING="type=sample&entity_id=2" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" run "$BIN"
    [[ "$output" =~ "platform-print-label-btn" ]]
    [[ "$output" =~ "BrowserPrint-3.0.216.min.js" ]]

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/detail" QUERY_STRING="type=experiment&entity_id=1" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" run "$BIN"
    [[ ! "$output" =~ "platform-print-label-btn" ]]
}

@test "creating and editing a label_template row is ledgered exactly like any other entity" {
    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "admin3" "ia")
    payload='[{"for_entity_type":"sample","sql":"SELECT lab_name FROM sample WHERE id = ?","zpl":"^XA^FD{{lab_name}}^FS^XZ"}]'
    output=$(printf '%s' "$payload" | GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/submit" QUERY_STRING="type=label_template" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" HTTP_X_CSRF_TOKEN="${TEST_CSRF_TOKEN}" "$BIN")
    [[ "$output" =~ '"success":true' ]]

    update_payload='{"zpl":"^XA^FD{{lab_name}} v2^FS^XZ"}'
    output=$(printf '%s' "$update_payload" | GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/update" QUERY_STRING="type=label_template&entity_id=1" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" HTTP_X_CSRF_TOKEN="${TEST_CSRF_TOKEN}" "$BIN")
    [[ "$output" =~ '"success":true' ]]

    run "$BIN" ledger history 1
    [[ "$output" =~ "create" ]]
    [[ "$output" =~ "update" ]]
    [[ "$output" =~ "zpl" ]]
}
