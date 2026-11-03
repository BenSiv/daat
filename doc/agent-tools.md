# Agent tools: one record per tool

Status: design, for review. Implementation is #6 and starts only after this is approved.

## Problem

Everything daat knows about one agent tool is spread over several places, and nothing checks that they agree. Adding a tool means editing two to four of them.

| Fact about a tool | Where it lives today |
|---|---|
| Name, description, parameters, `destructive` | `agent_tools.AGENT_TOOLS` (`src/agent_tools.lua`): 13 groups, 33 methods, 8 destructive |
| What it does | `agent_tools.execute_tool`: one function of about 800 lines, a chain of 32 `if tool_name == ... and method_name == ...` branches, then the extension fallback |
| A check before approval | `agent_tools.reject_before_approval`: hard-coded cases for `entity.update` and `document.update` |
| `clarify.ask` | No handler at all. `agent.run_turn` special-cases it by name, and ends the turn |
| What a sub-agent can't call | The names `research`, `clarify` and `background`, written twice: in `agent_tools.research_tool_declarations` and in `agent.run_research_loop`'s per-call guard |
| Extension tools | Resolved by `agent_tools.find_extension_tool`, called separately from `agent.is_known_tool`, `agent.is_destructive`, `agent.tool_declarations`, `research_tool_declarations` and `execute_tool` |
| Names an extension may not take | `RESERVED_TOOL_NAMES` (`src/extension.lua`), a hand-kept copy of the group names |
| Which calls may be answered with "same as before" | `REPEAT_SAFE_TOOLS` (`src/agent.lua`, Context Phase 1): six names |
| Which results survive compaction | `PINNED_SCHEMA_TOOLS` (`src/agent.lua`, Context Phase 1): the three schema tools, the same names written a second time |
| What to tell the model when the arguments are wrong | Inside individual handlers, where someone thought of it: `unknown_entity_type_message` suggests the nearest type; `stats.fit` lists the actual columns for a wrong `group_column` (6845d3e); `entity.query`'s SQL error (`src/view.lua`) only says to call `entity.fields`, without naming the columns (#8) |

### The lists have already drifted

`RESERVED_TOOL_NAMES` has 10 names. `AGENT_TOOLS` has 13 groups: `calc`, `stats` and `result` were added later and never reserved. So an extension named `stats` passes validation and is approved. `agent.tool_declarations` then offers its tools to the model, but `agent.is_known_tool` looks in `AGENT_TOOLS` first, finds the built-in `stats` group, and reports any method that group doesn't have as unknown. The model is shown a tool that can never run. This is the kind of error the design below makes impossible: the reserved names become the registry's own keys, not a list someone has to remember.

## Record shape

Every tool, built-in or from an extension, is one record:

```lua
{
    description = "...",           -- what the model reads
    parameters = {...},            -- plain JSON Schema (doc/agent-protocol.md)
    destructive = false,           -- true: always goes through the approval gate
    handler = function(ctx, args) -> result, err,
    in_research = true,            -- a research sub-agent may call it
    control = nil,                 -- nil | "clarify" | "research" | "background"
    precheck = nil,                -- optional, destructive only: function(ctx, args) -> err | nil
    recover = nil,                 -- optional: function(ctx, args, err) -> hint | nil
    repeat_safe = false,           -- an exact repeat may be answered from context
    pin_on_compaction = false,     -- the result is kept verbatim through compaction
    result_cap = nil,              -- nil: agent_tool_result_cap applies
}
```

`precheck` refuses a destructive call that can't do anything before it becomes a pending action, so a person is never asked to approve a no-op. It returns the error text, or `nil` when the call may go to approval. It replaces `agent_tools.reject_before_approval`: `entity.update` and `document.update`, the two tools with a case there today, get it as their `precheck`, with the same messages. `document.update`'s handler already repeats that check when it runs, and keeps doing so by calling its own `precheck`.

`recover`, `repeat_safe`, `pin_on_compaction` and `result_cap` are explained in "Recovery hints" and "Repeat calls and result size" below.

