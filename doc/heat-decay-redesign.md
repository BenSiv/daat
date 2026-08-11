# Heat decay: from wall-clock time to a conserved pool budget

## Problem

Heat currently decays against calendar time, regardless of whether the
pool was actually used during that time. Two concrete failure modes:

- A quiet week and a heavily used week age an item's heat by exactly the
  same amount, even though only one of them reflects anything actually
  happening in the pool.
- A burst of repeated retrieval can push one item's heat arbitrarily high
  with no ceiling relative to the rest of the pool, since heat is a
  free-standing, unboundedly-growing value per item.

## Current design (as implemented)

- `document` gets `heat REAL DEFAULT 1.0`, `retrieval_count INTEGER
  DEFAULT 0`, `last_retrieved_at TEXT` (`src/document.lua:108-144`).
- `document.reinforcement_delta(tier)` (`src/document.lua:544-550`):
  `delta = 0.15 + TIER_WEIGHT[tier]`, `TIER_WEIGHT = {0.0, 0.10, 0.20,
  0.35}` for tiers 0-3 (`src/document.lua:514`).
- `knowledge.record_retrieval_hit` (`src/knowledge.lua:301-316`) applies
  that delta on every hit: `heat = heat + delta`, `retrieval_count =
  retrieval_count + 1`, `last_retrieved_at = now()`. Heat is monotonic --
  never decremented on write.
- `document.effective_heat(heat, last_retrieved_at)`
  (`src/document.lua:590-598`) computes the read-time decayed view:
  `effective_heat = heat * (0.5 ^ (days_since_last_retrieval /
  half_life))`, where `half_life` comes from
  `platform_heat_decay_half_life_days` (default 14 days,
  `doc/architecture.md:467`). The raw `heat` column is never rewritten by
  decay; only the read-time view decays.
- Two real call sites depend on `effective_heat`:
  - `knowledge.due_for_review` (`src/knowledge.lua:756-761`): `retrieval_
    count >= 2 or effective_heat >= 1.15`, gating whether a review pass
    re-checks a document's tier/dedup state.
  - `document.search_score` (`src/document.lua:908-909`): `final_score =
    final_score + (tier_weight * 10.0) + effective_heat`, added to
    ranking after the lexical/semantic relevance floor.

## Why this doesn't fit

Decay is driven purely by elapsed calendar time since `last_retrieved_at`,
not by any measure of how much has actually happened in the pool since.
That makes two items decay identically regardless of whether the
intervening time was idle or the busiest week the pool has ever seen, and
it means an item retrieved constantly for a short burst can reach a heat
level with no defined relationship to the rest of the pool's scale --
`effective_heat` values aren't directly comparable across items that were
retrieved at very different absolute rates.

## Proposed direction: a conserved heat budget

Treat the total heat across the whole pool as a conserved quantity
rather than a free-standing value that grows per item without bound.
Reinforcing one item transfers heat away from the rest of the pool,
proportionally, instead of manufacturing new heat from nothing. Heat
becomes a relative share of a total, and decay is driven by a context
span measured in retrievals rather than by calendar time -- a genuinely
idle pool has no usage event to redistribute against, so nothing decays
just because a clock ran.

## Design decisions (resolved)

- **Redistribution rule:** proportional. A document gives up heat in
  proportion to its own current share, never an even split. This is also
  what guarantees no document can ever be pushed negative.
- **Total budget size:** scales with pool size, not a fixed constant.
- **Context span:** every retrieval, by default. See "Cost" below for
  why this is affordable without the escape hatch it was conditioned on.
- **Migration of existing values:** reset, not a proportional remap from
  today's unbounded values.
- **Downstream call sites:** redefined in terms of the new
  `effective_heat`, not adapted to preserve the old one's exact scale.

## The formula

### Invariant

Total heat across all active (non-archived, non-merged) documents stays
exactly `N * BASE_HEAT`, where `N` is the active document count and
`BASE_HEAT = 1.0` (matching today's `heat REAL DEFAULT 1.0`, so a
freshly created, never-retrieved document reads the same under either
model).

### Avoiding an O(N) write per retrieval

Proportional redistribution means every *other* active document's heat
shrinks by the exact same multiplicative factor on any single
reinforcement event (derivation below) -- the shrink factor doesn't
depend on which document it is, only on the event itself. That means it
doesn't need to be written to every row. It can be tracked as one shared
multiplier and applied lazily the next time each document is actually
read or reinforced -- the same "compute the decay at read time, don't
rewrite it eagerly" pattern `effective_heat` already uses today, just
replacing the decay driver.

