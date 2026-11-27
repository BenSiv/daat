# 003. Append-Only Entity Ledger, Projected Relational Storage & Soft-Archive

- **Date:** 2026-11-27
- **Status:** Accepted

## Context & Real Need

Laboratory and knowledge-management deployments (`celleste-lims`: `34` custom Entity types, `152k+` ledger events, `77k+` `sample` Entities) require two properties simultaneously: complete, non-destructive provenance for every change ("who changed what, when, from which source, and why"), and fast relational SQL queries (`JOIN`, `GROUP BY`, Views, `/browse`, `entity.query`). Versioning Entities as flat files breaks relational reporting, whereas mutating rows in place without an event log — or packing multivalue/polymorphic links into comma-separated text columns — destroys auditability and foreign-key integrity. Additionally, an early `SELECT MAX(event_id)` ID-assignment pattern raced under concurrent `mod_cgid` processes (`#77`).

## Decision

1. **Append-only `entity_event` + projected typed tables (`src/ledger.lua`, `src/schema.lua`, `src/entity.lua`):** Every `create`, `update`, and `archive` writes an immutable `entity_event` row (`LONGTEXT` JSON `field_changes` recording `{old, new}` diffs, `author`, source metadata, and optional/schema-required `reason`) in the same `database.transaction` that updates the Entity type's generated SQL table `<entity_type>`. An Entity's logical `id` equals the connection-scoped `insert_id` (`event_id`) of its `create` event — never `SELECT MAX(event_id)`.
2. **Normalized companion tables & resolved dropdowns (`src/schema.lua`):**
   - `multi_select` and `multi_reference` fields never create scalar columns on `<entity_type>`; they project into companion `<entity_type>_<field>` junction tables (`(<type>_id, value)` or `(<type>_id, <field>_id)` with real FKs) and diff as order-independent sets in `entity_event`.
   - `polymorphic_reference` and `multi_polymorphic_reference` fields require a closed `allowed_entity_types` list (never open-ended "any type") and project into one shared `entity_ref(from_type, from_id, field_name, to_type, to_id)` table.
   - Shared `dropdowns/*.lua` lists sync into `entity_dropdown_value` first and resolve into `entity_field.enum_values` at `schema.sync_all` time so validation reads one uniform column.
3. **Soft-archive everywhere & additive-only DDL (`src/entity.lua`, `src/auth.lua`, `src/agent.lua`, `src/store.lua`):**
   - Entities, Documents, Tags, `document_link` edges, `auth_user` accounts, and `auth_api_key` rows are never hard-deleted; retiring sets a nullable `archived_at` timestamp (excluded from default listings, still reachable by direct `id` lookup and `ledger.history`).
   - Schema evolution (`schema.sync_table`, `store.migrate`) only adds columns/tables and renames superseded tables to `*_legacy`; removing a field from `schemas/<type>.lua` removes its `entity_field` row while keeping its SQL column and data intact.
   - Chat compaction (`agent.compact_if_needed`) marks summarized `agent_message` rows `in_context = 0` rather than deleting them; only aged operational logs (`agent_model_call.prompt`, `tool_trace` payloads, unused passage-cache vectors, and under `lean` already-curated raw chat rows) are pruned by `daat store prune` ([agent-data.md](../agent-data.md)).

## Deliberate Tradeoffs & Not in Scope

- **Accepted cost:** Every Entity write updates both `entity_event` and projected tables; raw `SELECT * FROM <type>` readers must call `entity.apply_computed_field_overrides` (batched `WHERE ... IN (...)`) so companion junction/`entity_ref` sets populate and shadow any stale column left behind after a scalar-to-polymorphic schema conversion; ad-hoc SQL in Views, `/sql`, and `entity.query` must filter `archived_at IS NULL` explicitly (`view.run_agent_query` appends an automatic warning note when omitted on tables containing archived rows).
- **Not in scope:** Hard `DELETE` mutations on Entities, Documents, or accounts; unconstrained polymorphic references without `allowed_entity_types`; automatic `DROP COLUMN` during `schema.sync_all`.
- **Revisit trigger:** If `entity_event.field_changes` (`LONGTEXT` full-body snapshots on frequently edited Documents) creates material database size pressure, introduce content-addressed delta compression on `entity_event` while preserving exact L2 fold equivalence.

## Verification

- `./bin/daat store verify` — Law **L2** (`verify.ledger_projection`) replays `entity_event` from `event_id = 1` and verifies exact agreement across all projected Entity tables, multi-value junctions, and `entity_ref`
- `./bld/test.sh` (`tst/unit/schema.lua`, `tst/integration/entity*.bats`, `tst/integration/mariadb_backend.bats`)
- Field & DDL reference: [schema.md](../schema.md) and [mariadb-migration.md](../mariadb-migration.md)
