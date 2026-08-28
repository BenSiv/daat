# Extensibility

The extension system exists so that behavior specific to one deployment's own needs -- a validation rule, a reaction to an entity being created or changed -- never has to be written into the platform itself. An extension is a small script, version-controlled the same way an entity type definition is, that declares up front what it needs and gets exactly that and nothing more.

This whole document describes one of three trust tiers -- deployment-authored, sandboxed, capability-checked, admin-approval-gated. It's the only one of the three that isn't first-party code: `agent_provider.lua`/`search_provider.lua` and their implementations under `src/provider/` are the middle tier (ships with daat, full access, but swappable via config); everything else in `src/` is core (also full access, not swappable). See doc/architecture.md's "Providers" section for the full three-tier picture and why the line is drawn where it is.

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

**"Queued," concretely**: an after-hook doesn't run the instant its event fires. Creating, updating, or archiving an entity records a pending job in the same transaction as the change itself, and that job only actually executes when something later asks the platform to run its pending jobs (`entity run-pending`, wired up on whatever schedule a deployment chooses) -- not as an automatic side effect of the write. Unarchiving an entity does **not** enqueue an after-hook today (only archiving does) -- not a deliberate design stance, just not wired up yet.

## Capabilities

A manifest declares what an extension needs; it's granted exactly that and nothing more when its code actually runs:

- `read: [entity]` -- read-only lookups into current entity state via `ctx.query(entity_type, filter)`. No raw query language is ever exposed.
- `write: [entity]` -- access to create or update entities via `ctx`. Most extensions (especially validation rules) declare no write access at all.
- `net: outbound` -- opts into outbound networking being available to the extension. Absent by default; an extension that doesn't declare this has no network access, full stop.

An extension needs an explicit approval before any of its hooks run at all, and the exact capabilities it declared at that moment are what get recorded as approved. If the manifest's declared capabilities change afterward, approval is automatically treated as stale until a human reviews and re-approves it -- an extension can't silently escalate what it's allowed to touch just by editing its own manifest.

## What extensions cannot do today

- Render their own pages or routes. The event hooks cover the concrete cases (integrations, derived-entity automation) without this.
- Cross-entity-type rules. A rule is scoped to one entity type's own values, plus read-only lookups into others -- it cannot subscribe to every entity type at once.
- Anything outside its declared capabilities. There is no "trusted mode" escape hatch; if a script needs more, the manifest has to declare it and it has to be (re-)approved.
