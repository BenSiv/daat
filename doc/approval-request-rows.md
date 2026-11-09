# Approvals and denials as request rows

Plan, 2026-11-09. Issue #23, `doc/agent-data.md` ("Storage": "Approvals and denials are also written as `request` rows when they happen"). Built with piece 2 (curation by type), whose curation is the first thing that reads them.

## Why

A person's approval or denial of a write is a decision, and decisions are knowledge (`doc/agent-data.md`, principle 1). Today it exists in two places, neither of which is a request:
- `agent_pending_action.status` (`approved` / `denied`): a control record, outside the conversation.
- The tool result the model gets: the write's own result, or `User denied execution of this action.` That is a `tool_trace` row, which curation never reads and retention stubs after 90 days.

So a conversation's curated note can't say "the user declined to archive the old SOP". With a `request` row, the conversation alone holds what the person decided, and it is kept as long as the rest of their requests.

## Design

**One row per decision, written when it is made.** `agent.approve_pending` and `agent.deny_pending` each add a row through `agent.add_message`:
- `role = 'decision'`, `data_type = 'request'`, `loop_kind = 'chat'`, no parent;
- `in_context = 0`;
- written right after the claim succeeds and before the tool result. The conversation then reads in order: the proposed call, the decision, the result.

**Content:** one line a reader understands without the pending-action table, plus the reason when one is given:

```
Approved document.update (pending action #12): {"id": 431, "title": "Media prep SOP v3"}
Denied entity.archive (pending action #13): {"entity_type": "sample", "id": 88}. Reason: still in use for Exp412.
```

The arguments are the claimed row's `args_json`, cut to 300 characters: enough to say which record, without copying a document body into the conversation a second time.

**Why out of context (`in_context = 0`):** the model already gets the decision as the tool result, so a second copy only costs tokens. And `build_history_messages` turns rows into provider messages by role: a row between a tool call and its result would need its own rule in `pair_tool_results`. A row the model never sees changes neither. Curation reads `request` rows whether in context or not, so this costs it nothing.

**A reason for a denial.** `POST /api/chat-widget-deny` takes an optional `reason` (cut to 1,000 characters). When given, it goes into the decision row and into the tool result (`User denied execution of this action. Reason: ...`), so the model can act on it in the same turn. The widget gets an optional "Why not?" field beside Deny. Approvals take no reason: nobody asked for one, and an approval's arguments already say what was agreed to.

**Display.** All readers that load a whole session already include the row, since it has no parent:
- the chat view and widget show it as a short step line, labelled "Decision" (`ROLE_LABELS`);
- the transcript and curation input show it as `Decision: ...`.

**Clarifying questions** need nothing new: the person's answer to `clarify.ask` arrives as their next message, already a `user` row typed `request`.

## What doesn't change

- `agent_pending_action` stays the control record (claims, status, arguments).
- The tool result rows, their pairing, and what the model sees.
- History: past decisions aren't backfilled (`doc/chat-history-migration.md`, decision 4). For those sessions, curation can read the decided rows in `agent_pending_action` next to the conversation.

## Retention

A decision is a `request`, so it is kept like the rest of the person's words: forever under `standard`, and under `lean` until 30 days after the conversation is curated.

## Tests

- An approval writes one `decision` row (`request`, out of context) between the call and its result, naming the tool, the pending id and the arguments.
- A denial with a reason writes the reason into both the decision row and the tool result. A denial without one writes neither reason line.
- A second approve or deny that loses the claim writes no decision row.
- `build_history_messages` gives the model the same messages with and without decision rows present.
- The chat view shows the decision; the transcript and the curation input include it.
- Long arguments are cut to 300 characters in the decision row.

## Measure

Decisions per week and the share with a reason, from `agent_message` (`role = 'decision'`). How often a curated note states a decision (`daat repair curate` output reviewed by hand on the first prod pass).
