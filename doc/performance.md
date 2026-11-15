# Performance Architecture, Benchmarks & Optimization Roadmap

`daat` runs as a single statically-linked Luam binary invoked per HTTP request via CGI (`Apache mod_cgid`), backed by either local SQLite (WAL) or network MariaDB / MySQL (such as Cloud SQL behind an auth proxy). Because the web server, bundling layer, HTML escaping, subprocess execution, and database adapters live in `../luam/lib/`, end-to-end request latency is determined jointly by `luam/lib`, `daat/src`, and web-server configuration.

This document records:
1. How a request executes and what invariants keep CGI-per-request fast across both SQLite and MariaDB.
2. What was optimized across `luam/lib`, `daat`, and deployment Apache configs, with measured before-and-after benchmarks on an 85-table LIMS workload.
3. Saved next-step design options (including async search retrieval curation, native C `float32` vector kernels, and persistent worker mode `#57`) for future scaling phases.

---

## 1. Where Latency Actually Goes (CGI vs. Database & Query Amplification)

A natural hypothesis when running CGI-per-request is that OS process creation and binary initialization dominate response time (`#57`). Empirical profiling on a realistic 85-table deployment (`34` custom Entity types, `5,000` `sample` Entities, `10,000` `sample_state` rows, `1,500` Documents with `768`-dim embeddings and `3,000` aspect vectors) showed the opposite:

- Raw OS `fork + exec` costs **`0.73 ms`**, and empty Luam VM startup costs **`0.98 ms`**.
- Prior to optimization, `daat` binary startup took **`18.6–29.8 ms`** (copying `1.97 MB` of bundled `.lua` text into the Lua heap and compiling 65 source modules per request), while actual page latencies over a `~1.5 ms` RTT database proxy ranged from **`397–548 ms`** on trivial routes (`/login`, `/theme-asset`) to **`5.58–5.74 s`** on Entity browse/Extension views and **`19.63 s`** on Document semantic search.
- Roughly **93%–99% of baseline latency** came from four multiplicative factors rather than OS process spawning:
  1. **Database adapter per-call overhead (`luam/lib/database_adapter.lua`):** On MariaDB, `get_mariadb_connection` issued a synchronous `mysql_ping()` (`COM_PING`) network round-trip on every query *and* once per escaped string parameter (`2x–4x` wire RTTs per SQL statement). On SQLite, `_sqlite_keep_open = false` reopened the `.db` file and re-parsed all 85 `sqlite_master` table/index definitions on every query (`30.7x` slower than reusing one handle per process).
  2. **Unconditional per-request schema initialization (`src/web.lua`, `src/document.lua`):** Every HTTP request executed `130` SQL statements (`18` DDL, `59` `information_schema` reads, and `42` write DML statements including `27` `REPLACE INTO entity_field`) before routing — even on `/theme-asset`, `/vendor`, and `/login` health checks. Those `42` writes per `GET` serialized concurrent SQLite readers behind the single WAL writer lock at **`4.4 req/s`**.
  3. **`N+1` query storms on Entity browse and Extensions (`src/entity.lua`, `src/ui.lua`):** Rendering `100` `sample` Entities issued **`1,539` SQL queries** (`3,074` TCP RTTs) across per-row multi-value fields, polymorphic `entity_ref` checks, and uncached foreign-key display labels, plus quadratic `..` HTML string concatenation.
  4. **Repeated pool-state DDL during Document search (`src/document.lua`, `src/knowledge.lua`):** `document.ensure_pool_state` ran `CREATE TABLE IF NOT EXISTS` and column inspection inside per-hit loops, turning one `GET /documents?q=...` into **`8,927` SQL queries** (`929` DDL statements, `17,850` TCP RTTs).

With those four bottlenecks fixed and bundled Lua modules precompiled to bytecode in `.rodata`, `daat` boots in **`5.6 ms`**, serves static theme/vendor routes with **`0` SQL queries (`6–8 ms`)**, serves `/login` in **`9.2 ms` (SQLite) / `27.9 ms` (MariaDB proxy)**, and renders `100`-row complex Entity tables in **`21.4 ms` (SQLite) / `95.4 ms` (MariaDB proxy)**.

---

## 2. Current Performance Architecture & Invariants

