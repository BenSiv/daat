# Entity Types as Code

An entity type is defined as a small declarative file, one file per type -- not a schema entered through an admin UI, and not a serialized data format like YAML or JSON. The definition is itself executable, in the same language as everything else in the system, so there's exactly one thing a definition author, an extension author, or the platform itself ever needs to know how to read or write. That also means a definition gets ordinary language conveniences (comments, no quoting-every-key ceremony) for free, with no second parser to maintain for a serialization format that would have bought nothing a plain definition doesn't already give.

## Format

```lua
-- schemas/reagent.lua
return {
  name = "reagent",
  fields = {
    {name = "lot_number",    type = "text",      required = true},
    {name = "concentration", type = "number",    required = true},
    {name = "prepared_on",   type = "date",      required = true},
    {name = "status",        type = "select",    required = true,
      values = {"active", "depleted", "discarded"}},
    {name = "prepared_from", type = "reference", required = false,
      entity_type = "reagent"},
  },
}
```

## Field types

| type | meaning |
|---|---|
| `text` | free string |
| `number` | numeric, integer or float |
| `date` | ISO 8601 date |
| `select` | one of a fixed `values` list, or a shared named `dropdown` (see below) |
| `reference` | points at another entity by id, optionally constrained to a specific entity type |
| `multi_select` | several values from a fixed `values` list or named `dropdown` |
| `multi_reference` | several links to another entity type by id |
| `polymorphic_reference` | points at another entity by id, where the *target entity type itself* varies per row (a fixed, closed `allowed_entity_types` list, not "any registered type") |
| `multi_polymorphic_reference` | several such links, each independently typed |
| `sql_select` | a `text`-shaped value that must be a single, plain `SELECT` statement (no `;`, no DDL/DML/pragma) -- see "Label printing" below for the built-in type that uses it |

A `number` field may optionally declare `min`/`max` -- wired into the registration form's number input (bounding its native spinner arrows), but **a UI hint only, not enforced when a value is actually saved**. A real range constraint (rejecting an out-of-bounds value outright) is still a validation extension's job (see `extensibility.md`) -- `min`/`max` here don't replace that, they just stop the input widget itself from suggesting an obviously-invalid value. Making this a real, enforced constraint at the definition level is a bigger change (the underlying storage would need new columns) not done yet.

Deferred: attachments/files, computed/formula fields, enforced numeric bounds. None of these are ruled out by the design -- they're just not needed to prove the core registration workflow end to end. (Rich text editing exists for the built-in Document entity type -- see `architecture.md`'s "Documents" section -- but a schema-defined `text` field on a custom entity type is still a plain string, no markup.)

## Multivalue fields (`multi_select`/`multi_reference`) -- a real
## junction table, not a delimited string column

```lua
-- schemas/sample.lua
return {
  name = "sample",
  fields = {
    {name = "label",          type = "text",           required = true, display = true},
    {name = "source_plants",  type = "multi_reference", required = false, entity_type = "plant"},
    {name = "process",        type = "multi_select",   required = false, dropdown = "work_process"},
  },
}
```

A multivalue field never becomes a column on the entity's own table -- it gets its own companion junction table instead (`schema.ensure_multi_field_table`), named `<entity_type>_<field_name>` (e.g. `sample_source_plants`, `sample_process`): a real many-to-many table with a composite primary key, the same shape `document_link` already uses for document-to-document links. `multi_reference`'s second column is a genuine foreign key into the referenced entity type's table -- never a lossy string join. A value arrives as either a real array (e.g. a JSON API payload) or a comma-separated string (CLI convenience); both normalize to the same array before validation and storage.

Ledger history records a multivalue field's old/new as real sets, the same as any other field -- editing one is exactly as auditable as editing a scalar field, not an untracked side channel.

## Polymorphic references (`polymorphic_reference`/
## `multi_polymorphic_reference`) -- a link whose target type varies per row

A plain `reference` field's target type is fixed once, in the schema file. Real data sometimes doesn't work that way: a lab sample's "source" might be a plant specimen directly, or another sample it was propagated from -- decided per row, not something the schema can pin down to one type. `entity_type` (singular) doesn't fit that; declare a closed list of the types this field can actually point to instead:

