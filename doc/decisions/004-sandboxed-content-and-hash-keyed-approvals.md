# 004. Unified Lua Sandboxing, Content-Keyed Approvals & Split Hook Execution

- **Date:** 2026-11-27
- **Status:** Accepted

## Context & Real Need

`daat` keeps deployment customization in Luam files (`schemas/*.lua`, `dropdowns/*.lua`, `templates/*.lua`, `views/*.lua`, `extensions/<name>/{manifest,main}.lua`) so authors learn one language and the binary carries zero YAML/JSON schema parsers ([why-luam.md](../why-luam.md)). Because those files execute as code or run SQL against the store, three concrete hazards arise: (1) an untrusted schema or Extension reaching `io`/`os`/network globals or querying `auth_user` password hashes; (2) a View's SQL or Extension's `manifest.lua` silently escalating capabilities after an Admin approved an earlier version (including `dkjson.encode` key-order nondeterminism breaking naive JSON-string equality); and (3) a slow or failing `after_*` integration hook hanging or rolling back user data entry.

## Decision

1. **One `sandbox.lua` mechanism across all deployment files (`luam/lib/sandbox.lua`, `src/schema.lua`, `src/view.lua`, `src/template.lua`, `src/extension.lua`):**
   - Declarative definitions (`schemas/`, `dropdowns/`, `templates/`, `views/`, and `extensions/*/manifest.lua`) execute under `sandbox.data_env()` with zero filesystem, OS, DB, or network primitives, returning a plain table (`setfenv` only redirects globals, and Luam top-level `function` definitions are implicit-local, so `main.lua` must explicitly `return {on_before = ..., ...}`).
   - Extension `main.lua` code runs under `sandbox.extension_env(manifest.capabilities)` via `extension.call_bounded` (`sandbox.pcall_bounded`) and receives a capability-gated `ctx` (`entity.build_ctx`), where `read = {"entity"}` permits equality/array-`IN` lookups strictly on `schema.is_registered` Entity types and their real scalar columns — never internal tables (`auth_user`, `auth_api_key`, `agent_message`).
2. **Content-keyed Admin approvals in `system_approval` (`src/store.lua`, `src/view.lua`, `src/extension.lua`):**
   - Saved Views enforce lexical single-statement `SELECT`-only syntax (`view.select_only_problem`) and store `view.approval_identity(def)` (`sql` plus `sql_mariadb` when present) in `system_approval`. Editing either SQL string immediately marks the View unapproved until an Admin re-approves it.
   - Extensions store their approved capabilities in `system_approval` and verify `extension.is_approved` on every invocation (including per-call `agent.tool_registry` construction) via order-independent structural/set comparison (`extension.capabilities_equal` across `read`, `write`, `net`, `ui`, `tools`, `schemas`, `views`, and `manual_triggers`), avoiding `dkjson` hash-iteration false negatives while invalidating approval on any capability, tool-schema, or owned-table change.
3. **Synchronous `before_*` vs. queued `after_*` Hooks (`src/entity.lua`, `src/extension.lua`):**
   - `entity.before_create` and `entity.before_update` run synchronously inside `entity.validate` with read-only `ctx` and can return `{field, severity = "error", message}` issues that abort the write.
   - `entity.after_create`, `entity.after_update`, and `entity.after_archive` never execute inline during the save; `extension.enqueue_after_hooks` inserts pending rows into `system_job` inside the write transaction, and an external worker (`daat extension run-pending` / `daat run-pending`) claims (`status = 'running:<token>'`, `900 s` stale recovery) and retries jobs up to `extensions.max_job_attempts` (default `5`) before marking `'failed'`.

## Deliberate Tradeoffs & Not in Scope

- **Accepted cost:** Touching any part of a View's query text (`sql` or `sql_mariadb`) or an Extension's `capabilities` table (even editing a tool description or UI label) requires explicit Admin re-approval via CLI or `/system`; `after_*` hooks are asynchronous and require a deployment cron/systemd timer running `daat run-pending`.
- **Not in scope:** An unsandboxed "trusted mode" for Extensions, DDL or arbitrary raw SQL inside Extensions, synchronous `after_*` execution on user writes, or `after_unarchive` / whole-batch hook events until a concrete deployment requires them.
- **Revisit trigger:** If batch CLI imports (`entity.create_batch`) need whole-batch `before_batch`/`after_batch` hooks or cross-Entity-type wildcard subscriptions.

## Verification

- `./bld/test.sh` (`tst/unit/extension.lua`, `tst/unit/view.lua`, `tst/integration/extension.bats`, `tst/integration/view.bats`)
- Full capability & View reference: [extensibility.md](../extensibility.md)
