# Database Concurrency, Transactions & Store Verification

`daat` runs against two storage engines through a single backend-agnostic adapter (`../../luam/lib/database.lua` over `../../luam/lib/database_adapter.lua`; see [Luam](../../luam/README.md)): local SQLite in WAL mode (`.store/store.db`) and networked MariaDB / MySQL (such as Cloud SQL behind an auth proxy). Because `daat` serves web requests as separate CGI OS processes alongside background CLI workers (`daat run-pending`, `daat agent continue`) — and because companion tools such as [brain-ex knowledge](../../brain-ex/doc/knowledge.md) share the same `luam/lib/database.lua` layer — transaction atomicity, cross-process advisory locking, and connection hygiene cannot rely on in-process mutexes or happy-path SQL execution.

This document codifies the hard-won concurrency, locking, and verification invariants established across `luam/lib/database.lua`, `luam/lib/database_adapter.lua`, `luam/lib/laws.lua`, and `daat/src/verify.lua`.

---

## 1. MariaDB `GET_LOCK` Returns `0` on Timeout Without Raising a SQL Error

Schema migrations and DDL cannot rely on `START TRANSACTION` on MariaDB/MySQL because DDL statements (`CREATE TABLE`, `ALTER TABLE`, `CREATE INDEX`) cause an **implicit commit** of any open transaction. Cross-process schema synchronization therefore uses `database.with_lock(db_path, lock_name, timeout_secs, fn)`, backed on MariaDB by `SELECT GET_LOCK(name, timeout)`.

**The trap:** When `GET_LOCK(name, timeout)` times out waiting for another session, MariaDB does **not** raise a SQL error — the `SELECT` succeeds normally and returns a single row with `got = 0` (or `NULL` on internal error). Naive code that only checks `pcall(database.query, ...)` silently proceeds into the critical section completely unlocked.

**The rule (`database.with_lock`):**
- Always inspect the returned row value and require `tonumber(lock_rows[1].got) == 1`.
- Any `0`, `NULL`, or empty result immediately unpins the connection and raises a hard error (`could not acquire database lock <name> within <N>s`), never executing `fn()` unlocked.
- `RELEASE_LOCK(name)` is issued only when `got == 1` *and* `CONNECTION_ID()` proves the original session is still alive.

---

## 2. `mariadb_pin_connection`: Preventing Auto-Reconnect from Dropping Locks or Transactions

For normal stateless reads, `database_adapter.get_mariadb_connection` caches one connection per `(host, port, user, database)` per OS process and transparently reconnects once if an idle socket was closed by the server or proxy.

**The trap:** Both MariaDB transactions (`START TRANSACTION`) and named advisory locks (`GET_LOCK`) are strictly **session-scoped** on the server. If a TCP socket drops mid-transaction or mid-migration and the adapter transparently opens a fresh connection:
1. The server rolls back the uncommitted prefix of the transaction and releases the `GET_LOCK` on the dead session.
2. Subsequent statements in `fn()` execute on the new connection in **autocommit mode without the lock**, silently committing torn state while another worker enters the critical section.

**The rule (`mariadb_pin_connection` + `CONNECTION_ID()`):**
- Both `database.transaction` and `database.with_lock` call `database_adapter.mariadb_pin_connection(db_path, +1)` before starting and record `conn_before = database.connection_id(db_path)` (`SELECT CONNECTION_ID()`).
- While pin depth `> 0`, `get_mariadb_connection_internal` **refuses** to replace a dead socket, returning an immediate error (`MariaDB connection dropped while holding an active transaction or advisory lock`) instead of reconnecting.
- Before issuing `COMMIT` (and optionally per batch step via the `check_alive()` callback passed to `fn(check_alive)`), `database.transaction` verifies `database.connection_id(db_path) == conn_before`, aborting if the session identity ever changed.
- Every exit path (`ok`, Lua error, or commit failure) decrements the pin depth (`mariadb_pin_connection(db_path, -1)`) so the process never leaks a permanently pinned dead handle.
- Separately, every new MariaDB session appends `NO_BACKSLASH_ESCAPES` to `@@SESSION.sql_mode` and reads it back before accepting the connection, ensuring `database.quote` single-quote doubling is safe against backslash-escape SQL injection (`doc/auth.md`, "SQL quoting").