```lua
-- schemas/sample.lua
return {
  name = "sample",
  fields = {
    {name = "label",  type = "text", required = true, display = true},
    {name = "source", type = "polymorphic_reference", required = false,
      allowed_entity_types = {"plant", "sample"}},
  },
}
```

```lua
-- schemas/product.lua -- a product can have more than one source
{name = "source", type = "multi_polymorphic_reference", required = false,
  allowed_entity_types = {"plant", "sample"}}
```

This is deliberately **not** "a reference to any registered type" -- `allowed_entity_types` is a closed list validated the same strictness as a plain `select` field's declared `values`: a value naming a type outside that list is rejected, same as an out-of-list `select` value would be. Real-world check before adding this field-type pair at all: every genuine case found in this deployment's own data had 1-2 possible target types, never "could be anything" -- if a field in your own data genuinely needs "any of dozens of types," that's a sign this isn't the right tool for it.

Storage is a single shared table (`entity_source`: `from_type, from_id, field_name, to_type, to_id`) across every polymorphic field on every entity type -- not a table per (entity type, field name) the way `multi_reference`'s own junction tables work, since a per-type junction table's foreign key is fixed to one target type at creation time and can't represent "this row's target type differs from that row's." A value is submitted as either a real `{type, id}` object (JSON API payloads) or a `type:id` string (CLI convenience, e.g. `source=plant:12`); several as a comma-separated list of either shape for the multi-value variant. Rendered the same real clickable link (with hover preview) a plain `reference` field's value gets, resolving each item's link target from its own `type`, and shows up in `entity.relationships`/the Data page's relation diagram as one edge per `allowed_entity_types` entry, exactly like a fixed-type reference field's edge would.

## Named dropdown lists -- share one value list across fields

A `select`/`multi_select` field can either inline its own `values` list (as above) or reference a shared, reusable list by name:

```lua
-- dropdowns/work_process.lua
return {
  name = "work_process",
  values = {"cultivation", "harvest", "processing"},
}
```

```lua
{name = "process", type = "multi_select", dropdown = "work_process"}
```

Dropdown files live in `dropdowns/*.lua`, loaded the same config-as-code way `schemas/*.lua` is. A dropdown's current values are resolved into the field's own `enum_values` at schema-sync time, so editing `dropdowns/work_process.lua` and re-syncing updates every field that references it -- one edit, not a hunt-and-replace across every schema file that happened to inline the same list. This is purely a literal-value mechanism -- no foreign key, no entity type involved -- entirely separate from `reference`/`multi_reference`, which are real entity links.

## Type-level flags -- `admin_write_only`

A definition can opt into `admin_write_only = true` at the top level (alongside `name`/`fields`), requiring Admin capability to create/update/archive any row of that type (checked in `cgi.lua`'s entity-write routes, not here -- schema.lua has no notion of an HTTP session). Anyone can still read/view rows of the type; this only gates writes. Meant for entity types whose data is itself sensitive or consequential in a way ordinary lab entities aren't -- see `label_template` below, the first real consumer.

## Label printing (`label_template`)

Label printing prints a physical barcode/ID label (ZPL, Zebra Programming Language) for one entity, via the Zebra Browser Print desktop app's local JS SDK. A label template is a real, ledgered entity of a built-in type, `label_template` -- not a config file -- created/edited the same way any other entity is (`/register`, `/detail`), so editing a label's query or ZPL body is exactly as auditable as editing a sample:

```lua
-- schemas/label_template.lua
return {
  name = "label_template",
  admin_write_only = true,
  fields = {
    {name = "for_entity_type", type = "text",       required = true},
    {name = "sql",             type = "sql_select",  required = true},
    {name = "zpl",             type = "text",        required = true},
  },
}
```

- `for_entity_type`: which entity type's `/detail` page shows the "Print Label" button (e.g. `"sample"` -- matches a real schema name).
- `sql`: a single `SELECT` with exactly one `?` placeholder, bound to the entity's own id at print time. Column aliases become `{{token}}` names the `zpl` body can reference. Any cross-entity value (e.g. a linked experiment's title) is just a `JOIN` in this query -- not a separate mechanism, and not depth-limited the way a bespoke field-path resolver would be.
- `zpl`: raw ZPL; every `{{column_name}}` token is substituted from the query's single result row. `^`/`~` are ZPL's own command-prefix characters -- a substituted value containing either is stripped, not left to corrupt the label (no ZPL string-escaping convention exists to encode them safely instead).

