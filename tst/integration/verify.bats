#!/usr/bin/env bats
# CLI integration tests for `daat store verify [--json]`, `daat repair pool-count`,
# and `daat extension run-pending`.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
}

teardown() {
    cleanup_test_env
}

@test "daat store verify and --json succeed with exit 0 on a valid populated store" {
    mkdir -p schemas
    cat > schemas/reagent.lua <<'EOF'
return {
  name = "reagent",
  fields = {
    {name = "code", type = "text", required = true, identifier = true},
    {name = "label", type = "text", required = true, display = true},
  },
}
EOF
    "$BIN" schema add schemas/reagent.lua
    "$BIN" entity create reagent code="RGT-101" label="Sodium Chloride"
    "$BIN" entity create document title="Media Recipe" content="Dissolve RGT-101 in water. See [[Autoclave Guide]]."
    "$BIN" entity create document title="Autoclave Guide" content="Sterilize at 121 C for 20 min."

    run "$BIN" store verify
    [ "$status" -eq 0 ]
    [[ "$output" =~ "L1 pool_thermodynamics: PASS" ]]
    [[ "$output" =~ "L2 ledger_projection:   PASS" ]]
    [[ "$output" =~ "L3 derived_indexes:     PASS" ]]
    [[ "$output" =~ "L4 ontology_and_tiers:  PASS" ]]
    [[ "$output" =~ "Store verification passed (0 violations)." ]]

    run "$BIN" store verify --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
    [ "$(printf '%s' "$output" | jq -r '.violation_count')" = "0" ]
}

@test "daat store verify exits non-zero and names corrupted rows across L1-L4, and repair pool-count + links heal derived drift" {
    d1=$("$BIN" entity create document title="Doc Alpha" content="Links to [[Doc Beta]]." | grep -o '[0-9]\+')
    d2=$("$BIN" entity create document title="Doc Beta" content="Target note." | grep -o '[0-9]\+')

    # Tamper across all 4 invariant families:
    db "UPDATE knowledge_pool_state SET document_count = 42 WHERE id = 1;"
    db "UPDATE document SET title = 'Unledgered Title', parent_id = $d1, tier = 3 WHERE id = $d1;"
    db "DELETE FROM document_link WHERE from_document_id = $d1;"

    run "$BIN" store verify
    [ "$status" -eq 1 ]
    [[ "$output" =~ "pool_count_mismatch" ]]
    [[ "$output" =~ "scalar_field_mismatch" ]]
    [[ "$output" =~ "missing_active_document_link" ]]
    [[ "$output" =~ "document_parent_cycle" ]]
    [[ "$output" =~ "unauthorized_document_tier" ]]

    run "$BIN" store verify --json
    [ "$status" -eq 1 ]
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "false" ]

    # Heal pool_count and document_link via CLI repair commands, and restore the raw SQL tamper
    run "$BIN" repair pool-count
    [ "$status" -eq 0 ]
    [[ "$output" =~ "document_count resynced to 2" ]]

    run "$BIN" repair links --all
    [ "$status" -eq 0 ]
    db "UPDATE document SET title = 'Doc Alpha', parent_id = NULL, tier = 0 WHERE id = $d1;"

    run "$BIN" store verify
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Store verification passed (0 violations)." ]]
}

@test "daat extension run-pending executes approved entity.after_create jobs and keeps store laws intact" {
    mkdir -p schemas extensions/after-logger
    cat > schemas/batch.lua <<'EOF'
return {
  name = "batch",
  fields = {
    {name = "code", type = "text", required = true},
    {name = "status", type = "text", required = false},
  },
}
EOF
    "$BIN" schema add schemas/batch.lua

    cat > extensions/after-logger/manifest.lua <<'EOF'
return {
    name = "after-logger",
    events = {"entity.after_create"},
    entity_types = {"batch"},
    capabilities = {
        read = {"entity"},
        write = {"entity"},
        net = "none",
    },
}
EOF
    cat > extensions/after-logger/main.lua <<'EOF'
function handle_after_create(new_values, old_values, ctx)
    if new_values.code == "FAIL-ME" then
        error("deliberate failure")
    end
    rows = ctx.query("batch", {code = new_values.code})
    ctx.update_entity("batch", rows[1].id, {status = "processed"})
    return {}
end

return {
    on_after = handle_after_create,
}
EOF
    "$BIN" extension approve after-logger
    b1=$("$BIN" entity create batch code="B-01" | grep -o '[0-9]\+')
    b2=$("$BIN" entity create batch code="FAIL-ME" | grep -o '[0-9]\+')

    run "$BIN" extension run-pending
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Ran 1, failed 1" ]]

    run "$BIN" entity show batch "$b1"
    [[ "$output" =~ "processed" ]]

    run "$BIN" store verify
    [ "$status" -eq 0 ]
}
