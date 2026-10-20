# Agent evaluation: scorecard and demo-lab test environment

Status: steps 1-2 built (demo lab, loader, runner, report, 6 scenarios, test mode in `./bld/test.sh`). Live mode runs against Vertex in an eval-only project; `--rescore` re-checks a finished run without new model calls; `tst/eval/score_chats.lua` scores stored chat history. Tracked in GitHub issue #4.

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
- **Model-call logging:** every real model call already persists its exact prompt, model id and token counts (`knowledge_context`), and every reply gets a `knowledge_chat_eval` row. The scorecard reads these and adds no tables of its own.
- **Live providers:**
  - Vertex (`agent_vertex.lua`): chat and embeddings, gcloud auth.
  - Claude (`agent_claude.lua`): chat only. With no embeddings, semantic search is off, so on its own it is not a faithful environment for retrieval questions.

## Design

### 1. The demo lab: a public example deployment

`tst/eval/demo-lab/` is a small invented laboratory deployment, written for this purpose, with no content taken from any real deployment. It exists to reproduce, on purpose, the situations the agent has been seen to get wrong.

**Schemas (about 8 types):** project, experiment, sample, culture medium, ingredient, measurement, person. They include at least:
- one junction field (medium to ingredients);
- one `polymorphic_reference`;
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

**Generator** `tst/eval/demo-lab/generate.lua`:
- Seeded and deterministic. From one parameter set it writes both the entity rows *and the expected answers*: counts, doubling times, which document holds which fact. No expected value is typed by hand, so data and answers can't drift apart.
- `--docs N` scales the document set with the same seed. Retrieval and tiering are measured at 5,000-10,000 documents with the same tooling.

**Documents:** today the generator writes them too: one lab-notes page per experiment, three meeting notes sharing a title, one long protocol (26 in all). The fuller corpus (about 200: protocols, notes, literature summaries) is to be drafted once from an outline, reviewed, and committed as static markdown, so it stays a fixed input.

**Loader** `bld/eval-env.sh [--provider test|vertex] [--seed N]` (runs `tst/eval/load.lua`; `--docs N` and `--backend` are still to come):
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
            s.final("About 3.85 hours, calculated from ..."),   -- adds the self-check's CONFIRM
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

The checks live in `tst/eval/checks.lua`. All but `approval` and `state` read only a conversation decoded from stored `agent_message` rows, so they apply to any stored chat (see section 5). `tst/unit/agent_eval_checks.lua` makes sure each check fails on the conversation it exists to catch.

### 3. Runner and report

`bld/eval.sh --mode test|live [--repeat N] [--only name] [--set core|growth|all] [--compare old/results.json]`

- Each scenario runs in its own process (`tst/eval/run_scenario.lua`) on a fresh copy of the cached demo lab. It calls `agent.run_turn`, `agent.approve_pending` and `agent.deny_pending` directly: the same turn loop the web handlers run inline, without HTTP and login in between.
- **test mode:** the scripted provider. Free, and the same result every run. It checks the workflow around the model: approval, tool handling, finishing a turn. It says nothing about quality. It runs inside `./bld/test.sh`, so a broken workflow fails the build. Side-effect model calls a turn can trigger (distillation, tier judgment, tag upkeep) read `AGENT_TEST_GENERATE_RESPONSES`, so they can't consume the scripted conversation.
- **live mode:** the provider and model named in the eval `platform.lua`. Each scenario runs `--repeat` times (default 3). *Consistency* means all repeats give the same answer.
- **Output:** `eval-out/runs/<timestamp>-<mode>/`: `results.jsonl` (one row per scenario per repeat, with token counts read from `knowledge_context`), `results.json` (summary + rows), `report.md`, and `work/<scenario>-<repeat>/` with each run's database and `transcript.md`.

The report shows one line per score:

| Score | Meaning |
|-------|---------|
| Correct | % of scenarios whose `answer` check passed |
| Approval safety | % of writes that waited for approval (anything below 100% is a blocker) |
| Cites sources | % of answers that link what they used |
| Consistency | % of scenarios with the same answer across all repeats |
| Failed lookups | Guessed-schema and dialect errors per scenario |
| Finished | % of turns that ended in an answer |
| Cost | Tokens per scenario |

With `--compare` it adds a delta column. It also lists failing scenarios with links to their transcripts.

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

## Implementation steps

1. ~~Write the demo-lab schemas, generator and loader.~~ Done; the static ~200-document corpus is still to come (see "Documents").
2. ~~Add the runner in test mode with starter scenarios and wire it into `./bld/test.sh`.~~ Done, with 6 scenarios: approval, schema discovery, citation, id/number/name, calculation, missing information.
3. Complete the corpus (about 200 documents) and 25-30 scenarios covering every trap. Add live mode, repeats, the report and `--compare`.
4. Take the first live baseline and freeze the core set.
5. Add `--docs N` scaling and retrieval measurements: search latency p50/p95, model calls per search.
6. Make the conversation-level checks runnable on a stored session (section 5).

## Done when

- [ ] A fresh clone plus an eval credential runs `bld/eval-env.sh` and `bld/eval.sh --mode live` with no other setup.
- [ ] Every expected answer comes from the generator.
- [ ] Test mode runs in under 2 minutes inside `./bld/test.sh`.
- [ ] A live run of the core set with 3 repeats stays within an agreed monthly budget.
- [ ] This doc gains a "How to add a scenario" section.

## Open questions

- Default eval model: the cheapest production-grade model, so results carry over to typical deployments, or a stronger one?
- Is MariaDB part of the default eval run, or only of the dialect scenarios?
- Is Claude-as-chat with Vertex embeddings worth supporting? Today embeddings come from the same provider as chat.
