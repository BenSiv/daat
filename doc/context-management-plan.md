# Context management: implementation plan

Plan for the recommendations in `doc/context-management-research.md`, ordered by expected impact per unit of work, using the 2026-10-23 prod baseline in that doc. Each phase is its own branch, ships behind a config flag, and is measured before the next starts.

## Where the changes go

The techniques are general, so they go in the code every loop shares, not in chat:

| Shared point | What passes through it | Used by |
|---|---|---|
| `agent.run_tool` (`src/agent.lua`) | Every tool call and its result | chat turns, `research.investigate`, background tasks |
| `agent_provider.converse` (`src/agent_provider.lua`) | Every model call, with the canonical message list | the same, plus wrap-ups |
| `build_history_messages` (`src/agent.lua`) | Chat history from `agent_message` into canonical messages | chat; the research loop builds its list in memory |
| `agent.compact_if_needed` | Summarizing compaction | chat |

A new shaping step, `agent.shape_context(messages, policy)`, runs on the canonical list just before `converse`. Both loops call it, so masking and render-time caps are written once. The `policy` comes from config per loop (`chat`, `research`, `background`), which is how chat can be the first test case without the feature being chat-specific.

## Impact ranking

| Phase | What | Evidence of impact | Effort |
|---|---|---|---|
| 0 | Per-step usage logging + a re-runnable context report | Needed to measure everything below; today only the last step of a turn is recorded | S |
| 1 | Keep what's known: schema pinning + exact-repeat answers | 53% of schema calls and 33 searches are exact repeats | S–M |
| 2 | Concise defaults and size caps for the worst tools | Tool results are 77% of history; `knowledge.list` ~50k chars per call, `document.search` ~6k per call × frequent, `entity.query` tail to 59k | M |
| 3 | Real token accounting + better compaction | Estimate misses ~3.9k tokens of tool definitions and assumes 4 characters per token where prod shows 2.8; 20 of 26 compacted sessions compacted repeatedly | M |
| 4 | Observation masking (soft compaction) | Big win in the literature, but staff chat averages only 6 results per turn; matters for long loops | M |
| 5 | Summarize and split transcripts at save time | Cross-session retrieval; SeCom evidence; no prod measure yet | M–L |
| 6 | Later: sub-agent nudges, recitation, ACON-style tuning, Claude provider-side option | Unmeasured | — |

## Phase 0: measure (prerequisite)

**Why first:** `knowledge_context` records every chat step, but nothing from the research sub-agent or background tasks (where masking will be tested first), and no row says which kind of call it was or which step of its turn. Every later phase is judged on tokens per completed task per loop, which needs both.

