# 001. CGI-per-Request Process Isolation & Connection Lifecycle

- **Date:** 2026-11-27
- **Status:** Accepted

## Context & Real Need

`daat` ships as a single self-contained binary ([why-luam.md](../why-luam.md)) fronted by Apache `mod_cgid`, where every HTTP request runs as a fresh OS process and background queues run via CLI invocations (`daat run-pending`, `daat agent continue`). Running a separate persistent application daemon from day one would add process supervision, cross-request memory/state leak risk, and deployment complexity.

Conversely, naive CGI-per-request initially caused `397 ms–19.6 s` page latencies on an 85-table LIMS workload (`5,000` `sample` Entities, `1,500` Documents): `18.6–29.8 ms` copying and compiling `1.97 MB` of bundled `.lua` text on every spawn, `130` unconditional schema-init SQL queries per request (`42` write DMLs that serialized concurrent SQLite WAL readers at `4.4 req/s`), reopening SQLite or issuing `COM_PING` round-trips per query (`30.7x` SQLite slowdown; `2x–4x` MariaDB TCP RTTs), and stripping POSIX `(process, inode)` `fcntl` WAL locks whenever `io.open` + `io.close` probed `.store/store.db`.

## Decision

1. **Single-binary CGI-per-request dispatch (`src/main.lua`, `src/web.lua`):** `main()` dispatches to `web.handle_request` when `GATEWAY_INTERFACE` or `REQUEST_METHOD` is set and to CLI handlers otherwise. OS process exit bounds memory and isolates crashes per request; cross-process mutations coordinate strictly through SQL (`database.transaction`, `database.with_lock`, and conditional `UPDATE` claim tokens; see [database-concurrency.md](../database-concurrency.md)).
2. **Precompiled `.rodata` bytecode & zero-DB static short-circuit (`luam/lib/static`, `src/web.lua`):** Bundled `.lua` modules are compiled to Lua 5.1 bytecode at build time and loaded lazily from `.rodata` (`5.6 ms` binary boot). `/theme-asset` and `/vendor` respond before touching the database (`0` SQL queries, `6–8 ms`).
3. **Signature-gated schema initialization (`src/store.lua`, `src/web.lua`, `src/schema.lua`):** `store.migrate` fast-paths in one `system_state` read (`store.schema_version`), while built-in `init_schema` hooks and `schema.sync_all` gate behind `web.builtin_schema_signature` and `schema.sync_signature` in `system_state` (under `db.with_lock` on cold/changed deploys). Steady-state `GET` requests execute `0` DDL and `0` write DML statements.
4. **One reused connection per process (`luam/lib/database_adapter.lua`, `luam/lib/paths.lua`):** `main.lua` enables `sqlite_keep_open(true)` (parsing `sqlite_master` once per process) and caches one MariaDB connection per `(host, port, user, database)` descriptor (skipping `COM_PING` within `5 s` and pinning the socket inside active transactions/locks). File-existence checks (`paths.file_exists`) use `lfs.attributes` (`stat(2)`), never `io.open` + `io.close`, preserving SQLite WAL advisory locks.

## Deliberate Tradeoffs & Not in Scope

- **Accepted cost:** Every CGI request pays `0.73 ms` OS `fork + exec`, `5.6 ms` binary boot, and (on MariaDB) `~4–6 ms` TCP + auth + `SET SESSION sql_mode` connection setup (`9.2 ms` SQLite / `27.9 ms` MariaDB proxy on `/login` at `479` / `321 req/s` for `c = 16`; `21.4 ms` / `95.4 ms` on 100-row Entity browse). Work outliving one HTTP request spawns detached CLI workers (`daat agent continue`; see [005](005-agent-approval-gate-and-detached-queues.md)).
- **Not in scope:** In-process cross-request state caches, background threads/timers inside CGI handlers, or running an external connection-pooler/application-server daemon at current team/lab concurrency.
- **Revisit trigger:** Sustained per-host traffic exceeding `200–300 req/s` or latency SLAs where `~4–6 ms` per-request MariaDB connection setup dominates — at which point opt-in pre-fork persistent worker mode (`#57`, scoped with its state-hygiene checklist in [performance.md](../performance.md) Option 3) applies.

## Verification

- `./bld/test.sh` (including `tst/integration/mariadb_backend.bats`)
- `./bin/daat store verify`
- Benchmark harness & SQL telemetry tables: [performance.md](../performance.md) and [database-concurrency.md](../database-concurrency.md)