`sql`'s `sql_select` type means it's rejected at save time if it's anything but a plain `SELECT` (reusing the same check `views/*.lua` already uses) -- re-checked again at render time too, storage is never trusted alone. `admin_write_only` means only an Admin can create or edit a `label_template` row; anyone who can view an entity's `/detail` page can still print it.

## Master/detail: a entity type with a variable-length list of children

Some entities are naturally a fixed set of fields plus however many child rows a user adds -- e.g. a `composite` entity built from however many `component` rows describe it (task #112). No new storage concept is needed for this: `component` is just its own entity type with a plain `reference` field pointing at `composite`, exactly like any other `reference`. Children aren't picked from a pre-existing list the way a `multi_reference` value would be -- each one is entered fresh alongside its parent -- so the junction-table mechanism above doesn't apply here at all.

```lua
-- schemas/composite.lua
return {
  name = "composite",
  fields = { {name = "lab_name", type = "text", required = true, display = true} },
}
```
```lua
-- schemas/component.lua
return {
  name = "component",
  fields = {
    {name = "composite", type = "reference", required = true, entity_type = "composite"},
    {name = "amount", type = "number", required = false},
  },
}
```

Three generic mechanisms, computed from `schema.relationships()` (every `reference`/`multi_reference` edge across all entity types) rather than declared per pair of types, make the actual workflow work:

- **`/detail` shows a "Related records" section** for every plain `reference` field elsewhere that points back at this entity (e.g. `component.composite -> composite`) -- a short preview of the actual rows, an "+ Add component" link, and a "View all N" link once there are more than the preview cap. Automatic for *any* entity type with an incoming `reference` -- `experiment`'s `/detail` page would start showing "samples referencing this experiment" the same way, with no extra schema declaration.
- **`/register?lock_<field_name>=<value>`** fixes one field to a constant across every row of the batch-entry table -- the "+ Add component" link above points here with the parent's id, so adding several components for one composite means never re-picking (or risking mis-picking) which composite they belong to. The locked field renders as a read-only display (a `reference` field resolves the parent's own display label, not a bare id), not an editable input.
- **`/browse?filter_field=<field_name>&filter_value=<value>`** is the same generic filter, reused for the "View all" link -- a real, paginated list, not a second pagination scheme bolted onto `/detail`.

## Loading is sandboxed, not just a bare load

A definition file is executable, not inert data the way a YAML/JSON file would have been -- so it isn't loaded by simply running it: it's bound to a restricted execution environment that can only construct and return a plain description, nothing that could touch the filesystem, network, or anything else an extension might legitimately need. Same security posture a data format would have had, without needing a second parser to get there.

## What a definition generates

Loading a definition does two things:

1. Registers (or updates) the entity type's own field list, which the history log and validation both read at runtime.
2. Generates (or migrates) a real, typed table for that entity type -- `reagent(id, lot_number, concentration, prepared_on, status, prepared_from, created_by, created_at, updated_by, updated_at, last_event_id, archived_at)` -- the thing a dashboard actually queries. A `multi_select`/`multi_reference` field never becomes a column here -- it gets its own companion junction table instead (see above). A `polymorphic_reference`/`multi_polymorphic_reference` field never becomes a column either -- it's stored in the shared `entity_source` table instead (see "Polymorphic references" above).

Changes to a definition are themselves ordinary version-control commits: renaming or adding a field is a diff against `schemas/reagent.lua`, reviewable and revertable the same way any other change is.

## Where a generic data format still shows up

Only as invisible storage plumbing: the history log serializes each entry's field changes as a small blob inside a single column. That's never something a definition or extension author writes by hand, so it isn't a format anyone needs to learn.