### 2.1 Precompiled `.rodata` Bytecode & Lazy Module Loading (`luam/lib/static`)
- At build time (`luam/lib/static/init.lua`), every bundled `.lua` module is compiled to Lua 5.1 bytecode via `string.dump` (retaining debug line information for full stack traces) and emitted into a constant C `.rodata` table (`lua_bundle_entries[]`).
- Instead of copying all `~2 MB` of bundled code onto the Lua heap at C `main()` startup via `lua_pushlstring`, `static/init.lua` registers a C searcher (`c_bundle_loader`) at `package.loaders[2]` that calls `luaL_loadbuffer` directly against `.rodata` only for modules actually `require`d during that invocation.

### 2.2 Per-Process Connection Lifecycle (`luam/lib/database_adapter.lua`, `src/main.lua`)
- **MariaDB:** `get_mariadb_connection` caches one live connection per `(host, port, user, database)` descriptor per OS process. `mysql_ping()` is skipped unless the cached handle has been idle for at least `MARIADB_PING_INTERVAL_SECS` (`5` seconds). `mariadb_query` and `mariadb_update` acquire the connection once per SQL execution (`format_mariadb_sql`) and pass that handle directly to `native.escape` for all bound string parameters; if an idle cached socket was dropped by the server or proxy, the adapter reconnects and retries once before surfacing an error.
- **SQLite (`sqlite_keep_open`):** `src/main.lua` enables `database_adapter.sqlite_keep_open(true)` across the lifetime of every CLI or CGI invocation and closes all cached handles cleanly in an exit `pcall` guard (`sqlite_close_all()`). Schema inspection (`luam/lib/sqlite_schema.lua`) and bound View execution (`src/view.lua`) share the same `acquire_sqlite_connection` / `release_sqlite_connection` cache so `sqlite_master` is parsed once per process.
- **POSIX `fcntl` WAL Lock Invariant (`luam/lib/paths.lua`):** Under POSIX advisory locking (`man 2 fcntl`), calling `open()` followed by `close()` on *any* file descriptor referring to an already-open SQLite `.db` inode immediately releases **all** `SHARED`/`EXCLUSIVE` advisory locks held by that process on that inode while leaving `.db-shm` mapped. If another short-lived CGI reader exits while the first process's lock has been stripped, SQLite's `sqlite3WalClose` observes zero lock holders and unlinks `.db-wal` and `.db-shm` out from under the running worker. Therefore, file-existence checks (`paths.file_exists`, called by `config.is_initialized`) **must** use `lfs.attributes(path, "mode") != nil` (`stat()`) and never `io.open` + `io.close` on a live database path.

### 2.3 Pre-DB Static Routing & Signature-Gated Schema Init (`src/web.lua`, `src/store.lua`)
- **Zero-DB static routes:** `cgi.handle_request` dispatches `/theme-asset` and `/vendor` immediately from the filesystem before initializing or querying the database (`0` SQL queries).
- **Idempotent schema signature gate:** `store.migrate` fast-paths in a single `system_state` read when already at `latest_schema_version()`. Built-in module `init_schema` hooks (`auth`, `ledger`, `document`, `knowledge`, `extension`, `agent`) are gated behind `web.builtin_schema_signature` in `system_state` alongside `schema.sync_all`'s `schema.sync_signature`. Steady-state read requests execute **`0` DDL statements and `0` write DML statements**, allowing concurrent SQLite WAL readers and MariaDB connections to run completely uncontended.

### 2.4 Request Memoization, Batched Entity Resolution & Linear HTML Rendering
- **Schema metadata memoization & bulk preload (`src/schema.lua`, `src/entity.lua`):** `schema.fields(db_path, entity_type)` and `schema.is_registered(db_path, entity_type)` cache results per `(db_key, entity_type)` in process memory, while `schema.preload_all_fields(db_path, entity_types)` hydrates every registered schema's `entity_field` rows in `1` query for `/data` and relation-diagram rendering. `entity.counts_by_type(db_path, entity_types)` caches active Entity counts in `system_state` (`entity.active_counts_cache`) keyed by `(MAX(event_id), types_sig)` — executing `0` `SELECT COUNT(*)` scans on steady-state and `update`-only hits, and recounting only modified Entity types via batched `UNION ALL` when `create`/`archive`/`unarchive` ledger events arrive.
- **Client-side graph layout persistence (`src/ui.lua`):** `/knowledge-graph` stores linked-node topology signatures and settled coordinates in `localStorage` (`platform-kg-layout-v2`), excluding auto-placed grid orphans so newly connected documents spawn beside their linked neighbors, cooling `simLoop` with `simAlpha` decay + eager checkpoints so dense clusters always converge and save, and skipping physics completely (`0` steps) on unchanged reloads.
- **Array `IN (...)` filters (`src/entity.lua`):** `entity.list` and Extension `ctx.query(entity_type, filters)` accept a non-empty array as any field filter value (e.g. `ctx.query("sample_state", {sample = sample_ids})`), emitting `WHERE sample IN (...)` instead of forcing Extensions into `N+1` loops.
- **Batched computed overrides & display labels (`src/entity.lua`, `src/ui.lua`, `luam/lib/html.lua`):**
  - `entity.apply_computed_field_overrides` batches multi-value join tables (`1` `SELECT ... WHERE parent_id IN (...)` per multi-field) and polymorphic references (`1` `SELECT ... FROM entity_ref WHERE from_type = ? AND from_id IN (...)` for the whole page).
  - `html.render_browse` prefetches all referenced target Entities across reference, multi-reference, and polymorphic columns (`prefetch_browse_display_labels`) in one `WHERE id IN (...)` query per target Entity type before rendering rows, assembles HTML via `table.concat` rather than repeated `..` concatenation, and escapes strings via single-pass lookup tables in `luam/lib/html.lua`.
