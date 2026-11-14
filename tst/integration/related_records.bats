#!/usr/bin/env bats
# task #112: master/detail data entry for "composite"-style entities
# (fixed fields + a variable list of "component" child rows) -- kept
# purely as entities throughout: component.composite is a plain
# `reference` field, no junction table, no new storage mechanism.
# Everything here is fully generic (computed from
# schema.relationships()), not special-cased to this one pair of types.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    mkdir -p schemas
    cat > schemas/composite.lua <<'EOF'
return {
  name = "composite",
  fields = {
    {name = "lab_name", type = "text", required = true, display = true},
  },
}
EOF
    cat > schemas/component.lua <<'EOF'
return {
  name = "component",
  fields = {
    {name = "composite", type = "reference", required = true, entity_type = "composite"},
    {name = "amount", type = "number", required = false},
  },
}
EOF
    "$BIN" schema add schemas/composite.lua
    "$BIN" schema add schemas/component.lua
}

teardown() {
    cleanup_test_env
}

@test "entity.list_by_field/count_by_field return only matching, non-archived rows" {
    "$BIN" entity create composite lab_name="Batch-42"    # composite #1
    "$BIN" entity create composite lab_name="Batch-43"    # composite #2
    "$BIN" entity create component composite=1 amount=5   # component #3
    "$BIN" entity create component composite=1 amount=10  # component #4
    "$BIN" entity create component composite=2 amount=99  # component #5
    "$BIN" entity archive component 4

    run sqlite3 .store/store.db "SELECT COUNT(*) FROM component;"
    [ "$output" -eq 3 ]

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "viewer1" "i")
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/browse" QUERY_STRING="type=component&filter_field=composite&filter_value=1" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" run "$BIN"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "detail?type=component&entity_id=3" ]]
    # component #4 (composite=1, archived) shouldn't show by default;
    # component #5 (composite=2) shouldn't show either -- wrong filter value
    [[ ! "$output" =~ "detail?type=component&entity_id=4" ]]
    [[ ! "$output" =~ "detail?type=component&entity_id=5" ]]
}

@test "/detail shows a Related records section listing real child rows with an accurate count" {
    "$BIN" entity create composite lab_name="Batch-42"
    "$BIN" entity create component composite=1 amount=5
    "$BIN" entity create component composite=1 amount=10

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "viewer2" "i")
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/detail" QUERY_STRING="type=composite&entity_id=1" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" run "$BIN"
    [[ "$output" =~ "Related records" ]]
    [[ "$output" =~ "component (2)" ]]
    [[ "$output" =~ "detail?type=component&entity_id=2" ]]
    [[ "$output" =~ "detail?type=component&entity_id=3" ]]
    [[ "$output" =~ "register?type=component&lock_composite=1" ]]
}

@test "/detail shows no Related records section for a type nothing references" {
    "$BIN" entity create composite lab_name="Lonely"
    "$BIN" entity create component composite=1 amount=1

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "viewer3" "i")
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/detail" QUERY_STRING="type=component&entity_id=2" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" run "$BIN"
    [[ "$output" =~ "200 OK" ]]
    [[ ! "$output" =~ "Related records" ]]
}

@test "/detail's Related records shows a 'View all N' link once the preview cap is exceeded" {
    "$BIN" entity create composite lab_name="Big batch"
    for i in $(seq 1 11); do
        "$BIN" entity create component composite=1 amount="$i"
    done

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "viewer4" "i")
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/detail" QUERY_STRING="type=composite&entity_id=1" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" run "$BIN"
    [[ "$output" =~ "component (11)" ]]
    [[ "$output" =~ "View all 11" ]]
    [[ "$output" =~ "browse?type=component&filter_field=composite&filter_value=1" ]]
}

@test "/register?lock_<field>=<value> renders the field locked/read-only with the resolved display label" {
    "$BIN" entity create composite lab_name="Batch-42"

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "viewer5" "i")
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/register" QUERY_STRING="type=component&lock_composite=1" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" run "$BIN"
    [[ "$output" =~ '"locked_fields":{"composite":{"value":"1","label":"Batch-42"}}' ]]
    [[ "$output" =~ 'const lockedFields = boot.locked_fields;' ]]
}

@test "a submission that includes the locked field's value (as the hidden input would send) creates the row normally" {
    "$BIN" entity create composite lab_name="Batch-42"
    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "creator1" "i")

    payload='[{"composite": "1", "amount": 99}]'
    output=$(printf '%s' "$payload" | GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/submit" QUERY_STRING="type=component" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" HTTP_X_CSRF_TOKEN="${TEST_CSRF_TOKEN}" "$BIN")
    [[ "$output" =~ '"success":true' ]]

    run sqlite3 .store/store.db "SELECT composite, amount FROM component WHERE id = 2;"
    [[ "$output" =~ "1|99.0" ]]
}
