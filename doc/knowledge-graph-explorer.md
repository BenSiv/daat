# Knowledge graph explorer: an Obsidian-style visual map of the pool

## What this is

An interactive, in-browser visualization of the knowledge pool's own `document_link` graph -- nodes are documents, sized by heat; edges are links, weighted by strength (`doc/link-strength-redesign.md`). The same visual grammar as that doc's own worked-example diagram (line weight = edge strength), rendered for real from live data instead of a hand-picked example, and explorable the way Obsidian's own graph view is: pan, zoom, click a node to open that document.

## Where it lives

Follows `/knowledge`'s own established pattern exactly (`src/cgi.lua:816-853`): a new route, `/knowledge-graph`, gated the identical Setup-or-Admin check every other `/knowledge*` route already uses, wrapped in the same `html.page_shell`, linked from `/knowledge`'s own landing page as another drill-down view alongside `/knowledge-documents` and `/knowledge-reviewed` -- not a new top-level nav-rail entry, the same "one link away, not a dedicated icon" reasoning `doc/architecture.md`'s "Chat" section already applies to `/chat`.

**Open question, not resolved here:** `/knowledge`'s existing pages are Setup/Admin-gated because they're pool-health/analytics views. A graph *explorer* is arguably a different kind of thing -- closer to a navigation aid any user browsing their own accessible documents would want, the way Obsidian's graph view isn't an admin feature in Obsidian itself. Keeping the same gate is the conservative default (stated here, not silently assumed); loosening it to any authenticated user is a real, separate product decision this doc isn't making.

## Data: a new JSON endpoint, not a new page render

The frontend needs the graph as data, not server-rendered HTML -- `GET /knowledge-graph-data`, JSON, same gate as `/knowledge-graph` itself:

```json
{
  "nodes": [{"id": 12, "title": "Bioreactor SOP", "tier": 2, "heat": 1.34}, ...],
  "edges": [{"from": 12, "to": 7, "strength": 2.0}, ...]
}
```

- `heat` here is `document.pool_effective_heat`, the same live-computed value `search_score`/`due_for_review` already read -- no new heat representation.
- `edges` comes from `document_link` directly, `raw_strength` already on the row -- no aggregation needed beyond what's already stored (unlike `linked_neighbors`, which sums per-neighbor for one document's own spread; here every edge is its own row in the response, since the graph needs the full structure, not one document's local view of it).
- Excludes archived documents and documents `merged_into` another (dedupe, same as everywhere else in the pool reads them) -- a graph node for something that's been folded into a canonical duplicate would be visual noise pointing at content that no longer independently exists.

## Rendering: vanilla, no new dependency

