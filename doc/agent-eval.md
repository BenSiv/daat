# Agent evaluation: scorecard and demo-lab test environment

A fixed set of questions with known answers, asked of the chat agent on an invented demo lab, scored by rules. Built in #4; what is planned next is in the issues listed under "Planned".

## Running it

Needs a built luam (`LUAM_DIR`, as for `./bld/test.sh`) and `jq`.

```bash
./bld/eval.sh --mode test                    # scripted replies: free, deterministic, also run by ./bld/test.sh
./bld/eval.sh --mode test --only denied-write   # one scenario

# live: a real model, in the eval-only project (see "Model access for live runs")
gcloud auth login                            # or a service account with the Vertex AI user role
export DAAT_EVAL_VERTEX_PROJECT=celleste-daat-eval
export DAAT_EVAL_VERTEX_REGION=global        # optional, the default
export DAAT_EVAL_MODEL=...                   # optional; default: the provider's own default model
./bld/eval.sh --mode live                    # every scenario, 3 repeats each
./bld/eval.sh --mode live --compare /path/to/baseline/results.json

./bld/eval.sh --rescore eval-out/runs/<run>  # re-check a finished run after a check changed; no model calls
```

Other options: `--repeat N`, `--set core|growth|all`, `--seed N`, and `--extra 'k = v, ...'`, which appends `platform.lua` fields to every run's copy of the lab, to compare a setting without rebuilding it.

Each run writes `eval-out/runs/<timestamp>-<mode>/`: `report.md` (the scores, and the failing scenarios with links to their transcripts), `results.json` (summary and rows: what `--compare` reads), `results.jsonl`, and `work/<scenario>-<repeat>/` with each run's database and `transcript.md`. The scores are also printed. The command exits non-zero when any run fails a check, so test mode fails the build.

`eval-out/` is not in git, and a container rebuild loses it. Keep a run that serves as a baseline somewhere durable, and name it in the PR or issue that compares against it.

## Problem

There is no repeatable way to tell whether a change makes the chat agent better or worse.

The bats suite (`tst/integration/agent.bats`, `agent_detached.bats`) checks the turn loop's *mechanics* with scripted model replies:
- approval pauses;
- tool results pair up with their calls;
- compaction keeps what it should.

It says nothing about answer *quality*. Quality has so far been judged by reading real chat history on a live deployment. That has three problems:
- **Late:** it happens after the change has shipped.
- **Not comparable:** the questions differ from one review to the next.
- **Hard to share:** it needs access to a real deployment's data, which outside contributors don't and shouldn't have.

The agent also changes continuously: new tools, prompt changes, loop behaviour. So the measuring has to keep up with the code, not be a one-off study.

## Goals

- **One command:** the agent's quality is scored by a single command, against a fixed set of questions with known answers.
- **Fully public:** everything needed is in this repo. No deployment's data, credentials or chat history are required, beyond a model credential for live runs.
- **Same scores everywhere:** a check that can be computed from a finished conversation alone is scored the same way on real chat history, read-only, by whoever runs that deployment.
- **Keeps up with change:** comparisons stay like for like while the set of questions grows with the agent.

## What already exists to build on

- **A deployment is a folder:** `platform.lua`, `schemas/`, `dropdowns/`, `templates/`, `views/`, `docs/`, `extensions/`, `theme.lua`.
- **Data loads through the CLI:** `daat init`, `daat entity create`, `daat document create-json`, `daat document embed-pending`. The same is available over `/api/v1` (`doc/api.md`).
- **Deterministic stand-ins:**
  - `agent_provider = "test"` (`src/provider/agent_test.lua`): scripted `generate`/`converse` through `AGENT_TEST_RESPONSES`, plus content-derived pseudo-embeddings with no semantic meaning;
  - `search_provider = "test"`;
  - `mail_test`.
  `tst/integration/test_helper.bash` already builds a fresh temp deployment per test on these.
- **Model-call logging:** every real model call already persists its exact prompt, model id and token counts (`agent_model_call`), and every reply gets a classification row. The scorecard reads these and adds no tables of its own.
- **Live providers:**
  - Vertex (`agent_vertex.lua`): chat and embeddings, gcloud auth.
  - Claude (`agent_claude.lua`): chat only. With no embeddings, semantic search is off, so on its own it is not a faithful environment for retrieval questions.

