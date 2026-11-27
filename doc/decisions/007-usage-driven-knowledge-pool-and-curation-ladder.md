# 007. Unified Knowledge Pool, Conserved Heat & Usage-Driven Curation Ladder

- **Date:** 2026-11-27
- **Status:** Accepted

## Context & Real Need

Early iterations of the Knowledge Pool hit four concrete failure modes in production (`7,478` active Documents on `celleste-lims`):
1. **Shadow-table split:** Keeping a separate `knowledge_note` table that had to be manually "materialized" into `document` duplicated content and hid retrieved Documents from one unified tree/graph.
2. **Unbounded additive heat & slow search:** Adding raw heat + tier bonuses directly to search scores (`~12` bonus points vs. small relevance scores) caused frequently retrieved off-topic proceedings to surface on almost every query and reinforce themselves further, while synchronous retrieval heat/review/co-retrieval writes inside `GET /documents?q=...` issued `540–1,960` SQL queries (`201–253` write DMLs) and reading full content + JSON vectors into Lua took `19.6–120 s`.
3. **Raw sources mislabelled at high tiers (2026-10-28):** Promoting any Document with one `update` event (`was_revised`) via a body-only judge placed `151k`-char raw chat transcripts and `200k`-char synced files at Tiers 1–3 while leaving all `132` distilled facts at Tier 0 ([tier-curation-ladder.md](../tier-curation-ladder.md)).
4. **Silent overwrites of human intent:** Importing `6,865` documents with spreadsheet tokens (`#REF!`, `#123`) or folding duplicate titles risked inventing `172` bogus tags or archiving user-authored Documents.

## Decision

1. **One unified `document` pool with conserved log-space heat & RRF search (`src/document.lua`, `src/document/schema_pool.lua`):**
   - Pool columns (`tier`, `raw_heat`, `log_scale_at_write`, `pool_active`, `retrieval_count`, `source_type`, `source_id`, `source_ref`, `merged_into`) live directly on `document` (system-managed, hidden from `DOCUMENT_SCHEMA` user forms); agent-written notes file under the top-level `"Knowledge Pool"` folder Document.
   - Heat is conserved across all active non-merged Documents ([heat-decay-redesign.md](../heat-decay-redesign.md)): each Document's effective heat is `raw_heat * exp(log_pool_scale - log_scale_at_write)` (`O(1)` read, zero whole-table decay rewrites), maintaining `sum(eff) == document_count * BASE_HEAT` (`L1`).
   - `document.search` combines two-stage SQL BM25 lexical ranking with native C `float32` packed-vector cosine similarity (`luam/lib/vec/vec.c` over `document_embedding.vector_packed` and multi-passage `document_aspect` vectors for long Documents) via Reciprocal Rank Fusion (`k = 60`), applying tier/heat reinforcement *last* as a bounded multiplier (capped at `+50%`) so irrelevant hot Documents never enter results.
2. **Deferred retrieval review & four-tier verified curation ladder (`src/knowledge/{review,curate,synthesize,distill}.lua`):**
   - Interactive search (`search_review_mode = "deferred"`) writes at most `2` SQL `INSERT`s (`knowledge_retrieval` with `status = 'pending'` + batched `knowledge_retrieval_hit`), leaving `daat run-pending` to drain `review-pending` -> `curate-pending` -> `synthesize-due` -> `distill-due` asynchronously with per-row claim tokens.
   - Every source Document (user-authored Documents, synced files, connection notes, legacy transcripts) stays permanently at **Raw Intake** (Tier 0, enforced by `knowledge.can_hold_tier` and verified by `L4`). Tiers 1–3 are earned strictly by checked agent synthesis:
     - **Curated Draft** (Tier 1, `source_type = 'curated'`): queued when a source is `due_for_review` (`retrieval_count >= 2` or `effective_heat >= 1.15`, plus per-aspect curation on long Documents) or when an `agent_session` is quiet for `curate_quiet_minutes` (`60`, reading `request`/`answer`/`reasoning` rows only, never `tool_trace`), then verified by a second source-fidelity model call.
     - **Developed Reference** (Tier 2, `source_type = 'reference'`): synthesized per Tag once it holds `>= 3` Tier-1 notes (`synthesize.lua`), rewritten in place when notes change, and archived if its computed Tag is archived.
     - **Atomic Record** (Tier 3, `source_type = 'record'`): extracted from Tier-2 references (`distill.lua`), deduplicated at `>= 0.80` cosine (`SAME` / `UPDATE` / `NEW`, absorbing legacy `distilled` facts via `merged_into`), embedded immediately, and source-checked.
3. **Human choices always win (`src/knowledge/review.lua`, `src/document/duplicate.lua`, `src/tag/{upkeep,build,broader}.lua`):**
   - Auto-retitling and content-hash/shingle duplicate folding touch only system-derived (`source_type` set) or externally synced (`external_id` namespaced) Documents — never user-authored Documents.
   - Manual Tags, `pinned`/`excluded` `document_tag` memberships, inline `#tag` assertions written by human logins (skipping `"system"` and `"api:*"` imports), and human-edited `tag.parent` hierarchy edges (`tag/broader.lua` checks `entity_event.author != 'system'`) are never overridden by computed Tag builds or upkeep.

## Deliberate Tradeoffs & Not in Scope

- **Accepted cost:** Each ladder step pays `2` model calls (draft + source-fidelity check), paid only for retrieved/used Documents and quiet chats rather than whole-pool scans; under `search_review_mode = "deferred"`, heat reinforcement and curation queueing lag interactive searches until the next `daat run-pending` tick (every `2 min` in production).
- **Not in scope:** Promoting user-authored or raw synced Documents above Tier 0, feeding raw `tool_trace` outputs into curation or embeddings, full-corpus cron curation scans of unretrieved Documents, or database-specific vector extensions (`sqlite-vss`, `pgvector`) while `vec.c` scans `8,000 x 768`-dim vectors in `< 2 ms`.
- **Revisit trigger:** If active Document/aspect counts grow past `~100k` vectors where `< 2 ms` in-process `vec.c` scans exceed `~25–50 ms` per search, evaluate MariaDB 11.7+ native `VECTOR INDEX` (`HNSW`) behind `database.lua` while keeping SQLite on `vec.c`.

## Verification

- `./bin/daat store verify` — Laws **L1** (`pool_thermodynamics`), **L3** (`derived_indexes`), and **L4** (`ontology_and_tiers`)
- `./bld/test.sh` & `./bld/eval.sh --mode test`
- Detailed subsystem designs: [tier-curation-ladder.md](../tier-curation-ladder.md), [heat-decay-redesign.md](../heat-decay-redesign.md), [agent-data.md](../agent-data.md), and [tag-ontology.md](../tag-ontology.md)