Consistent with `doc/why-luam.md`'s "Minimal dependencies" section (`lib/`, vendored not pulled from a package manager) and `vnd/`'s existing precedent (the Toast UI Editor bundle, checked in, served via `cgi.lua`'s own `/vendor?name=X` route, no CDN) -- this should not reach for d3-force or a similar charting library. A basic force-directed layout (repulsion between all node pairs, spring attraction along edges, simple velocity damping) is a few hundred lines of plain JS and entirely sufficient at the scale a single deployment's document pool actually reaches; pulling in a graph-layout library to avoid writing that would be adding a real dependency -- its own versioning, its own bug surface -- for a problem this size doesn't need one to solve. Canvas rendering (not SVG-per-node), since node/edge counts could reach into the hundreds and a canvas redraw scales better than hundreds of live DOM elements under continuous simulation.

**Visual mapping, directly from the two mechanisms this is visualizing:**
- Node radius: scaled from `heat` (a hot document reads as a bigger circle -- directly legible, no legend needed to explain "bigger = more relevant lately").
- Edge width and opacity: scaled from `strength` (a well-worn connection reads as a thicker, more solid line; a link that's never been reinforced past `BASE_LINK_STRENGTH` reads as thin and faint -- the same "fades, never deleted" property `doc/link-strength-redesign.md` describes, made visible rather than just true in the data).
- Node color: tier, reusing `html.KNOWLEDGE_TIER_COLORS` -- a validated ordinal ramp (one hue, monotone lightness, light->dark as maturity rises) now shared with `/knowledge`'s own tier tiles (`html.render_knowledge_pool`'s `border-left` accent), themeable per-deployment via `theme.lua`'s `colors.tier_0`..`colors.tier_3` (`config.THEME_COLOR_KEYS`), same override convention as every other themed color. The graph explorer should read the same `--platform-tier-N` custom properties rather than hardcoding the fallback hexes a second time, so a deployment overriding its tier colors doesn't need to configure them twice.
- Click: navigates to that document, same as clicking a title anywhere else in the app.

## Phased plan

### Phase 1 -- design (this document)
Resolved: route/gating follows `/knowledge`'s own precedent, data via a new JSON endpoint (not server-rendered), vanilla-JS force layout on canvas (no new dependency), node size = heat / edge weight = strength / node color = tier. Open: whether the Setup/Admin gate is actually right for an explorer rather than an analytics page (see above). Pending review before Phase 2 starts.

### Phase 2 -- data endpoint + static (non-interactive) render (DONE)
`GET /knowledge-graph-data` (`knowledge.graph_nodes`/`document.graph_edges`) returns every active document (not `list_documents`' narrower "pool member" set -- a document can carry a real `[[title]]` edge without ever having been searched) and every `document_link` edge whose two endpoints are both active, as flat JSON. `/knowledge-graph` renders a canvas page that fetches this client-side, lays it out with a small hand-rolled force simulation (repulsion + spring attraction + center pull, ~250 iterations, settles once on load), and draws it -- no drag/pan/zoom/click-to-navigate yet, exactly this phase's scope. Node radius scales with heat, edge width/opacity with strength, node color reuses `KNOWLEDGE_TIER_COLORS` (the same ramp `/knowledge`'s own tier tiles use) via the shared `--platform-tier-N` custom properties -- no second palette. Linked from `/knowledge`'s own landing page, gated identically to every other `/knowledge*` route.

**Verified:** 4 new integration tests (`tst/integration/knowledge.bats`) -- the page renders for a Setup/Admin user and is forbidden for a plain one (mirrors `/knowledge`'s own two tests exactly), and the data endpoint returns real node titles and a real edge with a numeric `strength` for two documents connected by an actual `[[title]]` link, not just a shape check against empty data. All 11 unit test files and 21/22 integration tests pass (1 pre-existing, unrelated failure, unchanged).

### Phase 3 -- interaction (DONE)
Pan (drag empty canvas), zoom (scroll wheel, cursor-anchored so the point under the pointer stays put), drag-to-reposition, and click-to-navigate (mouse-down-and-up on a node with no drag in between opens `document?entity_id=<id>`, same URL convention `.platform-entity-ref` links already use elsewhere). Implemented as a screen-space camera (`{x, y, scale}`) over the same "world" coordinates the simulation below produces -- only how that world is projected changes via `ctx.setTransform`, so pan/zoom add no state that has to stay in sync with the fetched graph. A "Reset view" link next to the legend snaps the camera back to identity, since pan/zoom are otherwise unbounded.

Hover adds a small fixed-position tooltip (not itself scoped here, but the natural complement once pointer interaction exists at all): a node shows its title and heat; an edge -- hit-tested via point-to-segment distance, a screen-pixel-constant threshold divided by the current zoom -- shows both endpoint titles and the edge's `raw_strength`. Node hover takes priority over edge hover where they overlap, matching draw order (edges under, nodes on top).

**Live physics, not a one-shot layout.** The force simulation (repulsion + spring + center pull + damping) originally ran as a fixed 250-iteration batch at load, then froze -- dragging a node just moved that one node in isolation. It now runs continuously via `requestAnimationFrame`, sleeping once average per-node kinetic energy drops below a threshold and waking again on drag (the same "settle, then idle until disturbed" shape `d3-force`'s alpha decay uses). A dragged node is pinned (`fixed = true`, skipped by force integration) so the mouse fully controls it, but its neighbors still feel its repulsion/spring pull each frame and react live; releasing it un-pins and wakes the sim so it settles back in. `layout()` still does a quick synchronous batch first so the initial paint isn't a chaotic scatter, then hands off to the live loop.

The sleep check is deliberately an *average* over node count, not the raw sum -- an early version summed every node's kinetic energy against one fixed threshold, which scales with pool size regardless of how settled any individual node actually is, so on a real-sized pool the sum could sit above the threshold indefinitely and the sim would never actually go idle (visibly "still running" minutes later, not just slow).

**Settled positions persist per browser.** `layout()` seeds from a cached `{id: {x, y}}` map in `localStorage` (`platform-kg-layout-v1`) when one exists, instead of always randomizing from scratch -- a fully- or mostly-cached layout starts near equilibrium, so the pre-settle batch shrinks (120 iterations only for a from-scratch or mostly-new-nodes layout, 20 otherwise) and the live loop goes idle almost immediately. `simLoop` saves the current positions back to the cache every time it goes idle, including after a manual drag resettles, so a rearrangement sticks for the next visit too. A node absent from the cache (new since the last visit) spawns near the average position of any already-positioned neighbor rather than a random spot, falling back to fully random only when it has no positioned neighbor either. This is per-viewer-browser only, not shared across users or synced to the server -- purely a return-visit convenience layered on top of data that always still comes fresh from `/knowledge-graph-data`, wrapped in try/catch since private browsing or a disabled/full store should degrade to "no cache," never break the page.

Considered and rejected: extracting this as a standalone reusable JS asset (or a separate library outside daat entirely). This codebase's only precedent for shared JS is a same-file Lua function returning a self-contained `<script>` block (`html.popover_js`, `platform_common_js`) -- never a standalone static file; `vnd/` and its `/vendor` route are explicitly for third-party code, not in-house modules. With exactly one consumer today and no second page needing generic force-directed layout, splitting it out now would be solving a reuse problem that doesn't exist yet, against `doc/why-luam.md`'s own "minimal dependencies"/don't-add-a-graph-layout-dependency reasoning this feature was designed under in the first place. If a second consumer shows up, the existing `html.popover_js`-style pattern (a separate Lua function producing its own `<script>` block) is the established, cheap way to share it -- no new infrastructure needed.

**Verified:** manual check against a real deployment's pool (drag, pan, zoom, tooltip content, reset, click-through to a document) -- no new automated coverage, since bats' CLI/CGI harness has no way to drive canvas mouse/wheel events; `tst/integration/knowledge.bats`'s existing two page-renders-vs-forbidden tests already cover that the route itself still serves correctly. Full suite otherwise unchanged.

### Phase 4 -- open, not yet scoped
- Filtering (by tier, by folder, by date range) -- Obsidian has this; whether it's worth the added UI surface here depends on how large real pools actually get.
- Whether/how to represent `source` (`authored` vs `co-retrieval`) visually -- distinct from strength, but potentially useful context (e.g. dashed vs solid).
- Performance ceiling: at what node/edge count does a hand-rolled canvas force simulation stop being smooth, and is that ceiling ever actually reached by a real deployment's pool size.

## Critical files
- `src/cgi.lua` -- `/knowledge-graph` and `/knowledge-graph-data` routes, mirroring `/knowledge`/`/knowledge-documents`'s existing gating
- `src/knowledge.lua` -- `graph_nodes` (every active document + effective heat, not the narrower `list_documents`/`KNOWLEDGE_MEMBER_WHERE` set)
- `src/document.lua` -- `graph_edges` (every `document_link` row between two active documents, flat, no per-neighbor aggregation the way `linked_neighbors` needs)
- `src/html.lua` -- `render_knowledge_graph` (canvas + inline force-layout script), `KNOWLEDGE_TIER_COLORS` (reused for node color)
- `tst/integration/knowledge.bats` -- the 4 Phase 2 tests (render/gate for `/knowledge-graph`, render/gate for `/knowledge-graph-data`)
- `doc/link-strength-redesign.md` -- the mechanism this visualizes; its own "Worked example" section's diagram uses the identical visual grammar (line weight = strength) this explorer renders for real
- `doc/architecture.md` -- `/knowledge`'s existing routes and gating, the pattern this follows

## Still open (Phase 3+)
- Pan, zoom, drag-to-reposition, click-to-navigate -- none implemented yet.
- Filtering, `source` (`authored` vs `co-retrieval`) visual distinction, performance at real scale -- Phase 4, unscoped.
- Whether the Setup/Admin gate is actually right for an explorer vs. an analytics page -- still an open product decision, not resolved by shipping Phase 2 with the conservative default.
