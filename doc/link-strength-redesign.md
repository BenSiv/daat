# Link strength: usage-driven, not time-driven -- the same idea as heat, applied to edges

## Problem

`document_link` (`src/document.lua:58-66`) is a bare `(from_document_id, to_document_id, link_text)` row -- existence only, no strength. Once a link exists (authored, or created by `knowledge.maybe_link_co_retrieved` after a real co-retrieval pattern and an LLM's confirmation -- see `doc/link-adjudication-alternatives.md` for the separate question of *how that create decision is made*), `knowledge.spread_activation` treats every one of a retrieved document's neighbors identically: `document.spreading_delta(base_delta, fan_count)` splits `base_delta * SPREADING_ACTIVATION_FACTOR` **equally** across all of them (`src/document.lua:458-462`). A link formed from one early, possibly borderline co-retrieval burst carries exactly the same spreading weight forever as a link between two documents that keep genuinely being retrieved together every week. Nothing about ongoing usage -- or the lack of it -- ever changes an edge's influence. This is the same shape of problem `doc/heat-decay-redesign.md` identified for documents, one graph layer down: an edge is either fully "on" or (if never formed) absent, with no ongoing signal in between.

## Why not literally reuse the heat-decay-redesign mechanism

The instinct is right -- usage-driven, not wall-clock -- but the heat redesign's actual machinery (a global conserved pool, `pool_scale`/`scale_at_write`, log-space, the O(1)-per-event trick) was built to solve a specific problem that doesn't exist here: reinforcing one of potentially thousands of *documents* without an O(N) write across the whole pool. An edge's relevant comparison set is never the whole graph -- it's the small, already-fetched neighbor list of *one* document at the moment it's retrieved (`document.linked_neighbors`, typically a handful of rows). Normalizing a handful of already-in-memory numbers at read time costs nothing that needs a clever amortization trick. Copying the global-pool machinery here would be solving a scaling problem this design doesn't have, at the cost of a second `log_scale`-shaped construct in the codebase for no real benefit -- exactly the "add a mechanism that isn't earning its complexity" outcome `doc/why-luam.md`'s own tenet-2 discussion argues against. The result below keeps the two ideas heat actually needed (reinforce on genuine use, no wall-clock decay) and drops the ones it needed only because of the global-scale problem.

## Design

### Schema

One new column on the existing table, no new table:

```sql
ALTER TABLE document_link ADD COLUMN raw_strength REAL NOT NULL DEFAULT 1.0;
```

`BASE_LINK_STRENGTH = 1.0`, matching `BASE_HEAT`'s own convention: a freshly created link reads the same under the new model as a link would have under today's flat split (see "Backward-compatible degenerate case" below).

### Reinforcement: piggyback on the co-retrieval signal that already exists

`knowledge.co_retrieval_pairs(db_path, document_ids)` (`src/knowledge.lua:714-735`) already computes every co-retrieved pair in the current batch, for `knowledge.maybe_link_co_retrieved` to decide what's worth linking. Split that same result two ways instead of one:

- A pair with **no** existing `document_link` row: unchanged, feeds `due_for_link_review`/possible creation, exactly as today.
- A pair that **already has** a `document_link` row: reinforce it. `raw_strength = raw_strength + LINK_REINFORCEMENT_DELTA` (a flat constant -- an edge has no tier the way a document does, so there's no `reinforcement_delta(tier)`-shaped table to key off; `LINK_REINFORCEMENT_DELTA = 0.15` matches the tier-0 floor of the document formula it's modeled on).

One query already being run, two outcomes instead of one -- no new signal, no new trigger.

### Spread-time weighting: normalize the (small, local) neighbor set actually being read

`knowledge.spread_activation` already fetches every neighbor of the retrieved document before applying anything. Fetch each neighbor's own edge `raw_strength` in that same query, sum them once (`total_strength`), and replace the flat per-neighbor split with a weighted one:

```
neighbor_delta = base_delta * SPREADING_ACTIVATION_FACTOR * (edge.raw_strength / total_strength)
```

in place of today's

```
neighbor_delta = (base_delta * SPREADING_ACTIVATION_FACTOR) / fan_count
```

**Backward-compatible degenerate case:** with every edge still at `BASE_LINK_STRENGTH = 1.0` (a document whose links have never been reinforced -- true for the whole graph at migration time), `total_strength = fan_count * 1.0`, so `edge.raw_strength / total_strength = 1 / fan_count` -- identical to today's formula. The new behavior only diverges from today's once real, repeated co-retrieval actually differentiates one edge from its siblings.

### Decay is relative, never subtractive -- no wall clock anywhere

Nothing ever decrements `raw_strength`, and nothing reads a timestamp. An edge that stops being co-retrieved keeps its `raw_strength` exactly where it last was -- what changes is its *share* of `total_strength` at the next spread event, once a sibling edge has been reinforced and the denominator has grown. A month of silence changes no edge's share at all, because a month of silence produces no reinforcement events for anything to be relative to; a month where every *other* edge from that document gets reinforced shrinks the quiet one's share automatically, with no separate decay step to write. This is the exact "usage, not time" property heat's own redesign established, arrived at here without needing heat's conserved-budget invariant to get it -- relative normalization over a small live set gives the same property directly.

Consistent with this project's "nothing is ever deleted, only archived" stance (`README.md`, `doc/architecture.md`'s "History as the source of truth" section): a link that fades in relative influence is never itself removed. It just contributes less and less to spreading activation, asymptotically, the same way a stale duplicate document isn't deleted, just excluded from ranking.