**Changes:**
- Add `kind` (originally `step_kind`; `chat`, `research`, `background`, `compaction`, `wrapup`, `self_check`) and `step` (the step's number within its turn) to `knowledge_context`, set by every caller of `record_context`.
- Record every research and background step too, with its prompt, like chat steps already are: `doc/architecture.md` says every real model call is persisted.
- `daat agent context-report [--since DATE]`: prints the baseline tables from the research doc (tokens per call and per turn by loop and login class, tool result sizes, exact-repeat counts, compactions per session). It is read-only SQL, so it can run against prod with the read-only user and be re-run after each phase.
- Agent scorecard (`bld/eval.sh`): add `tokens_per_task`, `steps_per_task`, `exact_repeat_calls` and `compactions` to each scenario's result.

**Tests:** a unit test for the report's SQL on a seeded store; a bats test that one turn with tool calls records one usage row per step.

**Done when:** the report reproduces the 2026-10-23 baseline numbers from prod data, and a scorecard run in test mode prints the new columns.

**Status:** built on `feature/context-usage-logging`. Run on prod before the upgrade, the report reproduced the hand-measured baseline. Against a store without the new columns, every row reports as `unlabelled`, and chat turns are grouped by message instead. To read prod: open the read-only proxy (`software/benchling/migration/connect-platform-db.sh` documents it), point a scratch `platform.lua` at it with `mariadb_user = "platform_readonly"`, and run `daat agent context-report`, or run it inside the prod container. CLI agent entry points (`agent continue`, `agent run-pending-background`) now bring the knowledge tables up to date themselves, since the background timer can fire before any web request after a deploy.

## Phase 1: keep what's known

**Why:** the largest measured waste. The agent asks for the same schema again (133 of 249 calls), usually because compaction summarized the earlier answer away or it is buried in context.

**Changes:**
1. **Pin schema through compaction.** In `compact_if_needed`, collect the `entity.list_types` / `entity.fields` / `entity.relationships` results being compacted. Keep the latest per arguments, verbatim, under a "Confirmed schema" heading appended to the summary by code, like the user's requests are today. Cap the section (e.g. 6k characters, most recently used first); a type that doesn't fit is named, so the agent knows it was looked up.
2. **Answer exact repeats from what's in context.** In `agent.run_tool`, for read-only tools marked repeat-safe:
   - Repeat-safe tools: the schema tools, `entity.get`, `document.search`, `document.children`.
   - If the same tool with the same arguments already has a result in the *current* context, and no write tool has run since in the session (and no schema change for schema tools), return a short note instead of a second copy: `Same as your earlier call to entity.fields(sample), still above -- result unchanged.`
   - If the earlier result is no longer in context, run it normally: a re-fetch after compaction is legitimate.
   - The check needs the current message list, so `run_tool` gets it passed in from both loops.
3. **Config:** `agent_pin_schema` (default on), `agent_dedupe_repeat_calls` (on).

**Tests:**
- Compaction keeps a fetched `entity.fields` result verbatim in the summary.
- An exact repeat while the result is in context returns the note and makes no new tool execution.
- A repeat after a write tool reruns.
- A repeat after compaction reruns unless the result is pinned.

**Measure:** exact-repeat rate (prod and scorecard) should fall from 53% toward the share that is legitimate (after writes); correctness unchanged or better; fewer schema-guess errors.

## Phase 2: concise defaults and size caps

**Why:** tool results are 77% of history, concentrated in a few tools.

**Changes, in order of measured volume:**
1. **`document.search`:** lower `agent_search_excerpt_length` from 1200 to ~400 (config only). Add `detail: "full"` to the tool's arguments for when the agent needs longer excerpts. Try this first: it is a one-line config change, and the scorecard's search scenarios say whether answers suffer.
2. **`knowledge.list`:** it lists every pool document. Add `limit` (default 50) and `offset`, sorted as now by tier and heat, with a "showing N of M" footer. The curation loop pages explicitly.
3. **`entity.query`:** add a character budget beside the row cap (`agent_query_char_cap`, e.g. 12k). Stop adding rows when it's reached and say so ("showing 40 of 143 rows (size limit) -- narrow the columns or add LIMIT").
4. **`entity.get` on long text:** for text fields over ~4k characters, return the head, the heading outline and the total length. Add `offset` / `length` arguments to read more of that field.
5. **Safety net for every tool,** in `agent.run_tool`: a result over `agent_tool_result_cap` (e.g. 24k characters) is cut to the head plus `[truncated: N more characters of result #id -- call agent.read_result(id, offset)]`. The full text stays in `agent_message`, which already stores what the tool returned. A new read-only `agent.read_result(id, offset, length)` tool pages it, checked against the caller's session.

**Tests:** per-tool truncation footers; `read_result` returns the remainder and refuses another session's result; the scorecard search scenarios still pass at the shorter excerpt length.

**Measure:** average and maximum tool-result size per tool (context report); tokens per task; correctness.

## Phase 3: token accounting and better compaction

**Why:** compaction decides on an estimate that leaves out the tool definitions (part of ~3.9k fixed tokens) and assumes 4 characters per token where prod shows 2.8. And 20 of 26 compacted sessions were compacted again and again.

**Changes:**
1. **Trigger on real numbers:** last call's `prompt_tokens` (from Phase 0's log), plus the new messages since then at the measured ratio. The threshold is in real tokens (`agent_compaction_threshold` keeps its name; re-tune its value).
2. **Check before every step, not only at turn start,** in both the chat step loop and, if needed, the research loop.
3. **Anchored summary:**
   - Fixed sections: user requests (verbatim, by code, as now); established facts (entity ids and what they are; queries that worked); confirmed schema (Phase 1, by code); decisions; open questions and next step.
   - A second compaction updates those sections with only the newly dropped messages instead of summarizing the previous summary.
   - Summarize the unmasked history (relevant once Phase 4 exists).