`ctx` is what `execute_tool` builds or receives today, passed explicitly instead of read from its arguments:

```lua
ctx = {
    db_path = db_path,
    author = author,           -- the real logged-in user; tools run as them
    session_id = session_id,
    source = {notebook_entry_id = "agent-session:" .. tostring(session_id)},
}
```

A handler returns what an `execute_tool` branch returns today: result text, or `nil, err`. `agent.run_tool` keeps its `pcall`, so a handler that raises still becomes an error tool result rather than a dead turn.

Rules for the fields, checked when the registry is built:
- `description` and `parameters` are required. `handler` is required unless `control == "clarify"`, the one tool whose effect is the turn ending.
- `destructive` and `in_research` are booleans. A missing `in_research` means `false`, so a new tool is hidden from sub-agents until someone decides otherwise.
- `control` is `nil` or one of the three kinds. A tool with a `control` kind is never visible to a sub-agent, whatever `in_research` says.
- `repeat_safe` and `pin_on_compaction` are booleans, default `false`, and only allowed on a non-destructive tool: answering a write with "same as before" would skip the write.
- `precheck` is `nil` or a function, and only allowed on a destructive tool: it runs on the way to approval, which only destructive tools take.
- `recover` is `nil` or a function. `result_cap` is `nil` or a positive number.

### Where the records live

`AGENT_TOOLS` keeps its shape: `AGENT_TOOLS[group][method] = record`. Each record gains `handler`, `in_research` and `control` next to the fields it already has. Keeping the same table means `pairs` walks the same keys in the same order, which matters for "No change to what the model sees" below.

Handlers stay in `src/agent_tools.lua` for now, as named functions next to their group (`function document_search(ctx, args) ... end`, then `handler = document_search`). They use helpers already in that file (`row_summary`, `numeric_series` and others), and moving them to one file per group would add a cross-file require for each group during the migration. Splitting the file can come later, as a pure move.

## One registry

`agent.tool_registry(db_path)` returns every callable tool as `registry[group][method] = record`:

