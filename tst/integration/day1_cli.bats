#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
}

teardown() {
    cleanup_test_env
}

@test "daat --help and daat <cmd> --help work for every command before daat init" {
    [ ! -d ".store" ]

    run "$BIN" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Setup & Local Development:" ]]
    [[ "$output" =~ "Knowledge Pool & Maintenance:" ]]
    [[ "$output" =~ "run-pending" ]]
    [[ "$output" =~ "serve" ]]

    for cmd in init config status doctor serve user api-key schema entity ledger view extension document knowledge tag agent run-pending repair store; do
        run "$BIN" "$cmd" --help
        [ "$status" -eq 0 ]
        [[ "$output" =~ "Usage: daat" ]]
    done
}

@test "daat init prints guided next steps for both empty and --with-examples installs" {
    run "$BIN" init
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Initialized store at" ]]
    [[ "$output" =~ "Next steps:" ]]
    [[ "$output" =~ "daat user add admin" ]]
    [[ "$output" =~ "daat serve" ]]

    cleanup_test_env
    setup_test_env
    rm -f config.lua theme.lua
    run "$BIN" init --with-examples
    [ "$status" -eq 0 ]
    [[ "$output" =~ "daat view approve widgets-in-stock" ]]
    [[ "$output" =~ "daat extension approve widget-quantity-range" ]]
}

@test "daat run-pending drains queued embeddings, deferred reviews, curations, extensions, and --prune" {
    write_config 'knowledge = {embedding_quiet_minutes = 0, search_review_mode = "deferred"}'
    "$BIN" init >/dev/null
    export AGENT_TEST_EMBEDDINGS=terms

    # Queue an unembedded document and a deferred search retrieval.
    "$BIN" entity create document title="Protocol A" content="Bioreactor inoculation protocol for cacao suspension" >/dev/null
    db "DELETE FROM document_embedding; INSERT INTO document_embedding_due (document_id, queued_at) VALUES (1, '2020-01-01 00:00:00');"

    read session csrf < <(login_test_user "alice" "ia")
    raw_get "/documents" "q=inoculation" "session=${session}; csrf=${csrf}" >/dev/null
    [ "$(db "SELECT COUNT(*) FROM knowledge_retrieval WHERE reviewed_at IS NULL;")" -ge 1 ]

    run "$BIN" run-pending --prune
    [ "$status" -eq 0 ]
    [[ "$output" =~ "extensions: ran 0, failed 0" ]]
    [[ "$output" =~ "embeddings: embedded 1" ]]
    [[ "$output" =~ "reviews:" ]]
    [[ "$output" =~ "Retention strategy:" ]]

    [ "$(db "SELECT COUNT(*) FROM document_embedding;")" -eq 1 ]
    [ "$(db "SELECT COUNT(*) FROM knowledge_retrieval WHERE reviewed_at IS NULL;")" -eq 0 ]
}

@test "daat serve serves real HTTP requests over localhost via CGI" {
    "$BIN" init >/dev/null
    "$BIN" user add admin secret123 isa >/dev/null

    port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
    "$BIN" serve --host 127.0.0.1 --port "$port" --once >"$TEST_DIR/serve.log" 2>&1 &
    srv_pid=$!

    for _ in $(seq 1 30); do
        if grep -q "Serving Daat at" "$TEST_DIR/serve.log" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done

    resp=$(curl -sS -i "http://127.0.0.1:${port}/login")
    wait "$srv_pid"
    [[ "$resp" =~ "HTTP/1.0 200 OK" || "$resp" =~ "HTTP/1.1 200 OK" ]]
    [[ "$resp" =~ "Log in" ]]
}
