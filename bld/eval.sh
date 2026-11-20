#!/usr/bin/env bash
set -euo pipefail

# The agent scorecard -- see doc/agent-eval.md.
#
#   bld/eval.sh [--mode test|live] [--repeat N] [--only NAME] [--set core|growth|all] [--extra 'k = v, ...']
#   --extra appends config.lua fields to every run's copy of the demo
#   lab (e.g. --extra 'search_passages = true'), to compare settings
#   without rebuilding or re-embedding the lab.
#               [--compare eval-out/runs/<run>/results.json] [--seed N]
#   bld/eval.sh --rescore eval-out/runs/<run>   (re-check a finished run's
#               stored conversations after a check changed; no model calls)
#   --compare baseline   compares against the committed baseline
#               (tst/eval/baseline/results.json) instead of a path.
#   --save-baseline      (live, every scenario, no --extra) saves this run as
#               that baseline: report.md, results.json and RUN.md, to commit.
#   bld/eval.sh --save-baseline-from eval-out/runs/<run>   saves a finished
#               run as the baseline instead (no model calls).
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
EXTRA=""
SAVE_BASELINE=0
SAVE_FROM=""
BASELINE_DIR="$REPO_ROOT/tst/eval/baseline"
while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        --repeat) REPEAT="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --set) SET="$2"; shift 2 ;;
        --compare) COMPARE="$2"; shift 2 ;;
        --seed) SEED="$2"; shift 2 ;;
        --rescore) RESCORE="$2"; shift 2 ;;
        --extra) EXTRA="$2"; shift 2 ;;
        --save-baseline) SAVE_BASELINE=1; shift ;;
        --save-baseline-from) SAVE_FROM="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$MODE" in
    test) PROVIDER=test; [ -n "$REPEAT" ] || REPEAT=1 ;;
    live) PROVIDER="${DAAT_EVAL_PROVIDER:-vertex}"; [ -n "$REPEAT" ] || REPEAT=3 ;;
    *) echo "Error: --mode must be test or live" >&2; exit 2 ;;
esac

# The committed baseline (doc/agent-eval.md, "The baseline"): the last live
# run on main meant as the reference, so a pull brings the latest scores
# and every comparison is against the same run. eval-out/ isn't in git,
# and a run kept on one person's machine can't be compared against by
# anyone else; the transcripts (work/, ~150 MB a run) stay there.
if [ "$COMPARE" = baseline ]; then
    COMPARE="$BASELINE_DIR/results.json"
    if [ ! -f "$COMPARE" ]; then
        echo "Error: no committed baseline yet ($COMPARE); save one with --save-baseline." >&2
        exit 2
    fi
fi
if [ "$SAVE_BASELINE" = 1 ] && { [ "$MODE" != live ] || [ -n "$ONLY" ] || [ -n "$EXTRA" ] || [ "$SET" != all ]; }; then
    echo "Error: --save-baseline needs a full live run: --mode live, every scenario, no --only, --set or --extra." >&2
    exit 2
fi

# What a run ran on, written into the run as run.txt and copied into the
# baseline's RUN.md: without it a saved report can't say which code and
# model its numbers belong to.
run_info() {
    local model="${DAAT_EVAL_MODEL:-}"
    if [ -z "$model" ] && [ -f "src/provider/agent_${PROVIDER}.lua" ]; then
        model=$(grep -o 'default_model = "[^"]*"' "src/provider/agent_${PROVIDER}.lua" | cut -d'"' -f2 || true)
        model="${model} (provider default)"
    fi
    local commit dirty=""
    commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
    if [ -n "$(git status --porcelain --untracked-files=no -- src tst bld 2>/dev/null)" ]; then
        dirty=" (with uncommitted changes in src/, tst/ or bld/)"
    fi
    printf 'started: %s\n' "$(date '+%Y-%m-%d %H:%M %Z')"
    printf 'branch: %s\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    printf 'commit: %s%s\n' "$commit" "$dirty"
    # The agent code it measured, which is what a baseline stands for: on a
    # branch that leaves src/ as main has it (this one changes only eval
    # tooling), that is main at the commit the branch is based on.
    local base
    base=$(git merge-base HEAD origin/main 2>/dev/null || true)
    if [ -n "$base" ] && [ -z "$(git status --porcelain --untracked-files=no -- src 2>/dev/null)" ] \
            && git diff --quiet "$base" HEAD -- src 2>/dev/null; then
        printf 'agent code: main @ %s\n' "$(git rev-parse --short "$base")"
    else
        printf 'agent code: %s @ %s (src/ differs from main)\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)" "$commit"
    fi
    printf 'mode: %s\nprovider: %s\nmodel: %s\n' "$MODE" "$PROVIDER" "$model"
    printf 'repeat: %s\nset: %s\nseed: %s\n' "$REPEAT" "$SET" "$SEED"
}

