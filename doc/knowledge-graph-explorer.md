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

### Phase 2 -- data endpoint + static (non-interactive) render
`GET /knowledge-graph-data`, and a first render that lays out and draws the graph but doesn't yet support drag/pan/zoom -- gets the data plumbing and the visual mapping (size/width/opacity/color) right and checkable against real data before adding interaction on top.

### Phase 3 -- interaction
Pan, zoom, drag-to-reposition, click-to-navigate. Click behavior is simple (a real link, no JS routing framework); pan/zoom is the part actually worth prototyping against a real, sizable document pool before considering it done, since layout quality at real scale is the part a hand-rolled force simulation is most likely to need tuning on.

### Phase 4 -- open, not yet scoped
- Filtering (by tier, by folder, by date range) -- Obsidian has this; whether it's worth the added UI surface here depends on how large real pools actually get.
- Whether/how to represent `source` (`authored` vs `co-retrieval`) visually -- distinct from strength, but potentially useful context (e.g. dashed vs solid).
- Performance ceiling: at what node/edge count does a hand-rolled canvas force simulation stop being smooth, and is that ceiling ever actually reached by a real deployment's pool size.

## Critical files (once implementation starts)
- `src/cgi.lua` -- new `/knowledge-graph` and `/knowledge-graph-data` routes, mirroring `/knowledge`/`/knowledge-documents`'s existing gating (`816-853`)
- `src/document.lua` -- `pool_effective_heat` (node heat), `document_link`/`raw_strength` (edges, no new query logic beyond a plain `SELECT`)
- `src/html.lua` -- a new `render_knowledge_graph` page shell (the canvas + script tag), following `render_knowledge_pool`'s own pattern
- `vnd/` -- if the force-simulation JS grows large enough to want its own file rather than living inline, follows the existing vendored-asset convention (though this would be first-party JS, not a third-party bundle, so may not belong there specifically -- worth deciding at implementation time, not guessed here)
- `doc/link-strength-redesign.md` -- the mechanism this visualizes; its own "Worked example" section's diagram uses the identical visual grammar (line weight = strength) this explorer renders for real
- `doc/architecture.md` -- `/knowledge`'s existing routes and gating, the pattern this follows
