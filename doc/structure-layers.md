# Structure layers: content, placement, derived

Status: design, agreed 2026-09-27. Nothing here is built yet. It supersedes the "filtering" item of [knowledge-graph-explorer.md](knowledge-graph-explorer.md)'s Phase 4.

daat organizes documents with three separate mechanisms, each with exactly one job. **Content** carries knowledge, **placement** gives the explorer a stable tree, and **derived** data (tier, heat, tags) is recomputed from content and usage, with a manual override that survives recomputes. Each view reads one mechanism: the explorer reads placement, the graph draws content links and colours or filters by derived data, and nothing reads placement as knowledge.

## Why

Before this, the three were mixed without a rule. A "folder" is just a document other documents name as `parent_id`: there is no folder type, so the role only shows up as a side effect. The knowledge graph draws every active document as a node but only `[[links]]` as edges. Folders therefore appear as unconnected dots on its outer ring. There were no tags or other cross-cutting subjects, only the agent's `tier` and usage `heat`.

celleste-lims prod on 2026-09-27, 3,064 active documents:

| Role | Has children | Has content | Count |
|---|---|---|---|
| Folder | yes | no | 255 (Literature 1,683 children, Knowledge Pool 398, Experiment Views 226, Experiments 220, ...) |
| Parent page with its own text | yes | yes | 1 (Celleste Pedia) |
| Empty page | no | no | 0 |
| Ordinary document | no | yes | 2,808 |

## The three layers

| Layer | What | Set by | Read by |
|---|---|---|---|
| Content | text and `[[links]]` | people and the agent, by writing | knowledge; graph edges; retrieval |
| Placement | `parent_id` | people only, deliberately | the explorer tree only |
| Derived | `tier`, `heat`, tags | recomputes from content and usage; manual overrides win | graph colour and filters, pool review, search facets |

**Content** is unchanged: knowledge lives only in content (see [document-link-flow.md](document-link-flow.md)).

**Placement** is stable structure for browsing, like a file system. It isn't derived and isn't content-dependent. Nothing infers it, and nothing reads it as a claim about meaning. Creation paths may choose an initial parent (imports under Literature, the agent's output under Knowledge Pool), but after that only a person moves a document. Placement is the one deliberate exception to "everything from content", because where a document lives says nothing about what it means.

**Derived** data is anything daat computes about documents rather than being told. `tier` and `heat` already work this way. Tags join them. A derived value can always be recomputed, and a person's manual override is stored separately so a recompute never undoes it.

## Graph view

- **Colour by:** tier or tag (and none).
- **Filter by:** tier or tag.
- **Hide orphans:** a toggle, off by default. An orphan is a node with no edges. This also takes every folder out of the view, since folders have no links, without any rule about what a folder is.

The first two tier options and the orphan toggle need no new data, so they can ship before tags exist.

## Tags

A tag is a named group of documents about the same subject. Tags are derived, not written in content. They're recomputed by clustering, and writing them into the text would rewrite documents on every run.

- **Computed:** by clustering document embeddings (whole-document, `document_embedding`). This runs in a daat extension, not in core: core stores and shows tags, while the clustering method is replaceable.
- **Named:** one model call per cluster, from its most central titles. Naming is a genuine judgment call, which is where daat uses a model (rule-based by default everywhere else).
- **Stable across recomputes:** a new cluster inherits an existing tag's name when their members mostly overlap, so tags don't reshuffle on every run.
- **Manual override:** a person can add or remove a tag on a document, or rename a tag. Overrides are stored apart from computed membership and win on the next recompute.

Whole-document embeddings measure subject, which is what a tag is. They are not how daat judges whether two documents share an idea. Measured on 100 human-reviewed co-retrieval verdicts (2026-09-26, 12 accepted), whole-document similarity separated accepted from rejected pairs with AUC 0.93, mostly because accepted pairs share a subject. The best matching passage pair did as well (AUC 0.91) while also covering a small shared idea inside two documents on different subjects. That makes passages the right basis for connections, and whole documents the right basis for tags.

### Open: one tag per document, or several

Undecided; needs a closer look at the tradeoffs before building.

| | One tag (hard clustering) | Several tags (soft membership or overlapping topics) |
|---|---|---|
| Graph colouring | One colour per node, a clean read | Needs a primary tag for colour, or a multi-colour node |
| Filtering | Simple partition | More useful: a document shows up under each subject it covers |
| Fit to real documents | Poor for reviews and theses spanning topics | Good |
| Stability across recomputes | Easier to match clusters one to one | Harder: memberships shift at the margins |
| Manual override | Move to another tag | Add or remove; more to keep consistent |
| Computation | k-means or HDBSCAN-style clustering | Membership above a similarity threshold to each cluster centre, or topic modelling |

A middle path worth evaluating: one computed primary tag used for colour, plus manual extra tags.

## Prerequisites

1. **Embedding coverage:** 1,670 active documents in celleste-lims prod have no embedding, mostly imported papers. Run `daat repair embeddings`, then make save-time embedding failures visible instead of silent (`document.reindex_embedding` is best-effort).
2. **Extension capabilities** (see [extensibility.md](extensibility.md), "What extensions cannot do today"):
    - reading embeddings, which aren't entities, so `ctx.query` can't reach them;
    - writing derived tags through `ctx`;
    - a scheduled run. After-hooks react to writes and manual triggers must return quickly, and neither fits a periodic recompute.

## Phases

1. Graph controls on existing data: colour and filter by tier, hide orphans (off by default).
2. Tag storage and manual tags, and tags in the graph's colour and filter controls.
3. The embedding backfill and visible failures, then the extension capabilities, then the clustering extension with naming and stable matching.

The one-or-several question has to be settled before phase 2 fixes the storage shape.
