# Glossary

Terms this codebase, its UI, and its agent tools should use consistently.
When adding new UI copy, doc prose, or an `AGENT_TOOLS` description,
check here first rather than reintroducing a rival name for something
that already has one.

## Core concepts

- **Document** -- the wiki-style content unit (a real parent/child tree,
  Markdown, `[[title]]` links -- see `architecture.md`'s "Documents"
  section). Not "page" (too generic a word in this app -- the Home page
  and System page are also, unrelatedly, "pages" in the ordinary web
  sense) and not "Notebook entry" (reads as Benchling-specific jargon
  this platform is meant to generalize away from). `document.lua`, the
  `document` table, and the `/document*` routes are the internal
  identifiers this term always refers to -- those are not renamed to
  match; internal code identifiers and user-facing copy don't have to
  share a word, only be internally consistent each on their own terms.

- **Entity / Entity type** -- a schema-defined data record (a sample, a
  plant, a task) and the declarative definition that generates its
  table (`schema.lua`, `entity.lua`). Not "record"/"record type" -- code,
  UI copy, and every `AGENT_TOOLS` description already say "entity"
  consistently; that's the word that wins in prose too.

- **Knowledge Pool** -- the container: documents that have been
  retrieved, or were created as system/agent-derived content in the
  first place (chat-session transcripts, reasoning notes, distilled
  notes). See `architecture.md`'s "Knowledge pool" section for the full
  mechanism.

  - **Raw Intake** (Tier 0) -- captured, not yet worked on.
  - **Curated Draft** (Tier 1) -- has been revised at least once
    (`document.was_revised`), but its content hasn't earned a more
    specific shape yet.
  - **Developed Reference** (Tier 2) -- revised, and its content is
    "developed": multi-section or long -- a real, complete article, not
    a stub.
  - **Atomic Record** (Tier 3) -- revised, and its content is "atomic":
    short, single-subject, definition-card-shaped.

  Promotion is driven by **content-processing maturity**, not retrieval
  frequency -- retrieval count and heat only decide whether a document
  is *due for review* (`knowledge.due_for_review`) at all, never which
  tier it lands in. See `document.promotion_target_tier`'s own comment
  for the exact mechanism, and `architecture.md`'s "Knowledge pool"
  section for the full writeup.

- **Baseline / Setup / Admin** -- the three account capability levels
  (`cgi.lua`'s `REQUIRED_CAPABILITY`, `cgi.has_capability`). Baseline
  (`"i"`) is what every logged-in account needs to reach any gated
  route at all; Setup (`"s"`) additionally grants `/sql`, `/system`, and
  `/knowledge`; Admin (`"a"`) additionally grants user/API-key
  management, `/settings`, and any entity type whose schema opts into
  `admin_write_only`. Never "check-in" -- that word appeared in exactly
  one error string, nowhere else, and has been fixed to say "baseline"
  like everywhere else already did.

## Intentionally distinct -- don't conflate

These look like they might be naming clashes but genuinely aren't --
each already refers to a different thing, cleanly:

- **View** -- a saved, admin-approved SQL query definition (`/view`,
  `view.lua`) is a completely different thing from generically "viewing"
  a record (`/detail`) or a UI toggle's "list view" (the `/data`
  List/Diagram switch). Context always disambiguates which one; no
  rename needed.
- **Browse** -- `/browse` is the UI route/name for listing a type's rows;
  `entity.list` is its own internal fetch function, not a rival
  user-facing name. "List" only appears as the label on `/data`'s own
  List/Diagram display-mode toggle, an unrelated feature.
- **Template vs Example** -- `template.lua` (reusable entry layouts a
  user picks from `/templates`) and `examples.lua` (seed content
  `daat init --with-examples` writes once, for a fresh deployment to
  look at) are genuinely different features that happen to sound
  similar; not the same concept under two names.
- **Extension vs Hook** -- an "extension" (`extension.lua`) is the
  deployable, sandboxed, capability-scoped unit; a "hook" is the
  specific before/after event-callback mechanism *inside* one. "Plugin"
  is deliberately never used as a synonym for either -- this system is
  explicitly "a small, explicit registry, not an open plugin
  architecture" (see `architecture.md`).
