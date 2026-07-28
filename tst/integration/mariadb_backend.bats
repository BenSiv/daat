#!/usr/bin/env bats

# Covers the MariaDB backend (doc/mariadb-migration.md) end to end via
# the real CLI, mirroring entity.bats'/schema.bats' own SQLite-focused
# coverage. Needs a real, reachable MariaDB server -- not available in
# every dev/CI environment the way SQLite (zero external dependency)
# always is, so every test here is skipped (not failed) if one isn't
# configured, matching luam's own test_mariadb.lua/test_mariadb_
# wrapper.lua skip-not-fail convention. Point MARIADB_TEST_HOST/PORT/
# USER/PASSWORD/DATABASE at a real test server to actually run these.

load test_helper.bash

setup() {
    export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    resolve_bin

    # host/port/user/database are real, version-controlled deployment
    # content now (platform.lua, written below) -- only the password
    # stays a plain env var (config.mariadb_descriptor's own
    # PLATFORM_MARIADB_PASSWORD read), same secrets-stay-external split
    # production uses. Still plain bash variables here (not exported)
    # since the `mariadb` CLI calls throughout this file need them for
    # string interpolation regardless of how the app itself reads them.
    PLATFORM_MARIADB_HOST="${MARIADB_TEST_HOST:-127.0.0.1}"
    PLATFORM_MARIADB_PORT="${MARIADB_TEST_PORT:-3306}"
    PLATFORM_MARIADB_USER="${MARIADB_TEST_USER:-platform_test}"
    export PLATFORM_MARIADB_PASSWORD="${MARIADB_TEST_PASSWORD:-platform_test_pw}"
    PLATFORM_MARIADB_DATABASE="${MARIADB_TEST_DATABASE:-platform_bats_test}"

    if ! command -v mariadb >/dev/null 2>&1; then
        skip "mariadb CLI not available -- skipping MariaDB backend coverage"
    fi

    # Fresh database per test (mirrors mktemp -d's fresh-directory
    # isolation for the SQLite path) -- drop-then-create, not just
    # create, so a test that crashed mid-run doesn't leave stale
    # tables for the next one.
    if ! mariadb -h "$PLATFORM_MARIADB_HOST" -P "$PLATFORM_MARIADB_PORT" \
            -u "$PLATFORM_MARIADB_USER" -p"$PLATFORM_MARIADB_PASSWORD" \
            -e "DROP DATABASE IF EXISTS $PLATFORM_MARIADB_DATABASE; CREATE DATABASE $PLATFORM_MARIADB_DATABASE;" \
            2>/dev/null; then
        skip "no reachable MariaDB test server at ${PLATFORM_MARIADB_HOST}:${PLATFORM_MARIADB_PORT} -- skipping"
    fi

    export TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    cat > platform.lua <<EOF
return {db_backend = "mariadb", mariadb_host = "${PLATFORM_MARIADB_HOST}", mariadb_port = ${PLATFORM_MARIADB_PORT}, mariadb_user = "${PLATFORM_MARIADB_USER}", mariadb_database = "${PLATFORM_MARIADB_DATABASE}"}
EOF
}

teardown() {
    if [ -n "${PLATFORM_MARIADB_DATABASE:-}" ] && command -v mariadb >/dev/null 2>&1; then
        mariadb -h "$PLATFORM_MARIADB_HOST" -P "$PLATFORM_MARIADB_PORT" \
            -u "$PLATFORM_MARIADB_USER" -p"$PLATFORM_MARIADB_PASSWORD" \
            -e "DROP DATABASE IF EXISTS $PLATFORM_MARIADB_DATABASE;" 2>/dev/null || true
    fi
    cd "$PROJECT_ROOT"
    rm -rf "$TEST_DIR"
}

@test "platform init succeeds against MariaDB and is idempotent" {
    run "$BIN" init
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Initialized store" ]]

    run "$BIN" init
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Already initialized" ]]
}

@test "schema add, entity create/list/update/archive/unarchive all work against MariaDB" {
    "$BIN" init
    mkdir -p schemas
    cat > schemas/reagent.lua <<'EOF'
return {
  name = "reagent",
  fields = {
    {name = "lot_number", type = "text", required = true},
    {name = "concentration", type = "number", required = true},
  },
}
EOF
    run "$BIN" schema add schemas/reagent.lua
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Registered entity type 'reagent'" ]]

    run "$BIN" entity create reagent lot_number=LOT-1 concentration=5
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Created reagent #1" ]]

    "$BIN" entity create reagent lot_number=LOT-2 concentration=10
    "$BIN" entity create reagent lot_number=LOT-3 concentration=15

    run "$BIN" entity list reagent
    [[ "$output" =~ "#1" ]]
    [[ "$output" =~ "#2" ]]
    [[ "$output" =~ "#3" ]]

    run "$BIN" entity update reagent 2 concentration=99
    [ "$status" -eq 0 ]

    run "$BIN" entity archive reagent 3
    [ "$status" -eq 0 ]
    run "$BIN" entity list reagent
    [[ ! "$output" =~ "#3" ]]

    run "$BIN" entity unarchive reagent 3
    [ "$status" -eq 0 ]
    run "$BIN" entity list reagent
    [[ "$output" =~ "#3" ]]

    run "$BIN" ledger history 2
    [[ "$output" =~ "create" ]]
    [[ "$output" =~ "concentration: nil -> 10" ]]
    [[ "$output" =~ "update" ]]
    [[ "$output" =~ "concentration: 10 -> 99" ]]
}

