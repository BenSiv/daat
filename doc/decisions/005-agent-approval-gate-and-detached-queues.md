# 005. Rule-Based Agent Control, Persisted Approval Gates & Detached Execution Queues

- **Date:** 2026-11-27
- **Status:** Accepted

## Context & Real Need

Off-the-shelf agent SDKs assume a persistent in-memory loop that awaits tool callbacks within one process ([agent-harness-rationale.md](../agent-harness-rationale.md)). Under `daat`'s multi-process CGI model ([001](001-cgi-per-request-lifecycle.md)), three production realities forced an owned architecture:
1. **Cross-request human approval & concurrency races:** Destructive mutations (`entity.create`/`update`/`archive`/`unarchive`, `document.create`/`update`, `knowledge.distill`) and external data exits (`internet_search.search`) must pause for human approval minutes or hours later. Checking `status = 'pending'` without an atomic DB claim allowed double-clicks or racing approve/deny requests to run a write twice (`#16`), while an approved write killed mid-execution left an unanswered `toolCall` that caused the model to re-propose and duplicate the write on `"continue"` (`#22`).
2. **Authorization & prompt-injection boundaries:** Early `admin_write_only` checks keyed off a shared `"chat-agent"` API key rather than the chatting user, letting Baseline (`i`) users escalate writes or capping Admin (`a`) users; meanwhile LLM-authored SQL (`entity.query`) can be steered by untrusted Document text and must never read `auth_user`, `auth_api_key`, or other users' `agent_message` rows.
3. **HTTP timeout truncation:** Running multi-step tool loops synchronously inside `POST` requests hit `180 s` load-balancer/Apache timeouts (`28` of `115` production user turns lost silently on 2026-10-13), and storing raw `tool_trace` blobs (`76%` of transcript chars, `2.74 MB`) plus repeated full prompts (`26.4 MB` over 60 sessions) polluted Knowledge Pool search if untreated.

## Decision

1. **Rule-based enforcement in Lua, prompts for judgment (`src/agent.lua`, `src/agent_tools.lua`, `src/view.lua`):**
   - Closed tool registry (`agent.build_tool_registry` over `AGENT_TOOLS` + approved Extensions, sorted deterministically) with hardcoded `destructive` flags and pre-approval no-op `precheck`s.
   - Writes run as the authenticated session `login` and check `auth_user.cap` via `agent_tools.check_write_capability` — identical to browser forms.
   - `entity.query` runs through `view.run_agent_query`, enforcing lexical `SELECT`-only syntax and restricting `FROM`/`JOIN` targets to `view.queryable_tables` (registered Entity tables, companion `<type>_<field>` junctions, `entity_ref`, `document_link`, and `entity_event`).
   - `research.investigate` constructs its tool declarations via `agent.research_may_call`, omitting all `destructive` and `control` (`research`, `clarify`, `background`) tools by construction and seeding only `request` rows + pinned schema (`zero` main-loop `tool_trace`).
2. **Persisted `agent_pending_action` state machine with atomic claims (`src/agent.lua`):**
   - Proposing a destructive tool writes `agent_pending_action(status = 'pending')` (`turn-ending` `clarify.ask` takes precedence if proposed in the same step; trailing calls after a pending write are deferred) and ends the turn immediately.
   - `approve_pending` / `deny_pending` claim the row first via `agent.claim_pending_action` (`UPDATE ... SET status = 'running'|'denied', claim_token = <hex> WHERE id = ? AND status = 'pending'` followed by read-back verification across SQLite and MariaDB), read exact `args_json` from the claimed row (`approved_arguments`), record an out-of-context `decision` row, and quarantine crashed `'running'` rows via `agent.interrupted_writes` so `pair_tool_results` warns the model not to blindly re-propose the write.
3. **Detached turn workers, CLI background queue & typed persistence (`src/agent.lua`, `src/config.lua`):**
   - Turn budgets, row/excerpt caps, and compaction thresholds are read fresh via `config.load()` per call.
   - Under `agent.turn_mode = "detached"` (default), sending/approving/denying spawns `daat agent continue <session_id>` with `GATEWAY_INTERFACE`/`REQUEST_METHOD` cleared, heartbeating `agent_session` on every turn and `research.investigate` step, auto-continuing up to `auto_continue_max` / `auto_continue_minutes`, and settling silent crashes after `turn_stale_seconds` (`180 s`). Longer async investigations enqueue into `agent_background_task` (`background.start`), drained by `daat agent run-pending-background`.
   - Every model call across all loops records its exact prompt, model, tokens, `kind`, `step`, and `parent_message_id` in `agent_model_call`, while `agent_message` tags every row with `data_type` (`request`, `answer`, `reasoning`, `tool_trace`, `control`) and `loop_kind` so curation reads only `request`/`answer`/`reasoning` and `daat store prune` clears aged `model_input_days` prompts and stubs `tool_trace_days` outputs without breaking `toolCall`/`toolResult` pairing ([agent-data.md](../agent-data.md)).

## Deliberate Tradeoffs & Not in Scope

- **Accepted cost:** At most one destructive tool call can await approval per turn; browser chat widgets poll `GET /api/v1/chat/sessions/<id>` (`800 ms`) rather than holding open WebSockets; clicking `Stop` (`agent.request_cancel`) halts between steps rather than killing an in-flight `curl` request; and resumed turns after human approval receive a fresh `max_turns` budget (human approval itself acts as the circuit breaker).
- **Not in scope:** Third-party agent orchestration frameworks, unapproved autonomous writes, shared service-account agent credentials, or cross-session user memory outside the shared Knowledge Pool (`#11`).
- **Revisit trigger:** If live token-by-token streaming is required, layer SSE over persistent worker mode (`#57`, [001](001-cgi-per-request-lifecycle.md)) while keeping `agent_pending_action`, `agent_background_task`, and `agent_model_call` unchanged.

## Verification

- `./bld/test.sh` & `./bld/eval.sh --mode test`
- `tst/unit/interrupted_write.lua`, `tst/unit/agent_retention.lua`, `tst/unit/agent_context_by_type.lua`, `tst/integration/agent*.bats`
- Full design rationale: [agent-harness-rationale.md](../agent-harness-rationale.md), [agent-tools.md](../agent-tools.md), and [agent-data.md](../agent-data.md)