Two new pieces of state:

- One global row (see "New table" below): `pool_scale` (starts at
  `1.0`), `document_count` (`N`, maintained incrementally, never a
  `COUNT(*)` scan on the hot path).
- Two columns per document, replacing the plain `heat` column:
  `raw_heat` and `scale_at_write` -- the value `pool_scale` held at the
  moment `raw_heat` was last set.

A document's true current heat, at any moment, is:

```
effective_heat(doc) = doc.raw_heat * (pool_scale / doc.scale_at_write)
```

That single multiplication captures however much proportional shrink has
accumulated *elsewhere* since this document was last touched, with no
need to have visited every retrieval event that happened to other
documents in between.

### Reinforcement (a retrieval hit)

Document `X` is reinforced by `delta` (unchanged:
`document.reinforcement_delta(tier)`, still `0.15 + TIER_WEIGHT[tier]`
-- this redesign changes where the amount comes from, not how large it
is).

1. `X_eff = X.raw_heat * (pool_scale / X.scale_at_write)`, X's current
   true heat.
2. `T = document_count * BASE_HEAT`, the invariant total.
3. `f = 1 - delta / (T - X_eff)`, the shrink factor every *other*
   document experiences (derived below).
4. `pool_scale = pool_scale * f`, one global update, O(1).
5. `X.raw_heat = X_eff + delta`, `X.scale_at_write = pool_scale` (the
   *new*, post-update value, so X's stored value already reflects the
   shrink and isn't double-counted next time it's read).

Everyone else's row is untouched. The next time any other document `Y`
is read or reinforced, `Y.raw_heat * (pool_scale / Y.scale_at_write)`
transparently reflects this event's shrink, and every other event's
shrink since `Y` was last touched, with no per-event bookkeeping needed
on `Y`'s row.

**Why step 3 is correct:** proportional redistribution means `Y` gives
up `delta * (Y_eff / (T - X_eff))` of its own current heat (its share of
"everyone but X"). That is `Y_new = Y_eff * (1 - delta / (T - X_eff))`,
and the factor in parentheses doesn't mention `Y` at all, so it's
identical for every document except `X`. Summed across all of them, the
pool loses exactly `delta` from the rest and gains exactly `delta` on
`X`: `T` is unchanged, matching the invariant.

### Document creation

