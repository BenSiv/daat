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
    # content now (config.lua, written below) -- only the password
    # stays a plain env var (config.mariadb_descriptor's own
    # DAAT_MARIADB_PASSWORD read), same secrets-stay-external split
    # production uses. Still plain bash variables here (not exported)
    # since the `mariadb` CLI calls throughout this file need them for
    # string interpolation regardless of how the app itself reads them.
    DAAT_MARIADB_HOST="${MARIADB_TEST_HOST:-127.0.0.1}"
    DAAT_MARIADB_PORT="${MARIADB_TEST_PORT:-3306}"
    DAAT_MARIADB_USER="${MARIADB_TEST_USER:-platform_test}"
    export DAAT_MARIADB_PASSWORD="${MARIADB_TEST_PASSWORD:-platform_test_pw}"
    DAAT_MARIADB_DATABASE="${MARIADB_TEST_DATABASE:-platform_bats_test_$$}"

    if ! command -v mariadb >/dev/null 2>&1; then
        if [ "${DAAT_REQUIRE_MARIADB:-0}" = "1" ]; then
            echo "mariadb CLI missing despite DAAT_REQUIRE_MARIADB=1" >&2
            return 1
        fi
        skip "mariadb CLI not available -- skipping MariaDB backend coverage"
    fi

    # Fresh database per test (mirrors mktemp -d's fresh-directory
    # isolation for the SQLite path) -- drop-then-create, not just
    # create, so a test that crashed mid-run doesn't leave stale
    # tables for the next one.
    if ! mariadb -h "$DAAT_MARIADB_HOST" -P "$DAAT_MARIADB_PORT" \
            -u "$DAAT_MARIADB_USER" -p"$DAAT_MARIADB_PASSWORD" \
            -e "DROP DATABASE IF EXISTS $DAAT_MARIADB_DATABASE; CREATE DATABASE $DAAT_MARIADB_DATABASE;" \
            2>/dev/null; then
        if [ "${DAAT_REQUIRE_MARIADB:-0}" = "1" ]; then
            echo "MariaDB test server unreachable at ${DAAT_MARIADB_HOST}:${DAAT_MARIADB_PORT} despite DAAT_REQUIRE_MARIADB=1" >&2
            return 1
        fi
        skip "no reachable MariaDB test server at ${DAAT_MARIADB_HOST}:${DAAT_MARIADB_PORT} -- skipping"
    fi

    export TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    cat > config.lua <<EOF
return {database = {backend = "mariadb", host = "${DAAT_MARIADB_HOST}", port = ${DAAT_MARIADB_PORT}, user = "${DAAT_MARIADB_USER}", database = "${DAAT_MARIADB_DATABASE}"}}
EOF
}

teardown() {
    if [ -n "${DAAT_MARIADB_DATABASE:-}" ] && command -v mariadb >/dev/null 2>&1; then
        mariadb -h "$DAAT_MARIADB_HOST" -P "$DAAT_MARIADB_PORT" \
            -u "$DAAT_MARIADB_USER" -p"$DAAT_MARIADB_PASSWORD" \
            -e "DROP DATABASE IF EXISTS $DAAT_MARIADB_DATABASE;" 2>/dev/null || true
    fi
    cd "$PROJECT_ROOT"
    rm -rf "$TEST_DIR"
}

