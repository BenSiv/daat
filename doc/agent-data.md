# Agent data: types, curation, context and retention

Design, 2026-11-04, decisions settled the same day. Issue #23. This document decides what the agent keeps, what becomes knowledge, what the model sees, and for how long. It applies to every loop the agent runs: chat, research, background, self-check, compaction.

## Principles

1. **Reasoning and requests are knowledge.** What people ask and decide, and how the agent reasoned, are kept and curated, whichever loop produced them.
2. **Documents are knowledge-dense, not logs.** The pool holds what a reader can use, not a record of how the agent worked.
3. **Tool calls and results are for development, not for curation.** They are kept for debugging, evaluation and audit, and never feed the pool.
4. **Data is split by type, not by loop.** Knowledge and logs are handled differently in storage, curation, context and retention. Which loop produced a piece of data decides none of these.

## Today

Measured on celleste-lims production on 2026-11-04 (read-only, aggregates). The data covers 60 sessions by 7 users since 2026-09-03.

**What the agent writes, by what it is:**

| Data | Rows | Characters | Where |
|---|---|---|---|
| Person's messages | 216 | 0.04 M | `agent_message` (`user`) |
| Agent's text (replies, findings) | 165 text blocks | 0.21 M | `agent_message` (`assistant`) |
| Compaction summaries, self-checks | 115 | 0.14 M | `agent_message` |
| Thinking | 0 | 0 | none: the deployed model returns no thought parts, although Vertex is asked for them (`includeThoughts = true`) |
| Tool calls | 1,157 | 0.18 M | `agent_message` (`assistant` blocks) |
| Tool results | 1,104 | 2.74 M | `agent_message` (`tool_result`) |
| Model input (exact prompts) | 1,437 | 26.4 M | `agent_model_call.prompt`, kept 90 days (none older than that yet) |

What people and the agent actually said and concluded is about 0.4 M characters. Its working trail is about 30 times that.

**In the pool** (active documents):

| Type | Documents | Characters | Retrievals |
|---|---|---|---|
| People's and synced pages | 7,167 | 149.8 M | 1,201 |
| `chat_session` transcripts | 48 | 2.7 M (57k each on average) | 12 |
| `curated` (tier 1) | 160 | 0.4 M | 2 |
| `reference` (tier 2) | 15 | 0.1 M | 1 |
| `record` (tier 3) | 289 | 0.1 M | 0 |
| `distilled` (legacy) | 119 | 0.04 M | 5 |
| `experiment_view` | 226 | 0.2 M | 4 |

Chat transcripts are retrieved more often than all curated documents together. They are built from `agent_message`, where tool results are 76% of the characters, and they carry those results as written. Only 3 of the 48 have been curated.

**Sub-agents:** `research.investigate` was called 22 times in 13 sessions. Each sub-agent's steps were kept only inside its stored prompts. Its last step, and anything it reasoned about, were not kept anywhere.

