# Contributing to daat

This is the entry point for a new external contributor to the open-source `daat` project. It assumes no access to, and no need to know about, the maintainer's private infrastructure -- a couple of the other files in this directory mention that in passing (see "Docs that mix in private deployment details" below), but nothing about building, testing, or extending this project depends on it.

This doc is this project's contribution guide.

## What this is

`daat` is a single, self-contained web application written in [Luam](https://github.com/BenSiv/luam) and compiled to one static binary: its own login/sessions, its own HTML rendering, its own SQL storage. Its core piece is the **Knowledge Pool**: Documents, chat conversations, and the agent's own reasoning all sit in one shared pool that tiers, links, and distills itself automatically as it's actually retrieved and edited -- no curator, no scheduled job (see `architecture.md`'s "Knowledge pool" section, and the glossary's Knowledge Pool entry). A built-in, pluggable LLM-backed chat assistant (its own small approved tool registry, a human approval gate on anything that changes data) is what actually drives real usage of that pool.

It also ships an extensible entity-tracking layer: an **entity type is data, not code** -- you define a new kind of record (a sample, a task, whatever your domain needs) as a small declarative Lua file, and it generates storage, validation, a full audit trail, and a queryable table for it automatically, with nothing ever hard-deleted -- only archived. This general-purpose data-entry/LIMS-style layer is functional but earlier-stage and not the project's current focus.

## Quick start

### Option A: containerized (recommended)

`../dev/` in this repo has a minimal [Podman](https://podman.io/) dev environment -- one command gets you a shell with every build/test dependency already installed, no manual `apt install` needed:

```sh
cd dev && ./deploy.sh
```

`dev/Containerfile` installs the C toolchain, `cmark-gfm`, `bats`, and a built sibling `luam` checkout (see "Option B: manual" below for what each is for); `dev/deploy.sh` builds that image and drops you into a shell with the repo root bind-mounted at `/root/daat` -- edits you make on the host are what actually gets built and tested inside the container. The container is removed on exit (`--rm`); nothing but the image persists between runs. Re-run `./deploy.sh` after changing `Containerfile` to rebuild it.

### Option B: manual

**Required** to build, run, and run most tests:

- A sibling `luam` checkout, built (`../luam` with `obj/liblua.a` present) -- `bld/build.sh` looks there by default; override with the `LUAM_DIR` env var.
- A C toolchain (`cc`/`make`) and the dev headers `bld/build.sh` compiles against: `libsqlite3-dev`, `libreadline-dev`, `libssl-dev`, `libcrypt-dev`.
- `cmark-gfm` on `PATH` **at runtime** (`apt install cmark-gfm` / `brew install cmark-gfm`) -- Document rendering shells out to it; it is not compiled in. Not plain `cmark` -- a separate package/binary (GitHub's own fork, needed for the table/strikethrough/autolink extensions `document.lua` renders with); installing the wrong one is a real, previously-hit failure mode (missing `cmark-gfm` produces empty rendered content, not an error at install time).
- `bats` on `PATH` (`apt install bats` / `brew install bats-core`) -- required to run `tst/integration/*.bats`.
- SQLite itself needs no setup; it's the default storage backend.

**Optional** -- you do not need any of this to build, test, or run the app or its chat UI, because tests default to a deterministic stub LLM provider (see "Testing conventions"):

- `curl` and `gcloud` (`gcloud auth application-default login` plus a `vertex_project` in `platform.lua`) -- only if you want to actually exercise the real Google Vertex AI chat backend.
- `libmariadb-dev` -- only if you want the optional MariaDB storage backend compiled in; without it `bld/build.sh` silently builds a SQLite-only binary. `tst/integration/mariadb_backend.bats` skips itself (doesn't fail) when no real MariaDB server is configured.

### Build & test

```sh
./bld/build.sh          # -> bin/daat
./bld/build.sh -v       # same, with full compiler output
./bld/test.sh           # builds, then runs tst/unit/*.lua and tst/integration/*.bats
```

## Repo layout

| Path | Purpose |
|---|---|
| `bin/` | Build output (`bin/daat`) -- gitignored, never committed |
| `bld/` | `build.sh` (compiles everything into one binary), `test.sh` |
| `doc/` | Architecture/design docs -- see "Where to go next" below |
| `dev/` | Minimal Podman dev environment (see "Quick start" above) |
| `src/` | All Lua source; every file here gets bundled into the one binary |
| `tst/unit/` | Plain Luam scripts, no DB, run directly by the interpreter |
| `tst/integration/` | `.bats` tests against the real compiled binary, real CGI env vars |
| `vnd/` | Vendored, checked-in frontend JS (Toast UI Editor, Zebra Browser Print) -- no CDN, no JS build step |

`src/*.lua` at a glance -- each module's top-of-file comment has the full story:

- `main.lua` -- CLI/CGI entry point
- `cgi.lua` -- route dispatch, capability checks
- `entity.lua` / `ledger.lua` / `schema.lua` -- the entity/history/schema model
- `auth.lua` -- login, sessions, CSRF
- `document.lua` -- the Document entity type and its tree/links
- `knowledge.lua` -- the knowledge pool (tiering/heat on documents)
- `agent.lua` + `agent_provider*.lua` -- the chat/assistant subsystem and its pluggable LLM backends
- `extension.lua` / `view.lua` -- the drop-in extensibility mechanisms (see below)
- `sandbox.lua` -- the shared capability-scoped execution environment used by schema loading, views, and extensions
- `html.lua` / `render.lua` / `template.lua` -- rendering
- `db.lua` / `config.lua` / `init.lua` / `multipart.lua` / `label.lua` -- storage adapter, deployment config, `daat init`, CGI form parsing, ZPL labels

## Architecture concepts to know before contributing

- **Entity/schema/ledger model** -- every change is recorded first in an append-only event log; a typed table per entity type is projected from that log for fast querying. The log is the source of truth. See `architecture.md` ("History as the source of truth") and `schema.md`.
- **Traceability** -- archiving/unarchiving are additive log entries, never a row removal. Listing excludes archived rows by default; a direct lookup or full history always works regardless of archive state. Same convention for accounts.
- **Sandboxing** -- schema definitions, extension hooks, and views are all untrusted source loaded into a restricted environment exposing only the capabilities that role (or that extension's approved manifest) actually needs. One mechanism, `src/sandbox.lua`, covers all three. See `architecture.md` ("Sandboxed extensibility") and `extensibility.md`.
- **Auth** -- every route but `/login`/`/logout` requires a session; permissions are re-read from the account's current row on *every* request, never trusted from the session itself, so a permission change or account archive takes effect on the very next request. See `architecture.md` ("Auth") and `api.md`.
- **Chat/agent** -- per-user DB-backed sessions, a small explicit tool registry, a pluggable LLM backend behind a neutral protocol (`agent-protocol.md`), and a hard human-approval gate before any tool call that changes data can run.
- **Glossary discipline** -- `glossary.md` is treated as authoritative for terminology (Document, not page/Notebook; Entity, not record; View vs. Extension vs. Hook kept deliberately distinct). Check it before introducing new UI copy, doc prose, or tool descriptions -- this is a hard rule in this codebase, not a suggestion.

## Extending the platform

Three drop-in mechanisms, none requiring changes to `src/`:

- **Entity types** -- a declarative file under `schemas/<name>.lua` (name + typed field declarations), registered with `daat schema add schemas/<name>.lua`. Full details, including every field type: `schema.md`.
- **Views** -- a named, `SELECT`-only saved query, requiring explicit admin approval keyed to the exact SQL text (editing it invalidates approval). Exposed to humans at `/view` and to the chat agent as `view.list`/`view.run`.
- **Extensions** -- `extensions/<name>/{manifest.lua, main.lua}`. The manifest declares which entity events it hooks and which capabilities (`read`, `write`, `net`) it needs; a capability change invalidates prior approval automatically. Before-hooks run synchronously and can block a save; after-hooks are queued and can never block or undo. Full details: `extensibility.md`.

## Testing conventions

- `tst/unit/*.lua` are plain Luam scripts (`require` the module under test, a local `check(condition, message)` + failure counter, no DB, no CGI) run directly by the interpreter.
- `tst/integration/*.bats` exercise the real compiled `bin/daat` binary with real CGI environment variables end to end. `tst/integration/test_helper.bash` provides the shared harness: `setup_test_env`/`cleanup_test_env` (a fresh scratch dir per test), `write_platform_config`, `login_test_user`, and CGI-call helpers (`raw_get`, `raw_post`, `run_cgi`, `run_cgi_admin`, etc).
- **You will never need real LLM credentials to run the test suite.** `write_platform_config` defaults every test's `platform.lua` to `agent_provider = "test"`, which selects `src/agent_provider_test.lua` -- a deterministic stub scripted via the `AGENT_TEST_RESPONSES` env var (canned JSON responses matching `agent-protocol.md`'s shape). It lives in `src/` rather than `tst/` specifically so it gets bundled into the same binary the tests run against -- tests exercise the real production binary, never a separate test build.

## Coding conventions

- Luam has no `local` keyword -- bare assignment scopes to the enclosing block automatically. Every file in `src/` relies on this; don't reach for `local` out of habit if you're used to standard Lua.
- Comments in this codebase are dense, first-person engineering-log prose (rationale, rejected alternatives, explicit tradeoffs), not terse conventional comments -- match the existing style in a file rather than switching it to something terser.

## Docs that mix in private deployment details

Two other files in this directory are written for the maintainer's own production hosting and contain some private infrastructure specifics (GCP project/instance names, Terraform paths, private-repo paths) mixed in with genuinely general content:

- `data-durability.md` -- the SQLite-durability reasoning is general and useful; skip the specific Terraform file paths and GCP instance names it references.
- `mariadb-migration.md` -- the MariaDB-portability/dialect content (what changes between SQLite and MariaDB, why) is general and useful; skip the specific Cloud SQL instance names, container names, and private-repo paths it references partway through.

Everything else in `doc/` (`architecture.md`, `schema.md`, `extensibility.md`, `glossary.md`, `api.md`, `agent-protocol.md`, `heat-decay-redesign.md`) is fully general -- no private context needed.

## Where to go next

- `architecture.md` -- the full entity-history model, sandboxing, and auth/session design (the big one -- start here for depth).
- `schema.md` -- defining entity types.
- `extensibility.md` -- the extension system in full.
- `api.md` -- the HTTP API surface.
- `agent-protocol.md` -- the LLM-provider protocol every `agent_provider_*.lua` backend implements.
- `glossary.md` -- terminology, keep it open while writing docs or UI copy.
- `../README.md` -- project status, CLI reference, build/test basics.
