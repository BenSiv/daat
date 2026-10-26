# Passage retrieval

How search decides what to show of each document it finds, and why. The agent's `document.search` tool and the `/documents` search box run the same search (`knowledge.search_for_display`), so a person and the agent always see the same documents and the same passages (`doc/architecture.md`, "The agent sees what a user sees").

## Two stages

1. **Narrow by whole document.** Documents are ranked by keyword relevance fused with whole-document embedding similarity (`document.search`), with tier and heat as a bounded multiplier. Documents are embedded whole on purpose. They are not cut into chunks: they are meant to shrink and cohere as the knowledge pool distills them.
2. **Concentrate within the shortlist** (`src/passage.lua`, when `search_passages` is on). Each shortlisted document is split along its own structure, its passages are scored against the question, and only the best are shown, within the same character budget an excerpt has.

A document no longer than the budget is shown whole. With `search_passages` off, or whenever stage 2 can't run (no query embedding, a provider failure), each document shows the keyword window (`document.search_snippet`): the stretch with the most of the query's words. Stage 2 never makes search worse than that.

## Passages

`passage.split` cuts a document's text (past any metadata preamble a synced file opens with):
- at its headings, so each section starts a passage and keeps its heading line
- within a section longer than `passage_max_chars`, at paragraph breaks, then sentence ends, then whitespace, never mid-word
- merging pieces shorter than `passage_min_chars` into a neighbour

Every passage is an exact, contiguous slice of the document. Splitting is deterministic, so the same text always gives the same passages.

**Nothing is stored as chunks.** Passages are derived from the document's current text at every search, so when a document is distilled or edited, its passages change with it.

## Scoring

`score = cosine(passage, query) + passage_lexical_weight × (share of the query's words in the passage)`.
- The query's embedding is the one stage 1 already computed.
- A passage is embedded led by its heading when it doesn't start with it, so its meaning includes what it's about.
- Words break ties and catch exact names and ids that embeddings blur.

The best passages are chosen, at most `passages_per_document` (twice that with `detail = "full"`), while they fit the budget. The best one is cut to the budget if it alone is longer. They're shown in document order, each marked `[at character N]` (and `under <heading>` when needed), so a reader can continue with `entity.get field=content offset=N`.

## The embedding cache

`document_passage_cache`: one row per (hash of the embedded passage text, embedding model), holding the vector L2-normalised and packed as in `document_embedding`.
- **One round trip per search:** one query for all candidate passages, and one batched embedding call (`agent_provider.embeddings_batch`) for whatever is missing, capped at `passage_max_embeds_per_search`. Passages over the cap are scored by words alone.
- **Keyed by text, not document.** Identical passages share an entry. An edited document re-embeds only the passages that changed; its old passages are no longer used.
- **Expiry:** every use refreshes `last_used_at`. `daat store prune` (the jobs timer) deletes entries unused for `passage_cache_days`; 0 keeps them forever.
- **Derived:** it can be emptied at any time and refills as people search. Not queryable by the agent's `entity.query`.

## Usage

A search from the `/documents` box counts as usage like the agent's: it's logged as a retrieval (with no chat session), and it reinforces the documents it returns. After a search, `knowledge.review_retrieval` can make model calls (tier judgments, link checks). On the page those run inside the web request, so a search can occasionally take longer; worth watching after rollout.

## Settings (`platform.lua`)

| Setting | Default | |
|---|---|---|
| `search_passages` | `true` | stage 2 on or off, for the agent and the page alike |
| `agent_search_excerpt_length` | 1200 | characters per document |
| `agent_search_excerpt_full_length` | 4000 | characters per document with `detail = "full"` |
| `passage_max_chars` / `passage_min_chars` | 1500 / 200 | passage size |
| `passages_per_document` | 2 | most passages shown per document |
| `passage_lexical_weight` | 0.2 | weight of word matches next to meaning |
| `passage_max_embeds_per_search` | 60 | new embeddings one search may request |
| `passage_cache_days` | 30 | cache entries expire this long after last use (0: never) |

## Evidence

Live scorecard, 2026-10-26 (16 scenarios × 2, `gemini-3.5-flash-lite`, passages off vs on): correct answers 100% both ways, all checks 62% both ways, tokens per passed run 59.6k → 57.9k. The demo lab has one long document, so the handbook scenarios passed both ways: this shows no regression and a small saving, not the size of the gain on a large corpus. Measure that on production with `daat agent context-report` (tool result sizes for `document.search`, `entity.get` follow-ups) before and after rollout.

## Tests

- `tst/unit/passage.lua`: splitting and selection.
- `tst/integration/passage_retrieval.bats`: the answering passage, the off switch, the cache (hits, refresh, edits, the cap), the fallback, retention, the same results on the page.
- `tst/integration/mariadb_backend.bats`: the cache on MySQL.
- Scorecard: `handbook-deep-passage` and `handbook-media-cooling` (answers in late sections, asked in other words).
