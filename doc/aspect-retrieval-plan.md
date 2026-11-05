# Aspect retrieval: plan

Plan, 2026-11-04. Search should find a document by a subject it covers anywhere in its text, not only by what its opening is about. Documents stay embedded whole and stay the unit of ranking, heat, tiers and display. A long document gets a few extra **aspect vectors** used to find it. A hit through an aspect queues that part of the document for curation, so the insight ends up as a note of its own.

## Problem

Stage 1 of search (`doc/passage-retrieval.md`) ranks whole documents by words (BM25 over the full text) fused with one embedding per document. That embedding doesn't cover the document.

**`text-embedding-005` reads at most 2,048 tokens and silently drops the rest.** `embedding_text` sends the title and the whole body, and Vertex truncates it. Checked on prod 2026-11-04: three synced files of 62-68k characters were re-embedded from prefixes of increasing length. Each one's stored vector equals the embedding of its first 7,000-10,000 characters (cosine 1.0000), and nothing after that changes it.

Prod, 2026-11-04, 8,024 searchable documents, with ~8,000 characters as the cut:

| | Documents | Over the cut | Characters | Never embedded |
|---|---|---|---|---|
| synced files (no source_type) | 7,167 | 3,013 | 148.7 M | 119.0 M |
| chat sessions | 48 | 9 | 0.2 M | 0.1 M |
| references | 15 | 10 | 0.1 M | < 0.1 M |
| curated, records, distilled, experiment views | 794 | 0 | 0.6 M | 0 |
| **all** | **8,024** | **3,032 (38%)** | **149.6 M** | **119.1 M (80%)** |

By length: 3,492 are under 1.5k characters, 1,324 between 1.5k and 5.7k, 822 between 5.7k and 20k, 1,273 between 20k and 50k, 1,066 between 50k and 200k, and 47 over 200k.

So 80% of the text in the pool is invisible to the semantic ranking. A finding on page 30 of a report isn't outranked by the report's main subject. It isn't in the vector at all. It can still be found:
- by words, when the question uses the document's words (BM25 sees everything, but discounts long documents and passes only its top 50 to fusion);
- by stage 2 (passages), but only for documents that already made the shortlist.

All curated knowledge is fully embedded. The gap is in the raw sources, and the curation ladder (`doc/tier-curation-ladder.md`) doesn't close it:
- **Curation is driven by use.** A source is queued when it's retrieved, and `curate.due_sources` and `distill.due_references` order by `retrieval_count`. A part that search can't find is never retrieved, so it is never curated.
- **Curation reads the start.** `curate` reads the first 40,000 characters (`CURATE_INPUT_MAX_CHARS`) and writes one note of at most ~400 words about the source's key findings. That note covers the main subject, and a second subject at character 90,000 isn't in it. At least 1,113 sources are longer than 50k characters.
- **Distillation keeps the most useful 12 claims** of a reference, which again favours the main subject.

The loop is closed: an insight that can't be found isn't retrieved, so it isn't curated, so it never becomes a note that can be found.

## The idea

**Passages find, curation keeps.**

1. **Aspects.** A document longer than the embedding window gets up to *k* aspect vectors besides its own: its passages (`passage.split`, the same split stage 2 uses) are embedded and grouped by meaning, and each group becomes one aspect. Aspects are derived like `document_embedding`: built by the embedding job, rebuilt when the text changes, safe to drop.
2. **Search scores a document by its best match.** In `semantic_ranking`, a document's similarity is the highest of its own vector and its aspects. Everything after that (fusion, tier and heat, the shortlist, stage 2, logging) is unchanged and works on documents.
3. **An aspect hit is a curation signal.** When a document is found through an aspect rather than its own vector, the retrieval records which aspect. The curate step then writes a note **about that part** of the source (its passages, wherever they sit), not about the first 40k characters. The note is short, on one subject, embedded whole, ranks above the raw source by tier, and links to it. Once the note exists, it answers that kind of question by itself, without the aspect.