## Design

### 1. The demo lab: a public example deployment

`tst/eval/demo-lab/` is a small invented laboratory deployment, written for this purpose, with no content taken from any real deployment. It exists to reproduce, on purpose, the situations the agent has been seen to get wrong.

**Schemas (8 types):** project, experiment, sample, culture medium, ingredient, measurement, person, equipment. They include at least:
- one junction field (medium to ingredients);
- one `polymorphic_reference`;
- one type (`equipment`) with no `display = true` field, mixing rows that carry an imported builtin `name` with locally registered rows whose `name` is unset;
- `reference_aliases` in `platform.lua` (`"Experiment 027"` -> `exp027`);
- archivable rows.

**Built-in traps:**

| Trap | How the data sets it up |
|------|-------------------------|
| Id vs number vs name | Experiments have a database id, a lab number (`EXP-012`) and a name, which never coincide. |
| Schema discovery | Answers need joins across 2-3 types and through junction tables, so guessed column names fail. |
| Archived rows | Superseded rows are archived; a count is wrong unless it filters `archived_at`. |
| Duplicate titles | Several documents share a title and differ only by date or content. |
| Calculations | Growth measurements drawn from known curves, so a doubling time has one correct value. |
| Long documents | Multi-section protocols that qualify for distillation. |
| Missing information | Questions whose answer isn't in the data; the right reply says so. |
| SQL dialect | Date arithmetic, run on SQLite and on MariaDB. |
| Conflicting sources | Two meeting notes with the same title disagree on the OD600 reading interval; the later one replaces the earlier. |
| Several hops | No single row or document holds the answer: a meeting note's decision, then the experiments it affected, then their readings. |
| Every group at once | A value per medium, so reporting some groups and extrapolating the rest fails. |
| Writing documents | Summaries saved as documents, with `[[title]]` links to the right documents, filed sensibly, over several turns ("do the same for the others"). |
| Editing a document | Adding a section to the protocol; a content update replaces the whole field, so the rest must be written back. |

**Generator** `tst/eval/demo-lab/generate.lua`:
- Seeded and deterministic. From one parameter set it writes both the entity rows *and the expected answers*: counts, doubling times, which document holds which fact. No expected value is typed by hand, so data and answers can't drift apart.
- `--docs N`, planned in #7, scales the document set with the same seed, so retrieval and tiering can be measured at 5,000-10,000 documents with the same tooling.

**Documents:** the generator writes them too: lab-notes pages per experiment, meeting notes sharing a title, a long protocol and handbook. A fuller corpus (about 200: protocols, notes, literature summaries), drafted once from an outline, reviewed and committed as static markdown so it stays a fixed input, is part of #7.

**Loader** `bld/eval-env.sh [--provider test|vertex] [--seed N]` (runs `tst/eval/load.lua`; `bld/eval.sh` calls it, so it rarely needs running by hand):
- builds a fresh deployment in a temp folder: init, schemas, rows, documents, embeddings;
- caches the finished deployment under `eval-out/env/`, keyed by a hash of (generator, schemas, loader, seed, platform settings). Live runs don't pay to embed the corpus again each time.
- writes `facts.json`: the generator's facts with every record key resolved to the id the database gave it. Ids come from one global sequence, so they never line up with lab numbers.

### 2. Scenarios

One file per scenario, `tst/eval/scenarios/<name>.lua`. It returns a function of the deployment's facts (`f`) and helpers (`s`), so every expected value comes from the generator:

```lua
return function(f, s)
    e = f.experiments["EXP-027"]          -- or pick one by its facts, as the shipped scenarios do
    return {
        name = "calculation-doubling-time",
        set = "core",                     -- core | growth (see "Keeping up with change")
        traps = {"calculation"},
        turns = {"What was the doubling time of " .. e.lab_number .. "?"},
        approval = "leave",               -- approve | deny | leave, for any pending action
        script = {                        -- test mode only: the model's replies, in order
            s.tool("entity.query", {sql = "SELECT ..."}),
            s.final("About 3.85 hours, calculated from ..."),   -- the test provider confirms it by itself
        },
        checks = {
            {kind = "answer", number = e.doubling_time_hours, tolerance = 0.05},
            {kind = "shows_method"},
            {kind = "no_failed_lookup"},
            {kind = "finished"},
        },
    }
end
```

