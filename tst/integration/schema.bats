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

@test "a field removed from a schema file stops being a field, but its column and data stay" {
    write_reagent_schema
    "$BIN" schema add schemas/reagent.lua
    "$BIN" entity create reagent lot_number=L1 concentration=5 >/dev/null

    cat > schemas/reagent.lua <<'SCHEMA'
return {
  name = "reagent",
  fields = {
    {name = "lot_number", type = "text", required = true},
  },
}
SCHEMA
    run "$BIN" schema add schemas/reagent.lua
    [ "$status" -eq 0 ]

    run sqlite3 .store/store.db "SELECT name FROM entity_field WHERE entity_type = 'reagent' ORDER BY field_order;"
    [ "$output" = "lot_number" ]
    # Retiring a field hides it; nothing is deleted.
    run sqlite3 .store/store.db "SELECT concentration FROM reagent WHERE lot_number = 'L1';"
    [ "$output" = "5.0" ]
    # Creating without the retired field works (it was required before).
    run "$BIN" entity create reagent lot_number=L2
    [[ "$output" =~ "Created reagent" ]]
}

@test "concurrent schema sync across processes never persists empty enum_values for dropdown fields" {
    mkdir -p dropdowns schemas
    cat > dropdowns/tissue.lua <<'EOF'
return {
  name = "tissue",
  values = {"leaf", "callus", "suspension", "embryo"},
}
EOF
    cat > schemas/culture.lua <<'EOF'
return {
  name = "culture",
  fields = {
    {name = "code", type = "text", required = true},
    {name = "tissue_type", type = "select", required = true, dropdown = "tissue"},
  },
}
EOF

    pids=()
    for _ in $(seq 1 8); do
        "$BIN" schema sync &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    enum_val=$(sqlite3 .store/store.db "SELECT enum_values FROM entity_field WHERE entity_type = 'culture' AND name = 'tissue_type';")
    [[ "$enum_val" =~ "leaf" ]]
    [[ "$enum_val" =~ "embryo" ]]
    [ "$enum_val" != "[]" ]
}

@test "entity update allows editing unrelated fields on legacy rows after retiring dropdown values or adding required=true" {
    mkdir -p dropdowns schemas
    cat > dropdowns/stage.lua <<'EOF'
return {
  name = "stage",
  values = {"legacy_stage", "active_stage"},
}
EOF
    cat > schemas/batch_run.lua <<'EOF'
return {
  name = "batch_run",
  fields = {
    {name = "code", type = "text", required = true},
    {name = "stage", type = "select", required = true, dropdown = "stage"},
    {name = "notes", type = "text", required = false},
  },
}
EOF
    "$BIN" schema sync
    bid=$("$BIN" entity create batch_run code=B-01 stage=legacy_stage notes=initial | grep -o '[0-9]\+')

    # Retire legacy_stage and add a brand-new required field operator_name
    cat > dropdowns/stage.lua <<'EOF'
return {
  name = "stage",
  values = {"active_stage"},
}
EOF
    cat > schemas/batch_run.lua <<'EOF'
return {
  name = "batch_run",
  fields = {
    {name = "code", type = "text", required = true},
    {name = "stage", type = "select", required = true, dropdown = "stage"},
    {name = "operator_name", type = "text", required = true},
    {name = "notes", type = "text", required = false},
  },
}
EOF
    "$BIN" schema sync

    # Editing notes on the legacy row succeeds without forcing stage/operator_name backfill
    run "$BIN" entity update batch_run "$bid" notes="checked-ok"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Updated batch_run" ]]

    # Clearing an already-populated required field (code) or setting a new invalid enum value still fails
    run "$BIN" entity update batch_run "$bid" code=""
    [[ "$output" =~ "required field is missing" ]]

    run "$BIN" entity update batch_run "$bid" stage="brand_new_bogus"
    [[ "$output" =~ "must be one of the declared values" ]]
}

@test "changing multi_select to multi_reference recreates an empty junction table and refuses a populated one" {
    mkdir -p schemas
    cat > schemas/tag_target.lua <<'EOF'
return {name = "tag_target", fields = {{name = "label", type = "text", required = true}}}
EOF
    cat > schemas/item_box.lua <<'EOF'
return {
  name = "item_box",
  fields = {
    {name = "code", type = "text", required = true},
    {name = "markers", type = "multi_select", values = {"a", "b"}},
  },
}
EOF
    "$BIN" schema sync

    # Empty companion table -> converting multi_select to multi_reference succeeds cleanly
    cat > schemas/item_box.lua <<'EOF'
return {
  name = "item_box",
  fields = {
    {name = "code", type = "text", required = true},
    {name = "markers", type = "multi_reference", entity_type = "tag_target"},
  },
}
EOF
    run "$BIN" schema sync
    [ "$status" -eq 0 ]

    tid=$("$BIN" entity create tag_target label="T1" | grep -o '[0-9]\+')
    "$BIN" entity create item_box code="BOX-1" markers="$tid" >/dev/null

    # Populated companion table -> incompatible switch back to multi_select is refused clearly
    cat > schemas/item_box.lua <<'EOF'
return {
  name = "item_box",
  fields = {
    {name = "code", type = "text", required = true},
    {name = "markers", type = "multi_select", values = {"a", "b"}},
  },
}
EOF
    run "$BIN" schema sync
    [[ "$output" =~ "cannot change multivalue field" ]]
}