---

## 3. The POSIX `fcntl` Advisory-Lock Trap on SQLite WAL

Under POSIX advisory file locking (`man 2 fcntl`), kernel locks (`F_SETLK` / `F_SETLKW`) belong to a **`(process, inode)`** pair — **not** to the individual file descriptor that acquired them. Closing *any* file descriptor in the process that points to that inode immediately releases **every** `fcntl` lock the process holds on that file.

**Two concrete ways this corrupts or races SQLite WAL:**
1. **Probing `.db` with `io.open` + `io.close`:** If a process holds an open SQLite WAL connection (`sqlite_keep_open(true)`) and checks file existence by opening and closing `.store/store.db` (`io.open(db_path, "r")` -> `io.close`), the kernel strips SQLite's `SHARED`/`EXCLUSIVE` WAL locks on `.store/store.db` while leaving `.db-shm` mapped in memory. When a concurrent short-lived CGI reader exits, `sqlite3WalClose` sees zero lock holders and unlinks `.db-wal` and `.db-shm` out from under the live process.
   - **Rule:** File-existence checks (`luam/lib/paths.lua`'s `paths.file_exists`, called by `config.is_initialized`) **must** use `lfs.attributes(path, "mode") != nil` (`stat(2)`), never `io.open` + `io.close`.
2. **Cross-process DDL locks (`database.with_lock` on SQLite):** Acquiring an OS lock directly on `db_path` would either contend with `fn()`'s own SQLite connections or get stripped the moment an uncached helper opened and closed `db_path`.
   - **Rule (`sqlite_acquire_lock`):** `database.with_lock` hashes `(canonical_sqlite_path(db_path), lock_name)` into a dedicated companion SQLite lock file in `/tmp` (`/tmp/luam_dblock_<hash>.lck`) and enters `BEGIN EXCLUSIVE` under `PRAGMA busy_timeout`. Kernel locks on the companion file auto-release if a worker crashes or receives `SIGKILL`, while `fn()` can freely open, close, or migrate `db_path` without touching the lock file's inode.

---

## 4. `sqlite_keep_open(true)` Requires `database.transaction(db_path, fn)`

`daat` (`src/main.lua`) enables `database_adapter.sqlite_keep_open(true)` for the lifetime of each CLI or CGI invocation so all queries reuse a single cached SQLite handle per process instead of re-parsing `sqlite_master` on every call (`doc/performance.md`).

**The traps with raw `BEGIN` / `COMMIT` on a kept-open handle:**
- When connections were opened per call, an uncaught Lua error mid-transaction closed the transient handle and rolled back automatically. On a kept-open handle, a raw `BEGIN` followed by a thrown error leaves the transaction **open on the cached connection**, causing unrelated later writes in the same process to silently piggyback onto — and eventually commit — the broken partial transaction.
- Issuing a nested `BEGIN` inside an already-active transaction raises `cannot start a transaction within a transaction` on SQLite and **implicitly commits** the outer transaction on MariaDB/MySQL.
- Plain `BEGIN` (deferred) on SQLite starts as a reader and upgrades to a writer lock on the first `INSERT`/`UPDATE`; if two WAL connections try to upgrade simultaneously, SQLite immediately returns `SQLITE_BUSY` without waiting for `busy_timeout`.

**The rules (`database.transaction(db_path, fn)`):**
- **Never emit raw `BEGIN` / `START TRANSACTION` / `COMMIT` in application modules.** Wrap every multi-statement atomic write (entity + ledger projection, pool heat conservation, duplicate folding, link re-indexing) in `database.transaction(db_path, fn)`.
- **Immediate writer acquisition on SQLite:** `database.transaction` issues `BEGIN IMMEDIATE;` on SQLite so concurrent writers wait cleanly on `PRAGMA busy_timeout = 5000` at transaction entry rather than deadlocking mid-transaction on a reader-to-writer upgrade.
- **Guaranteed `pcall` + `ROLLBACK`:** `fn` executes under `pcall`. If `fn` throws an error *or* returns `false, ...` as its first return value (explicit abort without throwing, used for validation failures), `database.transaction` executes `ROLLBACK;` before propagating the error or result. In addition, `release_sqlite_connection` issues a defensive `ROLLBACK;` whenever a statement fails on a kept-open handle.
- **Re-entrancy:** `_active_transactions[database.cache_key(db_path)]` makes nested `database.transaction` calls join the outer transaction rather than issuing a second `BEGIN` / `START TRANSACTION`.
- **Normalized mutation counts & connection-scoped IDs:** `database.exec(db_path, sql)` returns `(true, insert_id, affected_rows)` identically on both SQLite (`sqlite3_last_insert_rowid` + `sqlite3_changes`) and MariaDB (`mysql_insert_id` + `mysql_affected_rows`) on the exact connection that performed the write — never use `SELECT MAX(id)` under concurrency.

---

## 5. Property-Based Law Checking (`luam/lib/laws.lua`) & `daat store verify` (L1–L4)

Fixing individual concurrency and quoting bugs is paired with executable invariants that check both pure algebraic properties in unit tests and full relational store consistency on any live SQLite or MariaDB deployment.

### 5.1 Generative & Stateful Law Checking (`luam/lib/laws.lua`)
`luam/lib/laws.lua` provides deterministic, zero-dependency property-based testing (`DEFAULT_SEED = 20261117`, overridable via `LAWS_SEED=<int|random>`) with integrated shrink trees:
- **Algebraic combinators:** `laws.forall`, `laws.idempotent`, `laws.involution`, `laws.commutative_diagram`, `laws.homomorphism`, and `laws.monotone`.
- **Stateful command-trace models (`laws.state_machine`):** Generates random sequences of store operations (creates, updates, archives, unarchives, heat reinforcements, link edits, duplicate folds), checks postconditions and global invariants after every step, and shrinks any failing trace down to a minimal reproducible counterexample.

### 5.2 Whole-Store Invariant Verification (`daat store verify [--json]`)
`src/verify.lua` (`verify.check_all(db_path)`, exposed on the CLI as `daat store verify [--json]`) performs a read-only audit of four formal invariant families across any SQLite or MariaDB store:

| Law | Function | Invariants Verified |
|---|---|---|
| **L1** | `verify.pool_thermodynamics` | **Knowledge-pool heat conservation:** `pool_active` matches `archived_at IS NULL AND merged_into IS NULL`; `knowledge_pool_state.document_count` equals `\|D_active\|`; every active document has finite positive `eff = raw_heat * exp(log_pool_scale - log_scale_at_write)`; total effective heat satisfies `sum(eff) == \|D_active\| * BASE_HEAT` within floating-point tolerance; and every `document_link.raw_strength >= 1.0`. |
| **L2** | `verify.ledger_projection` | **Event-sourcing fold homomorphism:** Replays `entity_event` from `event_id = 1` upward and verifies that every registered entity table — including scalar columns, `last_event_id`, `archived_at`, multi-value junction tables, and polymorphic `entity_ref` rows — exactly equals the folded ledger state, with `create` `event_id == entity_id` and zero orphan or missing projected rows. |
| **L3** | `verify.derived_indexes` | **Derived-index agreement:** Verifies exact agreement between live source tables and derived lookup structures: active `document_link` rows match `[[link]]` targets extracted from active `document.content` (accounting for folded duplicates), `entity_name_index` matches `reference.expected_index_rows` for all active named entities, and `tag_centre` member counts and vector sums match active `document_tag` + `document_embedding` vectors. |
| **L4** | `verify.ontology_and_tiers` | **Forest acyclicity & tier provenance:** Proves `document.parent_id` and active `tag.parent` pointers form cycle-free forests, and verifies that every document with `tier > 0` has a curation `source_type` permitted by `knowledge.can_hold_tier(source_type)`. |
