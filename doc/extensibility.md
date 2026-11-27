# Extensibility

The extension system exists so that behavior specific to one deployment's own needs -- a validation rule, a reaction to an entity being created or changed -- never has to be written into the platform itself. An extension is a small script, version-controlled the same way an entity type definition is, that declares up front what it needs and gets exactly that and nothing more.

This whole document describes one of three trust tiers -- deployment-authored, sandboxed, capability-checked, admin-approval-gated. It's the only one of the three that isn't first-party code: `agent_provider.lua`, `search_provider.lua`, and `mail_provider.lua` and their implementations under `src/provider/` are the middle tier (ships with daat, full access, but swappable via `config.lua`); everything else in `src/` is core (also full access, not swappable). See doc/architecture.md's "Providers" section for the full three-tier picture and why the line is drawn where it is.

## Extension layout

```
extensions/<name>/
  manifest.lua
  main.lua
```

A manifest is a small declarative file, loaded the same sandboxed way an entity type definition is (see `schema.md` and `architecture.md`) -- one language for everything a definition or extension author writes, no separate config format:

```lua
-- extensions/unique-lot-number/manifest.lua
return {
  name = "unique-lot-number",
  events = {"entity.before_create", "entity.before_update"},
  entity_types = {"reagent"},
  capabilities = {
    read = {"entity"},
    write = {},
    net = "none",
  },
}
```

```lua
-- extensions/unique-lot-number/main.lua
-- Hooks are returned as a table, the same convention manifest.lua
-- already uses -- never a bare top-level `function on_before() end`.
-- A bare function statement is implicit-local in Luam (see
-- ../../luam/doc/manifesto.md and doc/why-luam.md), exactly like bare
-- assignment already is -- it compiles to a variable private to this
-- file, invisible to the host regardless of what capability-scoped
-- environment this script runs under. Returning the hooks explicitly
-- is how they actually reach daat.
return {
  on_before = function(new, old, ctx)
    issues = {}
    if old == nil or new.lot_number != old.lot_number then
      dup = ctx.query("reagent", {lot_number = new.lot_number})
      if #dup > 0 then
        table.insert(issues, {field = "lot_number", severity = "error",
          message = "Lot number already registered"})
      end
    end
    return issues
  end,
}
```

## Event model

| Hook | Timing | Can it block? | Typical use |
|---|---|---|---|
| `entity.before_create` / `entity.before_update` | Synchronous, as part of saving the change | Yes -- returned issues can block the save | Validation rules |
| `entity.after_create` / `entity.after_update` / `entity.after_archive` | Queued when the change is saved, executed later | No | Notifications, derived-entity computation, external sync |

Before-hooks and after-hooks are deliberately different code paths, not a timing flag on the same one: a slow or broken after-hook must never be able to hang or corrupt someone's data entry, so it doesn't get the chance to run as part of it at all.

**"Queued," concretely**: an after-hook doesn't run the instant its event fires. Creating, updating, or archiving an entity records a pending job in the same transaction as the change itself, and that job only actually executes when something later asks the platform to run its pending jobs (`daat extension run-pending`, or `daat run-pending` to drain all background queues together on whatever schedule a deployment chooses) -- not as an automatic side effect of the write. Unarchiving an entity does **not** enqueue an after-hook today (only archiving does) -- not a deliberate design stance, just not wired up yet.

## Capabilities

A manifest declares what an extension needs; it's granted exactly that and nothing more when its code actually runs:

