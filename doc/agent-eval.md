# Agent evaluation: scorecard and demo-lab test environment

Status: design, not yet implemented. Tracked in GitHub issue #4.

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

**Documents (about 200):**
- protocols, experiment notes, meeting notes, short literature summaries;
- drafted once from an outline, reviewed, and committed as static markdown, so the corpus is a fixed input and not regenerated per run.

**Loader** `bld/eval-env.sh [--provider test|vertex] [--docs N] [--backend sqlite|mariadb]`:
- builds a fresh deployment in a temp folder: init, schemas, rows, documents, embeddings;
- caches the finished database keyed by a hash of (generator inputs, documents, embedding model). Live runs don't pay to embed the corpus again each time.

### 2. Scenarios

One file per scenario, `tst/eval/scenarios/<name>.lua`, returning a table:

```lua
{
  name = "doubling-time-by-lab-number",
  set = "core",                         -- core | growth (see "Keeping up with change")
  traps = {"id-number-name", "calculation"},
  turns = {"What was the doubling time in EXP-012?"},
  approval = "approve",                 -- approve | deny | leave, for any pending action
  scripted = {...},                     -- test mode only: AGENT_TEST_RESPONSES entries
  checks = {
    {kind = "answer", expected = "doubling_time.EXP-012", tolerance = 0.05},  -- read from the generator's answers
    {kind = "shows_method"},
    {kind = "no_failed_lookup"},
    {kind = "finished"},
  },
}
```

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

`cites`, `no_failed_lookup`, `finished` and `shows_method` are written as functions over stored `agent_message` rows, not over the live run (see section 5).

### 3. Runner and report

`bld/eval.sh --mode test|live [--repeat N] [--only name] [--set core|growth|all] [--compare old/results.json]`

- Each scenario runs on a fresh copy of the cached demo lab and drives the real chat entry points, the same path the bats tests use.
- **test mode:** the scripted provider. Free, and the same result every run. It checks the workflow around the model: approval, tool handling, finishing a turn. It says nothing about quality. It runs inside `./bld/test.sh`, so a broken workflow fails the build.
- **live mode:** the provider and model named in the eval `platform.lua`. Each scenario runs `--repeat` times (default 3). *Consistency* means all repeats give the same answer.
- **Output:** `eval-out/<timestamp>/results.json` (one row per scenario per repeat, with token counts read from `knowledge_context`) and `report.md`.

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

### 4. Keeping up with change

The scenario set is split in two:
- **core:** frozen when a baseline is taken. Comparisons against that baseline use core only, so they stay like for like.
- **growth:** scenarios added since. Scored and reported separately, and moved into core when the next baseline is taken.

Rule: a change that adds a tool or a new agent behaviour comes with at least one scenario that exercises it.

### 5. The same scores on real use

A deployment's own chat history is already in `agent_session`/`agent_message`. The conversation-level checks run on it read-only, with no change to the deployment: `cites`, `no_failed_lookup`, `finished`, `shows_method`. That gives the maintainer of a deployment the same numbers for real use after each rollout, and the conversations stay inside the deployment. The demo lab measures what changed; real-use scoring confirms it holds up.

### 6. Model access for live runs

- Live runs use a model credential meant only for evaluation, in a cloud project that holds no production deployment or data, under a monthly budget.
- For Vertex, a service account with only the Vertex AI user role is enough.
- `search_provider` and mail stay on their test stand-ins in every mode. A live run never reaches an external system other than the model API.

## Implementation steps

1. Write the demo-lab schemas, generator and loader, plus the first 20 documents. `bld/eval-env.sh --provider test` builds a working deployment.
2. Add the runner in test mode with 5 scenarios (approval, schema discovery, citation, id/number/name, calculation). Wire it into `./bld/test.sh`.
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