@test "daat init succeeds against MariaDB and is idempotent" {
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

    # 100 KB exceeds MariaDB's 65,535-byte TEXT cap while staying below
    # Linux's 131,072-byte per-argument MAX_ARG_STRLEN execve limit.
    big_content=$(python3 -c "print('x' * 100000)")
    run "$BIN" entity create paper "body=${big_content}"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Created paper #1" ]]

    run "$BIN" entity show paper 1
    stored_len=$(printf '%s' "$output" | grep -o 'x*' | awk '{ if (length($0) > max) max = length($0) } END { print max }')
    [ "$stored_len" -eq 100000 ]

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

@test "a parameterized view runs correctly against a real MariaDB backend, not just SQLite" {
    # Found while building label printing: view.run's
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

@test "a view's sql_mariadb variant runs on MariaDB where sql (SQLite-only) would fail" {
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

@test "concurrent entity creates never collide on entity_id or leave one NULL against MariaDB" {
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

    null_count=$(mariadb -h "$DAAT_MARIADB_HOST" -P "$DAAT_MARIADB_PORT" \
        -u "$DAAT_MARIADB_USER" -p"$DAAT_MARIADB_PASSWORD" -N \
        -e "SELECT COUNT(*) FROM $DAAT_MARIADB_DATABASE.entity_event WHERE event_type = 'create' AND entity_id IS NULL;")
    [ "$null_count" -eq 0 ]

    total_creates=$(mariadb -h "$DAAT_MARIADB_HOST" -P "$DAAT_MARIADB_PORT" \
        -u "$DAAT_MARIADB_USER" -p"$DAAT_MARIADB_PASSWORD" -N \
        -e "SELECT COUNT(*) FROM $DAAT_MARIADB_DATABASE.entity_event WHERE event_type = 'create';")
    distinct_entity_ids=$(mariadb -h "$DAAT_MARIADB_HOST" -P "$DAAT_MARIADB_PORT" \
        -u "$DAAT_MARIADB_USER" -p"$DAAT_MARIADB_PASSWORD" -N \
        -e "SELECT COUNT(DISTINCT entity_id) FROM $DAAT_MARIADB_DATABASE.entity_event WHERE event_type = 'create';")
    [ "$total_creates" -eq 15 ]
    [ "$distinct_entity_ids" -eq 15 ]
}

@test "label printing works against MariaDB, not just SQLite ('sql' is a reserved word there)" {
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

@test "passage search caches embeddings in document_passage_cache on MariaDB/MySQL, reads them back, and prunes them" {
    cat > config.lua <<EOF2
return {database = {backend = "mariadb", host = "${DAAT_MARIADB_HOST}", port = ${DAAT_MARIADB_PORT}, user = "${DAAT_MARIADB_USER}", database = "${DAAT_MARIADB_DATABASE}"}, agent = {provider = "test"}, knowledge = {embedding_quiet_minutes = 0, search_passages = true, passage_min_chars = 50}, search = {provider = "test"}}
EOF2
    export AGENT_TEST_EMBEDDINGS=terms
    export AGENT_TEST_EMBEDDINGS_LOG="$TEST_DIR/embeddings.log"
    "$BIN" init >/dev/null
    "$BIN" user add alice secret123 i >/dev/null
    filler=$(printf 'Plants were watered and the greenhouse lights were checked. %.0s' $(seq 1 40))
    "$BIN" document create-json <<< "[{\"title\":\"Lab handbook\",\"content\":\"# Greenhouse\\n${filler}\\n\\n# Incubator\\nThe incubator held the cultures at twenty five degrees.\"}]" >/dev/null
    raw=$(printf 'login=alice&password=secret123' | GATEWAY_INTERFACE=CGI/1.1 REQUEST_METHOD=POST PATH_INFO=/login QUERY_STRING="" "$BIN")
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    page() { GATEWAY_INTERFACE=CGI/1.1 REQUEST_METHOD=GET PATH_INFO=/documents QUERY_STRING="q=incubator+cultures+degrees" HTTP_COOKIE="session=$session" "$BIN"; }
    q() { mariadb -N -h "$DAAT_MARIADB_HOST" -P "$DAAT_MARIADB_PORT" -u "$DAAT_MARIADB_USER" -p"$DAAT_MARIADB_PASSWORD" "$DAAT_MARIADB_DATABASE" -e "$1" 2>/dev/null; }

    run page
    [[ "$output" =~ "twenty five degrees" ]]
    [[ "$output" =~ "[at character " ]]
    stored=$(q "SELECT COUNT(*) FROM document_passage_cache;")
    [ "$stored" -ge 2 ]
    [ "$(q "SELECT MIN(LENGTH(vector_packed)) FROM document_passage_cache;")" = "256" ]
    first=$(grep -c '^# ' "$AGENT_TEST_EMBEDDINGS_LOG")

    q "UPDATE document_passage_cache SET last_used_at = '2020-01-01 00:00:00';"
    run page
    [[ "$output" =~ "twenty five degrees" ]]
    [ "$(grep -c '^# ' "$AGENT_TEST_EMBEDDINGS_LOG")" -eq "$first" ]
    [ "$(q "SELECT COUNT(*) FROM document_passage_cache WHERE last_used_at > '2020-01-01 00:00:00';")" -gt 0 ]

    q "UPDATE document_passage_cache SET last_used_at = '2020-01-01 00:00:00';"
    run "$BIN" store prune
    [[ "$output" =~ "Deleted ${stored} passage embeddings" ]]
}

@test "aspects are built into document_aspect on MariaDB/MySQL, and search finds a document through one" {
    cat > config.lua <<EOF2
return {database = {backend = "mariadb", host = "${DAAT_MARIADB_HOST}", port = ${DAAT_MARIADB_PORT}, user = "${DAAT_MARIADB_USER}", database = "${DAAT_MARIADB_DATABASE}"}, agent = {provider = "test"}, knowledge = {embedding_quiet_minutes = 0, search_passages = true, passage_min_chars = 50, aspect_min_chars = 1000, build_aspects = true, search_aspects = true}, search = {provider = "test"}}
EOF2
    export AGENT_TEST_EMBEDDINGS=terms
    "$BIN" init >/dev/null
    "$BIN" user add alice secret123 i >/dev/null
    # See tst/integration/aspect_retrieval.bats: "qqqvq" shares only its
    # embedding dimension with "centrifuge", and no characters at all.
    filler=$(printf 'Plants were watered and the greenhouse lights were checked. %.0s' $(seq 1 40))
    spin=$(printf 'centrifuge %.0s' $(seq 1 30))
    "$BIN" document create-json <<< "[{\"title\":\"Lab handbook\",\"content\":\"# Greenhouse\\n${filler}\\n\\n# Watering\\n${filler}\\n\\n# Centrifuge\\n${spin}\"}]" >/dev/null
    raw=$(printf 'login=alice&password=secret123' | GATEWAY_INTERFACE=CGI/1.1 REQUEST_METHOD=POST PATH_INFO=/login QUERY_STRING="" "$BIN")
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    q() { mariadb -N -h "$DAAT_MARIADB_HOST" -P "$DAAT_MARIADB_PORT" -u "$DAAT_MARIADB_USER" -p"$DAAT_MARIADB_PASSWORD" "$DAAT_MARIADB_DATABASE" -e "$1" 2>/dev/null; }

    [ "$(q "SELECT COUNT(*) FROM document_aspect;")" -ge 2 ]
    [ "$(q "SELECT MIN(LENGTH(vector_packed)) FROM document_aspect;")" = "64" ]
    GATEWAY_INTERFACE=CGI/1.1 REQUEST_METHOD=GET PATH_INFO=/documents QUERY_STRING="q=qqqvq" HTTP_COOKIE="session=$session" "$BIN" >/dev/null
    [ "$(q "SELECT COUNT(*) FROM knowledge_retrieval_hit WHERE aspect IS NOT NULL;")" -eq 1 ]
    run "$BIN" repair aspects
    [[ "$output" =~ "0 document(s) (0 aspects), 1 unchanged" ]]
}

@test "store migration 9 widens MariaDB agent_message.content to LONGTEXT so >64 KB thinking payloads survive (#37)" {
    cat > config.lua <<EOF2
return {database = {backend = "mariadb", host = "${DAAT_MARIADB_HOST}", port = ${DAAT_MARIADB_PORT}, user = "${DAAT_MARIADB_USER}", database = "${DAAT_MARIADB_DATABASE}"}, agent = {provider = "test", thinking = "full", turn_mode = "inline"}}
EOF2
    "$BIN" init >/dev/null
    read -r session csrf <<< "$(login_test_user alice i)"
    cookie="session=${session}; csrf=${csrf}"
    q() { mariadb -N -h "$DAAT_MARIADB_HOST" -P "$DAAT_MARIADB_PORT" -u "$DAAT_MARIADB_USER" -p"$DAAT_MARIADB_PASSWORD" "$DAAT_MARIADB_DATABASE" -e "$1" 2>/dev/null; }

    # Trigger agent table creation, then rewind to the pre-migration-9 MariaDB
    # layout (plain TEXT = 65,535-byte cap) to verify store.migrate widens it.
    resp=$(raw_post_json "/api/chat-widget-start" '{"title":"Long thinking"}' "$cookie" "$csrf" "")
    sid=$(json_body "$resp" | jq -r '.session_id')
    q "ALTER TABLE agent_message MODIFY COLUMN content TEXT NOT NULL;"
    q "UPDATE system_state SET number_value = 8 WHERE name = 'store.schema_version';"

    export AGENT_TEST_THINKING="$(python3 -c "print('T' * 75000)")"
    run raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${sid}\",\"message\":\"Hello\"}" "$cookie" "$csrf" "$(done_response "Answer after 75 KB thinking.")"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Answer after 75 KB thinking." ]]
    [ "$(q "SELECT MAX(CHAR_LENGTH(content)) > 75000 FROM agent_message;")" = "1" ]
    [ "$(q "SELECT number_value >= 9 FROM system_state WHERE name = 'store.schema_version';")" = "1" ]
}

@test "store prune stubs tool_trace rows, clears model_input, reports stored chars by type, and is idempotent on MariaDB (#35)" {
    cat > config.lua <<EOF2
return {database = {backend = "mariadb", host = "${DAAT_MARIADB_HOST}", port = ${DAAT_MARIADB_PORT}, user = "${DAAT_MARIADB_USER}", database = "${DAAT_MARIADB_DATABASE}"}, agent = {provider = "test", turn_mode = "inline", retention = "standard"}}
EOF2
    "$BIN" init >/dev/null
    read -r session csrf <<< "$(login_test_user alice i)"
    cookie="session=${session}; csrf=${csrf}"
    q() { mariadb -N -h "$DAAT_MARIADB_HOST" -P "$DAAT_MARIADB_PORT" -u "$DAAT_MARIADB_USER" -p"$DAAT_MARIADB_PASSWORD" "$DAAT_MARIADB_DATABASE" -e "$1" 2>/dev/null; }

    resp=$(raw_post_json "/api/chat-widget-start" '{"title":"MariaDB prune"}' "$cookie" "$csrf" "")
    sid=$(json_body "$resp" | jq -r '.session_id')
    scripted="$(tool_call_response "entity.list_types" "{}")"$'\1'"$(done_response "Done on MariaDB.")"
    raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${sid}\",\"message\":\"Check types\"}" "$cookie" "$csrf" "$scripted" >/dev/null

    q "UPDATE agent_message SET created_at = '2020-01-01 00:00:00' WHERE session_id = '${sid}';"
    q "UPDATE agent_model_call SET created_at = '2020-01-01 00:00:00' WHERE session_id = '${sid}';"

    run "$BIN" store prune
    [ "$status" -eq 0 ]
    [[ "$output" =~ "tool_trace: Stubbed 1 tool results older than 90 days" ]]
    [ "$(q "SELECT COUNT(*) FROM agent_model_call WHERE session_id = '${sid}' AND prompt IS NOT NULL;")" = "0" ]
    [[ "$(q "SELECT content FROM agent_message WHERE session_id = '${sid}' AND role = 'tool_result';")" =~ "result pruned after 90 days: entity.list_types," ]]

    # Second run is a complete no-op on MariaDB.
    run "$BIN" store prune
    [ "$status" -eq 0 ]
    [[ "$output" =~ "model_input: Cleared 0 stored prompts" ]]
    [[ "$output" =~ "tool_trace: Stubbed 0 tool results" ]]

    run "$BIN" agent context-report
    [ "$status" -eq 0 ]
    [[ "$output" =~ "## Stored characters by type" ]]
    [[ "$output" =~ "model_input	0	0" ]]
}

@test "deferred search_review_mode queues retrieval review on MariaDB and review-pending drains it idempotently" {
    cat > config.lua <<EOF2
return {database = {backend = "mariadb", host = "${DAAT_MARIADB_HOST}", port = ${DAAT_MARIADB_PORT}, user = "${DAAT_MARIADB_USER}", database = "${DAAT_MARIADB_DATABASE}"}, agent = {provider = "test"}, knowledge = {embedding_quiet_minutes = 0}, search = {provider = "test"}}
EOF2
    "$BIN" init >/dev/null
    read -r session csrf <<< "$(login_test_user alice i)"
    cookie="session=${session}; csrf=${csrf}"
    q() { mariadb -N -h "$DAAT_MARIADB_HOST" -P "$DAAT_MARIADB_PORT" -u "$DAAT_MARIADB_USER" -p"$DAAT_MARIADB_PASSWORD" "$DAAT_MARIADB_DATABASE" -e "$1" 2>/dev/null; }

    "$BIN" entity create document title="Bioreactor Protocol" content="Careful bioreactor pH and dissolved oxygen control." >/dev/null
    doc_id=$(q "SELECT id FROM document WHERE title = 'Bioreactor Protocol';")

    run raw_get "/documents" "q=bioreactor" "$cookie"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Bioreactor Protocol" ]]

    # Search request recorded only the pending retrieval and raw hit; zero document writes ran synchronously.
    [ "$(q "SELECT status FROM knowledge_retrieval ORDER BY id DESC LIMIT 1;")" = "pending" ]
    [ "$(q "SELECT author FROM knowledge_retrieval ORDER BY id DESC LIMIT 1;")" = "alice" ]
    [ "$(q "SELECT retrieval_count FROM document WHERE id = ${doc_id};")" = "0" ]
    [ "$(q "SELECT COUNT(*) FROM knowledge_retrieval_hit WHERE document_id = ${doc_id} AND reinforcement_delta IS NULL AND reviewed_at IS NULL;")" = "1" ]

    run "$BIN" knowledge review-pending
    [ "$status" -eq 0 ]
    [[ "$output" =~ "reviewed (1 hits)" ]]
    [ "$(q "SELECT status FROM knowledge_retrieval ORDER BY id DESC LIMIT 1;")" = "reviewed" ]
    [ "$(q "SELECT retrieval_count FROM document WHERE id = ${doc_id};")" = "1" ]
    [ "$(q "SELECT COUNT(*) FROM knowledge_retrieval_hit WHERE document_id = ${doc_id} AND reinforcement_delta IS NOT NULL AND reviewed_at IS NOT NULL;")" = "1" ]

    # Second run is a complete no-op.
    run "$BIN" knowledge review-pending
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$(q "SELECT retrieval_count FROM document WHERE id = ${doc_id};")" = "1" ]
}

@test "store migration 11 and daat store verify succeed end-to-end on MariaDB" {
    cat > config.lua <<EOF2
return {database = {backend = "mariadb", host = "${DAAT_MARIADB_HOST}", port = ${DAAT_MARIADB_PORT}, user = "${DAAT_MARIADB_USER}", database = "${DAAT_MARIADB_DATABASE}"}, agent = {provider = "test"}, knowledge = {embedding_quiet_minutes = 0}, search = {provider = "test"}}
EOF2
    "$BIN" init >/dev/null
    q() { mariadb -N -h "$DAAT_MARIADB_HOST" -P "$DAAT_MARIADB_PORT" -u "$DAAT_MARIADB_USER" -p"$DAAT_MARIADB_PASSWORD" "$DAAT_MARIADB_DATABASE" -e "$1" 2>/dev/null; }

    d1=$("$BIN" entity create document title="MariaDB Doc A" content="Links to [[MariaDB Doc B]]." | grep -o '[0-9]\+')
    d2=$("$BIN" entity create document title="MariaDB Doc B" content="Second note." | grep -o '[0-9]\+')

    # Simulate pre-migration-11 MariaDB store and verify migration 11 backfills LN(scale_at_write) + pool_active + document_count
    q "ALTER TABLE document DROP COLUMN log_scale_at_write, DROP COLUMN pool_active;"
    q "UPDATE document SET raw_heat = 1.5, scale_at_write = 0.5 WHERE id = ${d1};"
    q "UPDATE knowledge_pool_state SET log_pool_scale = LN(0.5), document_count = 77 WHERE id = 1;"
    q "UPDATE system_state SET number_value = 10 WHERE name = 'store.schema_version';"

    run "$BIN" store verify
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Store verification passed (0 violations)." ]]
    [ "$(q "SELECT document_count FROM knowledge_pool_state WHERE id = 1;")" = "2" ]
}

@test "Law L6: dual-backend SQLite vs. MariaDB observational equivalence across seeded command traces" {
    run_luam "$PROJECT_ROOT/tst/integration/lua/dual_backend_laws.lua" \
        "$DAAT_MARIADB_HOST" "$DAAT_MARIADB_PORT" "$DAAT_MARIADB_USER" "$DAAT_MARIADB_DATABASE"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Law L6 dual-backend SQLite == MariaDB observational equivalence passed" ]]
}

@test "/api/v1 REST CRUD, archive/unarchive, and X-Api-Key auth succeed end-to-end on MariaDB" {
    "$BIN" init >/dev/null
    mkdir -p schemas
    cat > schemas/widget.lua <<'EOF'
return {
  name = "widget",
  fields = { {name = "label", type = "text", required = true} },
}
EOF
    "$BIN" schema add schemas/widget.lua >/dev/null
    key=$("$BIN" api-key create mdb-sync i | tail -1)
    [ -n "$key" ]

    api_write() {
        printf '%s' "${3:-}" | \
            GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="$1" PATH_INFO="$2" QUERY_STRING="" \
            HTTP_X_API_KEY="$key" "$BIN"
    }
    api_get() {
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="$1" QUERY_STRING="${2:-}" \
            HTTP_X_API_KEY="$key" "$BIN"
    }

    run api_write "POST" "/api/v1/widget" '{"label":"alpha"}'
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ '"created_id":1' ]]

    run api_write "PATCH" "/api/v1/widget/1" '{"label":"alpha-v2"}'
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ '"updated_id":1' ]]

    run api_get "/api/v1/widget/1"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ '"label":"alpha-v2"' ]]

    run api_write "POST" "/api/v1/widget/1/archive" '{}'
    [[ "$output" =~ "200 OK" ]]
    run api_get "/api/v1/widget"
    [[ ! "$output" =~ '"label":"alpha-v2"' ]]

    run api_write "POST" "/api/v1/widget/1/unarchive" '{}'
    [[ "$output" =~ "200 OK" ]]
    run api_get "/api/v1/widget"
    [[ "$output" =~ '"label":"alpha-v2"' ]]
}

