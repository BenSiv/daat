#!/usr/bin/env bash
set -euo pipefail

# The agent scorecard -- see doc/agent-eval.md.
#
#   bld/eval.sh [--mode test|live] [--repeat N] [--only NAME] [--set core|growth|all]
#               [--compare eval-out/runs/<run>/results.json] [--seed N]
#   bld/eval.sh --rescore eval-out/runs/<run>   (re-check a finished run's
#               stored conversations after a check changed; no model calls)
#
# test (default): scripted replies, free, the same result every run; checks
#   the workflow around the model and fails when any check fails.
# live: the eval-only model project (see bld/eval-env.sh); each scenario
#   runs --repeat times (default 3) to measure consistency.
#
# Each run gets its own copy of the cached demo lab under
# eval-out/runs/<timestamp>-<mode>/work/, kept for its transcript.

cd "$(dirname "$0")/.."
REPO_ROOT=$(pwd)

MODE=test
REPEAT=""
ONLY=""
SET=all
COMPARE=""
RESCORE=""
SEED=20261020
while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        --repeat) REPEAT="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --set) SET="$2"; shift 2 ;;
        --compare) COMPARE="$2"; shift 2 ;;
        --seed) SEED="$2"; shift 2 ;;
        --rescore) RESCORE="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$MODE" in
    test) PROVIDER=test; [ -n "$REPEAT" ] || REPEAT=1 ;;
    live) PROVIDER=vertex; [ -n "$REPEAT" ] || REPEAT=3 ;;
    *) echo "Error: --mode must be test or live" >&2; exit 2 ;;
esac

if [ -z "${LUAM_DIR:-}" ]; then
    LUAM_DIR=$(cd ../luam && pwd)
fi
export LUAM_DIR
export LUA_PATH="$REPO_ROOT/src/?.lua;${LUAM_DIR}/lib/?.lua;${LUAM_DIR}/lib/?/init.lua;;"
export LUA_CPATH="${LUAM_DIR}/bin/?.so;${LUAM_DIR}/lib/lfs/?.so;${LUAM_DIR}/lib/hmac/?.so;${LUAM_DIR}/lib/bcrypt/?.so;${LUAM_DIR}/lib/mariadb/?.so;;"
LUAM="$LUAM_DIR/bin/luam"

if [ -n "$RESCORE" ]; then
    RUN_DIR=$(cd "$RESCORE" && pwd)
    # Keep the first scoring; a rescore always starts from it.
    if [ ! -f "$RUN_DIR/results.jsonl.before-rescore" ]; then
        mv "$RUN_DIR/results.jsonl" "$RUN_DIR/results.jsonl.before-rescore"
    fi
    : > "$RUN_DIR/results.jsonl"
    while IFS= read -r line; do
        name=$(jq -r .scenario <<<"$line")
        r=$(jq -r '.repeat' <<<"$line")
        mode=$(jq -r .mode <<<"$line")
        sid=$(jq -r .session_id <<<"$line")
        status=$(jq -r .status <<<"$line")
        (cd "$RUN_DIR/work/$name-$r" && "$LUAM" "$REPO_ROOT/tst/eval/run_scenario.lua" rescore \
            "$REPO_ROOT/tst/eval/scenarios/$name.lua" "$mode" "$r" all "$sid" "$status") >> "$RUN_DIR/results.jsonl"
    done < "$RUN_DIR/results.jsonl.before-rescore"
    args=("$RUN_DIR")
    if [ -n "$COMPARE" ]; then
        args+=("$COMPARE")
    fi
    exec "$LUAM" "$REPO_ROOT/tst/eval/report.lua" "${args[@]}"
fi

ENV_DIR=$(./bld/eval-env.sh --provider "$PROVIDER" --seed "$SEED")
RUN_DIR="$REPO_ROOT/eval-out/runs/$(date +%Y%m%d-%H%M%S)-$MODE"
mkdir -p "$RUN_DIR/work"
: > "$RUN_DIR/results.jsonl"

for scenario in tst/eval/scenarios/*.lua; do
    name=$(basename "$scenario" .lua)
    if [ -n "$ONLY" ] && [ "$name" != "$ONLY" ]; then
        continue
    fi
    for r in $(seq 1 "$REPEAT"); do
        work="$RUN_DIR/work/$name-$r"
        cp -r "$ENV_DIR" "$work"
        (
            cd "$work"
            if [ "$MODE" = test ]; then
                AGENT_TEST_RESPONSES="$("$LUAM" "$REPO_ROOT/tst/eval/run_scenario.lua" script "$REPO_ROOT/$scenario")"
                export AGENT_TEST_RESPONSES
                # Side-effect model calls (distillation, tier judgment,
                # tag upkeep) get their own replies, not the script's.
                export AGENT_TEST_GENERATE_RESPONSES="Test response."
            fi
            "$LUAM" "$REPO_ROOT/tst/eval/run_scenario.lua" run "$REPO_ROOT/$scenario" "$MODE" "$r" "$SET" >> "$RUN_DIR/results.jsonl"
        )
        echo "  $name #$r" >&2
    done
done

args=("$RUN_DIR")
if [ -n "$COMPARE" ]; then
    args+=("$COMPARE")
fi
"$LUAM" "$REPO_ROOT/tst/eval/report.lua" "${args[@]}"
