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

cd "$(dirname "$0")/.."

if [ -z "${LUAM_DIR:-}" ]; then
    LUAM_DIR=$(cd ../luam && pwd)
fi

if ! command -v bats > /dev/null 2>&1; then
    echo "Error: bats not found on PATH. Install it (e.g. apt install bats) to run tst/integration/*.bats." >&2
    exit 1
fi

echo "Building"
LUAM_DIR="$LUAM_DIR" ./bld/build.sh

echo
echo "Running Luam unit tests (tst/unit/)"
export LUA_PATH="./src/?.lua;${LUAM_DIR}/lib/?.lua;${LUAM_DIR}/lib/?/init.lua;;"
export LUA_CPATH="${LUAM_DIR}/bin/?.so;${LUAM_DIR}/lib/lfs/?.so;;"
for f in tst/unit/*.lua; do
    echo "--- $f ---"
    "$LUAM_DIR/bin/luam" "$f"
done

echo
echo "Running bats integration/CGI tests (tst/integration/)"
bats tst/integration/*.bats