4. **Config:** `agent_compaction_mid_turn` (on).

**Tests:** the trigger uses recorded usage when present and the estimate otherwise; a mid-turn compaction keeps tool calls paired with their results (the existing cut rule); a second compaction keeps the first's facts.

**Measure:** compactions per session; facts lost across compaction (scorecard probes that ask about something established before it, like Factory's probe method); exact repeats after compaction.

## Phase 4: observation masking (soft compaction)

**Why:** the strongest result in the literature, but the baseline says staff chat turns are short. So it ships for the long loops first.

**Changes:**
- `agent.shape_context(messages, policy)`: keeps the last K tool results verbatim (policy, e.g. K = 5 or a token budget).
  - Replaces older results with a stub that keeps what they were: tool, arguments summary, size, result id, how to re-read.
  - Never masks errors, pinned schema results or results under ~300 characters.
  - Moves the masking boundary only in batches of at least ~4k tokens, so Gemini's implicit prefix cache survives between moves.
- Enabled per loop by config: `agent_masking = {research = true, background = true, chat = false}` first, then chat once the scorecard says so.
- Render-time only. The database and the UI transcript are unchanged.

**Tests:** stubs replace exactly the older results; errors and pinned results are untouched; the boundary moves only in batches; tool-call pairing holds.

**Measure:** on the scorecard's research-heavy scenarios and prod research/background runs: tokens per task, steps per task (watch for elongation), correctness, `cachedContentTokenCount` hit rate.

## Phase 5: summarize and split transcripts at save time

**Why:** cross-session memory and search. A session with tangents is one document with one embedding today.

**Changes:**
- `daat agent summarize-pending`, on the existing jobs timer next to `embed-pending`.
  - Picks sessions quiet for `embedding_quiet_minutes` whose transcript hash changed since the last run.
  - Makes one model call that returns structured segments: title, first and last message id, and an anchored summary (as Phase 3).
- Validation in code before writing: the message ids exist in the session and are in order, every message is in exactly one segment, and user requests are quoted verbatim.
- Each segment becomes a document under the transcript's document, linked to its message range, embedded and taggable like any other document.
  - A re-run updates segments matched by range, and archives ones a new segmentation dropped.
  - Segments inherit the transcript's visibility.
- `agent_transcript_segments` (default off until evaluated).

**Tests:** segmentation output validation (bad ids, gaps and overlaps are rejected); re-run idempotence; archive on resegmentation.

**Measure:** a small set of prod sessions with tangents, with questions only one tangent answers: `document.search` hit rank and answer quality, segments vs whole transcripts.

## Phase 6: later, only if the numbers ask for it

- System-prompt nudges to use `research.investigate` for reading-heavy work (cheap; can ride along with any phase).
- Recitation: a plan/notes block the agent updates in long loops.
- ACON-style tuning of the compaction and segmentation prompts from scorecard failures.
- The Claude path: `clear_tool_uses_20250919` and `count_tokens`, only if Claude becomes a production provider.

## Decisions for Ben

1. The usage log: a column on `knowledge_context` or a separate `agent_usage` table (plan assumes the former).
2. Whether `document.search`'s shorter excerpt (Phase 2.1) ships as the new default or only after a scorecard run (plan assumes after).
3. Whether segment documents (Phase 5) join the knowledge pool like other documents, or stay out of retrieval until reviewed.
4. Starting values: K for masking, the tool-result cap, the excerpt length. The plan's numbers are starting points for the scorecard, not decisions.