### Concurrency

Reinforcement here is a single additive `UPDATE`, with no computed multiplicative factor and no shared cross-row state to race over:

```sql
UPDATE document_link SET raw_strength = raw_strength + ? WHERE from_document_id = ? AND to_document_id = ?;
```

This is already the safe, atomic-in-place shape `record_retrieval_hit` uses for `heat`, and it needs none of `doc/heat-decay-redesign.md`'s "Concurrency" section's extra care (the `pool_scale`-style lost-update race, the same-row live-expression fix) -- those existed specifically because that design computed a shared multiplicative factor from a live read before writing it back. There's no such factor here: normalization happens at spread-time read, never written back, so there's nothing for two concurrent reinforcements of the *same* edge to race over beyond what a plain atomic increment already handles correctly.

### Migration

Add the column with `DEFAULT 1.0`. No reset, no backfill, no one-time `COUNT(*)` pass -- unlike heat's migration (replacing an existing unbounded quantity), this is a genuinely new quantity with a clean, already-correct starting value that reproduces today's behavior exactly until real usage moves it.

## What this buys

A hub document's spreading activation stops treating every neighbor as equally relevant. A neighbor that keeps genuinely being retrieved alongside it captures a growing share of that document's limited spread budget; a one-off or since-superseded link recedes toward negligible influence on its own, with no separate pruning pass and no row ever touched or removed. This closes the gap identified against Fractal Neurons' "links reinforced by use, weakened by disuse" framing (see the conversation that motivated this doc) without adopting their apparent literal-removal model -- daat's version of "falls away" is asymptotic and reversible (a quiet link that starts co-retrieving again just resumes gaining share), not a delete.

## Phased plan

Same shape as `doc/heat-decay-redesign.md`'s own phasing -- add the new signal alongside the old behavior first, verify it against real data, only then let it actually change ranking -- because this design is a straight read/write mechanism swap this time (no global invariant, no migration reset), the phases themselves are correspondingly smaller.

### Phase 1 -- design (this document)

Resolved: additive, unbounded `raw_strength` per edge (no conserved budget -- see "Why not literally reuse the heat-decay-redesign mechanism"); reinforcement piggybacks on the existing `co_retrieval_pairs` computation; weighting is a local, read-time normalization over one document's own neighbor set; no wall-clock decay anywhere. Pending review before Phase 2 starts.

### Phase 2 -- schema + reinforcement write, dark-launched (spread_activation unchanged)

