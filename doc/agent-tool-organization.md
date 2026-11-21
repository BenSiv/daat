# Agent tools: how the registry is organized

Design, 2026-11-04. Builds on `doc/agent-tools.md`, which defines one record per tool and one registry (#6). That document says what a tool *is*. This one says where a tool *belongs*, and when a new one is justified, so the registry keeps a defined structure as it grows.

## Why

After #6 the registry holds 34 tools in 13 groups, plus each approved extension's tools under its own name. Nothing written says which group a tool belongs in, what its operations may be called, or when a new tool is better than improving an existing one. The registry already shows the cost:
- **Groups follow different principles.** Some are domain objects (`entity`, `document`), some are computations (`calc`, `stats`), some are about the conversation (`clarify`, `research`), and one reaches outside the deployment (`internet_search`).
- **Operations differ from group to group.** Only `entity` has the full set (schema, read, write). A document is read with `entity.get`, since `document` has no `get`. Three tools in three groups take SQL.
- **"Destructive" means two things.** `internet_search.search` is marked destructive because it leaves the deployment, not because it changes data. The one flag mixes "changes data" with "needs approval".
- **The pull is toward a tool per use case.** Each scorecard failure suggests one (#6 step 9 proposed `entity.find`), and every special-purpose tool adds something the model has to choose between.

## Principles

1. **A small, stable set of general tools.** A recurring mistake is fixed in the tool that's misused, with a guard, a recovery hint (`recover`), a parameter, a prompt rule or a scorecard scenario. Adding a tool is the last option, not the first.
2. **Every tool has one place:** a group of a defined kind, and an operation that kind allows.
3. **What a tool does to the world is declared,** and whether it needs approval follows from that.
4. **The structure is enforced by tests,** not only by review.
5. **Order and structure are domain rules.** Nothing depends on how a table iterates or a directory lists.

## Group kinds

Every group has exactly one kind, declared once for the group.

| Kind | About | Groups today | Allowed operations | Effect |
|---|---|---|---|---|
| `domain` | the deployment's own records | `entity`, `document`, `knowledge`, `view`, `template` | schema, read, write (below) | none or writes |
| `compute` | numbers and charts derived from data the agent gives or queries | `calc`, `stats`, `plot` | one per computation, named for what it computes | none |
| `conversation` | this conversation itself | `result`, `clarify`, `research`, `background` | read (`result.read`) and the control kinds of `doc/agent-tools.md` | none |
| `external` | anything outside the deployment | `internet_search` | read only | external |

A group's kind decides what its tools may do:
- A `compute` or `conversation` tool never writes.
- Only a `domain` tool writes data.
- Only an `external` tool leaves the deployment.

Sub-agent access stays per tool (`in_research`). Control tools are never available to sub-agents.

## Operations of a domain group

A domain group's methods come from this set. A new operation name is a change to this document first.

| Family | Operations | Meaning |
|---|---|---|
| Schema | `list_types`, `fields`, `relationships` | the structure of the records, not the records (`entity` only) |
| Read | `list` | rows of one type, optionally filtered on a field's exact value, paged |
| | `get` | one record, by its key (see "Read by key") |
| | `query` | read-only SQL over the records (`entity` only) |
| | `search` | records ranked by relevance to a text (`document`) |
| | `children`, `breadcrumbs`, `links` | navigation, for a domain with a structure (`document`: tree and links) |
| | `run` | runs a saved, approved query (`view`) |
| | `validate` | a write's checks without the write: a dry run, no effect |
| | `stats` | counts about the domain (`knowledge`) |
| Write | `create`, `update`, `archive`, `unarchive` | change records; always through approval |

**Exceptions, listed so they stay the only ones:**
- `knowledge.distill` is a `create` of a pool document that records its source. Renaming it would change what the model sees, so it keeps its name.

**Documents are entities.** Reading one is `entity.get` with `entity_type = "document"`. The `document` group holds only what is particular to documents: search, navigation, links, and writes that handle `[[links]]`. It gets no `get` of its own; that would be a second way to do one thing.

## Read by key: `get` takes a name too

`entity.get` reads one record by id. The trap in `id-number-start-date` and `sample-last-readings` is a person writing "EXP-027". The model then uses 27 as an id, or guesses a query. A separate `entity.find` (name in, ids out) would solve that with a fourth way to read entities, and then a second call to `get` the record.

Instead, `get` takes exactly one key: `entity_id`, or `name`, the name or number as a person writes it.
- **The match goes through `entity_name_index`.** That index already exists for references (`src/reference.lua`). It holds each record's `name` or display field, matched ignoring case, spacing and separators ("Exp 185" is Exp185), with the deployment's `reference_aliases`. `entity_type` is optional with a name.
- **One match** returns the record, as an id would.
- **Several matches** return their types, ids and labels to choose from, and nothing else.
- **No match** returns a hint: a number inside a name isn't an id, and here is the field to filter on with `list` or `query`. This hint is `get`'s `recover`.

That's one tool and one call, from the name to the record, with no new operation.

**Limit:** the index holds only distinctive names (four or more characters, with a digit or punctuation inside a word), and only the name or display field. A lab number in another field isn't in it (decision 2).

## Effects and approval

The boolean `destructive` becomes `effect`:

| `effect` | Meaning | Approval | Sub-agents | Repeat-safe and pin allowed |
|---|---|---|---|---|
| `none` | reads or computes only | never | when `in_research` | yes |
| `writes` | changes the deployment's data | always (invariant 1, unchanged) | never | no |
| `external` | reaches outside the deployment | per deployment, `agent_external_approval` (default `true`, as today) | never | no |

`destructive` stays readable as `effect != "none"` during the change, so the approval gate and `precheck` read it unchanged. `internet_search.search` becomes `external`. With the default, nothing a person sees changes; a deployment can choose to let searches run without asking.

## Tools that take SQL

Any tool that takes SQL calls the parameter `sql` and runs it through one gate: `view.run_agent_query`, which `entity.query`, `stats.fit` and `plot.from_query` already share (one SELECT, registered entity tables only). A new SQL tool uses the same gate, so there's one place where what SQL the agent may run is decided. The name `sql` is what the `/sql` console prefill reads (`agent.last_console_query_sql`).

## Extensions

An extension's tools live in its own group, named after the extension (invariant 4, unchanged). Its manifest declares the group's kind: `domain` for the entity types it owns (its `schemas`), `compute`, or `external`. Never `conversation`. Its methods follow that kind's rules.

An extension does not add operations to a core group. The core groups are the contract every deployment has; a deployment-specific need is met in the extension's own group, or, when every deployment needs it, in the core group by a change here. Reading a record by its name is the second case, which is why it goes into `entity.get`.

## Adding a tool: the order of questions

1. **Can an existing tool cover it,** with a guard, a `recover` hint, a parameter or another key? Do that.
2. **Does it fit a group and an operation that kind allows?** Add the record there, with its tests.
3. **Otherwise** it's a new operation or a new kind: change this document first, and get it reviewed.

Every new or changed tool comes with a scorecard scenario showing the need, and a live comparison before and after.

## Enforced by tests

The registry tests (`tst/unit/agent_tool_registry.lua`) check:
- every built-in group has a kind;
- every method of a domain group is in the operation set or the exceptions list;
- `effect` is one of the three values, a `compute` or `conversation` tool has `effect = "none"`, and only `external` groups have `external`;
- an extension's declared kind is allowed and its methods follow it;
- every tool with an `sql` parameter runs it through `view.run_agent_query` (checked as `no_tool_is_dispatched_by_name` checks the source).

## Today's registry against this

| Tool | Kind and operation | Change |
|---|---|---|
| `entity.*` (11) | domain: schema, read, write | `get` takes `name` |
| `document.search`, `children`, `breadcrumbs`, `links` | domain: read, navigation | — |
| `document.create`, `update` | domain: write | — |
| `knowledge.list`, `stats` | domain: read | — |
| `knowledge.distill` | domain: write (named exception) | — |
| `view.list`, `run` | domain: read | — |
| `template.list`, `get` | domain: read | — |
| `calc.evaluate`, `stats.fit`, `plot.from_query` | compute | — |
| `result.read` | conversation: read | — |
| `clarify.ask`, `research.investigate`, `background.start`, `status` | conversation: control | — |
| `internet_search.search` | external: read | `effect = "external"` instead of destructive |

Only two changes reach the model: the `name` key on `entity.get` (a new optional parameter and a new hint) and, if a deployment chooses, searches without approval.

## Migration

1. **Kinds and the operation set:**
   - a `GROUPS` table next to `AGENT_TOOLS` with each group's kind;
   - the exceptions list;
   - the registry tests above, and the `kind` field in the extension manifest (optional, default `domain`).

   No change to what the model sees.
2. **`effect`:**
   - `effect` replaces `destructive` in the records, with `destructive` derived from it;
   - `internet_search` becomes `external`;
   - `agent_external_approval` (default `true`).

   No change to what the model sees.
3. **`entity.get` by name:** the `name` key, the several-matches answer, and the no-match `recover` hint. Measured with a live scorecard, `id-number-start-date` and `sample-last-readings` before and after. This is #6's step 9, in place of a new tool.
4. **Docs:** `doc/agent-tools.md`'s how-to section points here for where a tool goes.

## Decisions

1. **Reading by name** is a `name` key on `entity.get`, not a new `entity.find` (proposed).
2. **Identifier fields:** a lab number in a field other than the name or display field isn't in the name index. Either a schema flag (`identifier = true`) adds that field to the index, or every text field is indexed (proposed: the flag; explicit, and it keeps matches precise).
3. **Extensions** add tools only in their own group, never in a core group (proposed). The alternative is extensions adding operations to core domain groups, with a clash refused.
4. **External effects** need approval by default, with a per-deployment setting (proposed).
5. **`knowledge.distill`** keeps its name as a listed exception (proposed), or is renamed into the operation set with a measured change.