1. Copy the built-in records from `AGENT_TOOLS`.
2. For each extension in `extension.approved_with_tools` (already approved, and approved for its current capabilities: a stale approval is filtered there), convert each `capabilities.tools` entry to a record:
   - `description`, `parameters` from the manifest;
   - `destructive = tool.destructive == true`;
   - `in_research = not destructive`, which is today's behaviour (`research_tool_declarations` already offers non-destructive extension tools to sub-agents);
   - `control = nil` (an extension can't declare a control tool);
   - `handler` calls `extension.load_hooks` and the extension's `hooks.tools[method]` with `entity.build_ctx(ctx.db_path, manifest)`, exactly what `execute_tool`'s fallback does now.
3. Refuse a collision rather than silently picking a winner: an extension whose name is a built-in group, or that declares the same method twice, is left out, and the reason is written to stderr (and shown on `daat extension show`).

Every reader goes through it:

| Today | After |
|---|---|
| `agent.is_known_tool` | `registry[group][method] != nil` |
| `agent.is_destructive` | `record.destructive == true` |
| `agent.tool_declarations` | every record, as `{name, description, parameters}` |
| `agent_tools.research_tool_declarations` | records that pass `agent.research_may_call(record)` |
| `run_research_loop`'s name guard | `agent.research_may_call(record)`: the same function, so the two can't disagree |
| `execute_tool`'s `if` chain | `record.handler(ctx, args)` |
| `RESERVED_TOOL_NAMES` | the keys of `AGENT_TOOLS` |
| `REPEAT_SAFE_TOOLS` | records with `repeat_safe = true` |
| `PINNED_SCHEMA_TOOLS` | records with `pin_on_compaction = true` |
| hints written inside handlers | the record's `recover`, using shared hint helpers |
| `reject_before_approval` | the record's `precheck` |

`agent.research_may_call(record)` is `record.in_research == true and record.destructive != true and record.control == nil`.

### When it is built

Approval is checked on every lookup today: `find_extension_tool` reads the manifests and the approval rows each time. Revoking an extension therefore takes effect on the next tool call, even mid-turn in a detached worker. The registry keeps that property by being built per call to `agent.tool_registry`, not cached for the process. It is called once per model step (for the declarations) and again where a tool runs. A tool approved through `agent.approve_pending` is looked up again at that moment, so a pending call to an extension that was revoked while it waited fails as an unknown tool, as it does now.

If that turns out to cost too much on a deployment with many extensions, the fix is caching per step, never longer than one model call.

## Invariants

Each one is enforced in code and has a test. None of them relies on the system prompt.

1. **A destructive tool always goes through the approval gate.** Today this holds because every caller happens to check `is_destructive` first; a new caller that forgets could run a write. After this, `agent.run_tool` runs a destructive record only when it is given the id of an `agent_pending_action` row, and checks that row first:
   - it exists, belongs to this session (`session_id`) and is still `pending`;
   - its `tool` and `method` are the record being run;
   - the arguments come from the row's `args_json`, not from the caller, so what runs is exactly what the user saw and approved.

   Any other call to a destructive record returns an error, not a result. A plain `approved = true` flag was rejected: any caller could pass it. The row is also moved out of `pending` before the handler runs, not after as today, with an update conditional on the status still being `pending`. Two approve requests for the same action (a double click, two tabs) then can't both run the write. `agent.approve_pending` keeps checking that the action's session belongs to the logged-in user.
2. **A stale or unapproved extension is never registered.** The registry is built only from `extension.approved_with_tools`, which compares the approved capabilities to the manifest's current ones. A changed manifest drops out until it is approved again.
3. **Sub-agents see only `in_research = true`, non-destructive, non-control tools.** One predicate, `agent.research_may_call`, is used both to build the sub-agent's declarations and to refuse a call inside its loop.
4. **Names are unique, and an extension can't shadow a built-in.** Built-in group names are reserved because they are the registry's keys. A colliding extension is left out at build time, and manifest validation rejects it with the same check.

## Control tools in `run_turn`

Today `run_turn` has `elseif tool_name == "clarify" and method_name == "ask"`, and the research loop names `research`, `clarify` and `background`. After the change, `run_turn` asks the record what kind of call it is, and keeps one table of what each control kind does:

```lua
CONTROL_KINDS = {
    clarify = {ends_turn = true},
    research = {ends_turn = false},
    background = {ends_turn = false},
}
```

The per-call classification in `run_turn` becomes, in this order:

1. no record: "unknown tool" error result;
2. `CONTROL_KINDS[record.control].ends_turn`: the first such call wins, later ones get the existing "only one ... per turn" result, and the turn ends with `needs_clarification` as now;
3. `record.destructive`: `record.precheck`, if it has one (an error goes back to the model and nobody is asked), then pause for approval, first one wins;
4. a pending call earlier in the turn: "deferred";
5. otherwise: run the handler.

`research.investigate` and `background.start`/`status` have handlers and run in step 5, as they do today. Their `control` kind only marks them as tools about the conversation's own structure, which is why a sub-agent can't call them. The order of checks, "a clarifying question wins over a write proposed in the same step", is unchanged. A new control kind is a new row in `CONTROL_KINDS`, not a new `elseif`.

## Recovery hints

When a call's arguments are wrong, what the error says decides whether the model fixes the call or gives up. Two recent fixes show the pattern, and the scorecard shows the cost of not having it:
- `unknown_entity_type_message` answers an unknown type with the nearest registered one ("did you mean 'sample'?"), or points to `entity.list_types`.
- `stats.fit`, given a `group_column` that isn't in the result, now lists the actual columns (6845d3e). Before, in the `mean-per-medium` scenario, the agent got the error and gave up on grouping.
- `entity.query`'s SQL error says "call entity.fields/entity.relationships for the real names" but doesn't name them. The agent guesses instead (`p.name`, `e.name`); `no_failed_lookup` fails in 9 of the 24 live scenarios, nearly always on "no such column" (#8).

Each of these was added by hand to one tool. The record gives the same help a fixed place:

```lua
recover = function(ctx, args, err) -> hint | nil
```

The dispatcher calls it when the handler returns `nil, err`, and appends the hint: `err .. " -- " .. hint`. It runs under `pcall`; a `recover` that fails leaves the original error unchanged. It never runs after a success, and it only adds to the error, never replaces it, so the real cause is always in the result.

The hints themselves are a few shared helpers, so every tool phrases the same situation the same way:

| Helper | Tells the model | Used by today, or first |
|---|---|---|
| `hint_entity_type(ctx, name)` | the nearest registered type, or to call `entity.list_types` | every `entity.*` tool (today inside `unknown_entity_type_message`) |
| `hint_result_columns(row)` | the columns the query actually returned | `stats.fit`, then `plot.from_query` |
| `hint_table_columns(ctx, sql, err)` | for a "no such column" error, the real columns of each table the query names | `entity.query` (#8), then `plot.from_query` and `stats.fit`, which run SQL too |

Moving an existing hint into `recover` must not change its text. `unknown_entity_type_message` today returns `unknown entity type: X -- did you mean 'Y'?`; after the move, the handler returns `unknown entity type: X` and `hint_entity_type` returns `did you mean 'Y'?`, which the dispatcher joins with ` -- ` into the same string. Each group's migration PR keeps its error texts byte-identical. A new hint, like #8's column list, is a change to what the model reads, so it lands in its own PR with a scorecard run (`no_failed_lookup`, failed lookups per run) before and after.

`hint_table_columns` needs the database's own wording for the error: SQLite says `no such column: p.name`, MariaDB says `Unknown column 'p.name' in 'field list'`. It reads the table names from the query's `FROM`/`JOIN` aliases and lists their columns, the same way `entity.fields` does, including `<type>_<field>` junction tables. When it can't tell which table is meant, it lists all the tables the query names rather than guessing.

Extension tools get no `recover` (their manifests have no place to declare one); their errors pass through as now.

## Repeat calls and result size

Context Phases 1 and 2 (doc/context-management-plan.md) added per-tool policy in two more name lists and in a few handlers:

| Policy | Today | Record field |
|---|---|---|
| An exact repeat, with no write since and the earlier result still in context, is answered with a one-line note | `REPEAT_SAFE_TOOLS` in `src/agent.lua`: the three schema tools, `entity.get`, `document.search`, `document.children` | `repeat_safe = true` |
| The latest result per arguments is kept verbatim through compaction, under "Confirmed schema" | `PINNED_SCHEMA_TOOLS` in `src/agent.lua`: the three schema tools | `pin_on_compaction = true` |
| A result over the cap is cut when rendered for the model, and `result.read` pages the stored whole | `agent_tool_result_cap` (24,000), the same for every tool, applied in `build_history_messages` and the research loop | `result_cap`, `nil` = the global cap |
| The tool's own output is shaped to a budget | inside the handlers: `entity.query` (`agent_query_char_cap`), `entity.get` (`agent_get_field_chars`), `knowledge.list` (`agent_knowledge_list_page`) | stays in the handler |

`agent.find_repeat` keeps its logic and asks the record instead of the list. The "a write since?" test it already makes (`is_destructive` on every later call) reads `record.destructive`, so a new write tool can't be missed. The pinned-schema block in `compact_if_needed` reads `pin_on_compaction` the same way.

`result_cap` exists so a tool whose results are routinely large can have a different cap without a new setting being read in its handler. Every record starts with `nil`, so the migration changes no cap. The in-handler budgets stay where they are: they decide what a result contains (which rows, which part of a long field), not where it's cut, and they already read their own settings.

Extension tools get `repeat_safe = false`, `pin_on_compaction = false` and the global cap: an extension's tool may have effects daat can't see, so answering it from context isn't safe to assume.

## No change to what the model sees

The declarations sent to the provider stay byte-identical until a separate PR changes them on purpose and measures it on the scorecard (doc/agent-eval.md). Concretely:
- `agent.tool_declarations` still emits `{name, description, parameters}` per method, built-ins first in `pairs(AGENT_TOOLS)` order, then extension tools in `approved_with_tools` order;
- no record field is added to a declaration, and no description is rewritten while a group is moved;
- before the first migration PR, the current output for the built-ins is saved as a fixture, and a unit test compares `agent.tool_declarations` (with no extensions) against it on every run. Each migration PR must pass it unchanged;
- tool results and error texts stay the same too: moving a hint into `recover` must produce the same string (see "Recovery hints"), and no cap changes.

## Migration plan

One PR per group, each small enough to review on its own:

0. **Scaffold.** `agent.tool_registry`, `agent.research_may_call`, the pending-action check in `run_tool`, `CONTROL_KINDS`, the declaration fixture and the registry tests (invariants above, plus the field rules: every record has a handler unless it is `clarify`, flags are booleans, `control` is a known kind, and `precheck`, `repeat_safe` and `pin_on_compaction` sit only where they're allowed). `run_turn` calls `record.precheck` where it calls `reject_before_approval` today, falling back to `reject_before_approval` for a record that hasn't moved yet. `RESERVED_TOOL_NAMES` becomes `AGENT_TOOLS`' keys, which fixes the `calc`/`stats`/`result` gap. `agent_tools` already requires `extension`, so manifest validation requires `agent_tools` inside the function, the way `agent.lua` reaches `agent_tools`. It also adds the `recover` call in the dispatcher and the shared hint helpers (`hint_entity_type` takes over from `unknown_entity_type_message`), sets `repeat_safe` and `pin_on_compaction` on today's tools, and derives `REPEAT_SAFE_TOOLS` and `PINNED_SCHEMA_TOOLS` from them, with a test that the derived sets equal today's lists. No tool moves yet.
1. `document` (6 methods). `document.update` gets its `precheck`.
2. `entity` (11 methods), the largest. `entity.update` gets its `precheck`, and `reject_before_approval`, now empty, is deleted.
3. `knowledge`, `view`, `template`.
4. `result`, `calc`, `stats`, `plot`.
5. `research`, `background`, `clarify`: the control tools. Removes the per-name checks in `run_turn` and `run_research_loop`.
6. `internet_search`.
7. Extension tools: converted into records by the registry, and `find_extension_tool`'s separate callers removed.
8. **Cleanup.** Delete what's left of the `if` chain and the fallback.

After the migration, and separately: new hints, one measured PR each, starting with #8 (`hint_table_columns` on `entity.query`). They change what the model reads, so they don't ride along with a move.

During the transition, `execute_tool` first looks for `record.handler`; if the record has none yet, it falls through to the old chain, which still has that group's branch. A group's branch is deleted in the same PR that gives its records handlers, so no method is ever handled in two places. Each PR passes `./bld/test.sh` (which includes the scorecard in test mode) unchanged; a PR that needs a test changed is changing behaviour and should say why.

## Non-goals

- No change to the provider protocol (doc/agent-protocol.md). Providers keep receiving the same declaration list.
- No new dependencies.
- No change to what the model sees (see above).
- Not an open plugin system. The registry is still a closed set: daat's own records plus approved extensions, as doc/architecture.md's "Agent control: rule-based by default" requires.

## Worked example: adding a tool

A hypothetical `entity.count`: how many active rows a type has, optionally where one field equals a value. Read-only, so a sub-agent may use it. Every line a contributor writes:

**1. The record and its handler** (`src/agent_tools.lua`, in the `entity` group and next to its other handlers):

```lua
function entity_count(ctx, args)
    if args.entity_type == nil then
        return nil, "count requires entity_type"
    end
    if schema.is_registered(ctx.db_path, args.entity_type) == false then
        return nil, "unknown entity type: " .. tostring(args.entity_type)
    end
    n = nil
    if args.filter_field != nil and args.filter_value != nil then
        n = entity.count_by_field(ctx.db_path, args.entity_type, args.filter_field, args.filter_value, false)
    else
        n = entity.count(ctx.db_path, args.entity_type, false)
    end
    return tostring(n) .. " active " .. args.entity_type .. " row(s)"
end
```

```lua
    entity = {
        -- ...existing methods...
        count = {
            destructive = false,
            in_research = true,
            repeat_safe = true,
            handler = entity_count,
            recover = function(ctx, args, err)
                return hint_entity_type(ctx, args.entity_type)
            end,
            description = "Count active rows of an entity type, optionally only those where filter_field equals filter_value. Cheaper than entity.list or entity.query when only the number is needed.",
            parameters = {
                type = "object",
                properties = {
                    entity_type = {type = "string"},
                    filter_field = {type = "string", description = "optional field name"},
                    filter_value = {type = "string", description = "optional value filter_field must equal"},
                },
                required = {"entity_type"},
            },
        },
    },
```

**2. A test** (`tst/integration/agent.bats`), with the scripted provider, as the other tool tests do:

```bash
@test "entity.count returns the number of active rows" {
    write_task_schema
    "$BIN" entity create task title="one" status=open
    "$BIN" entity create task title="two" status=done
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted="$(tool_call_response "entity.count" '{"entity_type":"task"}')"$'\1'"$(done_response "Two.")"
    run raw_post_json "/api/chat-widget-send" "{\"session_id\":\"${session_id}\",\"message\":\"how many tasks?\"}" "$COOKIE" "$CSRF" "$scripted"
    [[ "$output" =~ "200 OK" ]]

    run latest_tool_result "$session_id"
    [[ "$output" =~ "2 active task row(s)" ]]
}
```

That's all. What the contributor no longer has to touch, and what checks it for them:

| Today they would also edit | Now |
|---|---|
| A new branch in `execute_tool` | the record's `handler` |
| `research_tool_declarations`' name list | `in_research = true` |
| `RESERVED_TOOL_NAMES` (for a new group) | derived from `AGENT_TOOLS` |
| `run_turn`, for a tool that changes the turn's flow | `control` and a row in `CONTROL_KINDS` |
| `REPEAT_SAFE_TOOLS` in `src/agent.lua` | `repeat_safe = true` (a count can't change without a write, and any write since makes the repeat run again) |
| a hand-written "did you mean" in the handler | `recover`, with the shared `hint_entity_type` |

A wrong `entity_type` such as `"tasks"` then comes back as `unknown entity type: tasks -- did you mean 'task'?`, worded exactly like every other `entity.*` tool.

The registry tests fail if the record has no handler, a non-boolean flag, an unknown `control` kind, `repeat_safe` on a destructive tool, or a `precheck` on a read-only one. The declaration fixture test fails as well, since the model now sees one more tool. A PR that adds a tool updates the fixture on purpose; one that only moves code must leave it unchanged.

## Decisions (2026-11-03)

1. **`precheck` is part of the record.** `reject_before_approval` was a third place with per-tool logic (`entity.update` and `document.update` refuse a call with nothing to change before it reaches approval). Its cases move into those records' `precheck`, the field rules allow it only on destructive tools, and the function is deleted once both groups have moved.
2. **`in_research = true` for the same 21 tools during the migration.** Those are the read-only built-ins a sub-agent sees today (25 non-destructive methods, less the 4 control-tool methods), so the migration keeps that behaviour exactly. Hiding any of them, for example `plot.from_query` or `result.read`, is a separate, measured PR.
3. **`recover` per tool first.** It moves today's hints without changing their text. Hints per kind of argument (`arg_kinds = {entity_type = "entity_type", group_column = "result_column"}`, kept out of `parameters` so declarations don't change, with the dispatcher checking and hinting before the handler runs) are a possible follow-up once the migration is stable.
4. **The six `repeat_safe` tools stay as they are.** The migration copies today's set. `entity.list`, `entity.query`, `template.get` and `view.run` would qualify by the same rule, but adding them changes what the model reads after a repeat, so expanding the set is its own PR, measured with `daat agent context-report` (exact repeat calls per run) and the scorecard.