- `read: [entity]` -- read-only lookups into current entity state via `ctx.query(entity_type, filter)`. No raw query language is ever exposed: `entity_type` must be a registered entity type (not an internal table like `user` or `api_key`), and `filter` is per-field equality on the type's own single-valued fields or its system columns (`id`, `name`, `external_id`, `created_at`, `archived_at`, ...) -- anything else is an error.
- `write: [entity]` -- access to create or update entities via `ctx`. Most extensions (especially validation rules) declare no write access at all.
- `net: outbound` -- opts into outbound networking being available to the extension. Absent by default; an extension that doesn't declare this has no network access, full stop.
- `ui: {label, icon}` -- opts into a page at `/ext/<name>`, described as a typed "canvas" element tree (`heading`, `text`, `table`, `button`, `input` in `ui.validate_canvas`) rather than raw HTML/JS, plus named button actions the page can trigger. See `plugin-system-research.md` and [006-trusted-page-sections-vs-extension-canvas.md](decisions/006-trusted-page-sections-vs-extension-canvas.md).
- `tools: [{name, description, parameters, destructive?}]` -- contributes named tools the chat agent can call mid-conversation, dispatched under `<extension_name>.<tool_name>` the same way built-in tool groups are. Every tool must declare a JSON Schema `parameters` table (`#20`), the Extension's `name` cannot collide with a built-in `AGENT_TOOLS` group (`extension.is_reserved_tool_name`, `#15`), and tool names must avoid `__` so Claude/Ollama `.` <-> `__` wire mapping round-trips cleanly (`#21`, [agent-protocol.md](agent-protocol.md)).
- `schemas: [<entity type>]` / `views: [<view name>]` -- the extension ships these entity types and views itself, as `extensions/<name>/schemas/<type>.lua` and `extensions/<name>/views/<view>.lua` -- see "Extension-owned entity types and views" below.
- `manual_triggers: [{name, label, description}]` -- contributes admin-only "run this now" buttons, listed and dispatched from a dedicated `/admin-triggers` route (`/admin-triggers/<extension>/<trigger>`) rather than an extension's own `/ext/<name>` page (an extension can offer a manual trigger with no UI page at all). Unlike every other capability, reaching the dispatch route needs the account's own Admin capability, not merely the extension's approval -- a manual trigger runs someone's explicit request, on demand, not a reaction to a write any user made or a tool the model itself decided to call. Runs synchronously and returns a plain `{message = "..."}`; a trigger whose real work is slow is expected to kick that work off elsewhere (an outbound call, a queue write) and return quickly itself, the same way a `ui` action must.

Extension directory names and resource names must pass `config.valid_resource_name` (lowercase ASCII letters, digits, `_`, `-`; directories missing either `manifest.lua` or `main.lua` are ignored so unfinished scaffolds do not error). Every Extension invocation (`on_before`, `on_after`, `render`, UI actions, `tools`, and `manual_triggers`) executes inside `sandbox.extension_env` under `extension.call_bounded` (`sandbox.pcall_bounded`). Queued `system_job` rows from `after_*` hooks are claimed atomically (`status = 'running:<token>'`, recovering crashed claims after `900 s`) and retried up to `extensions.max_job_attempts` (default `5`) before moving to `'failed'` so one broken Extension job never blocks others.

An extension needs an explicit approval (`system_approval`, `kind = 'extension'`) before any of its hooks/routes/tools/triggers run at all, and the exact capabilities it declared at that moment are what get recorded as approved ([004-sandboxed-content-and-hash-keyed-approvals.md](decisions/004-sandboxed-content-and-hash-keyed-approvals.md)). `extension.capabilities_equal` compares stored vs. current capabilities via order-independent set and deep table equality (avoiding `dkjson.encode` hash-key ordering drift), and `agent.tool_registry` re-checks approval on every call so revoking or editing an Extension's manifest takes effect immediately, mid-turn included.

## Extension-owned entity types and views

A feature that needs its own data -- tasks, say -- can be packaged whole as one extension instead of split across the deployment's `schemas/`, `views/` and `extensions/`: its entity types and views live inside the extension directory, and are enabled, approved and changed as one unit.

```
extensions/task/
  manifest.lua          -- capabilities.schemas = {"task"}, capabilities.views = {"prioritized_tasks"}
  main.lua
  schemas/task.lua
  views/prioritized_tasks.lua
```

An extension never creates tables itself -- there's no DDL capability. Its schema files are ordinary entity type definitions, loaded by the same sandboxed `schema.register` path as the deployment's own `schemas/`, so the table, ledger, validation, `/browse`/`/detail`/`/register` pages and the agent's `entity.*` tools all come from daat exactly as they would for any other type. Views are ordinary view definitions and still need their own `daat view approve`, like any view.