What stays true:
- **Documents are the unit.** Nothing is shown, linked, heated or tiered as a chunk. Aspects never appear in results; they only decide whether a document is found.
- **Curation still decides what knowledge spreads.** Aspects make raw text reachable. The curated note made from it is what's meant to be found long-term.
- **The document's own vector is unchanged**, so tags, links, the passage gate, dedup and distillation's near-match checks, which all use it, keep working as they do.

## Design

### Which documents get aspects

Those whose embedding text is longer than `aspect_min_chars` (default 7,000, just under the measured cut). Shorter documents are fully covered by their own vector. That's 3,032 documents today: synced files, a few chats and references. Curated notes and records never get any.

### Building aspects

In `document.embed_pending` (the jobs timer), after the document's own vector:
1. `passage.split` the content: the same passages stage 2 uses, embedded as stage 2 embeds them (heading first, `embed_text`).
2. Their vectors come from `document_passage_cache`. Misses are embedded in batches (`agent_provider.embeddings_batch`) and written to the cache, so the build also warms stage 2.
3. Cluster the passage vectors with k-means, deterministic (seeded by farthest-point from the document's own vector), `k = min(aspect_max, ceil(sqrt(passages)))`.
4. Per cluster, store one vector (the normalised centroid, or its medoid passage's vector; the gate below decides) and the offset of the medoid passage. The offset is what curation and the result marker use.

The `text_hash` of the embedding text is stored too, so aspects are rebuilt only when the text changes, the same rule `document_embedding` uses.

### The table: `document_aspect`

```dbml
Table document_aspect {          // derived; safe to empty, rebuilt by the embedding job
  document_id integer [pk]
  model varchar(128) [pk]        // embedding model, as document_embedding
  aspect integer [pk]            // 1..k
  vector_packed blob [not null]  // int8, scaled by its largest component; renormalised on read
  passage_offset integer [not null]  // first character of the medoid passage
  passage_count integer [not null]   // passages in the group
  member_offsets text [not null]     // where each of the group's passages starts, comma-separated
  text_hash varchar(64) [not null]   // of the embedding text it was built from
  updated_at text
}
```

One more built-in table (37 → 38; 39 with `knowledge_aspect_curation`, commit 5). Archiving a document drops its aspects (`document.drop_derived`). Like `document_passage_cache`, neither is visible to `entity.query`.

### Search

`semantic_ranking` reads `document_embedding` and `document_aspect` for the current model, and keeps per document the best similarity and which vector gave it (0 = the document's own). The similarity floor applies to that best value. `document.search` passes `aspect` and `passage_offset` through on each result. Ranking, fusion and reinforcement don't change.

Cost per search. Search is CGI-per-request, so every search reads all vectors from MySQL:

| | Vectors read | float32, 768 dims | Lua scan (local, `luam`) |
|---|---|---|---|
| today | 8,024 | 24 MB | 0.17 s |
| aspects, k ≤ 4 | ~20,000 | 61 MB | ~0.4 s |
| aspects, k = √n ≤ 16 | ~27,400 | 84 MB | ~0.6 s |
| aspects, k ≤ 16 | ~53,700 | 165 MB | ~1.1 s |
| every passage (no grouping) | ~130,000 | 400 MB | ~2.8 s |

The arithmetic is cheap. Moving the bytes may not be: today's stage 1 already takes 4-5 s on prod, and reading the vectors is part of that (not yet profiled on its own). So aspects are stored small: **int8** (a quarter of the bytes) and, if `text-embedding-005` holds up truncated (`outputDimensionality`, measured in the gate), **256 dimensions**. At k = √n, int8 × 256 adds ~5 MB per search, about a fifth of what's read today. Indexing every passage doesn't fit this process model. It would need a vector index in the database, which is out of scope here (see "Not now").

### Curation from aspects

- `knowledge_retrieval_hit` gets `aspect` (null when the document's own vector or words found it).
- Each aspect stores its member passages (`member_offsets`), so curating it reads exactly that group: `aspect.passages` re-splits the content and picks them out by offset.
- A source can have one curation per aspect next to its whole-source one: a table of its own, `knowledge_aspect_curation` (keyed by document and aspect, with the same columns as `knowledge_curation`). A separate table, not a new key on `knowledge_curation`, so the existing table and its queries don't change.
- An aspect is due once searches found the document through it twice (`due_for_review` on that aspect's hit count; heat is per document, so it doesn't count here). Review queues it (`curate.queue_aspect`) next to the whole-source queueing; `curate_aspects` turns this off.
- The curate input for an aspect is that group's passages in document order, each with its heading, `[...]` where the document skips text between them, within `CURATE_INPUT_MAX_CHARS`. The prompt gets one rule more (`CURATE_ASPECT_RULE`): the note is about this part of the source, titled by its own subject.
- The check (`CURATE_CHECK_SYSTEM_PROMPT` plus `CURATE_ASPECT_CHECK_RULE`) compares the note with those passages only.
- The note is a tier-1 `curated` document with the source as `source_id` and `source_ref` = `aspect N`, and its source line ends with ", the part at character N", so a reader can go to that place.
- The source's hash for an aspect is of the part's text: an edit elsewhere in the document doesn't re-curate it. If aspects are rebuilt and the queued one is gone, the run records `nothing` ("the aspect no longer exists") and keeps any note it had. Aspect numbers can shift when a document is rebuilt; the next curation of that number rewrites its note in place.
- `daat knowledge curate-pending N` runs queued whole sources first, then queued aspects with what's left of N.

This also fixes the 40k cut for long sources: parts past it become reachable one subject at a time, through use.

### Settings (`platform.lua`)

| Setting | Default | |
|---|---|---|
| `build_aspects` | `false` | the embedding job keeps aspects current (`daat repair aspects` builds them regardless, for the backfill) |
| `search_aspects` | `false` until the gate, then the gate's result | aspects in stage 1, for the agent and the page alike |
| `aspect_min_chars` | 7000 | documents whose embedding text is longer than this get aspects |
| `aspect_max` | 8 until the gate (4-16) | most aspects per document |
| `aspect_dims` | 0 (all) until the gate (256 if it holds) | dimensions stored per aspect |
| `aspect_vector` | `medoid` until the gate | an aspect's vector: its most central passage (`medoid`) or the group's mean (`centroid`) |
| `curate_aspects` | `true` with `search_aspects` | aspect hits queue curation of that part (commit 5) |

Rollout: `build_aspects` on, `daat repair aspects --limit N` until the backfill is done, then `search_aspects` on. Changing `aspect_max`, `aspect_dims`, `aspect_vector` or the passage sizes makes every document's aspects stale (they're hashed with the content), and `daat repair aspects` rebuilds them; passage vectors come from the cache, so a rebuild embeds only passages whose cache entries have expired (`passage_cache_days`).

## Gate: a recall test on prod data, before building

The design rests on one number: how often a question about a deep, off-topic part of a long document finds that document today, and with aspects. Measure it before writing the code:

1. **Questions.** Sample ~120 passages from distinct long documents. Each must sit past character 10,000, be at least 600 characters, and be off the document's main subject: its vector's cosine with the document's own vector must be in the lowest third for that document. A model writes one question each passage answers, in other words than the passage's, and skips boilerplate (tables of contents, reference lists). Add ~40 control questions from passages inside the first 7,000 characters, to check that aspects don't hurt what works today.
2. **A hit** is the target document, or any document holding the same passage (duplicate files), ranked in the top 5 (the agent's `document.search`) or the top 10 (the `/documents` page).
3. **Compare**, with the full stage-1 ranking (BM25 + semantic, RRF, tier and heat), replicated offline from the code:
   - today
   - the document's vector replaced by the mean of its passages (fixes truncation only)
   - aspects at k ≤ 4, √n ≤ 16 and ≤ 16; centroid vs medoid; float32/768 vs int8/256
   - every passage (the ceiling)
4. **Precision side.** Replay the last month's real queries from `knowledge_retrieval` and count how often aspects change the top 5, and how often the new entries are long documents found only through an aspect. Read a sample of them. This guards against the "hot document for every query" failure the reinforcement multiplier was built to stop (`document.search`'s comment): a 200k-character document with 16 aspects gets 17 chances to match.
5. **Decide.** Take the cheapest variant within ~3 points of the ceiling on the deep questions, with no loss on the controls and an acceptable replay. If even the ceiling barely beats today, aspects don't earn their table, and the effort goes into curation coverage instead (reading long sources in parts, not by use).

Cost: embedding every passage of the pool once (~150 M characters, ~130k passages; about $4 at text-embedding-005's list price), ~160 model calls for the questions, and ~20 min of embedding time. The passage vectors are the same ones the build would make, so they aren't wasted if the gate passes.

## Commits, in order

On `feature/aspect-retrieval`, each tested on its own:

1. **The gate** (above). Numbers into this doc, `aspect_max` and `aspect_dims` set from them. No daat code.
2. **Clustering and the table:** k-means and medoids as pure functions (`src/aspect.lua`), unit-tested; `document_aspect` on SQLite and MySQL; int8/256 packing next to `document.pack_vector`.
3. **Building:** `embed_pending` builds aspects; `daat repair aspects` backfills (batched, resumable, capped per run); archiving drops them.
4. **Search:** `semantic_ranking` reads aspects behind `search_aspects`; results carry `aspect` and `passage_offset`; retrieval hits record the aspect.
5. **Curation from aspects:** queue, input, prompt line, check; per-aspect rows in `knowledge_aspect_curation`.
6. **Scorecard scenarios and docs,** then the backfill and deploy, with your OK.

## Tests

- **Unit (`tst/unit/aspect.lua`):** k-means is deterministic and gives `min(aspect_max, ceil(sqrt(n)))` groups; one passage gives one group; medoids are real passages; int8/256 packing round-trips within tolerance; best-of scoring picks the aspect and keeps the floor.
- **Integration (`tst/integration/aspect_retrieval.bats`, test provider with word-based embeddings):**
  - a long document whose opening is about A and whose later section is about B is found by a question about B with aspects on, not with them off
  - the result is the document, not a passage, and the hit records the aspect
  - short documents get no aspects
  - editing a document rebuilds its aspects and reuses cached passage vectors for unchanged passages
  - archiving drops its aspects
  - two retrievals through the same aspect queue an aspect curation, whose input is that group's passages, including one past character 40,000
  - `search_aspects` off gives today's results byte for byte
- **MySQL (`tst/integration/mariadb_backend.bats`):** the table, BLOB round-trip, the joined read.
- **Scorecard (`tst/eval/scenarios/`):** questions about a second subject deep in a long document, asked in other words.

## Docs to update

- `doc/passage-retrieval.md`: stage 1 now scores by the best of a document's vector and its aspects, and the 2,048-token cut is stated.
- `doc/tier-curation-ladder.md`: curation per aspect, next to per source.
- `doc/architecture.md`: the semantic search bullet, the settings.
- `doc/schema-revision.md`: the new tables (39 built-in).

## Not now

- **A vector index in the database** (every passage searchable, no grouping). It's the ceiling the gate measures. If it beats aspects by a lot, it's a separate decision, tied to the persistent process (brex 245159427) and to what Cloud SQL for MySQL offers.
- **`task_type`.** daat sends none; `RETRIEVAL_DOCUMENT` for documents and `RETRIEVAL_QUERY` for questions usually help short questions find long text. It needs a full re-embed. The gate's harness can measure it on the same questions, as a separate change.
- **A larger-window embedding model.** It would push the cut further out, but a single vector still averages a long document's subjects together. Aspects are needed either way.
- **Scanning sources for curation without use.** If the gate shows aspects don't help, this is the alternative: curate long sources part by part on a schedule. It costs model calls for every source, used or not.

## Risks

- **Long documents crowd the results.** Several chances to match favours documents with many aspects. Mitigations: k grows with √n and is capped, the precision replay in the gate, and an aspect score discount (`aspect_weight` < 1) if the replay asks for one.
- **Read cost per search.** Bounded by k and the int8/256 storage, measured in the gate. Watch stage-1 time on prod after rollout (baseline 4-5 s).
- **Backfill.** ~5,000 batched embedding requests, once; capped per jobs run. Then only changed documents.
- **Passage cache growth.** The build warms `document_passage_cache` with every passage of long documents (~130k rows, against ~7k today). Stage 2 gets faster for it (today it hits its 60-embedding cap on every search). Rows still expire after `passage_cache_days` unused; aspects keep their own vectors, so expiry doesn't affect search.