@test "email verification and forgot/reset-password flow work end-to-end on MariaDB" {
    cat > config.lua <<EOF2
return {database = {backend = "mariadb", host = "${DAAT_MARIADB_HOST}", port = ${DAAT_MARIADB_PORT}, user = "${DAAT_MARIADB_USER}", database = "${DAAT_MARIADB_DATABASE}"}, mail = {provider = "test", from = "noreply@example.com", public_url = "https://lims.example.com/"}}
EOF2
    export MAIL_TEST_OUTBOX="$TEST_DIR/outbox"
    "$BIN" init >/dev/null
    "$BIN" user add alice oldpass123 i >/dev/null
    "$BIN" user email alice alice@example.com >/dev/null

    form_post() {
        printf '%s' "$2" | GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="$1" QUERY_STRING="" "$BIN"
    }
    last_tok() {
        tail -1 "$MAIL_TEST_OUTBOX" | grep -oE '(reset-password|verify-email)#token=[0-9a-f]*' | head -1 | sed 's/.*token=//'
    }

    verify_tok=$(last_tok)
    [ -n "$verify_tok" ]
    run form_post "/verify-email" "token=${verify_tok}&password=oldpass123"
    [[ "$output" =~ "302 Found" ]]

    rm -f "$MAIL_TEST_OUTBOX"
    run form_post "/forgot-password" "identifier=alice@example.com"
    [[ "$output" =~ "200 OK" ]]
    reset_tok=$(last_tok)
    [ -n "$reset_tok" ]

    run form_post "/reset-password" "token=${reset_tok}&new_password=newpass456&confirm_password=newpass456"
    [[ "$output" =~ "302 Found" ]]

    # Old password fails, new password succeeds, and reused token is rejected.
    run raw_login "alice" "oldpass123"
    [[ ! "$output" =~ "Set-Cookie: session=" ]]
    run raw_login "alice" "newpass456"
    [[ "$output" =~ "Set-Cookie: session=" ]]
    run form_post "/reset-password" "token=${reset_tok}&new_password=another789&confirm_password=another789"
    [[ "$output" =~ "invalid, has expired, or has already been used" ]]
}

