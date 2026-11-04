# Review checklist

The rules every change to daat is checked against, by its author before
opening a PR and by the reviewer after. Each rule links to where it is
argued in full; this page only collects them. A change that has to break a
rule says so in its PR and gives the reason. If the reason should hold for
every change, the rule changes here first.

## Process

- **An issue first, then the change.** The issue states the problem, the
  current design and why it is like that, the options, and a
  recommendation. Larger work gets a design doc in `doc/` before code
  (`doc/agent-tools.md` is the pattern).
- **Measure before changing agent behaviour.** A change meant to make the
  agent better names the scorecard numbers it should move and shows them
  in a `--compare` report (`doc/agent-eval.md`). "Seems better" on one
  conversation is not a result.
- **One concern per branch and PR.** The commit subject is
  `<area>: <what is now true>` and names its issue (`(#16)`). The body says
  why.
- **Docs describe the design, not the state of play.** Progress lives in
  issues; a doc that says "done / not done" goes stale the day it merges.

## The agent loop and its sub-agents

- **What the agent may do is a rule in code, never an instruction in a
  prompt.** Tool surface, destructive vs. read-only, approval, and what a
  sub-agent can call are all enforced in Lua (`doc/architecture.md`,
  "Agent control: rule-based by default"). Prompts are for judgment:
  inference, phrasing, self-critique.
- **A sub-agent is narrowed by the tools it is given, not told to behave.**
  A tool it must not use is not declared to it at all
  (`doc/agent-harness-rationale.md`, "A sub-agent's tool list is narrower by
  construction").
- **Prompts, reasoning and tool calls are source data, not exhaust.**
  Every model call is persisted with its exact prompt, model, tokens, kind
  and step, and can be traced to what called it
  (`doc/agent-harness-rationale.md`, `doc/architecture.md`, "Full
  prompt/reasoning/token persistence").
- **A sub-agent keeps what the main loop keeps.** Keeping a sub-agent's
  steps out of the conversation's *context* is the reason it exists; it is
  not a reason to keep them out of the *record*. Research and background
  steps get the same persistence, reasoning extraction and retention as a
  chat step, linked to the tool call that started them, including the step
  that ran out of budget or failed.
- **Every log has a reader and a retention rule** (`doc/schema-revision.md`,
  principle 3). A new table or column says who reads it and when it is
  cleared. Nothing a later feature depends on lives only in a column that
  is pruned.
- **A failure is visible, never silence.** A turn that runs out of steps,
  errors, stalls or is cancelled ends in a message the user can see and a
  row a developer can find.
- **One neutral protocol.** Core code speaks `doc/agent-protocol.md`;
  anything vendor-specific lives in `src/provider/`. Core names no model.
- **Concurrent requests are the normal case.** Each web request is its own
  process. A state change that must happen once is claimed in the database
  first, then acted on (`agent.claim_pending_action`).

## Code

- **One mechanism, not a copy.** A list that mirrors another table (tool
  names, reserved names, column lists) is read from the source, not kept by
  hand. A second near-identical function is a sign the first one wants a
  parameter (`../luam/doc/manifesto.md`, tenet 2).
- **A module is a table and functions; a program has one entry point.**
  `src/<module>.lua` builds its module table and returns it; command
  dispatch goes through `main()` in `src/main.lua` to a `do_<module>`
  function. No work at file load time beyond `require`s and constants.
- **Luam's implicit locals, no `local`** (`doc/onboarding.md`, "Coding
  conventions").
- **Comments carry the reasoning**: why, what was rejected, what was found
  live that led here. Match the surrounding file.
- **SQL that works on both backends.** Every query runs on SQLite and
  MariaDB; `doc/mariadb-migration.md`, "Dialect differences", lists the ones
  that matter.
- **No new dependency** without a written reason (`doc/why-luam.md`,
  "Minimal dependencies").

## Tests

- **Every fix comes with a test that fails without it.** A race is tested
  both ways: once fired for real, once deterministically through the seam
  that prevents it (#16 is the pattern).
- **Tests are built like `src`.** Shared harness code lives in one place
  (`tst/lib/` for Luam, `tst/integration/test_helper.bash` for bats), not
  copied into each file. A unit file declares its tests in a
  `unit.suite()` and ends with `unit.run(tests)`, so a test can't be
  written and silently never run. Scripts in `tst/eval/` have a `main()`
  like `src/main.lua`.
- **A bats test runs Lua through `run_luam`**, never its own copy of the
  luam paths. Fixtures (a schema, a view, `platform.lua`) are fine inline
  as heredocs; a Lua *script* longer than a few lines, or used by more
  than one test, is a file.
- **No real model, credentials or network in `./bld/test.sh`.** Agent
  behaviour is scripted through the test provider
  (`AGENT_TEST_RESPONSES`).
- **Behaviour the agent loop relies on has a characterization test**
  before it is refactored (#3 lists them).
- `./bld/test.sh` is green before a PR asks for review.
