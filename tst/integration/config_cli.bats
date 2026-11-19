#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
}

teardown() {
    cleanup_test_env
}

@test "daat config check and show work before daat init" {
    [ ! -d ".store" ]

    run "$BIN" config check
    [ "$status" -eq 0 ]
    [[ "$output" =~ "config.lua: present" ]]
    [[ "$output" =~ "OK (0 warning(s))" ]]

    run "$BIN" config show
    [ "$status" -eq 0 ]
    [[ "$output" =~ "[database]" ]]
    [[ "$output" =~ "[agent]" ]]
    [[ "$output" =~ "(config.lua)" ]]
    [[ "$output" =~ "(default)" ]]

    run "$BIN" config show --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.sections.agent.provider.value')" = "test" ]
    [ "$(printf '%s' "$output" | jq -r '.sections.agent.provider.source')" = "config.lua" ]
    [ "$(printf '%s' "$output" | jq -r '.sections.database.backend.value')" = "sqlite" ]
    [ "$(printf '%s' "$output" | jq -r '.sections.database.backend.source')" = "default" ]
}

@test "daat config check fails with actionable guidance on misplaced flat keys, typos, and secrets" {
    cat > config.lua <<'EOF'
return {
    agent_provider = "ollama",
    database = {
        backend = "sqlite",
        password = "secret-in-file",
    },
    agent = {
        max_turn = 10,
    },
}
EOF

    run "$BIN" config check
    [ "$status" -eq 1 ]
    [[ "$output" =~ "move it under 'agent.provider'" ]]
    [[ "$output" =~ "DAAT_MARIADB_PASSWORD" ]]
    [[ "$output" =~ "did you mean 'agent.max_turns'?" ]]

    run "$BIN" config check --json
    [ "$status" -eq 1 ]
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "false" ]
    [ "$(printf '%s' "$output" | jq '.errors | length')" -eq 3 ]
}

@test "init --with-examples generates a config.lua and theme.lua that pass daat config check" {
    rm -f config.lua theme.lua
    run "$BIN" init --with-examples
    [ "$status" -eq 0 ]

    run "$BIN" config check
    [ "$status" -eq 0 ]
    [[ "$output" =~ "config.lua: present" ]]
    [[ "$output" =~ "theme.lua:  present" ]]
    [[ "$output" =~ "OK (0 warning(s))" ]]
}