`s.id(key)` gives a record's real id (for `cites` and `state` checks).

**Checks** are rules, never a model's judgement:

| Check | Passes when |
|-------|-------------|
| `answer` | The reply matches the expected text, or a number within tolerance, taken from the generator's answers |
| `cites` | The reply links the document or record that holds the answer |
| `approval` | Every write waited for approval, and nothing was written before it |
| `no_failed_lookup` | No tool error from a guessed table or column, or from wrong-dialect SQL |
| `finished` | The turn ended in an answer, not a stall or a "should I continue?" |
| `says_unknown` | For a missing-information question, the reply says the data doesn't have it |
| `shows_method` | A numeric answer shows how it was calculated (the query, or the steps) |
| `state` | A field of a row ends with the expected value (scenario runs only; needs the database) |
| `no_latex` | The reply has no LaTeX (`\frac`, `$$`): the chat renders Markdown without math |
| `labels_not_ids` | The reply names records by label, never by database id ("sample 41") |
| `names_record` | The record's label appears in the reply (including as the visible text of a `/detail` link to the record itself), not only inside a link to a document about it |
| `links_documents` | The documents the conversation wrote hold stored, resolving links to the expected documents (a Markdown link to a page connects nothing) |
| `no_dangling_links` | Those documents link no title that doesn't exist |
| `not_filed_under` | No document the conversation wrote is filed under one of the given documents (e.g. under an experiment's notes) |
| `keeps_content` | An edited document still holds the given passages |

`answer` also takes `any` (one of several wordings) and `numbers` (every one within tolerance). The checks from `no_latex` down come from failures seen on a live deployment (daat-test, 2026-10-29); the database ones run in scenarios only.

The checks live in `tst/eval/checks.lua`. All but `approval` and `state` read only a conversation decoded from stored `agent_message` rows, so they apply to any stored chat (see section 5). `tst/unit/agent_eval_checks.lua` makes sure each check fails on the conversation it exists to catch.

### 3. Runner and report

`bld/eval.sh --mode test|live [--repeat N] [--only name] [--set core|growth|all] [--compare old/results.json]`

- Each scenario runs in its own process (`tst/eval/run_scenario.lua`) on a fresh copy of the cached demo lab. It calls `agent.run_turn`, `agent.approve_pending` and `agent.deny_pending` directly: the same turn loop the web handlers run inline, without HTTP and login in between.
- **test mode:** the scripted provider. Free, and the same result every run. It checks the workflow around the model: approval, tool handling, finishing a turn. It says nothing about quality. It runs inside `./bld/test.sh`, so a broken workflow fails the build. Side-effect model calls a turn can trigger (distillation, tier judgment, tag upkeep) read `AGENT_TEST_GENERATE_RESPONSES`, so they can't consume the scripted conversation.
- **live mode:** the provider and model named in the eval `platform.lua`. Each scenario runs `--repeat` times (default 3). *Consistency* means all repeats give the same answer.
- **Output:** `eval-out/runs/<timestamp>-<mode>/`: `results.jsonl` (one row per scenario per repeat, with token counts read from `agent_model_call`), `results.json` (summary + rows), `report.md`, and `work/<scenario>-<repeat>/` with each run's database and `transcript.md`.

The report shows one line per score (`SCORES` in `tst/eval/report.lua`):

| Score | Meaning |
|-------|---------|
| Scenarios solved on every repeat | % of scenarios whose every repeat passed every check: the headline |
| All checks passed | % of runs that passed every check |
| Correct answers | % of runs whose `answer` check passed |
| One line per conversation check | % of runs passing it: plain-text formulas (`no_latex`), labels not ids, names the record, links the right documents, no links to nothing, files new documents sensibly, keeps content on edit, cites sources, shows method, says when data lacks the answer, finished |
| Approval safety | % of writes that waited for approval (anything below 100% is a blocker) |
| Consistency across repeats | % of scenarios with the same answer across all repeats |
| Failed lookups per run | Guessed-schema and dialect errors per run (`no_failed_lookup`) |
| Tokens per run, per passed run; peak prompt tokens | Cost, read from `agent_model_call` |
| Exact repeat calls, compactions, `entity.get` calls per run | How the agent spends its context |

With `--compare` it adds a change column. It also lists failing scenarios with links to their transcripts.

`bld/eval.sh --rescore eval-out/runs/<run>` runs the checks again on that run's stored conversations. Use it after correcting a check: a check that was too strict must not count against the agent, and a fix must not mean paying for the model calls again. The first scoring is kept as `results.jsonl.before-rescore`.

### 4. Keeping up with change

The scenario set is split in two:
- **core:** frozen when a baseline is taken. Comparisons against that baseline use core only, so they stay like for like.
- **growth:** scenarios added since. Scored and reported separately, and moved into core when the next baseline is taken.

Rule: a change that adds a tool or a new agent behaviour comes with at least one scenario that exercises it.

### 5. The same scores on real use

A deployment's own chat history is already in `agent_session`/`agent_message`. The conversation-level checks run on it read-only, with no change to the deployment: `cites`, `no_failed_lookup`, `finished`, `shows_method`.

`tst/eval/score_chats.lua` reads rows as JSON lines on stdin (`{session_id, login, id, role, content, created_at}`), splits each session into exchanges at every user message, and prints only totals: no message content is written anywhere. `--exclude login,...` leaves out test accounts. A MariaDB deployment can stream the rows with `JSON_OBJECT(...)` from a read-only account straight into it. That gives the maintainer of a deployment the same numbers for real use after each rollout, and the conversations stay inside the deployment. The demo lab measures what changed; real-use scoring confirms it holds up.

### 6. Model access for live runs

- Live runs use a model credential meant only for evaluation, in a cloud project that holds no production deployment or data, under a monthly budget.
- For Vertex, a service account with only the Vertex AI user role is enough. Off GCE, the provider falls back to the logged-in `gcloud` account for its token.
- `bld/eval-env.sh --provider vertex` reads `DAAT_EVAL_VERTEX_PROJECT`, `DAAT_EVAL_VERTEX_REGION` (default `global`) and `DAAT_EVAL_MODEL`, never a deployment's own config. The loader refuses a lab whose documents didn't all get embedded.
- `search_provider` and mail stay on their test stand-ins in every mode. A live run never reaches an external system other than the model API.

## How to add a scenario

1. Pick the trap it tests (table above) and find the facts it needs in `facts.json` of a built demo lab (`bld/eval-env.sh` prints its directory). If the data doesn't set the trap up yet, extend `tst/eval/demo-lab/generate.lua` and record the answer in its facts.
2. Copy the closest scenario in `tst/eval/scenarios/`, put it in the `growth` set, and write the question as a user would ask it.
3. Write `script` as the replies a correct agent would give, using real tool calls, so test mode exercises real tools on the demo data.
4. Run `bld/eval.sh --only <name>`; read `work/<name>-1/transcript.md` if a check fails.

## Planned

Progress is tracked in the issues, not here:
- #7: a step-budget scenario, the full demo-lab corpus, and `--docs N` scaling.
- #9: aggregate questions that run out of steps and hide their method.
- #39: a repeatable stress test for the knowledge-pool tiers: search latency p50/p95, model calls and review cost per search, at 5,000-10,000 documents.
- #40: cross-session scenarios, whether knowledge from one chat reaches a later one.
- #41: checks for invented tool names and invalid or fabricated arguments.
- #45: whether the drop in plain-text formulas on #44's live run is noise or real.

The aims the scorecard is held to: a fresh clone plus an eval credential runs it with no other setup; every expected answer comes from the generator; test mode stays fast enough to run in every `./bld/test.sh`; a live run of the core set with 3 repeats stays within the agreed monthly budget.

## Open questions

- Default eval model: the cheapest production-grade model, so results carry over to typical deployments, or a stronger one?
- Is MariaDB part of the default eval run, or only of the dialect scenarios?
- Is Claude-as-chat with Vertex embeddings worth supporting? Today embeddings come from the same provider as chat.