@test "tags, tag_centre incremental updates, and repair tags --place-untagged work on MariaDB" {
    cat > config.lua <<EOF2
return {database = {backend = "mariadb", host = "${DAAT_MARIADB_HOST}", port = ${DAAT_MARIADB_PORT}, user = "${DAAT_MARIADB_USER}", database = "${DAAT_MARIADB_DATABASE}"}, agent = {provider = "test"}, knowledge = {embedding_quiet_minutes = 0, tag_min_text = 0}}
EOF2
    export AGENT_TEST_EMBEDDINGS=terms
    "$BIN" init >/dev/null
    q() { mariadb -N -h "$DAAT_MARIADB_HOST" -P "$DAAT_MARIADB_PORT" -u "$DAAT_MARIADB_USER" -p"$DAAT_MARIADB_PASSWORD" "$DAAT_MARIADB_DATABASE" -e "$1" 2>/dev/null; }

    "$BIN" entity create tag label="Bioreactor" source=computed >/dev/null
    tag_id=$(q "SELECT id FROM tag WHERE label = 'Bioreactor';")
    "$BIN" entity create document title="Bioreactor run 1" content="bioreactor impeller dissolved oxygen sparging bioreactor" >/dev/null
    d1=$(q "SELECT id FROM document WHERE title = 'Bioreactor run 1';")
    "$BIN" entity create document_tag document="$d1" tag="$tag_id" decision=computed score=0.95 >/dev/null
    [ "$(q "SELECT members FROM tag_centre WHERE tag_id = ${tag_id};")" = "1" ]

    "$BIN" entity create document title="Bioreactor run 2" content="bioreactor impeller dissolved oxygen sparging bioreactor" >/dev/null
    d2=$(q "SELECT id FROM document WHERE title = 'Bioreactor run 2';")
    q "DELETE FROM document_tag WHERE document = ${d2};"
    q "UPDATE tag_centre SET members = 1 WHERE tag_id = ${tag_id};"

    run "$BIN" repair tags --place-untagged
    [ "$status" -eq 0 ]
    [ "$(q "SELECT COUNT(*) FROM document_tag WHERE document = ${d2} AND tag = ${tag_id} AND archived_at IS NULL;")" = "1" ]
}

