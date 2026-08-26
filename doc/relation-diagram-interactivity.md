# Entity relation diagram: draggable/rearrangeable boxes

## Phase 1 -- drag-to-reposition (DONE)

`html.render_relation_diagram` (`src/html.lua:2232-2385`, backing `GET /data`, `src/cgi.lua:787-799`) renders `schema.relationships()`'s entity-type graph as an inline SVG ERD: each entity type is a box listing its real fields, edges connect the specific referencing field's row to the target type's `id` row with cardinality labels. Layout is still a deterministic, server-computed "shortest-column-first" packing (`src/html.lua:2260-2284`) -- the three open questions below resolved against plain drag, no physics.

Resolved, and why:
- **SVG-native drag, not canvas.** Each box is a real `<g class="platform-diagram-node">`; dragging just updates its own `transform="translate(dx,dy)"` and its children (rect, field rows) move for free. No hit-testing code needed at all -- the browser's own DOM event targeting does it.
- **No physics on load.** The packed-grid layout is already a sane starting point (unlike the knowledge graph's arbitrary document pool), so a fresh page load is still plain, instant, deterministic placement -- physics is opt-in (Phase 2, below), never runs automatically.
- **Edges follow their anchored row, not a box centroid.** Each edge's original `x1/y1/x2/y2` (and its two cardinality-label positions) are captured once at load (`edge._platformOrig`) and re-derived every drag frame as `original + the relevant endpoint box's current offset` -- so a line anchored to one specific field row tracks that row's box precisely, even when the *other* end's box has also been dragged independently.

Same `localStorage` persistence convention as `/knowledge-graph` (`platform-relation-diagram-layout-v1`, a browser-local `{type: {dx, dy}}` map, restored on load and saved on drag-release) -- per-viewer only, never shared/synced, degrades silently to "no cache" under private browsing or a disabled store. Click-to-browse (mouse-down-and-up with no movement in between) and the existing hover-to-highlight-relations behavior are both unchanged -- drag only kicks in once the pointer actually moves past a small threshold, same distinguishing mechanism `/knowledge-graph`'s click-vs-drag uses.

## Phase 2 -- auto-arrange (DONE)

An "Auto-arrange" button next to the hint text runs a force-directed pass on request -- shortens edges and, as an emergent property of spreading connected clusters apart, tends to reduce crossings. Not a guaranteed crossing-minimizer (that's a much harder graph-theoretic problem); this is the same heuristic-quality tool the knowledge graph uses, applied here.

Deliberately **not** identical to the knowledge graph's simulation:
- **Starts from the current positions, not a random scatter.** Auto-arrange refines wherever boxes already are (the packed grid on first use, or a prior manual/auto arrangement) instead of randomizing first -- runs on request rather than on every load specifically so it never clobbers a manual drag arrangement unasked, and starting from an already-reasonable layout means the settle is short, sidestepping the random-scatter "explosive first frame" and multi-minute settle the knowledge graph had to fix its way through.
- **AABB-overlap separation, not point/circle repulsion.** Boxes vary a lot in height (field count) at a fixed width; treating them as point/circle sources like the knowledge graph's documents would either crowd tall boxes or over-space short ones at the same "radius." Overlapping pairs (within a margin) get pushed apart along whichever axis has less overlap -- a standard rectangle-separation technique, not a hard non-overlap guarantee, but far closer to one than point repulsion at this size scale.
- **Springs pull box centers together** (target rest length tuned to this diagram's box-width scale, not the knowledge graph's small-node scale), same per-node-average energy-sleep threshold (the bug already fixed there: a raw summed threshold doesn't scale with node count and can run indefinitely).

Same persistence as Phase 1 -- the result is saved to the same cache and survives reload, indistinguishable from a manual arrangement to anything that reads it back.

**Verified:** full suite (`./bld/test.sh`) stayed green -- no new automated coverage (same bats limitation as Phase 1 and the knowledge graph); manual check covers auto-arrange on a real schema (edges visibly shorten, boxes separate without overlap, settles quickly since it starts from the packed grid), and that dragging still works normally afterward.
