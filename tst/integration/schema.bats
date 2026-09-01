#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
}

teardown() {
    cleanup_test_env
}

write_reagent_schema() {
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
}

@test "schema add registers a well-formed schema" {
    write_reagent_schema
    run "$BIN" schema add schemas/reagent.lua
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Registered entity type 'reagent'" ]]
}

@test "schema list shows a registered type" {
    write_reagent_schema
    "$BIN" schema add schemas/reagent.lua

    run "$BIN" schema list
    [ "$status" -eq 0 ]
    [[ "$output" =~ "reagent" ]]
}

@test "schema add rejects a select field with no values" {
    mkdir -p schemas
    cat > schemas/bad.lua <<'EOF'
return {
  name = "bad",
  fields = {
    {name = "status", type = "select"},
  },
}
EOF
    run "$BIN" schema add schemas/bad.lua
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Error" ]]

    run "$BIN" schema list
    [[ ! "$output" =~ "bad" ]]
}

@test "schema add rejects an unrecognized field type" {
    mkdir -p schemas
    cat > schemas/bad_type.lua <<'EOF'
return {
  name = "bad_type",
  fields = {
    {name = "priority", type = "integer"},
  },
}
EOF
    run "$BIN" schema add schemas/bad_type.lua
    [[ "$output" =~ "Error" ]]
}

@test "schema sync registers files in any filesystem order, not just dependency order" {
    # Real incident, 2026-09-01: a from-scratch sync failed because
    # lfs.dir's order isn't dependency order -- a multi_reference field's
    # junction table needs the referenced type's own table to already
    # exist. Named so the referencing file alphabetically (and by
    # creation time, in case a filesystem's readdir happens to follow
    # either) sorts before the type it references, to reproduce the
    # failure mode this test guards against rather than accidentally
    # passing either order.
    mkdir -p schemas
    cat > schemas/aaa_junction.lua <<'EOF'
return {
  name = "junction",
  fields = {
    {name = "targets", type = "multi_reference", entity_type = "target"},
  },
}
EOF
    cat > schemas/zzz_target.lua <<'EOF'
return {
  name = "target",
  fields = {
    {name = "label", type = "text"},
  },
}
EOF
    run "$BIN" schema sync
    [ "$status" -eq 0 ]

    run "$BIN" schema list
    [[ "$output" =~ "junction" ]]
    [[ "$output" =~ "target" ]]
}
