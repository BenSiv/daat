# DAAT

A self-maintaining knowledge base with a built-in AI agent: Documents, chat conversations, and the agent's own reasoning all sit in one shared pool that tiers, links, and distills itself automatically as it's actually retrieved and edited -- no curator, no scheduled job, no separate note-taking system to keep in sync. It also ships an extensible entity-tracking layer (define your own record types, get full audit history for free) for general data-entry/LIMS-style use cases -- functional, but earlier-stage and not the project's current focus. It's a single, self-contained web application -- its own login/sessions and its own rendering, no external identity system or separate version-control layer to run alongside it.

## Status

- **Knowledge Pool: usage-driven tiering, linking, and distillation** -- done. A document advances through four maturity tiers (Raw Intake -> Curated Draft -> Developed Reference -> Atomic Record) purely by being edited into something more developed -- never by being read or by time passing. Heat (what makes something surface near the top) is a fixed budget shared across the whole pool, not a wall-clock decay, so what's actually useful stays visible with no manual pruning pass. See "Knowledge Pool" below and `doc/architecture.md`'s own section.
- **Chat/assistant with full provenance** -- conversation history, context-window compaction, tool use with a web-native approval gate, and the exact prompt/token usage of every real model call persisted for audit -- done. See "Chat" below.
- **Reactive distillation and agent-judged co-retrieval linking** -- both triggered inline by real usage, never a scheduled scan of the pool -- done. See "Knowledge Pool" below.
- **Whole chat sessions are themselves documents** -- every conversation the agent has syncs into a real, searchable document that goes through the same tiering pipeline as anything else -- done.
- **Entity types as code, full event history, ad hoc querying, extensible behavior** -- functional, but this general-purpose data-entry/LIMS-style layer is earlier-stage and not where current effort is focused. See `doc/architecture.md`/`doc/schema.md`/`doc/extensibility.md`.
- **Nothing is ever deleted, only archived** -- done. See "Traceability" below.
- **Accounts, sessions, and permissions** -- done. See "Auth" below.
- **Hosting under a real web server** -- verified working as-is (no application changes needed); a minimal Admin user-management page (`/admin-users`) ships alongside the CLI for admins who'd rather not shell in.
- **Storage** -- already a single file; nothing to consolidate.

## Building

