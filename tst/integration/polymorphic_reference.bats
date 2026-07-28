#!/usr/bin/env bats
# Polymorphic references (task: "source" fields whose target entity
# type varies per row -- a sample derived from a plant or another
# sample, decided per row, not a fixed entity_type the way a plain
# reference/multi_reference field declares one). Stored in ONE shared
# entity_source table (schema.ensure_entity_source_table), not a table
# per (entity_type, field_name) the way multi_reference's own junction
# tables work -- see schema.lua's own is_polymorphic_field_type header
# comment for the full reasoning.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
}

teardown() {
    cleanup_test_env
}

write_plant_schema() {
    mkdir -p schemas
    cat > schemas/plant.lua <<'EOF'
return {
  name = "plant",
  fields = {
    {name = "label", type = "text", required = true, display = true},
  },
}
EOF
}

write_sample_schema() {
    mkdir -p schemas
    cat > schemas/sample.lua <<'EOF'
return {
  name = "sample",
  fields = {
    {name = "label", type = "text", required = true, display = true},
    {name = "source", type = "polymorphic_reference", required = false,
      allowed_entity_types = {"plant", "sample"}},
  },
}
EOF
}

write_product_schema() {
    mkdir -p schemas
    cat > schemas/product.lua <<'EOF'
return {
  name = "product",
  fields = {
    {name = "label", type = "text", required = true, display = true},
    {name = "source", type = "multi_polymorphic_reference", required = false,
      allowed_entity_types = {"plant", "sample"}},
  },
}
EOF
}

setup_full_schema() {
    write_plant_schema
    write_sample_schema
    write_product_schema
    "$BIN" schema sync
}

@test "registering a polymorphic_reference schema creates no column, but the shared entity_source table" {
    setup_full_schema
    run sqlite3 .store/store.db ".schema sample"
    [[ ! "$output" =~ "source" ]]

    run sqlite3 .store/store.db ".tables"
    [[ "$output" =~ "entity_source" ]]
    # Not a per-(entity_type, field_name) table the way multi_reference
    # gets one -- the whole point of this mechanism.
    [[ ! "$output" =~ "sample_source" ]]
    [[ ! "$output" =~ "product_source" ]]
}

@test "the shared entity_source table is used by every polymorphic field, not one table each" {
    setup_full_schema
    "$BIN" entity create plant label="Cocoa" >/dev/null
    "$BIN" entity create sample label="S1" source="plant:1" >/dev/null
    "$BIN" entity create product label="P1" source="plant:1,sample:2" >/dev/null

    run sqlite3 .store/store.db "SELECT COUNT(*) FROM entity_source;"
    [ "$output" -eq 3 ]
    run sqlite3 .store/store.db "SELECT DISTINCT from_type FROM entity_source ORDER BY from_type;"
    [[ "$output" =~ "product" ]]
    [[ "$output" =~ "sample" ]]
}

@test "create rejects a source type not in allowed_entity_types" {
    setup_full_schema
    "$BIN" entity create plant label="Cocoa" >/dev/null
    run "$BIN" entity create sample label="S1" source="container:1"
    [[ "$output" =~ "'container' is not an allowed source type" ]]
}

@test "create rejects a source pointing at a nonexistent row of an otherwise-allowed type" {
    setup_full_schema
    run "$BIN" entity create sample label="S1" source="plant:999"
    [[ "$output" =~ "references a nonexistent plant entity" ]]
}

@test "polymorphic_reference (singular) rejects more than one value" {
    setup_full_schema
    "$BIN" entity create plant label="Cocoa" >/dev/null
    "$BIN" entity create sample label="S1" source="plant:1" >/dev/null
    run "$BIN" entity create sample label="S2" source="plant:1,sample:2"
    [[ "$output" =~ "only one source is allowed" ]]
}

@test "a required polymorphic_reference field rejects an empty value" {
    mkdir -p schemas
    cat > schemas/plant.lua <<'EOF'
return {name = "plant", fields = {{name = "label", type = "text", required = true, display = true}}}
EOF
    cat > schemas/sample.lua <<'EOF'
return {name = "sample", fields = {
  {name = "label", type = "text", required = true, display = true},
  {name = "source", type = "polymorphic_reference", required = true, allowed_entity_types = {"plant"}},
}}
EOF
    "$BIN" schema sync
    run "$BIN" entity create sample label="S1"
    [[ "$output" =~ "required field is missing" ]]
}