**Today's split is by loop.** The main loop writes everything to `agent_message`, forever. Research and background loops keep their steps in memory and leave only prompts that expire after 90 days. A chat becomes a shared, searchable transcript with its tool output inside it. A step's thinking would become its own tier-0 pool document that is never curated (`CURATE_SOURCE_TYPES` covers transcripts and people's pages only), though none has been written yet.

## Data types

Every piece of data the agent produces has exactly one type. The type decides storage, curation, context and retention; the loop decides nothing.

### Knowledge sources

| Type | What it is | Today |
|---|---|---|
| `request` | What a person asked or decided, verbatim: messages, answers to `clarify.ask`, approve or deny with any reason. Corrections ("that's the wrong medium") and stated preferences are requests too. | `user` messages; approvals only in `agent_pending_action` |
| `answer` | What the agent concluded: final replies, research and background findings, progress notes, the wrap-up at a spent step budget. | `assistant` text blocks; a finding only as a tool result |
| `reasoning` | How it got there, in words: thinking, self-check critiques, compaction summaries, a sub-agent's intermediate text. | partly: `self_check` and `compaction_summary` rows; thinking not captured |

"Prompt" in principle 1 means the person's `request`. The assembled model input is a log (below).

### Logs

| Type | What it is | Today |
|---|---|---|
| `tool_trace` | Every tool call with its arguments, result or error, from any loop, linked to the model call that made it and, for a sub-agent, to the parent tool call. | main loop only, in `agent_message` |
| `model_input` | The exact prompt sent on each call. | `agent_model_call.prompt` |
| `call_metrics` | Kind, step, model, tokens, latency, reply evaluation, user feedback. | `agent_model_call` |
| `control` | Operational state: pending actions, background tasks, turn state and heartbeat, errors. | `agent_pending_action`, `agent_background_task`, `agent_session` |

### Curated knowledge

`curated` (tier 1), `reference` (tier 2) and `record` (tier 3), written by the ladder (`doc/tier-curation-ladder.md`). Unchanged by this design.

## Storage

**One conversation table, typed rows.** `agent_message` gets three columns:
- `data_type`: one of the types above;
- `loop`: `chat`, `research`, `background`, `self_check` or `compaction`;
- `parent_message_id`: for a sub-agent's rows, the message holding the tool call that started it.

Research and background steps are written there too, with `in_context = 0` for the main conversation. Their own loop reads them back by `parent_message_id`.

Why one table and not a separate log table: the provider protocol needs every tool call paired with its result inside the history the model reads (`pair_tool_results`). Keeping calls and results as rows of the same conversation keeps that pairing in one place. The type column, not the table, decides what curation, context and retention do with a row.

`agent_model_call` stays the record of each call (`model_input` and `call_metrics`), with `loop` and `parent_message_id` added, so research steps can be told apart and traced to their caller.

Approvals and denials are also written as `request` rows when they happen, so the conversation alone holds what the person decided. `agent_pending_action` stays the control record.

## Reasoning capture

Principle 1 needs reasoning to exist. Today it doesn't:
- **Thinking:** the deployed model returns no thought parts. Capturing it needs a thinking budget, which is a provider setting with a cost per call. Add `agent_thinking = "off" | "summary" | "full"` to `platform.lua`, translated per provider (Vertex `thinkingConfig.thinkingBudget` with `includeThoughts`; Claude `thinking`). Run the live scorecard with `off` and with `summary` (the model's thought summaries, the cheaper level), with the bar set before the run: no worse on correctness, at most about a third more tokens. If `summary` passes, production runs it; `full` is for eval.
- **Sub-agent text:** a research step's text is reasoning. It is kept as `reasoning` rows under its parent (Storage), not dropped.
- **Self-check and compaction:** already kept. Typed as `reasoning`.

Thinking is stored as `reasoning` rows in the conversation. It no longer becomes its own pool document: `knowledge.create_document_note(..., "reasoning", ...)` in `run_turn` is removed.

## Curation

**A conversation is one curation source: its `request`, `answer` and `reasoning` rows, from every loop.** A sub-agent's findings and reasoning join the conversation that started them. Tool traces are never read.
- The curate step reads the conversation that way, replacing `transcript_conversation`, which reads `user` and `assistant` rows only (no reasoning). Input is capped as now (40,000 characters). The newest requests and the final answers are kept whole first, reasoning fills the rest.
- The curated note says what was asked, what was concluded, why, and the caveats the reasoning raised. Corrections and preferences are stated as such. It cites the records and documents the answers cited.
- It may answer `NOTHING`, as now.
- **When:** a conversation is queued once it has been quiet for `agent_curate_quiet_minutes` (default 60) and has changed since its last curation, not only when a search retrieves it twice. An hour, not the 5 minutes embedding waits, so a chat picked up again after a short pause isn't curated in between; a later change rewrites its note in place. Today only 3 of 48 chats were curated, because a transcript is queued only after it is used.

**Raw conversations are not pool documents.** Only the curated note is in the pool and searchable. `sync_session_document` stops writing `chat_session` documents. The conversation stays readable on `/chat` for its owner, as now.

A deployment can keep raw transcripts searchable (`agent_transcript_documents`, below). Even then they hold `request`, `answer` and `reasoning` only, never tool traces, either whole or as Context Phase 5 segments.

**Logs are never curated.** Their readers are `daat agent context-report`, the scorecard, debugging, and audit. A display-only "how this was found" trail under an answer reads them in the UI; the model never does.

## Context

**Knowledge passes between loops; logs stay in the loop that produced them.**
- A sub-agent starts with the conversation's requests, the relevant curated knowledge, and the schema the main loop has confirmed. It does not get the main loop's tool trace.
- The main loop gets back the sub-agent's answer, plus its reasoning in short form (what it checked, what it ruled out, how much it covered). It never gets the sub-agent's tool trace. This keeps the reason research is a sub-agent (failed queries and raw rows stay out of the main context) while making the line one of type.
- Inside a loop, tool results are working memory. They are masked and compacted (#12, Context Phase 3). Requests and answers are carried word for word through compaction; reasoning is summarized.
- Across sessions, only knowledge carries over. Curated notes are found by search. A person's own requests and corrections may carry over into their own later sessions (#11). Tool traces never carry over.

## Visibility

- Raw conversation rows of every type are visible only to the session's owner, as `agent_session` already is, and to admins for debugging. Today's exception, the shared transcript document, goes away with the transcript documents. A colleague gets a conversation's curated note instead; a "share this chat" action can come later if people ask for it.
- Curated notes are shared, like every pool document. A curated note is written for the team: it states findings, not who asked.
- Logs are readable by the owner and by admins (debugging, audit).

## Retention

Retention is set per type. A deployment picks a strategy and can override single values in `platform.lua`:

```lua
agent_retention = "standard",                      -- "full" | "standard" | "lean"
agent_retention_override = {tool_trace_days = 30},  -- any key below
```

| Key | `full` (dev, eval, demo) | `standard` (default) | `lean` (privacy, partner test) |
|---|---|---|---|
| `knowledge_days` (raw `request`, `answer`, `reasoning`) | forever | forever | 30 days after the conversation is curated |
| `tool_trace_days` | forever | 90 | 14 |
| `model_input_days` (today `prompt_retention_days`) | forever | 30 | 0 (not stored) |
| `metrics_days` (`call_metrics`, `control`) | forever | forever | forever |
| `transcript_documents` | `whole` | `off` | `off` |
| Curated knowledge | forever | forever | forever |

What pruning does:
- **`tool_trace`:** a pruned result keeps its row, so the history still pairs every call with a result. Its content becomes a stub naming the tool, the argument summary and the original size, for example `[result pruned after 90 days: entity.query, 4,210 characters]`. The arguments are kept: they are small and show what was asked of the data.
- **`model_input`:** cleared, as `prune_prompts` does today.
- **Raw knowledge under `lean`:** removed only after the conversation's curated note exists or curation answered `NOTHING`, so nothing is lost before it is curated.

**"Prompt" in the code is the model input, not the person's request.** `agent_model_call.prompt`, `prompt_retention_days` and `prune_prompts` all mean the text assembled for one model call: the system prompt, the conversation so far and every tool result in it, stored again on every call. Clearing it removes those copies. The person's request is a `request` row in its conversation and is never touched by `model_input_days`. To end the double meaning, `prompt_retention_days` is renamed `model_input_days` (the old name still read as an alias), and `prune_prompts` becomes `prune_model_input`.

One job runs every rule: `daat store prune`, which already prunes stored model input and the passage cache, on the jobs timer.

With production's numbers, `standard` keeps the 0.4 M characters of knowledge forever. It keeps 30 days of model input (today 26 M characters over 60 days) and 90 days of tool results (2.7 M), then their stubs.

## Migration

1. **Type existing rows:**
   - `user` -> `request`;
   - `assistant` -> `answer` (a reply with tool calls is split by block type when read: text is the answer, tool calls belong to the trace);
   - `tool_result` -> `tool_trace`;
   - `self_check` and `compaction_summary` -> `reasoning`;
   - `error` and `progress` -> `control` and `answer`.

   Every existing row is `loop = chat`. Earlier research steps can't be recovered.
2. **Transcripts:** queue all 48 `chat_session` documents for curation, which reads them without tool output. Archive each transcript document once its conversation's note exists or curation answered `NOTHING`. Searches move to the curated notes.
3. **Reasoning documents:** none in production. The code path is removed.
4. **Prompts:** the new default (30 days) clears prompts older than that on the first prune.

Each step is reversible from the Cloud SQL backup. Only step 2 removes anything from the pool, and it archives rather than deletes.

## Decisions

Settled 2026-11-04:
1. **"Prompt" as knowledge** means the person's `request`. The assembled model input is a log.
2. **Storage:** typed rows in `agent_message`, no new table. The model needs every tool call paired with its result, and that pairing and the `in_context` flag already live there. Readers filter by type through one helper per use (curation input, context, display).
3. **Transcript documents** are retired. Each is archived only after its conversation's curated note exists, or curation answered `NOTHING`, so nothing leaves search before its note is there. Phase 5 segments only if the scorecard later shows curated notes missing what people ask for.
4. **Visibility:** raw conversations for their owner and admins; curated notes shared.
5. **Thinking:** `agent_thinking` added. The live scorecard decides between `off` and `summary` against a bar set before the run; production runs `summary` if it passes.
6. **Curation trigger:** quiet for `agent_curate_quiet_minutes` (60) and changed since the last curation, alongside the use-driven queue.
7. **Strategies:** production `standard` (knowledge forever, tool traces 90 days, model input 30 days); daat-test `lean` (a partner's environment keeps as little as possible beyond curated knowledge); eval, demo and local dev `full`.
8. **Naming:** `prompt_retention_days` becomes `model_input_days`, with the old name still accepted.

## Implementation

Each piece is its own issue, in this order; 5 can run alongside the others since it needs only a scorecard run. Each one measures its effect.

1. **Typed storage and the sub-agent trail:** the columns; research and background steps written under their parent; `agent_model_call.loop` and the parent link. Measure: every research step and its last step are recoverable; `context-report` breaks down by loop. Absorbs #19's step 0.
2. **Curation by type and visibility:** the conversation source (request, answer, reasoning from all loops), the quiet-plus-changed queue, transcript documents off, migration of the 48 transcripts, raw conversations owner- and admin-only. Measure: raw transcripts in the pool, from 48 documents (2.7 M characters) to none; scorecard `cites` and correctness; search hits on curated notes.
3. **Retention strategies:** `agent_retention` with overrides, tool-trace stubs, one prune job, the `model_input_days` rename. Measure: storage per type per day, before and after.
4. **Context by type:** sub-agent start context and its returned reasoning (#19 options 1 and 2), masking (#12), carried-over corrections (#11). Measure: failed lookups and tokens per run.
5. **Thinking capture:** `agent_thinking` per provider. Measure: live scorecard `off` vs `summary` against the bar in decision 5.

Tests for each: a research step that runs out of budget leaves its last step; a pruned tool result still pairs with its call; curation never reads a `tool_trace` row; a `lean` deployment removes raw knowledge only after curation; another user can't read a conversation's raw rows.