- **Pool-state & co-retrieval gating (`src/document.lua`, `src/knowledge.lua`):** `document.ensure_pool_state` memoizes initialization per `db_path` in memory, and `knowledge.maybe_link_co_retrieved` prefetches existing active links in `1` query and skips per-pair history queries until `co_count >= CO_RETRIEVAL_LINK_THRESHOLD`.
- **HTTP response compression:** Deployment Apache configs (`dev/demo/Dockerfile`, `dev/demo/apache.conf`, and downstream LIMS containers) enable `mod_deflate` across `text/html`, `text/css`, `text/plain`, `application/json`, `application/javascript`, and `image/svg+xml`, shrinking `200–520 KB` browse, tree, graph, and editor responses by **80%–88%** on the wire.

---

## 3. Measured Benchmarks (Before vs. After)

### 3.1 Testbed & Workload
- **Dataset (85 SQL tables):** `34` custom Entity types + `5` built-in Document/tag types, `5,000` `sample` Entities (`4,999` polymorphic `entity_ref` rows, `7,500` `sample_process` rows, `5,000` `sample_equipment` rows), `10,000` `sample_state` rows, `1,000` `contamination_test` rows, `200` `experiment` Entities, `1,500` Documents, `1,500` packed `768`-dim embeddings, `3,000` aspect vectors, `2,000` `document_link`s, and a `20`-message `agent_session`.
- **Storage profiles:**
  1. **SQLite (WAL):** Local NVMe `.store/store.db`.
  2. **MariaDB `0ms`:** Local MariaDB `10.11` (`log_bin=ON`) over loopback.
  3. **MariaDB Proxy (`~1.5 ms` RTT):** `TCP_NODELAY` proxy adding Cloud SQL Auth Proxy-equivalent intra-region round-trip latency and counting exact wire round-trips.

### 3.2 Per-Route SQL Telemetry & Single-Request (`c = 1`) Latency