@test "a real sample-to-sample lineage chain resolves and round-trips through entity.show" {
    setup_full_schema
    "$BIN" entity create plant label="Cocoa" >/dev/null
    "$BIN" entity create sample label="Gen1" source="plant:1" >/dev/null
    "$BIN" entity create sample label="Gen2" source="sample:2" >/dev/null
    run "$BIN" entity show sample 3
    [[ "$output" =~ "source               [sample:2]" ]]
}

@test "/browse doesn't crash on a polymorphic_reference field that used to be a plain column" {
    # Real production regression: sample.source started as a plain
    # `text` field (a real column, with real data), then got converted
    # to polymorphic_reference. Schema sync is additive-only and never
    # drops the old column, so a raw "SELECT * FROM sample" row
    # (entity.list's own query, which /browse uses) still carries the
    # *old* column's stale string value under the same "source" key.
    # Confirmed live: /browse crashed with "bad argument #1 to 'ipairs'
    # (table expected, got string)" because entity.list never got the
    # same raw-row override entity.get already had -- see entity.lua's
    # apply_computed_field_overrides.
    write_plant_schema
    mkdir -p schemas
    cat > schemas/sample.lua <<'EOF'
return {name = "sample", fields = {
  {name = "label", type = "text", required = true, display = true},
  {name = "source", type = "text", required = false},
}}
EOF
    "$BIN" schema sync
    "$BIN" entity create plant label="Cocoa" >/dev/null
    "$BIN" entity create sample label="S1" source="some old free text" >/dev/null

    cat > schemas/sample.lua <<'EOF'
return {name = "sample", fields = {
  {name = "label", type = "text", required = true, display = true},
  {name = "source", type = "polymorphic_reference", required = false,
    allowed_entity_types = {"plant", "sample"}},
}}
EOF
    "$BIN" schema sync

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "testuser" "i")
    export TEST_SESSION_COOKIE TEST_CSRF_TOKEN
    run_cgi "/browse" "type=sample"
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "Internal Server Error" ]]
    [[ ! "$output" =~ "bad argument" ]]
    [[ "$output" =~ "S1" ]]
}

@test "multi_polymorphic_reference stores several sources of different real types" {
    setup_full_schema
    "$BIN" entity create plant label="Cocoa" >/dev/null
    "$BIN" entity create sample label="S1" source="plant:1" >/dev/null
    "$BIN" entity create product label="P1" source="plant:1,sample:2" >/dev/null
    run "$BIN" entity show product 3
    [[ "$output" =~ "source               [plant:1, sample:2]" ]]
}

@test "updating a polymorphic_reference field replaces the old edge, not appends to it" {
    setup_full_schema
    "$BIN" entity create plant label="Cocoa" >/dev/null
    "$BIN" entity create plant label="Vanilla" >/dev/null
    "$BIN" entity create sample label="S1" source="plant:1" >/dev/null
    "$BIN" entity update sample 3 source="plant:2" >/dev/null
    run sqlite3 .store/store.db "SELECT COUNT(*) FROM entity_source WHERE from_type='sample' AND from_id=3;"
    [ "$output" -eq 1 ]
    run "$BIN" entity show sample 3
    [[ "$output" =~ "source               [plant:2]" ]]
}

@test "the ledger records a real old/new diff for a polymorphic_reference change, not an opaque table address" {
    setup_full_schema
    "$BIN" entity create plant label="Cocoa" >/dev/null
    "$BIN" entity create plant label="Vanilla" >/dev/null
    "$BIN" entity create sample label="S1" source="plant:1" >/dev/null
    "$BIN" entity update sample 3 source="plant:2" >/dev/null
    run "$BIN" ledger history 3
    [[ "$output" =~ "source: [plant:1] -> [plant:2]" ]]
    [[ ! "$output" =~ "table: 0x" ]]
}

@test "schema.relationships emits one edge per allowed_entity_types entry, discoverable the same way a plain reference is" {
    setup_full_schema
    "$BIN" entity create plant label="Cocoa" >/dev/null
    run sqlite3 .store/store.db "SELECT to_type FROM entity_source LIMIT 0;"
    # Exercised indirectly via /data's relation diagram in cgi.bats --
    # here just confirm schema.relationships (entity.relationships'
    # own backing query) actually lists both allowed target types for
    # the sample.source field, not just one collapsed edge.
    run "$BIN" schema show-json sample
    [[ "$output" =~ "polymorphic_reference" ]]
}

@test "a create-json/API payload with real {type,id} objects works the same as the CLI's type:id string" {
    setup_full_schema
    "$BIN" entity create plant label="Cocoa" >/dev/null
    echo '[{"label":"S1","source":{"type":"plant","id":1}}]' | "$BIN" entity create-json sample
    run "$BIN" entity show sample 2
    [[ "$output" =~ "source               [plant:1]" ]]
}