`document_count += 1` (`T` grows by exactly `BASE_HEAT` automatically,
since `T` is derived from `document_count`). New row: `raw_heat =
BASE_HEAT`, `scale_at_write = pool_scale` (current value, so it reads
back as exactly `1.0` until it's ever retrieved). No other row changes,
consistent with "total budget size: scales," and it reproduces today's
`DEFAULT 1.0` behavior exactly.

### Document deletion, archival, or merge (`duplicate_of`/`merged_into` set)

Order matters here: compute `X_eff` and `T` *before* touching
`document_count`, since both use the pre-departure count. To hold the
invariant exactly, the departing document's current heat has to be
returned to the survivors, using the same mechanism as reinforcement but
in reverse: survivors *gain* `X_eff - BASE_HEAT` collectively,
proportional to their own current share, where `X_eff` is the departing
document's heat at the moment it leaves:

```
X_eff = X.raw_heat * (pool_scale / X.scale_at_write)   -- before decrementing
T = document_count * BASE_HEAT                          -- before decrementing
f = 1 + (X_eff - BASE_HEAT) / (T - X_eff)
pool_scale = pool_scale * f
document_count = document_count - 1                     -- only now
```

**Worth flagging, not hiding:** if `X_eff > BASE_HEAT` (a hot document
leaving), survivors warm up slightly. If `X_eff < BASE_HEAT` (a cold,
rarely-touched document leaving, the common case for an unpromoted
duplicate), survivors actually cool slightly. Holding `T = N *
BASE_HEAT` exactly means removing a document that wasn't carrying its
"fair share" has to make up the shortfall from everyone else. This is a
real, if minor, consequence of an exact invariant, not a bug.

### Spreading activation to linked neighbors

`knowledge.spread_activation` (`src/knowledge.lua:855-879`) currently
does its own unconditional `UPDATE document SET heat = heat + %.17g ...`
directly on each linked neighbor (`src/knowledge.lua:868-871`), separate
from `record_retrieval_hit`'s own write. Under the conserved model this
has to route through the exact same reinforcement primitive above (each
neighbor bump is its own `reinforce(neighbor_id, spreading_delta)`
event, funded by the pool like any other), not a second, parallel place
that manufactures heat.

### New table

A single-row global-state table, alongside `knowledge.lua`'s other
hand-rolled bookkeeping tables (`knowledge_retrieval`, etc., defined
from `src/knowledge.lua:31` on):

```sql
CREATE TABLE IF NOT EXISTS knowledge_pool_state (
    id INTEGER PRIMARY KEY,
    pool_scale REAL NOT NULL DEFAULT 1.0,
    document_count INTEGER NOT NULL DEFAULT 0
);
```

Single row (`id = 1`), seeded once at migration time (see "Migration"
below).

### Concurrency

Every reinforcement, creation, and deletion event now touches this one
shared row. Under real concurrent traffic (this platform already runs
under Apache mod_cgid, see `doc/mariadb-migration.md`'s "genuinely
concurrent, multi-process web server") a naive read-then-write in
application code (read `pool_scale`, compute `f` in Lua, write it back)
is a real lost-update race: two concurrent reinforcements could both
read the same `pool_scale`, and whichever writes last silently discards
the other's shrink, breaking the conservation invariant.

The existing codebase already has the right primitive for this:
`record_retrieval_hit`'s own `UPDATE document SET heat = heat + %.17g
... WHERE id = %d` (`src/knowledge.lua:304-306`) is a single atomic
in-place arithmetic update, not a read-modify-write round trip.
`pool_scale`'s update needs the same shape:

```sql
UPDATE knowledge_pool_state SET pool_scale = pool_scale * ? WHERE id = 1;
```

Computing `f` from a value of `T`/`X_eff` that's allowed to be very
slightly stale is fine here (the invariant self-corrects on the next
event either way), as long as the multiplication itself is atomic and
never a separate read-then-write.

### Downstream call sites (search_score, due_for_review)

Both currently read `effective_heat` as an absolute decayed total. The
new `effective_heat` is computed differently (a proportional share of a
total that scales with pool size, rather than a wall-clock decay) but
lands in the same numeric neighborhood for a typical document, since
`BASE_HEAT = 1.0` matches today's default: an average, unremarkable
document reads close to `1.0` under either model. That means
`document.search_score`'s `+ effective_heat` term and
`knowledge.due_for_review`'s `effective_heat >= 1.15` threshold can
plausibly be left numerically unchanged as a first pass, but this needs
validating against real traffic, not assumed. That validation is exactly
what Phase 2's dark launch is for.

### Cost, and the "unless too costly" fallback

Every event above (reinforcement, creation, deletion) is O(1): one
document row, one shared state row, no scan across the rest of the
pool. Redistributing on every single retrieval is therefore the default,
not the exception. If real measurement in Phase 2 shows the shared
state row is a write-contention hotspot under concurrent load (row-lock
waits, not computational cost), the fallback is batching: accumulate
reinforcement events per search/chat session in memory and apply one
combined update to `knowledge_pool_state` at the end of the session,
instead of one update per hit within it. This is a fallback to reach
for if Phase 2's real traffic shows it's needed, not a default.

### Migration of existing values

At cutover, every document resets: `raw_heat = BASE_HEAT`,
`scale_at_write = 1.0` (matching a freshly-seeded `pool_scale = 1.0`),
and `document_count` seeded from a one-time `COUNT(*)` over active
documents (the only place a full scan happens, once, at migration).
`retrieval_count` is untouched: it's a separate, still-meaningful
lifetime counter, not part of the heat model, and stays exactly as-is.

## Phased plan

### Phase 1 -- design (this document)
Resolved: proportional redistribution, a total that scales with pool
size, per-retrieval redistribution, a hard reset at migration, and both
downstream call sites redefined in terms of the new `effective_heat`.
Pending review before Phase 2 starts.

### Phase 2 -- dark-launch alongside the existing columns (DONE)
Added `raw_heat`, `scale_at_write`, and `knowledge_pool_state` alongside
today's `heat`/`last_retrieved_at`. The new `effective_heat` is computed
on every reinforcement (`knowledge.record_retrieval_hit`,
`knowledge.spread_activation`), creation (`document.create_page`), and
departure event (merge via `knowledge.duplication_status`, and plain
archival/unarchival via `document.on_entity_archived`/
`on_entity_unarchived`, dispatched from every `entity.archive`/
`entity.unarchive` call site) -- without changing `search_score` or
`due_for_review`, so both models can be compared against real traffic
before cutover.

Verified: `tst/unit/document_pool.lua` asserts the conservation
invariant directly (reinforcement, creation, departure, and the
pool-scale-drift edge case all hold); the full integration suite and a
`git stash`-based before/after comparison confirmed zero regressions.

### Phase 3 -- cut over, remove the old decay path (DONE)

`document.search_score` and `knowledge.due_for_review` (via
`knowledge.get_document`) now both read `document.pool_effective_heat`
exclusively. `knowledge.record_retrieval_hit`/`spread_activation` no
longer write the old `heat`/`last_retrieved_at` columns at all --
`knowledge.spread_activation`'s neighbor bumps were already routed
through `document.reinforce_pool_heat` since Phase 2. `document.
effective_heat`/`days_since` and the `platform_heat_decay_half_life_days`
config are removed entirely (dead code, not just unused).

**Deliberate scope decision, deviating from this phase's original
wording:** the `heat`/`last_retrieved_at` *columns* were not dropped
from the schema. This already-production system's schema changes are
harder to reverse than a code change; leaving the columns in place,
simply no longer written, costs nothing meaningful and preserves a fast
rollback path (revert the code, the old data is still there, no
backfill needed) if Phase 3 ever needs to be undone quickly. Genuinely
dropping them is a fine follow-up once the new model has run
uncontested for a while, not a requirement of this phase.

`knowledge.list_documents`/`reviewed_documents` needed a real change
beyond a find-and-replace: their SQL `ORDER BY heat DESC` no longer
approximates the true ranking (raw_heat alone isn't comparable across
rows without each one's own `scale_at_write`, which differs per row).
Both now fetch unordered (no `LIMIT` on either query, so nothing is lost)
and re-sort in Lua by the computed `pool_effective_heat`, the same way
`document.search` already scored in application code.

**Verified**: all 8 unit test files pass (including the new
`document.pool_effective_heat` pure-function tests in
`tst/unit/document.lua`, replacing the removed `effective_heat`/
`days_since` tests). A real-traffic demo script
(`document.create_page` -> `knowledge.search_and_log`, the actual
production path, not a synthetic harness) produced identical numbers to
the Phase 2 dark-launch run and confirmed the conservation invariant
under live ranking. `entity.bats`/`document.bats`/`knowledge.bats`/
`knowledge_context.bats` show byte-for-byte the same 25 pre-existing
(environment-caused, not code-caused) failures before and after this
phase.

**Not done, and worth naming rather than leaving implicit**: the
same-document concurrent-reinforcement race noted in
`document.reinforce_pool_heat`'s own comment is now live, not just a
dark-launch curiosity. Low risk in practice (needs two truly
simultaneous retrievals of the exact same document), but a real gap to
close, not a dark-launch footnote anymore.

## Critical files
- `/root/projects/platform-wip/src/document.lua` -- `heat`/`retrieval_
  count`/`last_retrieved_at` columns (heat to become `raw_heat`/
  `scale_at_write`), `reinforcement_delta`, `effective_heat`,
  `search_score`, and the Phase 2 pool primitives (`ensure_pool_state`,
  `register_pool_document`, `reinforce_pool_heat`, `return_pool_heat`,
  `on_entity_archived`/`on_entity_unarchived`)
- `/root/projects/platform-wip/src/knowledge.lua` --
  `record_retrieval_hit` (`301-316`), `spread_activation` (`855-879`),
  `due_for_review` (`756-761`), `review_retrieval`, `duplication_status`
  (merge departure), `KNOWLEDGE_SCHEMA` (new `knowledge_pool_state`
  table)
- `/root/projects/platform-wip/src/entity.lua`,
  `/root/projects/platform-wip/src/cgi.lua`,
  `/root/projects/platform-wip/src/agent.lua` -- every `entity.archive`/
  `entity.unarchive` call site, each now calling
  `document.on_entity_archived`/`on_entity_unarchived` on success.
  `entity.lua`'s own CLI dispatcher uses a lazy, function-scoped
  `require("document")` rather than a module-top-level one, since
  `entity.lua` must never require `document.lua` (the reverse already
  holds)
- `/root/projects/platform-wip/tst/unit/document_pool.lua` -- the
  conservation-invariant tests
- `/root/projects/platform-wip/doc/architecture.md` --
  `platform_heat_decay_half_life_days` config entry, to be removed in
  Phase 3
