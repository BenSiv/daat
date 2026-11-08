# Agent tools: one record per tool

How daat's agent tools are defined, looked up, gated and shown to the model. Designed in #5, built in #6 (PRs #24-#32); later measured changes are under "What the model sees".

## Problem

Before #6, everything daat knew about one agent tool was spread over several places, and nothing checked that they agreed. Adding a tool meant editing two to four of them. This is why the design below exists.

| Fact about a tool | Where it lived before #6 |
|---|---|
| Name, description, parameters, `destructive` | `agent_tools.AGENT_TOOLS` (`src/agent_tools.lua`): 13 groups, 33 methods, 8 destructive |
| What it does | `agent_tools.execute_tool`: one function of about 800 lines, a chain of 32 `if tool_name == ... and method_name == ...` branches, then the extension fallback |
| A check before approval | `agent_tools.reject_before_approval`: hard-coded cases for `entity.update` and `document.update` |
| `clarify.ask` | No handler at all. `agent.run_turn` special-cased it by name, and ended the turn |
| What a sub-agent can't call | The names `research`, `clarify` and `background`, written twice: in `agent_tools.research_tool_declarations` and in `agent.run_research_loop`'s per-call guard |
| Extension tools | Resolved by `agent_tools.find_extension_tool`, called separately from `agent.is_known_tool`, `agent.is_destructive`, `agent.tool_declarations`, `research_tool_declarations` and `execute_tool` |
| Names an extension may not take | `RESERVED_TOOL_NAMES` (`src/extension.lua`), a hand-kept copy of the group names |
| Which calls may be answered with "same as before" | `REPEAT_SAFE_TOOLS` (`src/agent.lua`, Context Phase 1): six names |
| Which results survive compaction | `PINNED_SCHEMA_TOOLS` (`src/agent.lua`, Context Phase 1): the three schema tools, the same names written a second time |
| What to tell the model when the arguments are wrong | Inside individual handlers, where someone thought of it: `unknown_entity_type_message` suggests the nearest type; `stats.fit` lists the actual columns for a wrong `group_column` (6845d3e); `entity.query`'s SQL error (`src/view.lua`) only said to call `entity.fields`, without naming the columns (#8) |

### The lists had already drifted