@test "repair duplicates folds near-identical synced papers and updates links on MariaDB" {
    cat > config.lua <<EOF2
return {database = {backend = "mariadb", host = "${DAAT_MARIADB_HOST}", port = ${DAAT_MARIADB_PORT}, user = "${DAAT_MARIADB_USER}", database = "${DAAT_MARIADB_DATABASE}"}, agent = {provider = "test"}, knowledge = {embedding_quiet_minutes = 0}}
EOF2
    "$BIN" init >/dev/null
    q() { mariadb -N -h "$DAAT_MARIADB_HOST" -P "$DAAT_MARIADB_PORT" -u "$DAAT_MARIADB_USER" -p"$DAAT_MARIADB_PASSWORD" "$DAAT_MARIADB_DATABASE" -e "$1" 2>/dev/null; }

    body=$(python3 -c "print(' '.join('lipid%d' % i for i in range(1, 451)))")
    "$BIN" entity create document title="Lipid Maturation" external_id="sharepoint:item-1" content="$body" >/dev/null
    "$BIN" entity create document title="Copy Lipid Maturation" external_id="sharepoint:item-2" content="$body" >/dev/null
    "$BIN" entity create document title="Review Note" content="See [[Copy Lipid Maturation]]." >/dev/null
    keep=$(q "SELECT id FROM document WHERE external_id = 'sharepoint:item-1';")
    copy=$(q "SELECT id FROM document WHERE external_id = 'sharepoint:item-2';")

    run "$BIN" repair duplicates
    [ "$status" -eq 0 ]
    [ "$(q "SELECT merged_into FROM document WHERE id = ${copy};")" = "$keep" ]
    [ "$(q "SELECT COUNT(*) FROM document WHERE id = ${copy} AND archived_at IS NOT NULL;")" = "1" ]
    [ "$(q "SELECT COUNT(*) FROM document_link WHERE to_document_id = ${keep} AND archived_at IS NULL;")" = "1" ]
}