@test "a text field over 65535 bytes survives on MariaDB, including the ledger's own diff (task: bulk literature import)" {
    # Found live bulk-importing a literature corpus: MariaDB's plain
    # TEXT caps at 65,535 *bytes* (not characters), so any real paper's
    # full content -- and the ledger's own field_changes JSON diff,
    # which embeds that same content -- routinely exceeded it ("Data
    # too long for column"), silently fine on SQLite the whole time
    # regardless of the declared column type. Fixed by declaring
    # "text"-typed fields (schema.lua's SQL_TYPE) and the ledger's
    # field_changes column as LONGTEXT instead.
    "$BIN" init
    mkdir -p schemas
    cat > schemas/paper.lua <<'EOF'
return {
  name = "paper",
  fields = {
    {name = "body", type = "text", required = true},
  },
}
EOF
    "$BIN" schema add schemas/paper.lua

    big_content=$(python3 -c "print('x' * 200000)")
    run "$BIN" entity create paper "body=${big_content}"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Created paper #1" ]]

    run "$BIN" entity show paper 1
    stored_len=$(printf '%s' "$output" | grep -o 'x*' | awk '{ if (length($0) > max) max = length($0) } END { print max }')
    [ "$stored_len" -eq 200000 ]

    run "$BIN" ledger history 1
    [[ "$output" =~ "create" ]]
}

@test "the /sql ad-hoc console works against a real MariaDB backend, not just SQLite" {
    # Found live, in real production: view.run_adhoc called
    # sqlite3.open(db_path) directly, bypassing db.lua's own backend
    # dispatch entirely -- worked by accident whenever db_path was a
    # SQLite file path, but a MariaDB descriptor is a table, not a
    # string, so /sql has been a hard 500 ("bad argument #1 to 'open'
    # (string expected, got table)") on every single query since the
    # MariaDB cutover. No existing test exercised /sql against this
    # backend at all -- this is that missing coverage.
    "$BIN" init
    mkdir -p schemas
    cat > schemas/reagent.lua <<'EOF'
return {
  name = "reagent",
  fields = { {name = "lot_number", type = "text", required = true} },
}
EOF
    "$BIN" schema add schemas/reagent.lua
    "$BIN" entity create reagent lot_number=LOT-1

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "sqluser" "is")
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/sql" QUERY_STRING="q=SELECT+lot_number+FROM+reagent;" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" run "$BIN"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "LOT-1" ]]
    [[ ! "$output" =~ "Internal Server Error" ]]
    [[ ! "$output" =~ "bad argument" ]]
}

@test "a parameterized view runs correctly against a real MariaDB backend, not just SQLite (task #73)" {
    # Found while building label printing (task #73): view.run's
    # parameterized path called sqlite3.prepare/stmt.bind directly,
    # bypassing db.lua's backend dispatch entirely -- worked for SQLite,
    # but luam's MariaDB binding "deliberately does NOT expose a
    # prepared-statement/cursor object" at all (lib/mariadb/lmariadb.c's
    # own header comment), so a parameterized view had no working path
    # on MariaDB whatsoever. No existing test caught this. Fixed via
    # view.run_sql, dispatching by backend.
    "$BIN" init
    mkdir -p schemas views
    cat > schemas/reagent.lua <<'EOF'
return {
  name = "reagent",
  fields = { {name = "lot_number", type = "text", required = true} },
}
EOF
    "$BIN" schema add schemas/reagent.lua
    "$BIN" entity create reagent lot_number=LOT-1
    "$BIN" entity create reagent lot_number=LOT-2

    cat > views/by_id.lua <<'EOF'
return {
    name = "by_id",
    sql = "SELECT lot_number FROM reagent WHERE id = ?",
    columns = {{name = "lot_number"}},
    param = {name = "entity_id", type = "integer"},
}
EOF
    "$BIN" view approve by_id

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "viewuser" "is")
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/view" QUERY_STRING="view_name=by_id&entity_id=1" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" run "$BIN"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "LOT-1" ]]
    [[ ! "$output" =~ "LOT-2" ]]
    [[ ! "$output" =~ "Internal Server Error" ]]
    [[ ! "$output" =~ "bad argument" ]]
}