| Metric / Route | SQL Queries (Before -> After) | Write DML (Before -> After) | Wire TCP RTTs (Before -> After) | SQLite `p50` (Before -> After) | MariaDB `0ms` `p50` (Before -> After) | MariaDB Proxy `p50` (Before -> After) |
|---|---:|---:|---:|---:|---:|---:|
| **`daat --help` Binary Boot** | `0` -> `0` | `0` -> `0` | `0` -> `0` | `18.6 ms` -> **`5.6 ms` (`3.3x`)** | — | — |
| `GET /theme-asset?name=logo.png` | `130` -> **`0`** | `42` -> **`0`** | `256` -> **`0`** | `690.8 ms` -> **`6.0 ms` (`115x`)** | `85.6 ms` -> **`6.1 ms` (`14.0x`)** | `547.9 ms` -> **`6.0 ms` (`91.3x`)** |
| `GET /vendor` (Toast UI bundle) | `130` -> **`0`** | `42` -> **`0`** | `256` -> **`0`** | `681.6 ms` -> **`7.8 ms` (`87.4x`)** | `102.8 ms` -> **`7.7 ms` (`13.4x`)** | `542.2 ms` -> **`7.7 ms` (`70.4x`)** |
| `GET /login` (healthcheck) | `131` -> **`13`** | `42` -> **`0`** | `258` -> **`13`** | `626.4 ms` -> **`9.2 ms` (`68.1x`)** | `88.1 ms` -> **`10.2 ms` (`8.6x`)** | `529.5 ms` -> **`27.9 ms` (`19.0x`)** |
| `GET /` (home dashboard) | `133` -> **`15`** | `42` -> **`0`** | `262` -> **`15`** | `717.9 ms` -> **`10.0 ms` (`71.8x`)** | `92.5 ms` -> **`11.2 ms` (`8.3x`)** | `540.4 ms` -> **`37.8 ms` (`14.3x`)** |
| `GET /view` (bound SQL View) | `138` -> **`20`** | `42` -> **`0`** | `272` -> **`20`** | `428.7 ms` -> **`11.6 ms` (`37.0x`)** | `55.8 ms` -> **`13.3 ms` (`4.2x`)** | `397.4 ms` -> **`38.4 ms` (`10.3x`)** |
| `GET /documents` (1,500-Doc tree) | `134` -> **`16`** | `42` -> **`0`** | `264` -> **`16`** | `419.8 ms` -> **`27.0 ms` (`15.5x`)** | `70.7 ms` -> **`29.4 ms` (`2.4x`)** | `413.8 ms` -> **`48.7 ms` (`8.5x`)** |
| `GET /api/chat-widget-history` | `138` -> **`20`** | `42` -> **`0`** | `272` -> **`20`** | `486.6 ms` -> **`23.7 ms` (`20.5x`)** | `68.4 ms` -> **`25.2 ms` (`2.7x`)** | `435.6 ms` -> **`50.1 ms` (`8.7x`)** |
| `GET /knowledge-graph-data` | `140` -> **`20`** | `42` -> **`0`** | `276` -> **`20`** | `489.0 ms` -> **`39.6 ms` (`12.3x`)** | `85.5 ms` -> **`40.7 ms` (`2.1x`)** | `445.8 ms` -> **`72.2 ms` (`6.2x`)** |
| `GET /document?entity_id=1` | `221` -> **`94`** | `42` -> **`0`** | `438` -> **`94`** | `555.2 ms` -> **`18.7 ms` (`29.7x`)** | `72.5 ms` -> **`41.9 ms` (`1.7x`)** | `642.6 ms` -> **`145.4 ms` (`4.4x`)** |
| `GET /detail?type=experiment&id=1` | `248` -> **`72`** | `42` -> **`0`** | `492` -> **`72`** | `791.6 ms` -> **`13.5 ms` (`58.6x`)** | `129.2 ms` -> **`20.5 ms` (`6.3x`)** | `985.1 ms` -> **`110.7 ms` (`8.9x`)** |
| `GET /data` (39 Entity counts) | `295` -> **`17`** | `42` -> **`0`** | `586` -> **`17`** | `956.9 ms` -> **`14.2 ms` (`67.4x`)** | `203.2 ms` -> **`15.8 ms` (`12.9x`)** | `1,174.4 ms` -> **`36.5 ms` (`32.2x`)** |
| `GET /browse?type=sample_state` | `640` -> **`28`** | `42` -> **`0`** | `1,276` -> **`28`** | `1,378.6 ms` -> **`16.4 ms` (`84.1x`)** | `237.4 ms` -> **`18.6 ms` (`12.8x`)** | `2,368.9 ms` -> **`53.7 ms` (`44.1x`)** |
| `GET /ext/experiment_view` (50 samples) | `1,386` -> **`42`** | `42` -> **`0`** | `2,768` -> **`42`** | `2,598.7 ms` -> **`16.3 ms` (`159x`)** | `914.9 ms` -> **`25.6 ms` (`35.7x`)** | `5,737.5 ms` -> **`83.2 ms` (`69.0x`)** |
| `GET /browse?type=sample` (100 rows) | `1,539` -> **`57`** | `42` -> **`0`** | `3,074` -> **`57`** | `2,419.0 ms` -> **`21.4 ms` (`113x`)** | `477.7 ms` -> **`26.2 ms` (`18.2x`)** | `5,576.2 ms` -> **`95.4 ms` (`58.5x`)** |
| `GET /documents?q=...` (`co_count < 3`) | `8,927` -> **`561`** | `299` -> **`253`** | `17,850` -> **`561`** | `11,433.1 ms` -> **`791.0 ms` (`14.5x`)** | `2,616.0 ms` -> **`657.3 ms` (`4.0x`)** | `19,633.0 ms` -> **`1,301.3 ms` (`15.1x`)** |
| `GET /documents?q=...` (`co_count >= 3`) | `8,927` -> **`1,987`** | `299` -> **`201`** | `17,850` -> **`1,987`** | `11,433.1 ms` -> **`511.2 ms` (`22.4x`)** | `2,616.0 ms` -> **`459.5 ms` (`5.7x`)** | `19,633.0 ms` -> **`3,626.1 ms` (`5.4x`)** |

