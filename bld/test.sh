#!/usr/bin/env bash
set -euo pipefail

# Run this project's test suite: Luam unit tests (tst/unit/*.lua,
# standalone scripts that exit non-zero on failure) plus bats
# integration/CGI tests (tst/integration/*.bats, exercising the real
# built binary end to end -- see tst/integration/test_helper.bash).
# Mirrors luametry/brain-ex's own bld/test.sh + tst/*.bats
# conventions.
#
# Requires `bats` on PATH (apt install bats / brew install bats-core) and
# a built luam checkout the same way bld/build.sh does.
#
# MariaDB integration tests run deterministically by default: if no test
# server is already listening on MARIADB_TEST_HOST:MARIADB_TEST_PORT, an
# isolated ephemeral `mariadbd` is started in a temp directory on a free
# localhost port and torn down on EXIT. Set DAAT_SKIP_MARIADB=1 to opt out.

cd "$(dirname "$0")/.."

if [ -z "${LUAM_DIR:-}" ]; then
    LUAM_DIR=$(cd ../luam && pwd)
fi
export LUAM_DIR

if ! command -v bats > /dev/null 2>&1; then
    echo "Error: bats not found on PATH. Install it (e.g. apt install bats) to run tst/integration/*.bats." >&2
    exit 1
fi

MARIADB_EPHEMERAL_DIR=""
MARIADB_EPHEMERAL_PID=""
EVAL_EPHEMERAL_DIR=""

cleanup_ephemeral_mariadb() {
    if [ -n "$MARIADB_EPHEMERAL_PID" ]; then
        kill "$MARIADB_EPHEMERAL_PID" >/dev/null 2>&1 || true
        wait "$MARIADB_EPHEMERAL_PID" 2>/dev/null || true
    fi
    if [ -n "$MARIADB_EPHEMERAL_DIR" ] && [ -d "$MARIADB_EPHEMERAL_DIR" ]; then
        rm -rf "$MARIADB_EPHEMERAL_DIR"
    fi
    if [ -n "$EVAL_EPHEMERAL_DIR" ] && [ -d "$EVAL_EPHEMERAL_DIR" ]; then
        rm -rf "$EVAL_EPHEMERAL_DIR"
    fi
}
trap cleanup_ephemeral_mariadb EXIT