- `ALTER TABLE document_link ADD COLUMN raw_strength REAL NOT NULL DEFAULT 1.0;` (`document.lua`'s `DOCUMENT_LINK_SCHEMA`, plus an `ensure_document_link_strength_column` migration helper matching the existing `ensure_document_link_source_column` pattern at `document.lua:70-81`).
- `knowledge.maybe_link_co_retrieved` (`knowledge.lua:799-817`) currently only branches on `document_link_exists(...) == false`. Add the other branch: when a pair from `co_retrieval_pairs` *does* already have a link, reinforce it. The actual primary key on `document_link` is `(from_document_id, link_text)`, not `(from_document_id, to_document_id)` (`document.lua:58-66`) -- `to_document_id` isn't guaranteed unique or even non-null for an authored link (a `[[title]]` reference can dangle before its target exists). A co-retrieval-sourced row is always created with a real, resolved `to_document_id` (`evaluate_co_retrieval_pair` inserts `doc_a.id, doc_b.id` directly), so matching on `from_document_id = ? AND to_document_id = ?` is safe for links this mechanism itself created, but `document_link_exists` (`knowledge.lua:756-...`) already has to check both directions since `linked_neighbors` treats the pair as undirected -- the reinforcement write needs the identical both-directions check, or it'll silently miss (and never reinforce) a co-retrieved pair whose link happens to have been authored in the opposite direction from what `co_retrieval_pairs`' `doc_a < doc_b` ordering would predict. `LINK_REINFORCEMENT_DELTA = 0.15`, a new constant next to `SPREADING_ACTIVATION_FACTOR`.
- `knowledge.spread_activation`/`document.spreading_delta` stay exactly as they are -- flat `/fan_count` split, unchanged, still what actually determines ranking. `raw_strength` accumulates in the background with no visible effect yet.
- **Verify:** a new test reinforces the same pair repeatedly via simulated co-retrieval and asserts `raw_strength` grows by the expected amount with no lost updates under concurrent calls (mirrors `tst/unit/document_pool.lua`'s `test_racing_reinforcements_of_the_same_document_never_lose_a_delta`, scoped to the atomic `document_link` update instead of `document`). Existing coverage (`tst/integration/knowledge.bats:207`, "spreading activation reinforces a retrieved document's linked neighbors, not just the exact hit") should pass completely unchanged in this phase, since nothing about spread behavior has moved yet.

### Phase 3 -- cut over spread_activation to weighted reads

- Extract the weighting math into a pure, DB-free function first -- `document.weighted_spreading_delta(base_delta, edge_strength, total_strength)` -- next to `document.spreading_delta`, the same layering `document.pool_effective_heat` already established for heat's own pure arithmetic (`heat-decay-redesign.md`'s Phase 3 notes, "the new `document.pool_effective_heat` pure-function tests"). Unit-testable with plain numbers, no DB, in `tst/unit/document.lua`.
- Extend `document.linked_neighbors` (`document.lua:432-441`) to return each neighbor's `raw_strength` alongside its `id` -- both branches of the existing `UNION` select from `document_link` already, so this is adding one column to a query that already touches the right table, not a new query.
- `knowledge.spread_activation` (`knowledge.lua:873-...`): sum the fetched `raw_strength` values once (`total_strength`), then call `document.weighted_spreading_delta` per neighbor instead of `document.spreading_delta`.
- **Verify:** `tst/integration/knowledge.bats:207` should still pass with *no* code changes to the test itself -- confirms the "backward-compatible degenerate case" (all edges still at `raw_strength = 1.0` in that test's fixture data) holds under real integration conditions, not just the arithmetic argument in this doc. Add a new integration test that reinforces one edge from a document with two or more neighbors (via repeated simulated co-retrieval, or a direct `raw_strength` fixture value) and asserts the reinforced neighbor's heat bump is now measurably larger than an unreinforced sibling's -- the actual behavior change this phase exists to deliver.
- Compare weighted-vs-flat spread scores against whatever real retrieval logs exist before/after cutover, the same "don't just trust the arithmetic, check real traffic" discipline `heat-decay-redesign.md` Phase 2/3 applied.

### Phase 4 -- open questions, not yet scoped

- Whether `LINK_REINFORCEMENT_DELTA = 0.15` (borrowed from `reinforcement_delta`'s own tier-0 floor, which has no real connection to edges) is the right magnitude for real traffic, or needs its own tuning independent of the document-heat constant it happens to match today.
- Whether edge strength is ever worth surfacing to a human (e.g. on `/knowledge`, alongside the existing tier/heat display) so a stale-but-still-present link is visible as such, not just invisibly deprioritized.
- Whether `raw_strength` should ever be reset for a link whose `source = 'co-retrieval'` review gets re-evaluated (`knowledge.record_link_review`) -- today a link, once created, is never re-adjudicated; this design doesn't change that, only what happens to a link that's already there.

## Critical files

- `src/document.lua` -- `document_link` schema (`58-66`), `ensure_document_link_source_column` (`70-81`, the migration-helper pattern to follow), `linked_neighbors` (`432-441`), `spreading_delta`/`SPREADING_ACTIVATION_FACTOR` (`453-462`)
- `src/knowledge.lua` -- `spread_activation` (`873-...`), `co_retrieval_pairs` (`714-735`), `maybe_link_co_retrieved` (`799-817`), `evaluate_co_retrieval_pair` (`819-848`, the canonical `doc_a.id < doc_b.id` ordering for co-retrieval-sourced links)
- `tst/integration/knowledge.bats:207` -- the existing spreading-activation regression test that must keep passing unchanged through Phase 2 and Phase 3
- `tst/unit/document_pool.lua` -- the concurrency-test pattern (`test_racing_reinforcements_of_the_same_document_never_lose_a_delta`) to mirror for the new `document_link` reinforcement write
- `doc/heat-decay-redesign.md` -- the document-level precedent this design deliberately diverges from, and why
- `doc/link-adjudication-alternatives.md` -- the separate, complementary question of how a link gets created in the first place, not addressed here
- `doc/architecture.md` -- "Knowledge pool" section, "Spreading activation"