### 3.3 Concurrent CGI Throughput (`c = 16` Workers) & CLI Batch Ingestion

| Workload | Backend | Before | After | Improvement |
|---|---|---|---|---|
| `GET /login` (`c = 16`) | SQLite | `4.27 req/s` (`p50 = 2,978 ms`) | **`478.87 req/s`** (`p50 = 25.7 ms`) | **`112.1x` throughput** |
| `GET /login` (`c = 16`) | MariaDB `0ms` | `72.29 req/s` (`p50 = 206 ms`) | **`185.13 req/s`** (`p50 = 62.4 ms`) | **`2.56x` throughput** |
| `GET /login` (`c = 16`) | MariaDB Proxy | `34.79 req/s` (`p50 = 450 ms`) | **`321.15 req/s`** (`p50 = 41.0 ms`) | **`9.23x` throughput** |
| `GET /browse?type=sample` (`c = 16`) | SQLite | `1.60 req/s` (`p50 = 8,507 ms`) | **`272.90 req/s`** (`p50 = 47.3 ms`) | **`170.6x` throughput** |
| `GET /browse?type=sample` (`c = 16`) | MariaDB `0ms` | `10.53 req/s` (`p50 = 1,495 ms`) | **`42.88 req/s`** (`p50 = 284.8 ms`) | **`4.07x` throughput** |
| `GET /browse?type=sample` (`c = 16`) | MariaDB Proxy | `1.57 req/s` (`c = 8`, `p50 = 5,082 ms`) | **`128.36 req/s`** (`p50 = 110.3 ms`) | **`~81.8x` throughput** |
| `GET /ext/experiment_view` (`c = 16`) | SQLite / Proxy | `~1.5 req/s` (`>5,700 ms`) | **`362.10 req/s`** (`35.5 ms`) / **`145.73 req/s`** (`103.2 ms`) | **`~95x–240x` throughput** |
| CLI `entity create-json` (`50` rows) | SQLite | `668.0 ms` (`13.36 ms/row`) | **`18.0 ms`** (`0.36 ms/row`) | **`37.1x` faster** |
| CLI `entity create-json` (`50` rows) | MariaDB `0ms` | `226.1 ms` (`4.52 ms/row`) | **`58.2 ms`** (`1.16 ms/row`) | **`3.88x` faster** |
| CLI `entity create-json` (`50` rows) | MariaDB Proxy | `1,637.5 ms` (`32.75 ms/row`) | **`562.5 ms`** (`11.25 ms/row`) | **`2.91x` faster** |

---

## 4. Saved Next-Steps Options (Future Optimization Roadmap)

The options below are scoped and ranked by measured impact so any future scaling work can pick up directly from concrete designs rather than re-profiling from scratch.

### Option 1: Sub-`60 ms` Semantic & Aspect Search (`GET /documents?q=...`)

Search improved by `5.4x–22.4x` (`19.63 s` -> `0.51–3.63 s`), and its remaining cost comes from two well-isolated sources:

1. **Decouple retrieval heat/curation writes from interactive `GET /documents?q=...` (`src/knowledge.lua`):**
   - Today, `knowledge.search_and_log` synchronously runs `record_retrieval_hit`, `document.reinforce_pool_heat`, `spread_activation` heat updates, and `knowledge.review_retrieval` (`maybe_link_co_retrieved` + tier-promotion checks) before returning HTML to the browser — accounting for `201–253` write DML statements and `540–1,960` SQL queries on a read-facing search request.
   - **Design:** Persist a single lightweight `knowledge_retrieval_event` row (query text + ranked Document IDs) during `GET /documents?q=...`, and move heat reinforcement, spreading-activation updates, and `review_retrieval` co-retrieval link adjudication into the existing `agent_background_task` worker queue (matching how detached curation already runs). Interactive search drops from `561–1,987` SQL queries to `~8–12` read queries (`< 60 ms` over a database proxy), and concurrent searchers no longer contend on write locks.