Written in [Luam](https://github.com/BenSiv/luam); requires a sibling `luam` checkout, already built (`obj/liblua.a` present). By default `bld/build.sh` looks for it at `../luam`; override with the `LUAM_DIR` env var if yours lives elsewhere.

Also requires `cmark-gfm` on `PATH` **at runtime** (`apt install cmark-gfm` / `brew install cmark-gfm`, not plain `cmark` -- a separate package/binary) -- unlike everything else here, it isn't compiled into the binary; Document rendering shells out to it.

Chat/assistant features additionally need `curl` and `gcloud` on `PATH` at runtime (the built-in provider calls Google Vertex AI's REST API, authenticated via `gcloud auth application-default login`), plus a `vertex_project` field in `platform.lua` naming a real GCP project -- there's no default, since that's always a real, potentially billed deployment choice, never something to hardcode. See "Chat" below.

```sh
./bld/build.sh          # -> bin/daat
./bld/build.sh -v       # same, with full compiler output (default logs to a temp file)
```

## Testing

Requires `bats` on PATH (`apt install bats` / `brew install bats-core`).

```sh
./bld/test.sh
```

Runs the unit tests (`tst/unit/*.lua`, standalone scripts that exit non-zero on failure) and the integration tests (`tst/integration/*.bats`, which build and exercise the real binary end to end, including real web-request-shaped input -- see `tst/integration/test_helper.bash`).

## CLI

```
daat init                                   # create .store/ (the database) here
daat schema add <file.lua>                   # register/update an entity type
daat schema list
daat entity create <type> field=value ...
daat entity list <type> [--include-archived]
daat entity show <type> <id>
daat entity update <type> <id> field=value ...
daat entity archive <type> <id>              # never a delete -- see below
daat entity unarchive <type> <id>
daat ledger show|history <entity_id>
daat extension list|show|approve|revoke|run-pending <name>
daat view list|show|approve|revoke <name>
daat user add <login> <password> [cap]
daat user passwd <login> <new_password>
daat user capabilities <login> <cap_string>
daat user list [--include-archived]
daat user archive|unarchive <login>
daat document reindex-embeddings [entity_id]
```

Running with no arguments uses this CLI dispatch; running under a real (or test-simulated) web request runs the request-handling path instead -- see `src/main.lua`.

Entity types need an explicit `schema add` to register (that's what generates/migrates the type's own table). Saved queries and behavior extensions are just files dropped into `views/<name>.lua` / `extensions/<name>/{manifest,main}.lua` and picked up automatically -- `approve`/`revoke` is the only CLI step they need before they're live.

## Auth

`daat user add <login> <password> [cap]` creates a login. `/login` and `/logout` are the only routes reachable without an active session; every other route requires one. Permissions are re-checked from the account's current record on every request rather than trusted from anything the session itself carries, so changing or revoking someone's permissions (or archiving their account) takes effect on their very next request, not only once their existing session expires. See `doc/architecture.md`'s "Auth" section for the full session/CSRF design, and `src/auth.lua` itself.

## Traceability

Nothing is ever deleted. Every entity carries a nullable "archived" timestamp; archiving/unarchiving are additive history entries, never a removal. Listing/counting entities excludes archived ones by default (an opt-in flag brings them back); looking up an entity directly, or its full history, always works regardless of archive state. The same convention applies to accounts.

## Documents

A built-in entity type (`src/document.lua`) -- a real parent-child tree (a document's identity is its id, not its title, so renaming or moving a document is a plain field edit, never a collision risk), Markdown content rendered via `cmark-gfm`, and `[[title]]` / `[[folder/title]]` inline links between documents that show up as backlinks on the document they point to. `/documents` lists the tree, `/document?entity_id=<id>` views one document, `/document-edit` creates or edits one (a plain textarea with a live preview). A link to a document that doesn't exist yet renders as a plain, clearly-marked placeholder rather than a broken link.

## Chat

A built-in assistant (`src/agent.lua`) at `/chat`: real per-user conversation sessions with full history (nothing ever deleted -- see "Traceability"), automatic context-window compaction once a conversation gets long (the oldest turns get summarized into one new message and marked out-of-context, dimmed but still visible, never removed), and a small, explicit set of built-in tools (search documents, create a document, update a document) the assistant can call mid-conversation.

Every tool call is attributed to the real logged-in user, never a separate "agent" identity -- creating or updating a document through chat shows up in that document's own audit history exactly like a direct edit, just tagged with which chat session it came from. Read-only tool calls (search) run immediately; anything that changes data (create, update) pauses as a pending action and waits for an explicit Approve/Deny in the chat UI before running at all -- there's no way for the assistant to change data without a human confirming it first.

Document search blends keyword matching with semantic similarity (an embedding comparison) when a document has been explicitly indexed via `daat document reindex-embeddings` -- indexing is never an automatic side effect of saving a document, since it costs a real API call per document.

The LLM backend is pluggable (`src/agent_provider*.lua`, selected by `platform.lua`'s `agent_provider` field) -- ships with a real Google Vertex AI backend and a deterministic backend used by this project's own test suite so routine test runs don't repeatedly hit a paid API.

## Knowledge Pool

Every document that gets retrieved, plus anything the system or the agent produces on its own (chat-session transcripts, a leaked reasoning trace, distilled notes), lives in one shared pool alongside user-authored Documents -- filed under a single, always-visible "Knowledge Pool" folder, never a separate shadow table. A conversation, a wiki page, and a one-line distilled summary aren't different kinds of thing; they're the same kind of record at different points in one lifecycle.

**Tiers are earned by editing, never by reading or by time.** A document starts at Raw Intake (Tier 0) and only advances once it's actually been revised -- a real edit in its own ledger history, or a rewrite by `knowledge.distill` -- to Curated Draft (Tier 1), Developed Reference (Tier 2: multi-section/long content), or Atomic Record (Tier 3: short, single-subject, definition-card shape). Recomputed fresh from the current body on every review, so a document edited back down to something thinner drops back down too -- it isn't ratcheted upward for good.

**Heat is a fixed budget, not a decaying score.** Every retrieval hit reinforces a document's heat, but the total heat across the whole pool always equals a fixed amount -- reinforcing one document draws that reinforcement proportionally from every other document rather than manufacturing it from nothing. Nothing ever reaches zero and nothing is deleted for going cold; it just stops surfacing near the top until something needs it again.

**Reactive distillation, on demand and inline.** When a document's content shape comes back "developed" and it has no distilled derivative yet, the same request that retrieved it triggers a single direct model call that writes a new, concise, single-idea card -- filed at Tier 0 like anything else, pointing back at its source. No periodic scan of the pool; distillation is a side effect of a document actually mattering to a real search, not a scheduled job.

**Co-retrieval linking, judged, not assumed.** Two documents that keep turning up together in the same searches get evaluated by the agent -- a genuine relationship, or coincidental overlap? -- and only become an explicit link once judged real. A linked neighbor's retrieval gives the other document a smaller heat boost too (spreading activation, diluted by how many other links it already has), which is how cross-references form without anyone tagging anything by hand.

**Every real model call is fully auditable.** The exact prompt actually sent, the model id, and real token counts are persisted for every chat turn and every distillation call -- not reconstructed after the fact from chat messages. A reply that leaks visible reasoning gets that reasoning saved as its own document, attributed to the real user, going through the exact same tiering/heat/review pipeline as everything else.

Surfaced via `daat knowledge <stats|list|show|promote|distill>` on the CLI, and a `/knowledge` page (Setup/Admin capability) with stat tiles, tier breakdown, and recent retrievals. See `doc/architecture.md`'s own "Knowledge pool" section for the full mechanism and its derivation.

## Docs

- `doc/onboarding.md` -- start here if you're a new contributor to the open-source project: prerequisites, repo layout, architecture primer, and a `dev/` container for a one-command build/test setup.
- `doc/architecture.md` -- the Knowledge Pool mechanism, the entity-history model, how entity types and extensions run sandboxed, and the auth/session design.
- `doc/schema.md` -- defining entity types: field types, sandboxed loading, what a definition generates.
- `doc/extensibility.md` -- the extension system: manifest format, event hooks, capability sandboxing.
- `doc/glossary.md` -- terms this codebase should use consistently (Document vs page/Notebook, Entity vs record, Knowledge Pool tiers, capability names).
- `doc/link-adjudication-alternatives.md` -- a design perspective from comparing notes with the open-ontologies project: an auditable, rule-based alternative to today's LLM-judged co-retrieval linking.
- `doc/why-luam.md` -- why daat is written in Luam specifically: how each of Luam's own design tenets shows up in daat's code, and why Python or JavaScript couldn't get there.
- `doc/templating.md` -- how `html.lua` builds pages: the `{{ }}`/`{{{ }}}` interpolation convention (`render.lua`), `page.lua`'s typed-section vocabulary for daat's own trusted pages (and why it's a separate mechanism from the extension canvas), and the scope boundary for which pages fit that pattern at all -- plus real gotchas hit along the way, worth knowing before touching either.
- `doc/prior-art.md` -- the requirements a system like daat actually needs to meet, and where existing wikis, LIMS platforms, and note-taking tools fall short of them.
