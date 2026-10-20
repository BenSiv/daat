#!/usr/bin/env bash
set -euo pipefail

# Builds (or reuses) a demo-lab deployment for the agent scorecard --
# see doc/agent-eval.md. Prints the deployment's directory on stdout.
#
#   bld/eval-env.sh [--provider test|vertex] [--seed N]
#
# The finished deployment is cached under eval-out/env/, keyed by a hash
# of everything that shapes it (generator, schemas, loader, seed,
# provider, embedding model), so live runs don't pay to embed the corpus
# again each time. bld/eval.sh copies it per scenario; never run a
# scenario against the cached copy itself.
#
# Live (vertex) runs read the eval-only model project from the
# environment, never from a deployment's own config:
#   DAAT_EVAL_VERTEX_PROJECT  (required for --provider vertex)
#   DAAT_EVAL_VERTEX_REGION   (default: global)
#   DAAT_EVAL_MODEL           (default: the provider's own default)

cd "$(dirname "$0")/.."
REPO_ROOT=$(pwd)

PROVIDER=test
SEED=20261020
while [ $# -gt 0 ]; do
    case "$1" in
        --provider) PROVIDER="$2"; shift 2 ;;
        --seed) SEED="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ -z "${LUAM_DIR:-}" ]; then
    LUAM_DIR=$(cd ../luam && pwd)
fi
export LUA_PATH="$REPO_ROOT/src/?.lua;${LUAM_DIR}/lib/?.lua;${LUAM_DIR}/lib/?/init.lua;;"
export LUA_CPATH="${LUAM_DIR}/bin/?.so;${LUAM_DIR}/lib/lfs/?.so;${LUAM_DIR}/lib/hmac/?.so;${LUAM_DIR}/lib/bcrypt/?.so;${LUAM_DIR}/lib/mariadb/?.so;;"

case "$PROVIDER" in
    test)
        PLATFORM='return {agent_provider = "test", search_provider = "test", embedding_quiet_minutes = 0, tag_min_text = 0, agent_turn_mode = "inline"}'
        ;;
    vertex)
        if [ -z "${DAAT_EVAL_VERTEX_PROJECT:-}" ]; then
            echo "Error: set DAAT_EVAL_VERTEX_PROJECT to the eval-only model project (doc/agent-eval.md, 'Model access')." >&2
            exit 2
        fi
        MODEL_FIELD=""
        if [ -n "${DAAT_EVAL_MODEL:-}" ]; then
            MODEL_FIELD=", agent_model = \"${DAAT_EVAL_MODEL}\""
        fi
        PLATFORM="return {agent_provider = \"vertex\", vertex_project = \"${DAAT_EVAL_VERTEX_PROJECT}\", vertex_region = \"${DAAT_EVAL_VERTEX_REGION:-global}\"${MODEL_FIELD}, search_provider = \"test\", embedding_quiet_minutes = 0, agent_turn_mode = \"inline\"}"
        ;;
    *)
        echo "Error: --provider must be test or vertex" >&2
        exit 2
        ;;
esac

HASH=$( { cat tst/eval/demo-lab/generate.lua tst/eval/load.lua tst/eval/demo-lab/schemas/*.lua; echo "$SEED $PLATFORM"; } | sha256sum | cut -c1-12)
ENV_DIR="$REPO_ROOT/eval-out/env/${PROVIDER}-${HASH}"

if [ ! -f "$ENV_DIR/facts.json" ]; then
    rm -rf "$ENV_DIR.tmp"
    mkdir -p "$ENV_DIR.tmp"
    cp -r tst/eval/demo-lab/schemas "$ENV_DIR.tmp/schemas"
    printf '%s\n' "$PLATFORM" > "$ENV_DIR.tmp/platform.lua"
    (cd "$ENV_DIR.tmp" && "$LUAM_DIR/bin/luam" "$REPO_ROOT/tst/eval/load.lua" "$REPO_ROOT" "$SEED" >&2)
    rm -rf "$ENV_DIR"
    mv "$ENV_DIR.tmp" "$ENV_DIR"
fi

echo "$ENV_DIR"