- **Declared by name.** Only the names listed in `capabilities.schemas`/`views` are loaded, and the listed names are part of what gets approved -- so owning a new entity type (a new table) is a capabilities change that makes the extension unapproved until someone re-approves it. Editing an already-declared schema's fields doesn't: that deploys the same way a change to `schemas/` does. A file must define the name it's declared under, or schema sync fails.
- **Only while approved.** An unapproved extension's types are never registered or updated. Revoking one (or deleting it) never drops anything: a table registered while it was approved keeps its data, exactly like deleting a file from `schemas/`.
- **No overriding.** The same entity type or view name defined twice -- in `schemas/` and an extension, or in two extensions -- fails schema sync (or `daat view list`) with an error naming both, rather than one silently winning.

## Saved Views (`views/*.lua`, `src/view.lua`)

Saved Views are named, read-only `SELECT` queries stored in `views/<name>.lua` (or inside an approved Extension's `extensions/<ext>/views/<name>.lua` when listed in `capabilities.views`), loaded under `sandbox.data_env()`:

```lua
return {
  name = "widgets-in-stock",
  title = "Widgets in stock",
  entity_type = "widget", -- optional: renders "+ Register new" on /view
  param = {name = "min_qty", type = "integer"}, -- optional: integer | number | text (never 'id' or 'name')
  sql = "SELECT id, label, quantity FROM widget WHERE quantity >= ? AND archived_at IS NULL ORDER BY label ASC;",
  sql_mariadb = nil, -- optional MariaDB-specific SQL when no single portable expression exists (e.g. DATEDIFF vs julianday)
  columns = {
    {name = "id", label = "ID"},
    {name = "label", label = "Label"},
    {name = "quantity", label = "Quantity"},
  },
}
```

- **Exact-SQL approval (`system_approval`, `kind = 'view'`):** Views do not execute on `/view`, inline `{{view:...}}` embeds, or the agent's `view.run` tool until approved via `daat view approve <name>` or `/system`. `view.approval_identity` records `sql` (combined with `sql_mariadb` when present), so editing either query string invalidates approval immediately ([004-sandboxed-content-and-hash-keyed-approvals.md](decisions/004-sandboxed-content-and-hash-keyed-approvals.md)). Runtime parameters (`?`) execute via `db.query_params` rather than raw string interpolation.
- **Lexical `SELECT`-only enforcement (`view.select_only_problem`):** Shared across Saved Views, `label_template.sql`, `/sql` (`view.run_adhoc`), and `entity.query` (`view.run_agent_query`). A token scanner strips `--`, `#`, and `/* ... */` comments while rejecting MySQL executable comments (`/*! ... */`), stacked `;` statements, backslash-ambiguous literals, and `FORBIDDEN_SQL_WORDS` (`insert`, `update`, `delete`, `drop`, `alter`, `attach`, `pragma`, `replace`, `outfile`, `load_file`, `get_lock`, `sleep`, `benchmark`, ...).
- **Agent `entity.query` table boundary vs. `/sql` console:** Setup/Admin `/sql` (`view.run_adhoc`, capped at `ui.adhoc_row_cap`) can read any table, whereas the chat agent's `entity.query` (`view.run_agent_query`, capped at `agent.query_row_cap`) parses every `FROM`/`JOIN` target across CTEs and subqueries and restricts access to `view.queryable_tables`: registered Entity tables, their `<type>_<field>` multivalue junctions, `entity_ref`, `document_link`, and `entity_event` — keeping `auth_user`, `auth_api_key`, `agent_message`, and `agent_pending_action` unreachable even under prompt injection, and appending an explicit warning note whenever a query omits `archived_at` on a table that contains archived rows.

## What extensions cannot do today

- Cross-entity-type rules. A rule is scoped to one entity type's own values, plus read-only lookups into others -- it cannot subscribe to every entity type at once.
- Anything outside its declared capabilities. There is no "trusted mode" escape hatch; if a script needs more, the manifest has to declare it and it has to be (re-)approved.