2. **Native C `float32` vector dot-product helper in `luam/lib` (`lib/vec/lvec.c`):**
   - `document.unpack_vector` + pure-Lua `dot_product` (`src/document.lua`) is already `43x` faster than decoding `vector_json`, but scanning `8,000` `768`-dim vectors (`2,000` Documents x `4` aspects) still unpacks **`6.14M` Lua numbers (`+94.6 MB` transient Lua heap, `248.7 ms` CPU)** per search.
   - **Design:** Add a ~60-line C module in `luam/lib` (`vec.dot_packed_f32(a, b)` / `vec.max_aspect_scores_f32(query_blob, blobs_array)`) compiled into `static/init.lua`'s preload table. Operating directly on `lua_tolstring` little-endian `float` buffers with `-O3` auto-vectorization reduces `8,000 x 768`-dim scoring from **`249 ms` + `94.6 MB` RAM to `< 2 ms` + `0 MB` RAM** while staying portable across SQLite and MariaDB (without requiring MariaDB 11.7+ `VECTOR INDEX`).

### Option 2: Web-Server Static Assets, Cached Chat Markdown & Batched `/data` Counts

1. **Direct Apache static serving for `/vendor`:**
   - `/vendor` already skips DB initialization (`~7.7 ms`), but serving `Alias /vendor /app/vnd` directly from Apache ahead of `ScriptAliasMatch` eliminates even the CGI `fork + exec` for large vendored JS/CSS bundles (`< 1 ms` with native `ETag` / `If-None-Match` 304 caching).
2. **Cache rendered Markdown on `agent_message` rows (`src/agent.lua`, `src/web.lua`):**
   - Polling `/api/chat-widget-history` on a 20-message session spawns `20` `cmark-gfm` subprocesses (`~36.8 ms` total, `1.84 ms` per message via `/bin/sh` + temp files in `luam/lib/external_tool.lua`). Storing `rendered_html` when an `agent_message` is written (or batching unrendered messages into one `cmark-gfm` pipe) removes subprocess churn during active chat polling.
3. **Batch validation in `entity.create_batch` (`src/entity.lua`):**
   - `GET /data` already batches field metadata (`schema.preload_all_fields`) and caches active Entity counts against `MAX(event_id)` in `system_state` (`entity.counts_by_type`, recounting only dirty types via `UNION ALL`).
   - In `entity.create_batch`, preloading `schema.fields`, Extension hooks, and foreign-key existence sets once per batch (instead of per row) will cut MariaDB proxy CLI batch ingestion from `11.2 ms/row` to `< 2 ms/row`.

### Option 3: Persistent Worker Mode (`#57`) via `luam/lib/socket`

With CGI boot at `5.6 ms`, SQLite `GET /login` at `9.2 ms` (`479 req/s` at `c = 16`), and MariaDB proxy `/browse` at `95.4 ms` (`128 req/s` at `c = 16`), CGI-per-request is no longer a bottleneck at normal team/lab concurrency. Persistent worker mode (`#57`) remains an explicit, already-scoped option if deployment scale later requires either:
- Eliminating the per-request MariaDB TCP + auth + `SET SESSION sql_mode` connection setup (`~4–6 ms` over a local Cloud SQL Auth Proxy), or
- Sustaining `> 200–300 req/s` per host without process-spawn overhead.

**Scoped design when `#57` is warranted:**
1. **Transport (`luam/lib/cgi.lua` + `luam/lib/socket`):** `luam/lib` already ships `socket/core.so`. Add an opt-in pre-fork HTTP/1.1 or SCGI accept loop (`daat serve --listen 127.0.0.1:8001 --workers N --max-requests 1000`) that populates the per-request CGI environment table and invokes `cgi.handle_request`, fronted by Apache `mod_proxy_http` (`ProxyPass / http://127.0.0.1:8001/`).
2. **State-hygiene checklist before enabling persistent workers:**
   - Reset per-request module state at the start of every request: `response_nonce` in `src/web.lua` and any request-scoped display-label cache.
   - Gate `PLATFORM_CONFIG_CACHE` and `PLATFORM_SETTINGS_CACHE` in `src/config.lua` on file `mtime` (`lfs.attributes(..., "modification")`) so edits to `platform.lua` or `theme.lua` take effect without restarting workers.
   - Invalidate in-memory `schema.fields` / `schema.is_registered` caches across workers by checking `schema.sync_signature` in `system_state` (1 point read per request, which `schema.sync_all` already performs).
   - Run `collectgarbage("step")` after each response and recycle each worker after `max_requests = 1000` (`MaxRequestsPerChild`) to guarantee bounded memory while keeping MariaDB and SQLite handles warm across requests.
