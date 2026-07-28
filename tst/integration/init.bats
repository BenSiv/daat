#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
}

teardown() {
    cleanup_test_env
}

@test "a plain init stays truly empty -- no seed content, no theme.lua (task #101)" {
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

@test "init --with-examples writes one example of each kind plus theme.lua/platform.lua" {
    # setup_test_env's own write_platform_config already seeded a
    # minimal platform.lua (agent_provider = "test", for the
    # deterministic test provider) -- remove it first so this test
    # exercises examples.write_all's real platform.lua stub, not the
    # harness's own scaffolding file.
    rm -f platform.lua

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
    [ -f platform.lua ]
    run cat platform.lua
    [[ "$output" =~ "-- agent_provider" ]]

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
    rm -f platform.lua

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
    [[ "$output" =~ "collides with a builtin column" ]]
    [[ ! "$output" =~ "Registered" ]]
}