@test "tier curation ladder (curate -> synthesize -> distill) and store verify succeed on MariaDB" {
    cat > config.lua <<EOF2
return {database = {backend = "mariadb", host = "${DAAT_MARIADB_HOST}", port = ${DAAT_MARIADB_PORT}, user = "${DAAT_MARIADB_USER}", database = "${DAAT_MARIADB_DATABASE}"}, agent = {provider = "test"}, knowledge = {embedding_quiet_minutes = 0, tag_min_text = 0}}
EOF2
    export AGENT_TEST_EMBEDDINGS=terms
    "$BIN" init >/dev/null
    q() { mariadb -N -h "$DAAT_MARIADB_HOST" -P "$DAAT_MARIADB_PORT" -u "$DAAT_MARIADB_USER" -p"$DAAT_MARIADB_PASSWORD" "$DAAT_MARIADB_DATABASE" -e "$1" 2>/dev/null; }

    "$BIN" entity create tag label="Medium B" source=computed >/dev/null
    tag_id=$(q "SELECT id FROM tag WHERE label = 'Medium B';")

    text=$(printf 'Cell suspensions grown in medium B reached %s g/L dry weight. ' $(seq 1 20))
    for n in A B C; do
        "$BIN" entity create document title="Growth run $n" content="$text" >/dev/null
        sid=$(q "SELECT id FROM document WHERE title = 'Growth run $n';")
        q "UPDATE document SET retrieval_count = 3 WHERE id = ${sid};"
        AGENT_TEST_GENERATE_RESPONSES="# Medium B note $n"$'\n\n'"Cell suspensions in medium B reached up to 20 g/L dry weight."$'\1'"PASS" \
            run "$BIN" repair curate
        [ "$status" -eq 0 ]
        nid=$(q "SELECT id FROM document WHERE source_type = 'curated' AND source_id = ${sid};")
        [ -n "$nid" ]
        if [ "$(q "SELECT COUNT(*) FROM document_tag WHERE document = ${nid} AND tag = ${tag_id} AND archived_at IS NULL;")" = "0" ]; then
            "$BIN" entity create document_tag document="$nid" tag="$tag_id" decision=computed score=0.9 >/dev/null
        fi
    done

    AGENT_TEST_GENERATE_RESPONSES=$'# Medium B reference\n\nMedium B gave 20 g/L dry weight [[Medium B note A]].'$'\1'"PASS" \
        run "$BIN" repair synthesize
    [ "$status" -eq 0 ]
    ref_id=$(q "SELECT id FROM document WHERE source_type = 'reference' AND tier = 2;")
    [ -n "$ref_id" ]

    claim=$'CLAIM: Medium B reaches 20 g/L dry weight\nTEXT: Cell suspensions in medium B reached up to 20 g/L dry weight.\nNOTES: Medium B note A'
    AGENT_TEST_GENERATE_RESPONSES="${claim}"$'\1'"1: PASS" \
        run "$BIN" repair distill
    [ "$status" -eq 0 ]
    [ "$(q "SELECT COUNT(*) FROM document WHERE source_type = 'record' AND tier = 3 AND source_ref = 'reference:${ref_id}';")" = "1" ]

    run "$BIN" store verify
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Store verification passed (0 violations)." ]]
}
