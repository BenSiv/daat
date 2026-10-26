# Passage retrieval: implementation plan

Plan, 2026-10-26. `document.search` should give the chat the most relevant *parts* of the documents it finds, chosen by meaning, without storing documents as chunks. This is item 1 of Phase 2 in `doc/context-management-plan.md`, done properly rather than by shrinking the excerpt.

## The idea

Retrieval stays two-stage, and only the second stage changes.

1. **Narrow by whole document (unchanged).** `document.search` ranks whole documents by keyword relevance fused with whole-document embedding similarity, and keeps the top few. Documents are embedded whole on purpose: they are meant to shrink and cohere as the pool distills them, rather than be cut into arbitrary chunks.
2. **Concentrate within the shortlist (new).** For each shortlisted document, split it into *passages* along its own structure, score each passage against the question by meaning (and words), and give the chat only the best passages, within the same character budget as today's excerpt.

Why: today stage 2 picks one window by **keywords only** (`document.search_snippet`). A document found by meaning, sharing few words with the question, has nothing for that window to aim at, so the chat gets the wrong part of the right document, and the agent then reads the whole thing with `entity.get`.

What stays true:
- **No document is stored as chunks.** Passages are derived at search time from the document's current text. When a document is distilled, edited or retitled, its passages simply change.
- **What is cached is derived, keyed by content, and expires.** A passage's embedding is cached under the hash of the passage's text, so an unchanged passage is never embedded twice. Each entry lasts a fixed time *since it was last used* (like the Vertex token cache's expiry, and the prompt retention period), so a passage of a document that has since changed, or of one nobody searches for, disappears on its own.

## Design

### Passages: split by the document's own structure

`passage.split(content)` returns `{{text, offset}, ...}`, where `offset` is the passage's first character in `content`:
1. Skip a leading metadata preamble (a blockquote closed by a horizontal rule, which `search_snippet` already recognises: synced files start with one).
2. Split at markdown headings. Each passage keeps its heading line, so it says what it's about.
3. A section longer than `passage_max_chars` is split further at blank lines (paragraphs), and as a last resort at sentence ends. Never mid-word.
4. Passages shorter than `passage_min_chars` merge into the next one (or the previous one, at the end), so a lone heading or one-line paragraph isn't a passage.
5. A document no longer than the excerpt budget isn't split at all: it's returned whole, with no embedding call.

Deterministic, with no model involved: the same text always gives the same passages and hashes.

### Scoring

For each shortlisted document:
- **Meaning:** the cosine of the passage's embedding and the query's embedding. The query embedding is the one stage 1 already computed; `document.search` returns it instead of discarding it.
- **Words:** the share of the query's distinct terms the passage contains (the same terms `search_snippet` uses).
- **Score:** `cosine + passage_lexical_weight × term_share`. Words break ties, and catch exact names and ids that embeddings blur.
- **Pick** the best passages, at most `passages_per_document`, while their total length fits the excerpt budget (`agent_search_excerpt_length`). Show them in document order, each marked with its offset so the agent can read around it: `[at character 4210]`, then `entity.get field=content offset=4210`.

### Embedding passages: batched, cached, bounded

- **Cache lookup first:** one `SELECT` for all candidate passage hashes, under the current embedding model.
- **Misses are embedded in batched provider calls.** `agent_provider.embeddings_batch(model, texts)` is new. Vertex accepts many instances per `:predict` call, and batches are cut to stay under its per-request limits. A provider without batch support falls back to one call per text.
- **Bounded per search:** at most `passage_max_embeds_per_search` new embeddings (default 60). Passages left over (a very long document on a cold cache) are scored by words only.
- **Any embedding failure,** or an unconfigured provider, falls back to today's keyword window for that search, never to an error. Search must never get worse than today.

### The cache: `document_passage_cache`

```dbml
Table document_passage_cache {   // derived; safe to empty at any time
  text_hash varchar(64) [pk]      // hash of the passage text
  model varchar(128) [pk]         // embedding model it was made with
  vector_packed longblob [not null] // L2-normalised float32, same packing as document_embedding
  created_at text
  last_used_at text               // refreshed (in one UPDATE) whenever a search uses it
}
```

- **Keyed by text, not by document.** Identical passages (shared templates, synced boilerplate) are embedded once, and a document edit naturally leaves its old passages unused, so they expire.
- **Expiry: `passage_cache_days`** (default 30) since `last_used_at`. 0 keeps entries forever.
- **Pruning** shares one retention command with the prompt retention (next point).
- **Hidden from the agent's `entity.query`,** like every non-entity table. Described for the `/sql` console.
- **One more table** (36 → 37 built-in). It earns it: it's the only way to avoid re-embedding the same passages on every search, and it can't grow without bound.

### One retention command

Today `daat agent prune-prompts` clears old prompts. Rather than add a second, single-purpose timer job, `daat store prune` runs every retention rule:
- `prompt_retention_days`: clears old prompts in `agent_model_call`
- `passage_cache_days`: deletes expired `document_passage_cache` rows

Each rule reports what it removed. `daat agent prune-prompts` stays as an alias for one release, so the running timer keeps working until the startup script switches to the new name.

### Settings (`platform.lua`, all with defaults)

| Setting | Default | What it does |
|---|---|---|
| `search_passages` | `false` until the live check, then `true` | Turns stage 2 on, for the agent and the `/documents` page alike; off means today's keyword window |
| `passage_max_chars` | 1500 | Longest passage before it's split further |
| `passage_min_chars` | 200 | Shorter passages merge into a neighbour |
| `passages_per_document` | 2 | Most passages shown per document |
| `passage_lexical_weight` | 0.2 | Weight of word matches next to meaning |
| `passage_max_embeds_per_search` | 60 | New embeddings one search may request |
| `passage_cache_days` | 30 | Cache entries expire this long after last use (0: never) |
| `agent_search_excerpt_length` | 1200 (unchanged until the live check) | Characters per document, now shared by its passages |

## Changes by file

| File | Change |
|---|---|
| `src/passage.lua` (new) | `split`, `score`, `select`, cache read/write/refresh/prune. No knowledge of chat or tools |
| `src/agent_provider.lua` | `embeddings_batch(model, texts)`, falling back to per-text calls |
| `src/provider/agent_vertex.lua` | Batched `:predict` (many instances), cut by count and size |
| `src/provider/agent_test.lua` | Batch support, plus an opt-in word-based test embedding (`AGENT_TEST_EMBEDDINGS=terms`: hashed word counts, so texts sharing words are similar) so ranking tests mean something; the existing default is unchanged |
| `src/document.lua` | `document.search` also returns the query vector; the cache table is created in `document.init_schema`; column notes for `/sql` |
| `src/html.lua` / `src/cgi.lua` | The `/documents` search results use the same `passage.excerpt` (same setting, same fallback) |
| `src/agent_tools.lua` | `document.search` uses `passage.excerpt(...)` when `search_passages` is on, else `search_snippet` (also the fallback). `detail = "full"` doubles `passages_per_document` and uses the full excerpt length |
| `src/config.lua` | The settings above |
| `src/main.lua` | `daat store prune` (+ the `agent prune-prompts` alias) |
| `src/context_report.lua` | Optional: passage cache size, and hit rate if logged |
| `~/software/.../startup-platform.sh.tpl` | Jobs timer calls `platform store prune` |

## Commits, in order

Each is tested on its own, on a `feature/passage-retrieval` branch.

1. **Splitting:** `passage.split` with unit tests. Pure, no I/O.
2. **Batch embeddings:** `embeddings_batch` in `agent_provider`, Vertex and the test provider (plus the word-based test mode). Unit-test the batching and size cuts; check against Vertex once, by hand, with your OK, since it's a paid call.
3. **Cache and retention:** the table, read/write/refresh, `daat store prune` and the alias. Tests on SQLite and MySQL 8.
4. **Scoring and selection,** wired into `document.search` behind `search_passages`, with the fallbacks. Integration tests.
5. **Scorecard scenarios and docs.**
6. **Live comparison** (needs your OK: real model calls), then turn on the default if it holds, then deploy. The startup-script change ships with that deploy.

## Tests

**Unit (`tst/unit/passage.lua`):**
- Splitting:
  - headings start passages and keep their heading line
  - long sections split at paragraphs, then sentences, never mid-word
  - short pieces merge
  - the metadata preamble is skipped
  - offsets point at the passage's real first character (`string.sub(content, offset, …) == text`)
  - a short document isn't split
  - deterministic: the same input gives the same output
- Scoring and selection, with fixed vectors:
  - the highest cosine wins
  - word matches break ties
  - passages are shown in document order
  - the budget is never exceeded
  - at most `passages_per_document`
- Cache expiry arithmetic: what counts as expired at a given time.

**Integration (`tst/integration/passage_retrieval.bats`, test provider with word-based embeddings):**
- A long document whose answer sits in a late section: search returns that section's passage (with `[at character N]`), not the start of the document.
- With the setting off: today's keyword excerpt, byte for byte.
- A second identical search makes **no** new embedding calls (the test provider counts calls), and refreshes `last_used_at`.
- Editing a document: its changed passages are embedded fresh; unchanged ones come from the cache.
- An embedding failure (the test provider's failure switch) falls back to the keyword excerpt; the search still succeeds.
- `passage_max_embeds_per_search` caps new embeddings; the rest are scored by words.
- `daat store prune` deletes entries unused for longer than `passage_cache_days`, keeps recently used ones, keeps everything at 0, and still clears old prompts. `agent prune-prompts` still works.
- `entity.query` can't read `document_passage_cache`; `entity.fields` describes it.

**MySQL (`tst/integration/mariadb_backend.bats`, against a local MySQL 8):** the table and BLOB round-trip, the batch `IN (...)` lookup, and the `last_used_at` refresh in one `UPDATE`.

**Scorecard (`tst/eval/scenarios/`):** new scenarios whose answer sits deep inside a long document and shares few words with the question, plus the existing search-dependent ones. Compare passages off vs on, at 1200 and at ~600 characters per document:
- correct %
- tokens per passed run
- how often a search is followed by `entity.get` on the same document (were the passages enough?)
- latency per search

## Docs to update

- **`doc/passage-retrieval.md` (new):** how search works now, both stages, the reasoning (no arbitrary chunking, documents shrink by distillation, passages are derived), the cache and its expiry, the settings.
- **`doc/architecture.md`:** the semantic search bullet and the settings table.
- **`doc/schema-revision.md`:** the new table, and why it's justified (37 built-in tables).
- **`doc/context-management-plan.md`:** Phase 2 item 1 points here.
- **`~/lims/docs/database-schema.dbml`:** regenerate after the deploy.

## Risks and how they're handled

- **Latency:** one batched embedding call per search on a cold cache (about half a second), none on a warm one. Measured in the scorecard comparison; the per-search cap bounds the worst case.
- **Cost:** passage embeddings are cheap and cached; a cold cache costs one call per search, at most 60 passages.
- **Quality:** passages could miss context that a contiguous window kept. Mitigations: passages keep their heading, are shown with their offsets, and the agent can read around them. The live comparison decides the default; the setting can turn the feature off.
- **Cache growth:** bounded by expiry and by what's actually searched. The context report can show its size.

## Decisions (2026-10-26)

1. **`passage_cache_days` defaults to 30,** as a deployment setting in `platform.lua`, like every other value here. Nothing is hard-coded.
2. **People and the agent see the same thing.** The `/documents` search page shows the same passages the agent gets, from the same function. This is a standing design rule for the whole system (`doc/architecture.md`, "The agent sees what a user sees"): anything that decides what a search, list or record shows decides it once, for both.

Approved: the batched-embedding check against Vertex, and the live scorecard comparison.
