# platform-wip

A traceable, extensible data-entry and entity-keeping platform:
define your own entity types, get full audit history and validated
data entry for free, and extend behavior for your own domain without
touching the core. It's a single, self-contained web application --
its own login/sessions and its own rendering, no external identity
system or separate version-control layer to run alongside it.

**Working name only.** `platform` (the binary name) and this
directory's name are both placeholders pending a real project name.

## Status

- **Entity types as code, full event history, ad hoc querying,
  extensible behavior** -- done. See `doc/architecture.md`/
  `doc/schema.md`/`doc/extensibility.md`.
- **Nothing is ever deleted, only archived** -- done. See
  "Traceability" below.
- **Accounts, sessions, and permissions** -- done. See "Auth" below.
- **Hosting under a real web server** -- verified working as-is (no
  application changes needed); a minimal Admin user-management page
  (`/admin-users`) ships alongside the CLI for admins who'd rather not
  shell in.
- **Storage** -- already a single file; nothing to consolidate.
- **Documents** (a built-in entity type: a real tree, not
  a name-is-identity wiki page) -- done. See "Documents" below.
- **Chat/assistant** (conversation history, context-window compaction,
  tool use with a web-native approval gate, semantic search) -- done.
  See "Chat" below.

## Building

Written in [Luam](https://github.com/BenSiv/luam); requires a sibling
`luam` checkout, already built (`obj/liblua.a` present). By default
`bld/build.sh` looks for it at `../luam`; override with the `LUAM_DIR`
env var if yours lives elsewhere.

Also requires `cmark` on `PATH` **at runtime** (`apt install cmark` /
`brew install cmark`) -- unlike everything else here, it isn't compiled
into the binary; Document rendering shells out to it.

Chat/assistant features additionally need `curl` and `gcloud` on `PATH`
at runtime (the built-in provider calls Google Vertex AI's REST API,
authenticated via `gcloud auth application-default login`), plus a
`vertex_project` field in `platform.lua` naming a real GCP project --
there's no default, since that's always a real, potentially billed
deployment choice, never something to hardcode. See "Chat" below.

```sh
./bld/build.sh          # -> bin/platform
./bld/build.sh -v       # same, with full compiler output (default logs to a temp file)
```

## Testing

Requires `bats` on PATH (`apt install bats` / `brew install
bats-core`).

```sh
./bld/test.sh
```

Runs the unit tests (`tst/unit/*.lua`, standalone scripts that exit
non-zero on failure) and the integration tests (`tst/integration/*.bats`,
which build and exercise the real binary end to end, including real
web-request-shaped input -- see `tst/integration/test_helper.bash`).

## CLI

```
platform init                                   # create .store/ (the database) here
platform schema add <file.lua>                   # register/update an entity type
platform schema list
platform entity create <type> field=value ...
platform entity list <type> [--include-archived]
platform entity show <type> <id>
platform entity update <type> <id> field=value ...
platform entity archive <type> <id>              # never a delete -- see below
platform entity unarchive <type> <id>
platform ledger show|history <entity_id>
platform extension list|show|approve|revoke|run-pending <name>
platform view list|show|approve|revoke <name>
platform user add <login> <password> [cap]
platform user passwd <login> <new_password>
platform user capabilities <login> <cap_string>
platform user list [--include-archived]
platform user archive|unarchive <login>
platform document reindex-embeddings [entity_id]
```

Running with no arguments uses this CLI dispatch; running under a real
(or test-simulated) web request runs the request-handling path instead
-- see `src/main.lua`.

Entity types need an explicit `schema add` to register (that's what
generates/migrates the type's own table). Saved queries and behavior
extensions are just files dropped into `views/<name>.lua` /
`extensions/<name>/{manifest,main}.lua` and picked up automatically --
`approve`/`revoke` is the only CLI step they need before they're live.

## Auth

`platform user add <login> <password> [cap]` creates a login. `/login`
and `/logout` are the only routes reachable without an active session;
every other route requires one. Permissions are re-checked from the
account's current record on every request rather than trusted from
anything the session itself carries, so changing or revoking someone's
permissions (or archiving their account) takes effect on their very
next request, not only once their existing session expires. See
`doc/architecture.md`'s "Auth" section for the full session/CSRF
design, and `src/auth.lua` itself.

## Traceability

Nothing is ever deleted. Every entity carries a nullable "archived"
timestamp; archiving/unarchiving are additive history entries, never a
removal. Listing/counting entities excludes archived ones by default
(an opt-in flag brings them back); looking up an entity directly, or its
full history, always works regardless of archive state. The same
convention applies to accounts.

## Documents

A built-in entity type (`src/document.lua`) -- a
real parent-child tree (a document's identity is its id, not its title, so
renaming or moving a document is a plain field edit, never a collision
risk), Markdown content rendered via `cmark`, and `[[title]]` /
`[[folder/title]]` inline links between documents that show up as
backlinks on the document they point to. `/documents` lists the tree,
`/document?entity_id=<id>` views one document, `/document-edit` creates or
edits one (a plain textarea with a live preview). A link to a document
that doesn't exist yet renders as a plain, clearly-marked placeholder
rather than a broken link.

## Chat

A built-in assistant (`src/agent.lua`) at `/chat`: real per-user
conversation sessions with full history (nothing ever deleted -- see
"Traceability"), automatic context-window compaction once a
conversation gets long (the oldest turns get summarized into one new
message and marked out-of-context, dimmed but still visible, never
removed), and a small, explicit set of built-in tools (search documents,
create a document, update a document) the assistant can call mid-conversation.

Every tool call is attributed to the real logged-in user, never a
separate "agent" identity -- creating or updating a document through chat
shows up in that document's own audit history exactly like a direct edit,
just tagged with which chat session it came from. Read-only tool calls
(search) run immediately; anything that changes data (create, update)
pauses as a pending action and waits for an explicit Approve/Deny in
the chat UI before running at all -- there's no way for the assistant
to change data without a human confirming it first.

Document search blends keyword matching with semantic similarity (an
embedding comparison) when a document has been explicitly indexed via
`platform document reindex-embeddings` -- indexing is never an
automatic side effect of saving a document, since it costs a real API
call per document.

The LLM backend is pluggable (`src/agent_provider*.lua`, selected by
`platform.lua`'s `agent_provider` field) -- ships with a real Google
Vertex AI backend and a deterministic backend used by this project's
own test suite so routine test runs don't repeatedly hit a paid API.

## Docs

- `doc/architecture.md` -- the entity-history model, how entity types
  and extensions run sandboxed, and the auth/session design.
- `doc/schema.md` -- defining entity types: field types, sandboxed
  loading, what a definition generates.
- `doc/extensibility.md` -- the extension system: manifest format,
  event hooks, capability sandboxing.
- `doc/glossary.md` -- terms this codebase should use consistently
  (Document vs page/Notebook, Entity vs record, Knowledge Pool tiers,
  capability names).
