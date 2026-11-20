#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    mkdir -p views
    cat > views/samples.lua <<'EOF'
return {
  name = "samples",
  title = "All samples",
  sql = "SELECT id FROM sqlite_master WHERE type = 'table' LIMIT 5;",
  columns = {
    {name = "id", label = "ID"},
  },
}
EOF
}

teardown() {
    cleanup_test_env
}

@test "view list shows an unapproved view" {
    run "$BIN" view list
    [ "$status" -eq 0 ]
    [[ "$output" =~ "samples" ]]
    [[ "$output" =~ "not approved" ]]
}

@test "view approve marks a view approved" {
    "$BIN" view approve samples
    run "$BIN" view show samples
    [[ "$output" =~ "status: approved" ]]
}

@test "view revoke unapproves a previously approved view" {
    "$BIN" view approve samples
    "$BIN" view revoke samples
    run "$BIN" view show samples
    [[ "$output" =~ "status: not approved" ]]
}

@test "editing an approved view's sql requires re-approval" {
    "$BIN" view approve samples
    cat > views/samples.lua <<'EOF'
return {
  name = "samples",
  title = "All samples",
  sql = "SELECT id FROM sqlite_master WHERE type = 'table' LIMIT 10;",
  columns = {
    {name = "id", label = "ID"},
  },
}
EOF
    run "$BIN" view show samples
    [[ "$output" =~ "NOT APPROVED" ]]
}

@test "a view with sql_mariadb still runs its plain sql on a SQLite deployment" {
    cat > views/dual.lua <<'EOF'
return {
  name = "dual",
  title = "Dual-backend",
  sql = "SELECT name AS id FROM sqlite_master WHERE type = 'table' LIMIT 3;",
  sql_mariadb = "SELECT id FROM some_table_that_does_not_exist;",
  columns = {
    {name = "id", label = "ID"},
  },
}
EOF
    "$BIN" view approve dual
    run "$BIN" view show dual
    [[ "$output" =~ "status: approved" ]]
    [[ "$output" =~ "sql_mariadb: SELECT id FROM some_table_that_does_not_exist;" ]]

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "dualuser" "is")
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/view" QUERY_STRING="view_name=dual" \
        HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" run "$BIN"
    [[ "$output" =~ "200 OK" ]]
    [[ ! "$output" =~ "Internal Server Error" ]]
}

@test "editing only sql_mariadb (sql unchanged) still invalidates approval" {
    cat > views/dual.lua <<'EOF'
return {
  name = "dual",
  title = "Dual-backend",
  sql = "SELECT name AS id FROM sqlite_master WHERE type = 'table' LIMIT 3;",
  sql_mariadb = "SELECT id FROM t1;",
  columns = {
    {name = "id", label = "ID"},
  },
}
EOF
    "$BIN" view approve dual
    run "$BIN" view show dual
    [[ "$output" =~ "status: approved" ]]

    cat > views/dual.lua <<'EOF'
return {
  name = "dual",
  title = "Dual-backend",
  sql = "SELECT name AS id FROM sqlite_master WHERE type = 'table' LIMIT 3;",
  sql_mariadb = "SELECT id FROM t2;",
  columns = {
    {name = "id", label = "ID"},
  },
}
EOF
    run "$BIN" view show dual
    [[ "$output" =~ "NOT APPROVED" ]]
}

@test "view add rejects sql with a stacked statement" {
    mkdir -p views
    cat > views/evil.lua <<'EOF'
return {
  name = "evil",
  title = "Evil",
  sql = "SELECT id FROM sqlite_master; DROP TABLE entity_field;",
  columns = {
    {name = "id", label = "ID"},
  },
}
EOF
    run "$BIN" view show evil
    [[ "$output" =~ "Error" ]]
}

@test "view add rejects a stacked statement in sql_mariadb too, not just sql" {
    mkdir -p views
    cat > views/evil2.lua <<'EOF'
return {
  name = "evil2",
  title = "Evil2",
  sql = "SELECT id FROM sqlite_master;",
  sql_mariadb = "SELECT id FROM t1; DROP TABLE entity_field;",
  columns = {
    {name = "id", label = "ID"},
  },
}
EOF
    run "$BIN" view show evil2
    [[ "$output" =~ "Error" ]]
}