ensure_mariadb_test_server() {
    if [ "${DAAT_SKIP_MARIADB:-0}" = "1" ]; then
        echo "Skipping MariaDB setup (DAAT_SKIP_MARIADB=1)"
        return
    fi

    local host="${MARIADB_TEST_HOST:-127.0.0.1}"
    local port="${MARIADB_TEST_PORT:-3306}"
    local user="${MARIADB_TEST_USER:-platform_test}"
    local pass="${MARIADB_TEST_PASSWORD:-platform_test_pw}"

    if command -v mariadb >/dev/null 2>&1 && \
       mariadb -h "$host" -P "$port" -u "$user" -p"$pass" -e "SELECT 1;" >/dev/null 2>&1; then
        echo "Using reachable MariaDB test server at ${host}:${port}"
        export MARIADB_TEST_HOST="$host"
        export MARIADB_TEST_PORT="$port"
        export MARIADB_TEST_USER="$user"
        export MARIADB_TEST_PASSWORD="$pass"
        export DAAT_REQUIRE_MARIADB=1
        return
    fi

    local mariadbd_bin=""
    if command -v mariadbd >/dev/null 2>&1; then
        mariadbd_bin="$(command -v mariadbd)"
    elif [ -x /usr/sbin/mariadbd ]; then
        mariadbd_bin="/usr/sbin/mariadbd"
    fi

    if [ -z "$mariadbd_bin" ] || ! command -v mariadb-install-db >/dev/null 2>&1 || ! command -v mariadb >/dev/null 2>&1; then
        echo "Error: MariaDB server binaries (mariadbd, mariadb-install-db, mariadb) are required for full test coverage." >&2
        echo "Install mariadb-server or explicitly set DAAT_SKIP_MARIADB=1 to skip MariaDB tests." >&2
        exit 1
    fi

    MARIADB_EPHEMERAL_DIR="$(mktemp -d)"
    local datadir="${MARIADB_EPHEMERAL_DIR}/data"
    local sock="${MARIADB_EPHEMERAL_DIR}/mysql.sock"
    local pidfile="${MARIADB_EPHEMERAL_DIR}/mysql.pid"
    local logfile="${MARIADB_EPHEMERAL_DIR}/mariadbd.log"
    local eph_port
    eph_port="$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1]); s.close()")"

    mkdir -p "$datadir"
    local run_user_arg=()
    if [ "$(id -u)" -eq 0 ] && id mysql >/dev/null 2>&1; then
        chown -R mysql:mysql "$MARIADB_EPHEMERAL_DIR"
        run_user_arg=(--user=mysql)
    fi

    echo "Starting ephemeral MariaDB on 127.0.0.1:${eph_port}"
    mariadb-install-db "${run_user_arg[@]}" --datadir="$datadir" --auth-root-authentication-method=normal >/dev/null 2>&1
    "$mariadbd_bin" --no-defaults "${run_user_arg[@]}" \
        --datadir="$datadir" \
        --socket="$sock" \
        --pid-file="$pidfile" \
        --bind-address=127.0.0.1 \
        --port="$eph_port" \
        --skip-networking=0 \
        --log-error="$logfile" >/dev/null 2>&1 &
    MARIADB_EPHEMERAL_PID="$!"

    local ready=0
    for _ in $(seq 1 60); do
        if mariadb --socket="$sock" -u root -e "SELECT 1;" >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 0.25
    done
    if [ "$ready" -ne 1 ]; then
        echo "Error: ephemeral mariadbd failed to start (log at $logfile):" >&2
        cat "$logfile" >&2 || true
        exit 1
    fi

    mariadb --socket="$sock" -u root -e "
        CREATE USER IF NOT EXISTS '${user}'@'127.0.0.1' IDENTIFIED BY '${pass}';
        CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${pass}';
        GRANT ALL PRIVILEGES ON *.* TO '${user}'@'127.0.0.1';
        GRANT ALL PRIVILEGES ON *.* TO '${user}'@'localhost';
        FLUSH PRIVILEGES;
    "

    export MARIADB_TEST_HOST="127.0.0.1"
    export MARIADB_TEST_PORT="$eph_port"
    export MARIADB_TEST_USER="$user"
    export MARIADB_TEST_PASSWORD="$pass"
    export DAAT_REQUIRE_MARIADB=1
}

echo "Building"
LUAM_DIR="$LUAM_DIR" ./bld/build.sh

if [ "${DAAT_SKIP_JS_CHECK:-0}" = "1" ]; then
    echo
    echo "Skipping JS syntax check (DAAT_SKIP_JS_CHECK=1)"
else
    if ! command -v node > /dev/null 2>&1; then
        echo "Error: node not found on PATH (needed to syntax-check src/**/*.js). Install nodejs or set DAAT_SKIP_JS_CHECK=1 to skip." >&2
        exit 1
    fi
    echo
    echo "Checking extracted JS syntax (src/**/*.js)"
    while IFS= read -r -d '' js_file; do
        echo "--- $js_file ---"
        node --check "$js_file"
    done < <(find src -type f -name '*.js' -print0 | sort -z)
fi

echo
echo "Running Luam unit tests (tst/unit/)"
export LUA_PATH="./tst/lib/?.lua;./src/?.lua;${LUAM_DIR}/lib/?.lua;${LUAM_DIR}/lib/?/init.lua;;"
export LUA_CPATH="${LUAM_DIR}/bin/?.so;${LUAM_DIR}/lib/lfs/?.so;${LUAM_DIR}/lib/hmac/?.so;${LUAM_DIR}/lib/bcrypt/?.so;${LUAM_DIR}/lib/mariadb/?.so;;"
for f in tst/unit/*.lua; do
    echo "--- $f ---"
    "$LUAM_DIR/bin/luam" "$f"
done

echo
echo "Running the agent scorecard in test mode (doc/agent-eval.md)"
EVAL_EPHEMERAL_DIR="$(mktemp -d)"
DAAT_EVAL_RUN_DIR="$EVAL_EPHEMERAL_DIR/run" LUAM_DIR="$LUAM_DIR" ./bld/eval.sh --mode test
rm -rf "$EVAL_EPHEMERAL_DIR"
EVAL_EPHEMERAL_DIR=""

echo
ensure_mariadb_test_server

echo
echo "Running bats integration/CGI tests (tst/integration/)"
bats tst/integration/*.bats
