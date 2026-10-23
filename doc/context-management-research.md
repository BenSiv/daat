# Context management for daat's agent loops: research and options

Research note, 2026-10-23. Question: beyond the summarizing compaction daat already has, how should daat keep a model's context small and relevant as tool results and history pile up ("context rot")? It covers what the literature and other agent harnesses do, where daat stands, a measured prod baseline, and what to try first.

**Scope.** None of these techniques is specific to chat. They apply to every loop in daat that feeds a model a growing history:
- the chat agent (`agent.run_turn`)
- the `research.investigate` sub-agent
- `background.start` tasks
- knowledge-pool curation (`knowledge.list` / `knowledge.distill`)
- any future agent an extension runs

So they should be built once, in the shared pieces (tool dispatch, history rendering, compaction), not inside the chat code. **Chat is the first test case** because it is the only loop with prod history to measure (`agent_message`, `knowledge_context`) and a scorecard to A/B on (`bld/eval.sh`).

## Why it matters: context rot

- **Longer input means less reliable output, even on easy tasks.** Chroma tested 18 models (GPT-4.1, Claude 4, Gemini 2.5, Qwen3) on deliberately simple tasks and found every one got less reliable as input length grew, with the length as the only variable. Content that resembles what the model needs, without being it (distractors), hurt more than unrelated filler. ([Chroma, "Context Rot", 2025](https://trychroma.com/research/context-rot))
- **Anthropic frames context as an "attention budget"** that every token spends. Their advice is to find "the smallest possible set of high-signal tokens" for each step. ([Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents))
- **For daat this is concrete.** An `entity.query` that returns 150 near-identical sample rows is exactly the "similar but not needed" content Chroma found most harmful. Prod runs `gemini-3.5-flash-lite`, a small model, with a 20-step budget and up to 3 automatic continuations. The 2026-10-13 chat review found turns that died, schema re-fetched after compaction, and answers that weren't reproducible. Those are the symptoms this research targets.

## The techniques, from lightest to heaviest

| Technique | What it does | Costs a model call? | Reversible? | Who uses it |
|---|---|---|---|---|
| **Size cap at the tool boundary** | A single oversized tool result is cut down (head, plus a note on how to get the rest) before it enters context | No | Yes, if the full result is kept and re-readable | Claude Code caps tool output; LangChain deepagents moves results over 20k tokens to a file and leaves a pointer |
| **Observation masking / tool-result clearing** ("soft compaction") | Tool *results* older than the last K are replaced with a short placeholder. The model's own calls and reasoning stay. | No | Yes, if a pointer to the full result stays | Anthropic `clear_tool_uses`, LangChain `ClearToolUsesEdit`, SWE-agent |
| **Restorable compression** | Drop bulky content but keep the identifier that re-fetches it (URL, file path, record id) | No | Yes | Manus |
| **Trimming** | Drop whole old turns, keep the last N | No | No | OpenAI Agents SDK sessions |
| **LLM summarization (compaction)** | A model rewrites older history into a summary | Yes | No | Claude API compaction, Google ADK, OpenHands, deepagents, **daat today** |
| **Sub-agents** | Reading-heavy work runs in a separate context and returns a 1–2k-token finding | Yes, a whole sub-loop | n/a | Anthropic multi-agent research, **daat `research.investigate`** |
| **Recitation / notes** | The agent keeps a plan or notes and re-states it near the end of context | Small | n/a | Manus `todo.md`, Anthropic `NOTES.md` |

### The strongest evidence: masking matches summarization at lower cost

JetBrains Research compared the two directly on SWE-bench Verified (NeurIPS 2025, [arXiv 2508.21433](https://arxiv.org/abs/2508.21433)):

- **Masking:** keep the last 10 turns' tool observations, replace older ones with a placeholder, and keep every action and piece of reasoning verbatim.
- **Summarization:** an OpenHands-style summarizer folds 21 turns at a time into a running summary and keeps the last 10.

| Model | Strategy | Solve rate | Cost per task |
|---|---|---|---|
| Gemini 2.5 Flash | No management | 32.8% | $0.41 |
| | Masking | 35.6% | $0.18 (−56%) |
| | Summarization | 36.0% | $0.24 (−42%) |
| Qwen3-Coder 480B | No management | 53.4% | $1.29 |
| | Masking | 54.8% | $0.61 (−53%) |
| | Summarization | 53.8% | $0.64 (−50%) |

Three findings matter for daat:

1. **Masking was as good as summarization**, and both beat doing nothing on quality as well as cost. Clearing old observations is not just a cost trade.
2. **Summarization made runs longer:** about 52 turns versus 44 with masking on Gemini 2.5 Flash. The authors think a summary encourages the agent to keep going. The summary calls themselves were up to 7% of the cost.
3. **A hybrid did best:** mask from the start, summarize only as a last resort (and summarize the unmasked history when it does). That was 7% cheaper than masking alone and 11% cheaper than summarization alone. Their settings: mask window 10, summarize 43 turns at once.

Caveat: these are coding-agent results. daat's workload is shorter turns with heavier reads (records, documents), so the numbers won't transfer exactly. The direction is what to test.

### Other findings worth keeping

- **Keep the identifier, drop the bulk** (Manus): "the content of a web page can be dropped from the context as long as the URL is preserved". In daat terms: drop a document's body but keep `document #1234` and how to re-read it.
- **Keep errors in context** (Manus): failed calls and error messages are how the model learns not to repeat a mistake. Masking should exempt error results, or at least shrink them last.
- **Stable prefix for caching** (Manus): editing earlier context breaks prompt caching from that point on. Anthropic's `clear_at_least` exists for the same reason: clear in large batches, so the cache is rebuilt rarely. Moving the masking boundary one result per step would break the cache on every step.
- **Summaries need structure, and should be updated rather than redone** (Factory): an "anchored" summary with fixed sections (intent, facts established, decisions, next steps), extended with only the newly dropped segment, retained more than the Anthropic and OpenAI defaults in their probe-based evaluation. The metric that matters is *tokens per completed task*, not per request: a summary that loses a detail costs a re-fetch later. ([Factory, Evaluating context compression](https://factory.ai/news/evaluating-compression))
- **Learn what the compressor drops** (ACON, [arXiv 2510.00615](https://arxiv.org/abs/2510.00615)): find cases where the full context succeeds and the compressed one fails, and rewrite the compression instructions from them. That cut peak tokens 26–54% while keeping accuracy. daat's agent scorecard could drive the same loop.
- **Make tools concise by default** (Anthropic, [Writing tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents)): offer a concise vs detailed response shape, paginate, filter and truncate, and let the agent ask for more rather than receive everything.

## Provider-side vs in-house

There are two ways to get each technique: switch on a feature the model provider runs on its servers, or build it into daat's own agent loop (`agent.lua` builds the message list for every model call itself). They are kept apart here because they behave differently:

- **Provider-side** features only exist for one provider's API. They are often beta, and their behaviour, defaults and pricing are set by the provider. daat would get them for free, but only on that provider.
- **In-house** techniques work identically for every provider, because daat renders the history itself. They are daat's code to maintain, test and tune.

### Provider-side: what each API offers

**Gemini on Vertex (prod: `gemini-3.5-flash-lite`, via `generateContent` in `provider/agent_vertex.lua`):**

| Feature | Available | Notes |
|---|---|---|
| Clearing old tool results | **No** | No documented option on `generateContent` or the newer Interactions API |
| Compaction / summarization | **No**, for plain model calls | Google's managed agents (Interactions API) compact automatically at ~135k tokens, but daat doesn't use them. Google ADK compaction is a client-side framework feature, so it's effectively in-house code written in Python, not a server feature. |
| Implicit prompt caching | **Yes, on by default** | 90% discount on cached input tokens, prefix-based, minimum ~2k tokens (Google's sources differ for Gemini 3). `cachedContentTokenCount` in the response shows hits. This is the one provider feature daat already benefits from, and the one in-house edits can break. |
| Explicit context caching | Yes | Paid storage of a named cache; only worth it for a large fixed prefix |

([Vertex context cache overview](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/context-cache/context-cache-overview), [Gemini 2.5 implicit caching](https://developers.googleblog.com/gemini-2-5-models-now-support-implicit-caching), [Interactions API](https://ai.google.dev/gemini-api/docs/interactions-overview))

**Claude (daat's `provider/agent_claude.lua`, calling api.anthropic.com):**

| Feature | Available | Parameters / notes |
|---|---|---|
| Tool-result clearing | Beta `context-management-2025-06-27`, edit `clear_tool_uses_20250919` | `trigger` (default 100k input tokens), `keep` (default 3 tool uses), `clear_at_least`, `exclude_tools`, `clear_tool_inputs`. Cleared results become a placeholder; the client keeps the full history; `applied_edits` in the response reports what was cleared. Clearing invalidates the prompt cache from that point, which is why `clear_at_least` exists. |
| Thinking clearing | Same beta, `clear_thinking_20251015` | `keep` in thinking turns |
| Compaction | Beta: on demand (`compact-2026-09-04`, the recommended form) or at a token threshold | The server writes the summary. A custom summary prompt is supported, as is keeping recent turns verbatim. |
| Memory tool | `memory_20250818` | The model reads and writes files that daat would store. Combined with clearing, the model is warned to save notes before results are cleared. |
| Token counting | `count_tokens` endpoint | Exact pre-flight counts |
| Prompt caching | Yes, explicit breakpoints or automatic | |

All of these are also offered for Claude on Vertex, Bedrock and Foundry, as beta where marked. ([Context editing](https://platform.claude.com/docs/en/build-with-claude/context-editing), [Compaction](https://platform.claude.com/docs/en/build-with-claude/compaction))

**What this means for daat:** the provider daat runs in prod offers none of the context-shrinking features, only caching. Building on Claude's beta features would help only on a provider daat doesn't use in prod, and would give the two providers different behaviour on the same deployment. So the core techniques have to be in-house. Provider features are an optional extra for the Claude path, not the foundation.

### In-house: what daat builds itself

All of these run in daat's own loop, the same way for every provider:

| Technique | Where it lives in daat | Status |
|---|---|---|
| LLM summarization (compaction) | `agent.compact_if_needed` | **Exists**, at turn start only |
| Verbatim carry-over of user requests | inside compaction | **Exists** |
| Row caps on query tools | `agent_query_row_cap`, `entity.list` limit | **Exists** |
| Sub-agent context isolation | `research.investigate`, `background.start` | **Exists** |
| Size cap per tool result, restorable | tool dispatch, plus a paging tool | Proposed (step 1) |
| Observation masking / soft compaction | `build_history_messages` | Proposed (step 2) |
| Hybrid trigger, anchored summary, mid-turn compaction | `agent.compact_if_needed` | Proposed (step 3) |
| Recitation / notes | system prompt + a notes field | Later |
| Transcript summary, split by topic, at save time | a quiet-session job beside `embed-pending` | Proposed (step 6) |
| Keeping the cache prefix stable | batching the masking boundary; deterministic rendering | Proposed (part of step 2) |

**Where the two meet:** in-house edits to earlier messages change the prefix that Gemini's implicit cache matches on. That is the one interaction to design for, by clearing in batches and rendering deterministically. If the Claude path is ever used seriously, its provider-side clearing could replace step 2 there, but daat's own masking would still be needed for Gemini, so building it once in-house is simpler.

## Where daat stands

What exists (`src/agent.lua`):

- **Compaction** (`agent.compact_if_needed`): runs **once, at the start of a turn**, when the estimated size (characters ÷ 4) of the system prompt plus active history passes `agent_compaction_threshold` (32,000). It keeps the last 4 messages, never splits a tool call from its result, and summarizes the rest under a 400-word limit. Inside the summarizer's input, tool arguments are capped at 800 characters and tool results at 1,500. It appends the user's last 3 requests verbatim by code, marks the summarized rows `in_context = 0`, and deletes nothing.
- **Row caps:** `entity.query` is capped at 200 rows (`agent_query_row_cap`) with a "showing N of M" note. `entity.list` defaults to 20.
- **Sub-agents:** `research.investigate` runs a 12-step sub-loop and returns a finding. `background.start` runs longer work outside the chat.
- **Audit trail:** `knowledge_context` stores every model call's prompt and the provider's `prompt_tokens` / `completion_tokens`. So the real context size per step is already being recorded in prod.

Gaps:

1. **Nothing manages context *within* a turn.** Compaction only runs before the first step. A turn of 20 steps, plus up to 3 automatic continuations, sends every tool result from every step on every later model call. Context rot is likely worst exactly there: long research turns that end up as dead turns or status updates.
2. **No size cap on a single tool result.** `entity.get` returns every field of the record (`row_summary`), so `entity.get document` returns the whole document body, which can be a full imported paper. A 200-row `entity.query` of wide rows can be tens of thousands of tokens.
3. **Old tool results never shrink**, except by being summarized away at the next turn's compaction. Once compaction has run, a fetched schema is gone, which the 10-13 review saw as fields being re-fetched after every compaction.
4. **The size estimate is characters ÷ 4,** even though the provider's real `prompt_tokens` for the previous call is already available.

## Prod baseline (2026-10-23)

Measured read-only on prod (`platform_readonly`, SELECT-only): 57 sessions from 6 logins, of which 35 sessions were admin testing, and 1,398 recorded model calls on `gemini-3.5-flash-lite` between 09-03 and 10-22. Aggregates only; no content was read.

**How big context gets.** `knowledge_context` records a turn's final call (the largest step of the turn), compaction, wrap-ups and errors. It does not record intermediate tool-calling steps.

| | Calls | Avg prompt tokens | Max | Over 20k | Over 32k |
|---|---|---|---|---|---|
| Staff | 849 | 9,007 | 39,499 | 60 | 11 |
| Admin testing | 549 | 12,050 | 51,220 | 87 | 43 |

A staff turn averages 6 tool results totalling about 11k characters (max 11 results and 78k characters in one turn). Context is nowhere near the model's limit; the issue is quality and repetition, not overflow.

**Where the tokens come from.** Tool results are **77% of all stored history** (2.65M of ~3.45M characters).

| Tool | Calls | Avg chars | Max chars | Results >8k chars |
|---|---|---|---|---|
| `document.search` | 167 | 5,904 | 8,438 | 2 |
| `entity.query` | 517 | 1,502 | 59,130 | 21 (3 over 24k) |
| `knowledge.list` | 10 | 50,736 | 65,187 | 10 (all over 24k) |
| `entity.relationships` | 65 | 2,065 | 2,177 | 0 |
| `entity.get` | 44 | 2,147 | 44,642 | 2 |
| `entity.fields` | 114 | 589 | 1,703 | 0 |

**The agent re-fetches what it already had.** Exact repeats: same session, same tool, same arguments.

| Tool | Calls | Exact repeats |
|---|---|---|
| `entity.fields` | 114 | 48 |
| `entity.relationships` | 65 | 45 |
| `entity.list_types` | 70 | 40 |
| `document.search` | 206 | 33 |
| `entity.query` | 521 | 15 |

**133 of 249 schema calls (53%) repeat one already made in the same session.**

**Compaction fires often and repeatedly.** 26 sessions were compacted, 20 of them more than once, one 20 times.

**The size estimate is off.** Prompt tokens are about 5k of fixed overhead (system prompt and tool definitions, which the characters ÷ 4 estimate never counts) plus roughly 1 token per 3.3 characters of history, not per 4.

What this changes:
- **The cheapest, clearest win is not losing what's already known.** Over half the schema lookups are re-fetches. That points to keeping confirmed schema (and other small, stable facts) through compaction and masking, rather than to shrinking context further.
- **Size caps matter for a few tools, not across the board.** `knowledge.list` is the worst offender every time, then the long tail of `entity.query` and `entity.get` on documents. `document.search` is consistently ~6k characters and called often, so a more concise result shape there saves the most in total.
- **Masking is less urgent for staff chat than expected,** at 6 tool results per turn on average. It matters more for the long loops: admin research turns (up to 36 results), `research.investigate`, background tasks and curation. That is where to test it.
- **Measurement gap:** intermediate steps aren't logged, so the peak of a turn that dies mid-way is invisible. Record usage for every step (one row per model call, or at least the prompt token count) before A/B testing masking.

## Recommendation

All in-house (see above for why), and built in the shared tool-dispatch, history and compaction code so every loop gets it, with chat as the first test case. Re-ordered by the baseline above. Each step can ship on its own and be measured before the next.

**0. Keep what's known: pin small, stable results** (from the baseline: 53% of schema calls are re-fetches).
- Results of `entity.list_types`, `entity.fields` and `entity.relationships` (and, later, other small lookups that don't change within a session) are never masked. Compaction carries them as a "confirmed schema" section, verbatim, instead of summarizing them away.
- In addition, or as a cheaper first try: when the agent repeats an exact call whose result is still current, answer from the stored result with a note ("same as your earlier call") rather than re-running it and adding a second copy to context.

**1. Cap each tool result at the tool boundary (restorable).**
- When the text sent to the model exceeds a budget (a starting point is ~6k tokens, configurable as `agent_tool_result_cap`), send the head plus a footer: `[truncated: 48,213 more characters. Full result stored as result #812; call agent.read_result(812, offset) for more, or narrow the query]`.
- The full text is already stored in `agent_message`, so a small paging tool is the only new piece. No data is lost.
- Special case `entity.get` on long text fields: return metadata, an outline (the headings) and the first section, and let the agent page or `document.search` within it.
- From the baseline, the targets in order: `knowledge.list` (~50k characters every call), the long tail of `entity.query` (21 results over 8k), and `entity.get` on documents (up to 44k). For `document.search`, which is ~6k characters on every one of its frequent calls, a concise default (titles, ids and one short snippet each, with full snippets on request) saves the most in total.

**2. Observation masking at every step, in `build_history_messages` ("soft compaction").**
- When rendering history for a model call, keep the last K tool results verbatim (start with K = 5, or a token budget). Replace older results with a stub that keeps what the result *was*: `[earlier result cleared: entity.query, 143 rows (ids 812-955), result #812 -- agent.read_result to reread]`.
- Keep every assistant message and tool call, arguments included, verbatim (the JetBrains setup). Never mask error results, or results under a few hundred characters such as confirmations and short lookups.
- This happens at render time only. The database stays append-only, the UI transcript is unchanged, and it works the same for Gemini and Claude.
- **Move the boundary in batches** (clear at least ~4k tokens at a time) rather than one result per step, so the cached prefix stays stable between clearings.
- This fixes gap 1 without a model call. It also probably removes some of the reasons compaction fires at all.
- Test it first where turns are long: admin research turns, `research.investigate`, background tasks and curation. Average staff chat turns (6 results) would barely change.

**3. Keep LLM compaction as the last resort, and make it better (the hybrid).**
- Trigger on the provider's last real `prompt_tokens` instead of characters ÷ 4. Allow it to run mid-turn, not only at turn start.
- Summarize the *unmasked* history, so the summarizer sees real results.
- Make it anchored: fixed sections (user requests verbatim, as now; entity ids and what they are; confirmed table and field names; queries that worked; decisions; open questions and next step). Update the previous summary with only the newly dropped segment instead of re-summarizing a summary.
- Keep the confirmed schema as a carried section (step 0).

**4. Push reading-heavy work into the existing sub-agent.**
- Tell the main agent, in the system prompt and tool description, to use `research.investigate` for "read these N documents and tell me X", so the reading never enters the main context.
- That is what the Anthropic multi-agent pattern does, and daat already has the mechanism.

**5. Later, if turns stay long:** a short plan or notes block that the agent updates (recitation), and ACON-style tuning of the compaction prompt from scorecard failures.

**6. Across sessions: summarize each transcript at save time, split by topic.**

Steps 1–5 manage context *inside* a live session. This step is about what a finished session leaves behind for later sessions and for search.

*Today:* after every turn, `knowledge.sync_session_document` re-saves the whole session as one transcript document. It is embedded as a single unit, from its conversation without tool calls. A session that wandered (a question about Exp396 growth, then a tangent on media recipes, then a label-printing problem) becomes one embedding that is an average of three topics and a good match for none of them. A later session that needs one of those threads either finds the whole transcript or nothing.

*Proposal:* a background job that runs when a session goes quiet, like `embed-pending` (after `embedding_quiet_minutes` with no new message, and only if the transcript changed since the last run). It makes one model call over the conversation that both splits it by subject and summarizes each part. Its structured output, per segment:
- a title, plus the first and last message id it covers
- a summary in the same anchored shape as step 3: the user's request verbatim, what was established (entity ids and what they are, queries that worked, numbers with where they came from), decisions, and what was left open

Each segment becomes its own small document under the transcript's document, linked to the exact message range, so a reader can open the original. Each is embedded on its own and is taggable like any other document.

Why split rather than summarize the whole session:
- **Retrieval is better by topic segment.** In SeCom, memory built from topical segments retrieved better and gave better answers than memory built per turn, per session, or from session summaries, on long-conversation benchmarks (LOCOMO, Long-MT-Bench+). The authors also found that small models (Mistral-7B, even RoBERTa-sized) segment well, so a cheap model can do this part. ([SeCom, ICLR 2025](https://arxiv.org/abs/2502.05589))
- **The next session gets a small, relevant piece.** An agent that `document.search`es past conversations gets "the media-recipe thread from Tuesday: what was asked, what was found" at a few hundred tokens, instead of a whole transcript dropped into its context.
- **The same boundaries can drive live compaction later.** If a live session switches topic, the finished tangent's segment summary could replace that tangent's messages in context. That is compaction at a natural boundary rather than at an arbitrary token count. Worth trying only after steps 1–3.

Rules it needs, from what went wrong with compaction before:
- Segment boundaries must be message ids that exist in the session, and each summary may only use its own range. Check both in code before writing.
- Keep the user's requests verbatim. The 10-13 review saw a free-form summary turn a user's request into a different task.
- Re-running on a session that grew updates its segments in place (matched by message range) rather than adding duplicates. A changed segmentation replaces the old one, archived rather than deleted, as elsewhere in daat.
- Segment documents inherit the transcript's visibility. Transcripts are already shared documents, so this adds no new exposure, but it does make past chats easier to find, which users should know.
- Cost: one model call per session that went quiet and changed. Chat sessions are few enough that this is small next to the chat itself.

**Optional, Claude path only (provider-side):** when the Claude provider is used, `clear_tool_uses_20250919` could stand in for step 2 there and the `count_tokens` endpoint for the size estimate. This is worth doing only if Claude becomes a real production option. Until then, one in-house implementation for both providers is less to keep consistent.

**Not recommended:** trimming whole old turns (it loses the user's requests and the agent's decisions, which the current verbatim-requests rule exists to protect), or making a provider-side beta the foundation while prod runs Gemini, which has no equivalent.

## How to measure

Measure before changing anything, using data daat already has:

1. **Baseline from prod:** done, see "Prod baseline" above. Before A/B testing, add per-step usage logging, so a turn's whole growth (and the peak of a turn that dies) is visible.
2. **A/B on the agent scorecard** (`bld/eval.sh`, live mode against the demo lab): baseline vs cap vs cap+mask vs cap+mask+hybrid compaction. Compare:
   - correct %
   - **tokens per completed task**, not per call
   - steps per task (watch for the elongation summarization caused in the JetBrains study)
   - re-fetches of the same tool and arguments
   - dead or out-of-budget turns
3. **For step 6:** take past prod sessions that wandered, write questions only one tangent answers, and compare `document.search` hits and answer quality with whole-transcript documents vs segment documents.
4. **After deploying,** repeat the prod chat review against the 10-13 baseline: dead turns 28/115, schema-guess errors, "continue" replies.

## Sources

- Chroma, [Context Rot: How Increasing Input Tokens Impacts LLM Performance](https://trychroma.com/research/context-rot) (Jul 2025)
- Lindenbauer et al., JetBrains Research / TUM, [The Complexity Trap: Simple Observation Masking Is as Efficient as LLM Summarization for Agent Context Management](https://arxiv.org/abs/2508.21433) (NeurIPS 2025)
- Pan et al., Tsinghua / Microsoft Research, [SeCom: On Memory Construction and Retrieval for Personalized Conversational Agents](https://arxiv.org/abs/2502.05589) (ICLR 2025)
- Kang et al., [ACON: Optimizing Context Compression for Long-horizon LLM Agents](https://arxiv.org/abs/2510.00615) (2025)
- Anthropic, [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) and [Writing effective tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents)
- Claude API docs: [Context editing](https://platform.claude.com/docs/en/build-with-claude/context-editing), [Compaction](https://platform.claude.com/docs/en/build-with-claude/compaction)
- Manus, [Context Engineering for AI Agents: Lessons from Building Manus](https://manus.im/en/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus) (Jul 2025)
- Factory, [Evaluating context compression for AI agents](https://factory.ai/news/evaluating-compression) (Dec 2025)
- Google, [Vertex AI context cache overview](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/context-cache/context-cache-overview), [Gemini 2.5 implicit caching](https://developers.googleblog.com/gemini-2-5-models-now-support-implicit-caching), [Interactions API](https://ai.google.dev/gemini-api/docs/interactions-overview)
- OpenAI cookbook, [Session memory: trimming and compression](https://developers.openai.com/cookbook/examples/agents_sdk/session_memory)
- LangChain, [middleware reference](https://reference.langchain.com/python/langchain/middleware/) and [deepagents harness](https://docs.langchain.com/oss/python/deepagents/harness)
- Google ADK, [Context compaction](https://adk.dev/context/compaction/)
