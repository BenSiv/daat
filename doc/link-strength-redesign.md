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

### Phase 2 -- schema + reinforcement write, dark-launched (spread_activation unchanged) (DONE)

- `ALTER TABLE document_link ADD COLUMN raw_strength REAL NOT NULL DEFAULT 1.0;` added via `ensure_document_link_strength_column` (`document.lua`, mirrors `ensure_document_link_source_column`'s existing pattern), called from `document.init_schema` alongside it.
- `knowledge.maybe_link_co_retrieved` now has both branches: no existing link still feeds `due_for_link_review`/possible creation exactly as before; an already-linked pair now calls the new `knowledge.reinforce_link_strength(db_path, doc_a_id, doc_b_id)`. `LINK_REINFORCEMENT_DELTA = 0.15`, next to the other co-retrieval constants.
- **The both-directions concern flagged during design was real and is handled**: `reinforce_link_strength`'s `UPDATE` matches `(from = a AND to = b) OR (from = b AND to = a)`, the identical predicate `document_link_exists` already uses -- confirmed necessary by a dedicated test (below), not just asserted in the doc.
- `knowledge.spread_activation`/`document.spreading_delta` are untouched -- flat `/fan_count` split still what determines ranking. `raw_strength` accumulates in the background with no visible effect yet.
- **Verified:** `tst/unit/document_link.lua` (new) -- reinforcement adds exactly the configured delta; a pair whose `document_link` row was authored in the *opposite* direction from how it's reinforced still gets found and updated; two sequential "racing" reinforcements of the same edge both land (a plain additive `UPDATE`, not a read-modify-write round trip in Lua, so this is confirming the design has no lost-update shape to begin with, not demonstrating a fix for one); reinforcing a pair with no existing link is a safe no-op, not an error. All 11 unit test files and 16/17 `tst/integration/knowledge.bats` cases pass (the 1 failure, "spreading activation reinforces a retrieved document's linked neighbors" at line 207, is confirmed pre-existing -- reproduces identically on `main` before this phase's changes, and checks the deprecated `heat` column `heat-decay-redesign.md` Phase 3 stopped writing to; unrelated to this work, already flagged earlier this session).

### Phase 3 -- cut over spread_activation to weighted reads (DONE)

- `document.weighted_spreading_delta(base_delta, edge_strength, total_strength)` replaces `document.spreading_delta` outright (the latter had exactly one call site, `spread_activation` -- once that call site moved, it was dead code, removed rather than left unused, same discipline `heat-decay-redesign.md` Phase 3 applied to `effective_heat`/`days_since`). Pure, DB-free, unit-tested with plain numbers in `tst/unit/document.lua` (degenerate-case match, reinforced-edge-gets-a-bigger-share, single-neighbor-caps-at-the-direct-hit-factor, zero/nil-total_strength-is-a-safe-no-op).
- `document.linked_neighbors` now returns `raw_strength` alongside `id` -- **not** a bare column addition to the existing `UNION`, which turned out to be a real correctness trap: `UNION` dedupes on the whole row, and a neighbor connected by two distinct `document_link` rows (an authored link plus a separately-created co-retrieval link between the same pair) would only have been silently collapsed to one row when `id` was the only column being compared. Rewritten as `UNION ALL` wrapped in an outer `SELECT id, SUM(raw_strength) ... GROUP BY id`, so a neighbor reached by more than one edge gets its strengths summed into one total rather than either row winning arbitrarily.
- `knowledge.spread_activation` sums the fetched `raw_strength` values once (`total_strength`), then calls `document.weighted_spreading_delta` per neighbor inside the loop instead of computing one flat `delta` before it.
- **Verified:** `tst/integration/knowledge.bats:207` (the original spreading-activation test) passes/fails identically before and after this phase -- its 1 failure is confirmed pre-existing and unrelated (checks the deprecated `heat` column, not this mechanism; see Phase 2's own verification note). Since that test doesn't actually exercise the new weighting (only one neighbor, so nothing to differentiate against), a new test was added specifically for the real behavior change: `tst/integration/knowledge.bats`, "spreading activation weights a reinforced link's neighbor more than an unreinforced sibling" -- two neighbors of the same retrieved document, one edge pre-reinforced via direct SQL before the retrieval, asserts the reinforced neighbor's recorded `knowledge_retrieval_document.reinforcement_delta` is strictly larger than its unreinforced sibling's. All 11 unit test files and 17/18 integration cases pass (same 1 pre-existing failure, count unrelated to this phase).

### Phase 4 -- open questions, not yet scoped

- Whether `LINK_REINFORCEMENT_DELTA = 0.15` (borrowed from `reinforcement_delta`'s own tier-0 floor, which has no real connection to edges) is the right magnitude for real traffic, or needs its own tuning independent of the document-heat constant it happens to match today.
- Whether edge strength is ever worth surfacing to a human (e.g. on `/knowledge`, alongside the existing tier/heat display) so a stale-but-still-present link is visible as such, not just invisibly deprioritized.
- Whether `raw_strength` should ever be reset for a link whose `source = 'co-retrieval'` review gets re-evaluated (`knowledge.record_link_review`) -- today a link, once created, is never re-adjudicated; this design doesn't change that, only what happens to a link that's already there.

## Critical files

- `src/document.lua` -- `document_link` schema, `ensure_document_link_strength_column`/`BASE_LINK_STRENGTH`, `linked_neighbors` (now `SUM(raw_strength) ... GROUP BY id`), `weighted_spreading_delta`/`SPREADING_ACTIVATION_FACTOR`
- `src/knowledge.lua` -- `spread_activation`, `reinforce_link_strength`/`LINK_REINFORCEMENT_DELTA`, `co_retrieval_pairs`, `maybe_link_co_retrieved`, `document_link_exists` (the both-directions predicate `reinforce_link_strength` mirrors), `evaluate_co_retrieval_pair` (the canonical `doc_a.id < doc_b.id` ordering for co-retrieval-sourced links)
- `tst/integration/knowledge.bats` -- "spreading activation reinforces a retrieved document's linked neighbors" (the pre-existing, unrelated failure) and "spreading activation weights a reinforced link's neighbor more than an unreinforced sibling" (the new Phase 3 behavior test)
- `tst/unit/document_link.lua` -- `reinforce_link_strength`'s own tests (delta correctness, both-directions matching, race safety, safe no-op)
- `tst/unit/document.lua` -- `weighted_spreading_delta`'s pure-function tests
- `doc/heat-decay-redesign.md` -- the document-level precedent this design deliberately diverges from, and why
- `doc/link-adjudication-alternatives.md` -- the separate, complementary question of how a link gets created in the first place, not addressed here
- `doc/architecture.md` -- "Knowledge pool" section, "Spreading activation"
