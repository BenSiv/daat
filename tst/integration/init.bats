#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
}

teardown() {
    cleanup_test_env
}

@test "a plain init stays truly empty -- no seed content, no theme.lua" {
    run "$BIN" init
    [[ "$output" =~ "Initialized store at" ]]
    [ -d schemas ]
    [ -d extensions ]
    [ -d views ]
    [ -d templates ]
    [ -z "$(ls -A schemas)" ]
    [ -z "$(ls -A extensions)" ]
    [ -z "$(ls -A views)" ]
    [ -z "$(ls -A templates)" ]
    [ ! -f theme.lua ]
}

@test "init --with-examples writes one example of each kind plus theme.lua/config.lua" {
    # setup_test_env's own write_config already seeded a
    # minimal config.lua (agent_provider = "test", for the
    # deterministic test provider) -- remove it first so this test
    # exercises examples.write_all's real config.lua stub, not the
    # harness's own scaffolding file.
    rm -f config.lua

    run "$BIN" init --with-examples
    [[ "$output" =~ "Initialized store at" ]]
    [[ "$output" =~ "Wrote 8 example file(s)" ]]

    [ -f schemas/category.lua ]
    [ -f schemas/widget.lua ]
    [ -f views/widgets-in-stock.lua ]
    [ -f templates/widget-intake.lua ]
    [ -f extensions/widget-quantity-range/manifest.lua ]
    [ -f extensions/widget-quantity-range/main.lua ]
    [ -f theme.lua ]
    [ -f config.lua ]
    run cat config.lua
    [[ "$output" =~ "-- provider = \"ollama\"" ]]
    [[ "$output" =~ "-- model = \"qwen3:8b\"" ]]

    # The generated content is real, working config-as-code, not just
    # placeholder text -- both example schemas register successfully.
    run "$BIN" schema add schemas/category.lua
    [[ "$output" =~ "Registered entity type 'category'" ]]
    run "$BIN" schema add schemas/widget.lua
    [[ "$output" =~ "Registered entity type 'widget'" ]]

    run "$BIN" entity create category label="Fasteners"
    [[ "$output" =~ "Created category" ]]
    run "$BIN" entity create widget label="Bolt M6" quantity=100 status=in_stock category=1
    [[ "$output" =~ "Created widget" ]]

    run "$BIN" view approve widgets-in-stock
    [[ "$output" =~ "Approved 'widgets-in-stock'" ]]

    run "$BIN" extension approve widget-quantity-range
    [[ "$output" =~ "Approved 'widget-quantity-range'" ]]
    run "$BIN" entity create widget label="Bad Bolt" quantity=-5 status=pending
    [[ "$output" =~ "quantity cannot be negative" ]]
}

@test "init --with-examples on an already-initialized store is additive, and re-running it is a safe no-op" {
    "$BIN" init
    [ -z "$(ls -A schemas)" ]

    # Same harness-scaffolding removal as the previous test -- see its
    # own comment.
    rm -f config.lua

    run "$BIN" init --with-examples
    [[ "$output" =~ "Already initialized" ]]
    [[ "$output" =~ "Wrote 8 example file(s)" ]]
    [ -f schemas/widget.lua ]

    # Delete one example, keep the rest -- re-running only replaces
    # what's actually missing, never clobbers what's already there.
    echo "-- a real user's own edit, must survive" > schemas/category.lua
    rm views/widgets-in-stock.lua

    run "$BIN" init --with-examples
    [[ "$output" =~ "Wrote 1 example file(s)" ]]
    [ -f views/widgets-in-stock.lua ]
    run cat schemas/category.lua
    [[ "$output" =~ "a real user's own edit, must survive" ]]
}

@test "a schema field named the same as a builtin column is rejected with a clear error" {
    "$BIN" init
    mkdir -p schemas
    cat > schemas/bad.lua <<'EOF'
return { name = "bad", fields = { {name = "name", type = "text"} } }
EOF
    run "$BIN" schema add schemas/bad.lua
    [ "$status" -eq 1 ]
    [[ "$output" =~ "collides with a builtin column" ]]
    [[ ! "$output" =~ "Registered" ]]
}

@test "daat schema add rejects SQL reserved-word and internal table names cleanly, while allowing reserved-word fields (#65)" {
    "$BIN" init
    mkdir -p schemas

    for bad_type in order release auth_user; do
        cat > "schemas/${bad_type}.lua" <<EOF
return { name = "${bad_type}", fields = { {name = "label", type = "text", required = true, display = true} } }
EOF
        run "$BIN" schema add "schemas/${bad_type}.lua"
        [ "$status" -eq 1 ]
        [[ ! "$output" =~ "stack traceback" ]]
        [[ ! "$output" =~ "Registered" ]]
        rm -f "schemas/${bad_type}.lua"
    done

    cat > schemas/order.lua <<'EOF'
return { name = "order", fields = { {name = "label", type = "text"} } }
EOF
    run "$BIN" schema add schemas/order.lua
    [ "$status" -eq 1 ]
    [[ "$output" =~ "is a reserved SQL word" ]]
    rm -f schemas/order.lua

    # Reserved SQL words as field names (`usage`, `order`, `release`) work end-to-end via db.quote_ident.
    cat > schemas/step_spec.lua <<'EOF'
return {
    name = "step_spec",
    fields = {
        {name = "release", type = "text", required = true, display = true},
        {name = "order", type = "number", required = true},
        {name = "usage", type = "multi_select", required = false, values = {"seed", "prod"}},
    },
}
EOF
    run "$BIN" schema add schemas/step_spec.lua
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Registered entity type 'step_spec'" ]]

    run "$BIN" entity create step_spec release="R-1" order=1 usage="seed,prod"
    [ "$status" -eq 0 ]
    spec_id=$("$BIN" entity list step_spec | head -1 | tr -d '#')
    [ -n "$spec_id" ]
    run "$BIN" entity update step_spec "$spec_id" order=2
    [ "$status" -eq 0 ]
    run "$BIN" entity show step_spec "$spec_id"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "R-1" ]]
    [[ "$output" =~ "prod" ]]
    [[ "$output" =~ "seed" ]]
}

@test "CLI exits non-zero on unknown commands, missing init, and --help exits zero" {
    run "$BIN" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Usage: daat" ]]

    run "$BIN"
    [ "$status" -eq 1 ]

    run "$BIN" not-a-command
    [ "$status" -eq 1 ]
    [[ "$output" =~ "not a valid command" ]]

    run "$BIN" user list
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Not initialized" ]]
}