@test "a view's sql_mariadb variant runs on MariaDB where sql (SQLite-only) would fail (task #116)" {
    # Found via a real production 500 on /view?view_name=prioritized_tasks:
    # SQLite's julianday() and MariaDB's DATEDIFF()/GREATEST() share no
    # common function name, so no single sql string is portable for real
    # date-difference arithmetic. view.effective_sql now picks sql_mariadb
    # over sql whenever db.is_mariadb is true.
    "$BIN" init
    mkdir -p schemas views
    cat > schemas/task.lua <<'EOF'
return {
  name = "task",
  fields = {
    {name = "due_to", type = "date", required = false},
    {name = "urgency", type = "number", required = true},
  },
}
EOF
    "$BIN" schema add schemas/task.lua
    "$BIN" entity create task due_to=2026-01-01 urgency=1

    cat > views/due_soon.lua <<'EOF'
return {
    name = "due_soon",
    -- Deliberately SQLite-only -- this must NOT be what actually runs
    -- against MariaDB; if effective_sql picked this one, the query
    -- would fail outright (no julianday() on MariaDB).
    sql = "SELECT id, urgency, julianday(due_to) AS jd FROM task;",
    sql_mariadb = "SELECT id, urgency, DATEDIFF(due_to, '2000-01-01') AS jd FROM task;",
    columns = {{name = "id"}, {name = "urgency"}, {name = "jd"}},
}
EOF
    "$BIN" view approve due_soon

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "viewuser2" "is")
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/view" QUERY_STRING="view_name=due_soon" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" run "$BIN"
    [[ "$output" =~ "200 OK" ]]
    [[ ! "$output" =~ "Internal Server Error" ]]
    [[ ! "$output" =~ "no such function" ]]
}

@test "concurrent entity creates never collide on entity_id or leave one NULL against MariaDB (task #77)" {
    "$BIN" init
    mkdir -p schemas
    cat > schemas/reagent.lua <<'EOF'
return {
  name = "reagent",
  fields = {
    {name = "lot_number", type = "text", required = true},
  },
}
EOF
    "$BIN" schema add schemas/reagent.lua

    pids=()
    for i in $(seq 1 15); do
        "$BIN" entity create reagent lot_number="LOT-$i" &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    null_count=$(mariadb -h "$PLATFORM_MARIADB_HOST" -P "$PLATFORM_MARIADB_PORT" \
        -u "$PLATFORM_MARIADB_USER" -p"$PLATFORM_MARIADB_PASSWORD" -N \
        -e "SELECT COUNT(*) FROM $PLATFORM_MARIADB_DATABASE.entity_event WHERE event_type = 'create' AND entity_id IS NULL;")
    [ "$null_count" -eq 0 ]

    total_creates=$(mariadb -h "$PLATFORM_MARIADB_HOST" -P "$PLATFORM_MARIADB_PORT" \
        -u "$PLATFORM_MARIADB_USER" -p"$PLATFORM_MARIADB_PASSWORD" -N \
        -e "SELECT COUNT(*) FROM $PLATFORM_MARIADB_DATABASE.entity_event WHERE event_type = 'create';")
    distinct_entity_ids=$(mariadb -h "$PLATFORM_MARIADB_HOST" -P "$PLATFORM_MARIADB_PORT" \
        -u "$PLATFORM_MARIADB_USER" -p"$PLATFORM_MARIADB_PASSWORD" -N \
        -e "SELECT COUNT(DISTINCT entity_id) FROM $PLATFORM_MARIADB_DATABASE.entity_event WHERE event_type = 'create';")
    [ "$total_creates" -eq 15 ]
    [ "$distinct_entity_ids" -eq 15 ]
}

@test "label printing works against MariaDB, not just SQLite ('sql' is a reserved word there) (task #73)" {
    "$BIN" init
    mkdir -p schemas
    cat > schemas/sample.lua <<'EOF'
return {
  name = "sample",
  fields = { {name = "lab_name", type = "text", required = false} },
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
    "$BIN" schema add schemas/sample.lua
    "$BIN" schema add schemas/label_template.lua
    "$BIN" entity create sample lab_name="Test Sample"
    "$BIN" entity create-json label_template <<'JSON'
[{"for_entity_type": "sample", "sql": "SELECT lab_name FROM sample WHERE id = ?", "zpl": "^XA^FD{{lab_name}}^FS^XZ"}]
JSON

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "mdb_label_viewer" "i")
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/label" QUERY_STRING="type=sample&entity_id=1" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" run "$BIN"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Test Sample" ]]
    [[ ! "$output" =~ "Internal Server Error" ]]

    # /detail's own has_template check (decides whether to show the
    # Print Label button) runs this exact query for every entity type
    # on every /detail view -- confirmed live: this 500'd site-wide
    # before the fix, not just on the /label route itself.
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/detail" QUERY_STRING="type=sample&entity_id=1" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" run "$BIN"
    [[ "$output" =~ "200 OK" ]]
    [[ ! "$output" =~ "Internal Server Error" ]]
}
