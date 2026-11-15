#!/usr/bin/env bash
set -euo pipefail

# Thin delegation to luam's own shared build orchestrator
# (lib/static/build.lua) -- this project no longer hand-rolls its own
# temp-dir/file-flattening/C-extension-compiling/preload-injection
# logic; that's all owned in one place, in luam itself, instead of
# copy-pasted and independently re-edited across every downstream
# project that needs it. See lib/static/build.lua's own header comment
# for why it's a Luam script rather than another bash script.

cd "$(dirname "$0")/.."

if [ -z "${LUAM_DIR:-}" ]; then
    LUAM_DIR=$(cd ../luam && pwd)
fi

if [ ! -f "$LUAM_DIR/obj/liblua.a" ]; then
    echo "Error: $LUAM_DIR/obj/liblua.a not found. Set LUAM_DIR to a built luam checkout." >&2
    exit 1
fi

LUAM_COMMIT=$(tr -d '[:space:]' < bld/luam.commit)
if [ ! -e "$LUAM_DIR/.git" ] || ! git -C "$LUAM_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "Error: $LUAM_DIR is not a git checkout; cannot verify required luam commit ${LUAM_COMMIT:0:7} (bld/luam.commit)." >&2
    exit 1
fi
if ! git -C "$LUAM_DIR" merge-base --is-ancestor "$LUAM_COMMIT" HEAD >/dev/null 2>&1; then
    LUAM_HEAD=$(git -C "$LUAM_DIR" rev-parse --short HEAD)
    echo "Error: luam checkout at $LUAM_DIR ($LUAM_HEAD) does not contain required commit ${LUAM_COMMIT:0:7} ($LUAM_COMMIT, from bld/luam.commit)." >&2
    echo "Update and rebuild luam: git -C \"$LUAM_DIR\" pull && (cd \"$LUAM_DIR\" && ./bld/build_lang.sh && ./bld/build_libs.sh)" >&2
    exit 1
fi

LUAM_PIN_FILE="${LUAM_PIN_FILE:-bld/luam.pin}"
LUAM_PIN=""
if [ -f "$LUAM_PIN_FILE" ]; then
    LUAM_PIN=$(sed 's/#.*//' "$LUAM_PIN_FILE" | tr -d '[:space:]')
fi
if [ -n "$LUAM_PIN" ] && [ "${LUAM_ALLOW_MISMATCH:-0}" != "1" ]; then
    PIN_SHA=$(git -C "$LUAM_DIR" rev-parse --verify "${LUAM_PIN}^{commit}" 2>/dev/null || true)
    HEAD_SHA=$(git -C "$LUAM_DIR" rev-parse HEAD)
    if [ -z "$PIN_SHA" ] || [ "$HEAD_SHA" != "$PIN_SHA" ]; then
        echo "Error: luam checkout at $LUAM_DIR (${HEAD_SHA:0:7}) does not match exact pin $LUAM_PIN (from $LUAM_PIN_FILE; set LUAM_ALLOW_MISMATCH=1 to override)." >&2
        exit 1
    fi
fi

exec "$LUAM_DIR/bin/luam" "$LUAM_DIR/lib/static/build.lua" \
    --entry main.lua \
    --bin daat \
    --with sqlite3,lfs,bcrypt,hmac,mariadb \
    --luamdir "$LUAM_DIR" \
    --always_include provider \
    "$@"