`RESERVED_TOOL_NAMES` had 10 names. `AGENT_TOOLS` had 13 groups: `calc`, `stats` and `result` were added later and never reserved. So an extension named `stats` passed validation and was approved. `agent.tool_declarations` then offered its tools to the model, but `agent.is_known_tool` looked in `AGENT_TOOLS` first, found the built-in `stats` group, and reported any method that group didn't have as unknown. The model was shown a tool that could never run (#15). The design makes this impossible: the reserved names are the registry's own keys (`extension.is_reserved_tool_name`), not a list someone has to remember.

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
}
```

`precheck` refuses a destructive call that can't do anything before it becomes a pending action, so a person is never asked to approve a no-op. It returns the error text, or `nil` when the call may go to approval. It replaced `agent_tools.reject_before_approval`, which is gone: `entity.update` and `document.update`, the two tools that had a case there, have it as their `precheck` (`entity_update_precheck`, `document_update_precheck`), with the same messages. `document.update`'s handler repeats that check when it runs, by calling its own `precheck`.

`recover`, `repeat_safe` and `pin_on_compaction` are explained in "Recovery hints" and "Repeat calls and result size" below.

`ctx` is built by `agent.tool_ctx(db_path, author, session_id)` and passed to every handler, `precheck` and `recover`:

```lua
ctx = {
    db_path = db_path,
    author = author,           -- the real logged-in user; tools run as them
    session_id = session_id,
    source = {notebook_entry_id = "agent-session:" .. tostring(session_id)},
}
```

A handler returns result text, or `nil, err`. `agent.run_tool` calls `execute_tool` under `pcall`, so a handler that raises becomes an error tool result rather than a dead turn.

Rules for the fields. For built-in records they are checked by `tst/unit/agent_tool_registry.lua` on every `./bld/test.sh` (`every_builtin_record_follows_the_field_rules`, `every_builtin_tool_has_a_handler`), not at run time; an extension's records are built by `extension_tool_record` (`src/agent.lua`), which sets the flags itself:
- `description` and `parameters` are required. `handler` is required unless `control == "clarify"`, the one tool whose effect is the turn ending.
- `destructive` and `in_research` are booleans. A missing `in_research` means `false`, so a new tool is hidden from sub-agents until someone decides otherwise.
- `control` is `nil` or one of the three kinds. A tool with a `control` kind is never visible to a sub-agent, whatever `in_research` says.
- `repeat_safe` and `pin_on_compaction` are booleans, default `false`, and only allowed on a non-destructive tool: answering a write with "same as before" would skip the write.
- `precheck` is `nil` or a function, and only allowed on a destructive tool: it runs on the way to approval, which only destructive tools take.
- `recover` is `nil` or a function.

### Where the records live

`AGENT_TOOLS` (`src/agent_tools.lua`) has the shape `AGENT_TOOLS[group][method] = record`. The order the model is shown is set by the registry, by name (built-ins by group then method, extensions by name, each extension's tools in its manifest's order), never by how `pairs` walks a table or a directory lists, so it is the same on every luam build and every disk.

Handlers live in `src/agent_tools.lua` as named functions next to their group (`function document_search(ctx, args) ... end`), attached after the table, near the end of the file: `agent_tools.AGENT_TOOLS.document.search.handler = document_search`. They are attached there, not written inside the table, because a function defined further down the file doesn't exist yet when the table is built. They use helpers in the same file (`row_summary`, `numeric_series` and others); splitting the file per group can come later, as a pure move.

## One registry

`agent.tool_registry(db_path)` returns every callable tool as `registry[group][method] = record`, plus the ordered list the declarations are built from. The rules live in `agent.build_tool_registry(builtins, extensions)`, which is pure, so they're unit-tested without a database:

1. Copy the built-in records from `AGENT_TOOLS`.
2. For each extension in `extension.approved_with_tools` (already approved, and approved for its current capabilities: a stale approval is filtered there), convert each `capabilities.tools` entry to a record:
   - `description`, `parameters` from the manifest;
   - `destructive = tool.destructive == true`;
   - `in_research = not destructive`, as before the registry (`research_tool_declarations` offered non-destructive extension tools to sub-agents);
   - `control = nil` (an extension can't declare a control tool);
   - `handler` calls `extension.load_hooks` and the extension's `hooks.tools[method]` with `entity.build_ctx(ctx.db_path, manifest)`, never the agent's own ctx, so an extension's tool reaches only what its approved manifest grants.
3. Refuse a collision rather than silently picking a winner: an extension whose name is a built-in group, or that declares the same method twice, is left out whole, and the reason is written to stderr.

Every reader goes through it:

| Before #6 | Now |
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

Before #6, `find_extension_tool` read the manifests and the approval rows on every lookup, so revoking an extension took effect on the next tool call, even mid-turn in a detached worker. The registry keeps that property by being built per call to `agent.tool_registry`, not cached for the process. It is called once per model step (for the declarations) and again where a tool runs. A tool approved through `agent.approve_pending` is looked up again at that moment, so a pending call to an extension that was revoked while it waited fails as an unknown tool.

If that turns out to cost too much on a deployment with many extensions, the fix is caching per step, never longer than one model call.

## Invariants

Each one is enforced in code and has a test. None of them relies on the system prompt.

1. **A destructive tool always goes through the approval gate.** Before #6 this held only because every caller happened to check `is_destructive` first; a new caller that forgot could run a write. `agent.run_tool` runs a destructive record only when it is given an `agent_pending_action` row (`approved_arguments`), and checks that row first:
   - it exists, belongs to this session (`session_id`) and is still `pending`;
   - its `tool` and `method` are the record being run;
   - the arguments come from the row's `args_json`, not from the caller, so what runs is exactly what the user saw and approved.

   Any other call to a destructive record returns an error, not a result. A plain `approved = true` flag was rejected: any caller could pass it. The row is also moved out of `pending` before the handler runs, with an update conditional on the status still being `pending`, so two approve requests for the same action (a double click, two tabs) can't both run the write (#16, `agent.claim_pending_action`). `agent.approve_pending` also checks that the action's session belongs to the logged-in user.
2. **A stale or unapproved extension is never registered.** The registry is built only from `extension.approved_with_tools`, which compares the approved capabilities to the manifest's current ones. A changed manifest drops out until it is approved again.
3. **Sub-agents see only `in_research = true`, non-destructive, non-control tools.** One predicate, `agent.research_may_call`, is used both to build the sub-agent's declarations and to refuse a call inside its loop.
4. **Names are unique, and an extension can't shadow a built-in.** Built-in group names are reserved because they are the registry's keys. A colliding extension is left out at build time, and manifest validation rejects it with the same check (`extension.is_reserved_tool_name`).

The turn loop's behaviour around these (approval, holding calls after a pending one, deferral, repeats) is pinned by characterization tests written before the migration (#3).

## Control tools in `run_turn`

Before #6, `run_turn` had `elseif tool_name == "clarify" and method_name == "ask"`, and the research loop named `research`, `clarify` and `background`. Now `run_turn` asks the record what kind of call it is, and `src/agent.lua` keeps one table of what each control kind does:

```lua
CONTROL_KINDS = {
    clarify = {
        ends_turn = true,
        result = "Waiting for the user's answer before continuing.",
        another_this_turn = "ERROR: skipped -- only one clarifying question can be asked per turn",
        status = "needs_clarification",
        message_argument = "question",
        missing_message = "(no question given)",
    },
    research = {ends_turn = false},
    background = {ends_turn = false},
}
```

A kind that ends the turn says everything `run_turn` needs (what the call's result says, what a second one in the same turn is told, the status the turn returns, which argument is shown to the user), so `run_turn` and `display_blocks` read the row (`agent.turn_ending_kind`) and never a tool name.

The per-call classification in `run_turn`, in this order:

1. no record: "unknown tool" error result;
2. `CONTROL_KINDS[record.control].ends_turn`: the first such call wins, later ones get the kind's `another_this_turn` result, and the turn ends with the kind's `status`;
3. `record.destructive`: `record.precheck`, if it has one (an error goes back to the model and nobody is asked), then pause for approval, first one wins;
4. a pending call earlier in the turn: "deferred";
5. otherwise: run the handler.

`research.investigate` and `background.start`/`status` have handlers and run in step 5. Their `control` kind only marks them as tools about the conversation's own structure, which is why a sub-agent can't call them. The order of checks, "a clarifying question wins over a write proposed in the same step", is unchanged. A new control kind is a new row in `CONTROL_KINDS`, not a new `elseif`.

## Recovery hints

When a call's arguments are wrong, what the error says decides whether the model fixes the call or gives up. The scorecard shows the cost of not having it:
- `unknown_entity_type_message` answers an unknown type with the nearest registered one ("did you mean 'sample'?"), or points to `entity.list_types`.
- `stats.fit`, given a `group_column` that isn't in the result, lists the actual columns (6845d3e). Before, in the `mean-per-medium` scenario, the agent got the error and gave up on grouping.
- `entity.query`'s SQL error used to say "call entity.fields/entity.relationships for the real names" without naming them. The agent guessed instead (`p.name`, `e.name`), and on the live scorecard it hit "no such column" 0.42 times per run (#8). With `hint_table_columns` as `recover` and the columns listed by `entity.relationships`, that fell to 0.06 (PR #44).

These were first added by hand to one tool each. The record gives the same help a fixed place:

```lua
recover = function(ctx, args, err) -> hint | nil
```

The dispatcher calls it when the handler returns `nil, err`, and appends the hint: `err .. " -- " .. hint`. It runs under `pcall`; a `recover` that fails leaves the original error unchanged. It never runs after a success, and it only adds to the error, never replaces it, so the real cause is always in the result.

The hints themselves are a few shared helpers, so every tool phrases the same situation the same way:

| Helper (`agent_tools.`) | Tells the model | Used by |
|---|---|---|
| `hint_entity_type(ctx, name)` | the nearest registered type, or to call `entity.list_types` | every `entity.*` tool, through `unknown_entity_type_message` |
| `hint_result_columns(names)` | the columns the query actually returned | `stats.fit` (`group_column`) and `plot.from_query` (`x_column`/`y_column`), inside their handlers |
| `hint_table_columns(ctx, sql, err)` | for a missing column, the real columns of the table its prefix stands for, and the closest name when one is really close | the `recover` of `entity.query`, `stats.fit` and `plot.from_query` (`sql_column_recover`, #8) |

A moved hint keeps its text: `unknown entity type: X -- did you mean 'Y'?` reads the same whether a handler builds it or the dispatcher joins the handler's error and the hint with ` -- `, and `moved_hints_keep_their_text` checks it. A new hint is a change to what the model reads, so it lands in its own PR with a scorecard run (`no_failed_lookup`, failed lookups per run) before and after, as #8 did.

`hint_table_columns` reads both databases' wording: SQLite says `no such column: p.name`, MariaDB says `Unknown column 'p.name' in 'field list'`. It resolves the prefix through the query's own `FROM`/`JOIN` aliases (`view.query_aliases`): an alias the query never defines is named as the problem; without a prefix it lists every table the query names. Only tables `entity.query` may read are described (`view.queryable_tables`). The closest-name suggestion (`closest_column`) is offered only when the match is really close, since a wrong suggestion is worse than none.

Extension tools get no `recover` (their manifests have no place to declare one); their errors pass through as now.

## Repeat calls and result size

Context Phases 1 and 2 (doc/context-management-plan.md) added per-tool policy that used to sit in two name lists in `src/agent.lua`; it is now on the records:

| Policy | Before #6 | Now |
|---|---|---|
| An exact repeat, with no write since and the earlier result still in context, is answered with a one-line note | `REPEAT_SAFE_TOOLS`: the three schema tools, `entity.get`, `document.search`, `document.children` | `repeat_safe = true` on the same six |
| The latest result per arguments is kept verbatim through compaction, under "Confirmed schema" | `PINNED_SCHEMA_TOOLS`: the three schema tools | `pin_on_compaction = true` on the same three |
| A result over the cap is cut when rendered for the model, and `result.read` pages the stored whole | `agent_tool_result_cap` (24,000), the same for every tool | unchanged: one global cap |
| The tool's own output is shaped to a budget | inside the handlers: `entity.query` (`agent_query_char_cap`), `entity.get` (`agent_get_field_chars`), `knowledge.list` (`agent_knowledge_list_page`) | unchanged: in the handler |

`agent.find_repeat` asks the record (`builtin_tool_has`) instead of a list. Its "a write since?" test reads `record.destructive` on every later call, so a new write tool can't be missed. The pinned-schema block in compaction reads `pin_on_compaction` the same way. `repeat_safe_and_pinned_are_the_lists_they_replace` pins both sets.

A per-tool `result_cap` was designed but not built: no tool has needed a cap other than the global one. The in-handler budgets decide what a result contains (which rows, which part of a long field), not where it's cut, and read their own settings.

Extension tools get `repeat_safe = false`, `pin_on_compaction = false` and the global cap: an extension's tool may have effects daat can't see, so answering it from context isn't safe to assume.

## What the model sees

What the model is shown changes only on purpose, in its own PR, measured on the scorecard (doc/agent-eval.md). Moving code must not change it.
- `agent.tool_declarations` emits `{name, description, parameters}` per method, in the registry's order (built-ins by group then method, then extensions by name, each in its manifest's order). No other record field reaches a provider.
- Every record declares `parameters`, a tool without arguments too: `EMPTY_OBJECT_SCHEMA` (`src/agent_tools.lua`), whose empty `properties` is marked to encode as `{}`, since Vertex refuses `[]` (#20).
- The declarations are pinned byte for byte: `tst/unit/fixtures/tool_declarations.json` and `research_tool_declarations.json`, one canonical JSON line per tool, compared by `tst/unit/agent_tools.lua` on every run. After an intended change, regenerate them with `DAAT_UPDATE_SNAPSHOT=1` and say why in the PR; the fixture diff names the tools that changed.
- The same test translates every declaration for each provider and checks it encodes. Each provider meets its own rules in its translation, never in the records (doc/review-checklist.md, "A stable base, a flexible shell"): Vertex gets Gemini's uppercase type names; Claude, whose tool names may not contain dots, gets `.` as `__` on the way out and back (#21).

Intended changes so far: #8 (PR #44) rewrote the `entity.query` and `entity.relationships` descriptions and made `entity.relationships` list every type's columns; #20 gave five argument-less tools their empty schema.

## How it was built

#6 moved the tools one group per PR (#24-#32), each small enough to review on its own and each passing `./bld/test.sh` with the declaration fixture unchanged. During the move, `execute_tool` ran `record.handler` if there was one and fell through to the old chain otherwise; a group's branch was deleted in the PR that gave its records handlers. The steps:

0. **Scaffold** (#24): the registry, `agent.research_may_call`, the approval gate in `run_tool`, `CONTROL_KINDS`, the declaration fixture, the registry tests, the `recover` call and the shared hint helpers, and `repeat_safe`/`pin_on_compaction` in place of the two name lists.
1. `document` (#25), with `document.update`'s `precheck`.
2. `entity` (#26), with `entity.update`'s `precheck`; `reject_before_approval` deleted.
3. `knowledge`, `view`, `template` (#27).
4. `result`, `calc`, `stats`, `plot` (#28).
5. The control tools `research`, `background`, `clarify` (#29).
6. `internet_search` (#30).
7. Extension tools, as records built by the registry (#31).
8. Cleanup: the `if` chain and the fallback deleted (#32).

New hints came after, one measured PR each, starting with #8.

## Non-goals of #6

- No change to the provider protocol (doc/agent-protocol.md). Providers keep receiving the same declaration list.
- No new dependencies.
- No change to what the model sees as part of a move (see "What the model sees").
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
            recover = function(ctx, args, err)
                if args.entity_type == nil then
                    return nil
                end
                return agent_tools.hint_entity_type(ctx, args.entity_type)
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

and, with the other `entity` handlers near the end of the file:

```lua
agent_tools.AGENT_TOOLS.entity.count.handler = entity_count
```

**2. A test** (`tst/integration/agent.bats`, which has `start_chat` and `write_task_schema`), with the scripted provider, as the other tool tests do:

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

**3. The declaration fixtures.** The model now sees one more tool, so `tst/unit/agent_tools.lua` fails until the fixtures are regenerated on purpose:

```bash
DAAT_UPDATE_SNAPSHOT=1 $LUAM_DIR/bin/luam tst/unit/agent_tools.lua   # with LUA_PATH/LUA_CPATH as bld/test.sh sets them
```

The PR says why the model should see the new tool, and a tool meant to change the agent's behaviour shows it on the scorecard.

That's all. What the contributor doesn't have to touch, and what checks it for them:

| Before #6 they would also have edited | Now |
|---|---|
| A new branch in `execute_tool` | the record's `handler` |
| `research_tool_declarations`' name list | `in_research = true` |
| `RESERVED_TOOL_NAMES` (for a new group) | derived from `AGENT_TOOLS` |
| `run_turn`, for a tool that changes the turn's flow | `control` and a row in `CONTROL_KINDS` |
| `REPEAT_SAFE_TOOLS` in `src/agent.lua` | `repeat_safe = true` (a count can't change without a write, and any write since makes the repeat run again) |
| a hand-written "did you mean" in the handler | `recover`, with the shared `hint_entity_type` |

A wrong `entity_type` such as `"tasks"` then comes back as `unknown entity type: tasks -- did you mean 'task'?`, worded exactly like every other `entity.*` tool.

The registry tests (`tst/unit/agent_tool_registry.lua`) fail if the record has no handler, a non-boolean flag, an unknown `control` kind, `repeat_safe` on a destructive tool, or a `precheck` on a read-only one. `tst/unit/agent_tools.lua` checks that it has a description and an object schema, that it translates for every provider, and that the fixtures match.

## Decisions (2026-11-03)

1. **`precheck` is part of the record.** `reject_before_approval` was a third place with per-tool logic (`entity.update` and `document.update` refuse a call with nothing to change before it reaches approval). Its cases move into those records' `precheck`, the field rules allow it only on destructive tools, and the function is deleted once both groups have moved.
2. **`in_research = true` for the same 21 tools during the migration.** Those are the read-only built-ins a sub-agent sees today (25 non-destructive methods, less the 4 control-tool methods), so the migration keeps that behaviour exactly. Hiding any of them, for example `plot.from_query` or `result.read`, is a separate, measured PR.
3. **`recover` per tool first.** It moves today's hints without changing their text. Hints per kind of argument (`arg_kinds = {entity_type = "entity_type", group_column = "result_column"}`, kept out of `parameters` so declarations don't change, with the dispatcher checking and hinting before the handler runs) are a possible follow-up once the migration is stable.
4. **The six `repeat_safe` tools stay as they are.** The migration copies today's set. `entity.list`, `entity.query`, `template.get` and `view.run` would qualify by the same rule, but adding them changes what the model reads after a repeat, so expanding the set is its own PR, measured with `daat agent context-report` (exact repeat calls per run) and the scorecard.