save_baseline() {
    local run_dir="$1"
    if [ ! -f "$run_dir/results.json" ] || [ ! -f "$run_dir/report.md" ]; then
        echo "Error: $run_dir has no results.json and report.md; run the report first." >&2
        exit 2
    fi
    mkdir -p "$BASELINE_DIR"
    cp "$run_dir/results.json" "$run_dir/report.md" "$BASELINE_DIR/"
    {
        echo "# Scorecard baseline"
        echo
        echo "The last live scorecard run on \`main\` kept as the reference: \`report.md\` is its scores, \`results.json\` what \`bld/eval.sh --compare baseline\` reads. Transcript links in \`report.md\` point into the run's own \`eval-out/\` folder, which isn't in git."
        echo
        echo "- run: \`$(basename "$run_dir")\`"
        echo "- saved: $(date '+%Y-%m-%d')"
        if [ -f "$run_dir/run.txt" ]; then
            sed 's/^/- /' "$run_dir/run.txt"
        else
            echo "- (run.txt not recorded: a run from before --save-baseline; name its commit and model in the commit message)"
        fi
    } > "$BASELINE_DIR/RUN.md"
    echo "Baseline saved to tst/eval/baseline/ from $(basename "$run_dir"); commit it to share it." >&2
}

if [ -n "$SAVE_FROM" ]; then
    if [ ! -d "$SAVE_FROM" ]; then
        echo "Error: no run folder at $SAVE_FROM" >&2
        exit 2
    fi
    save_baseline "$(cd "$SAVE_FROM" && pwd)"
    exit 0
fi

if [ -z "${LUAM_DIR:-}" ]; then
    LUAM_DIR=$(cd ../luam && pwd)
fi
export LUAM_DIR
export LUA_PATH="$REPO_ROOT/src/?.lua;${LUAM_DIR}/lib/?.lua;${LUAM_DIR}/lib/?/init.lua;;"
export LUA_CPATH="${LUAM_DIR}/lib/?.so;${LUAM_DIR}/lib/?/?.so;${LUAM_DIR}/bin/?.so;;"
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
RUN_DIR="${DAAT_EVAL_RUN_DIR:-$REPO_ROOT/eval-out/runs/$(date +%Y%m%d-%H%M%S)-$MODE}"
mkdir -p "$RUN_DIR/work"
: > "$RUN_DIR/results.jsonl"
printf '%s\n' "$EXTRA" > "$RUN_DIR/extra.txt"
run_info > "$RUN_DIR/run.txt"

for scenario in tst/eval/scenarios/*.lua; do
    name=$(basename "$scenario" .lua)
    if [ -n "$ONLY" ] && [ "$name" != "$ONLY" ]; then
        continue
    fi
    for r in $(seq 1 "$REPEAT"); do
        work="$RUN_DIR/work/$name-$r"
        cp -r "$ENV_DIR" "$work"
        if [ -n "$EXTRA" ]; then
            CFG_OUT="$work/config.lua" CFG_OVER="$EXTRA" "$LUAM" -e '
                data = require("data")
                out_path = os.getenv("CFG_OUT")
                base = data.load(out_path)
                over = data.loads("return {" .. os.getenv("CFG_OVER") .. "}")
                for sec, tbl in pairs(over) do
                    if type(tbl) == "table" and type(base[sec]) == "table" then
                        for k, v in pairs(tbl) do base[sec][k] = v end
                    else
                        base[sec] = tbl
                    end
                end
                data.save(out_path, base)
            '
        fi
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
# The report exits non-zero when any run fails a check, which a live run
# nearly always does; the baseline is saved either way, as the measurement.
status=0
"$LUAM" "$REPO_ROOT/tst/eval/report.lua" "${args[@]}" || status=$?
if [ "$SAVE_BASELINE" = 1 ]; then
    save_baseline "$RUN_DIR"
fi
exit "$status"
