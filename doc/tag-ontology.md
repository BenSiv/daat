# Tag ontology: tags the data defines and the agent maintains

Status: proposal, 2026-10-02 (Ben); placement and phases revised 2026-10-04. Builds on [structure-layers.md](structure-layers.md)'s tags; only `tag.parent` exists so far (daat e7f8eb8). Tags are applied today by an outside batch job (`cluster_tags.py` in the deployment's own repo); this plan moves their upkeep into daat.

Today a tag is a flat cluster label: a hand-picked count (`k`) and a one-off name. The goal: the data decides how many tags there are and how they nest, the agent names, describes and relates them, and the user mostly just sees them, the same way tiers, distillation and connections already maintain themselves through usage. A user shouldn't need to know how any of it works, and the UI shouldn't grow to expose it.

## Three concepts, one word each

| | Folder | `[[link]]` | `#tag` |
|---|---|---|---|
| Answers | where does it live? | what does it point to? | what is it about? |
| Per document | exactly one | any number | a few |
| Set by | a person, by hand | a person or the agent, in the text | mostly automatic; a person can add one in the text |
| Shown as | the explorer tree | lines in the graph | colours in the graph, chips on a document |

These never stand in for each other. A folder is placement only and nothing infers meaning from it ([structure-layers.md](structure-layers.md)). A link is an edge between two documents. A tag is a subject on a group of documents: never a document, never a node, never an edge, and never written into a document's text by the system. Tags never look like folders: there's no tag tree to browse and no path syntax.

The user-facing word is **tag**, nothing else. A tag can have a broader tag ("Cocoa › Fermentation"); there's no second word for that ("subject", "group", "level", "cluster" are internal).

## What the user sees and does

- **On a document:** its tags as chips, a broader tag before it when there is one ("Cocoa › Fermentation"). A chip opens the tag.
- **A tag's page:** its description, its documents, and "see also" tags. Actions: rename, edit the description. That's all.
- **Tags page:** the list of tags, grouped under their broader tags, with document counts. A list, not an explorer.
- **Graph:** colour by tag (the broader tag) or by sub-tag; the legend hides and shows tags (built).
- **In the text:** `#tag` adds a tag to a document, as `[[link]]` adds a link (below).
- **In chat:** the agent can answer by tag ("what do we have on fermentation?"). When it thinks two tags are the same, or one covers two unrelated things, it says so in chat and asks, through the same approval as any other change it proposes.

Nothing else is user-facing: no recompute button, no proposals queue, no scores or plan reviews. An admin sees them through the CLI and the ledger: every split, merge and rename is an ordinary entity write.

### `#tag` in text

- **Syntax:** `#` then a letter, then letters, digits, `-` or `_` (`#fermentation`, `#cocoa-butter`); a tag whose name has spaces is written with `-` (`#cocoa-bean-fermentation` = "Cocoa bean fermentation"). Not a tag: headings (`# Title`), code, URL fragments (`page#section`), `#123`. No `#a/b` paths: how tags nest is the system's job, and a path would look like a folder.
- **On save,** next to `document.sync_links`: each `#tag` becomes a membership the person asserted (`decision = pinned`, `via = text`); deleting it from the text removes it. An unknown tag is created, as a `[[link]]` to a page that doesn't exist yet waits for it.
- **It holds while it's in the text:** recomputes never remove it, and it wins over a removal elsewhere.
- **Shown** as a chip, never a link.
- The agent may write `#tags` in documents it writes, through the same approval as the rest of the write.

## What runs on its own

- **Tags and how they nest**, from the data (below), kept up incrementally: a new or edited document joins its nearest tag on save, a tag that loosens splits, two that converge merge. No batch recompute, no schedule, no request.
- **Names and descriptions,** by the agent, when a tag is new or its documents changed.
- **"See also" tags,** by the agent, on pairs the data suggests.
- **A person's change always wins:** a renamed tag keeps its name, an edited description isn't overwritten, a `#tag` in the text stays, and a document a person removed from a tag isn't put back.

## Internals

### The data decides the shape

No fixed `k`, no fixed depth, and no batch job: daat keeps tags up from its own cached embeddings (`document_embedding`), in Luam, with no new dependency.

1. **A tag is a running summary:** its member count and the sum of its members' vectors, so its centre is always current.
2. **On save:** a new or edited document joins the nearest centre (one pass over the tags, about 1 ms). A person's `pinned`/`excluded` memberships and `#tags` in the text are never moved.
3. **Restructuring is local:** when a tag's spread grows past what it had when built, it splits in two (2-means over its own members); when two centres come closer than any two tags were when built, they merge. Thresholds are relative to the pool, never fixed cosines (a fixed 0.92 merged 32 tags into 18 in the 2026-10-04 check).
4. **Broader tags:** Ward over the tag centres (a few dozen points), cut where the merge heights jump; depth zero, one or two, from the data. The 2026-10-04 pool has no clear jump (1.2 against a median 1.07), so it stays flat for now.
5. **Stable names:** a tag keeps its name while its members mostly stay; a split's larger half keeps it.
6. **First build:** mini-batch k-means in queued chunks (about 0.25 s per 256 documents in Luam), so no long-running process is needed even for a new deployment.

Measured on 6,534 documents before writing any Luam (deployment check `incremental_tags_check.py`): held-out documents join one of their own tags by nearest centre 91% of the time (84% for the newest fifth); clustering daat's vectors agrees with the batch job's tags at adjusted Rand 0.46, against 0.62 between two seeds of the same batch method; half the pool streamed in with split/merge agrees with a full batch at 0.49. Cutting vectors to 256 dimensions costs about a point, and makes every step about 3x cheaper. If Luam is ever too slow, the fallback is a small C vector module in Luam's `lib/` (bound like `bcrypt`; the same pass runs 38x faster), not an outside runtime.

### Evidence between tags

Relations between tags are derived from tags and from the edges between their documents, not read from content: the tag-level graph is the edges between documents lifted onto their tags, compared with what the tags' own totals predict (lift, shrunk towards 1 on little evidence). `tag_evidence` (`tag_a`, `tag_b`, `kind`, `weight`, `support`, `producer`, `updated_at`) holds it, one row per pair and kind:

- **Core kinds:** `link` (`[[links]]`, directed) and `connection` (connection documents), kept current alongside `document.sync_links` and membership changes.
- **Extension kinds:** a deployment extension may write its own kinds (references to its entity types, say), through ordinary entity writes. Like `document` content, the rows are domain-specific and core never interprets them: `kind` is an open string, and core never branches on its value.
- **Kinds are scored apart and never summed:** each kind's own lift, combined by geometric mean, so a kind with thousands of edges can't outweigh one with dozens. A producer with high-volume edges collapses them first (one unit per underlying thing, minimum support), and evidence is never drawn as graph edges.

### The agent describes and relates

Model calls only for judgment, each memoized on a hash of the tag's documents so an unchanged tag is never re-asked (as `knowledge_tier_review` does for tiers): a name (a broader tag from its sub-tags' names); a description (`tag.description`); "see also" judgments on candidate pairs (tags in different branches with close centres, shared second-best memberships, or many links between their documents), yes or no with a reason, like the co-retrieval link judgment; and merge or split suggestions, raised in chat for approval. A suggestion a person declines isn't raised again unless the tags' documents change. Additive work happens automatically, as distillation does.

### Provenance and evidence

Kept in the data, not shown as such (after open-ontologies' [decision 0001](https://github.com/fabio-rovai/open-ontologies/blob/main/docs/decisions/0001-an-inference-is-not-an-assertion.md), an inference is not an assertion): relations between tags live in `tag_relation` (`from`, `to`, `kind`, `source`, `score`, `evidence`), apart from content and document links. Each tag, membership and relation records whether it was computed from the data, judged by the agent, or set by a person (person over agent over data), plus enough evidence to check it: central documents and terms, the jump that made a level, a pair's scores, the documents the agent's reason cites.

### Lifecycle

After open-ontologies' [lifecycle](https://github.com/fabio-rovai/open-ontologies/blob/main/docs/lifecycle.md), adapted to incremental upkeep: every structural change (a split, a merge, a rename, a new broader tag, a relation) is an ordinary entity write, ledgered with the evidence that made it; anything a person set is locked; nothing is deleted (dropped memberships and tags are archived), so an admin can roll any change back; and a dry-run CLI reports what upkeep would change right now, for review before trusting a new threshold.

### Where it runs

One rule decides placement:

| | Continuous, driven by usage | One-time or scheduled batch |
|---|---|---|
| **Generic** | daat core | -- (nothing left here once clustering moves into core) |
| **Deployment-specific** | a daat extension | the deployment's own scripts |

- **Core:** the schema (`tag`, `document_tag`, `tag_relation`, `tag_evidence`), tag upkeep on save, `#tag` sync, core evidence kinds, the agent's judgment during retrieval review (memoized like tier and link reviews), the UI, agent tools and the SKOS export.
- **Extension:** evidence kinds about the deployment's own entity types, written as its entities change; its own context for the agent's naming prompts.
- **Deployment scripts:** one-time backfills, labelled checks of evidence thresholds, and the outside batch job, kept only as an audit until core's tags agree with it, then retired.

## Phases

1. **Done:** `tag.parent`; graph colours by tag or sub-tag (daat e7f8eb8).
2. **Schema:** `tag_relation` (`from`, `to`, `kind` broader/related, `source` data/agent/person, `score`, `evidence`), `tag_evidence`, `tag.description` as the tag's definition.
3. **Tag upkeep in core:** running summaries, join-nearest on save, relative split/merge, broader level, first build in queued chunks; checked against the outside job's tags before it's retired.
4. **Core evidence:** `link` and `connection` kinds kept current; lift on read.
5. **`#tag` in text:** parse and sync on save, chips, precedence; `document_tag.via`.
6. **The agent's judgment:** names, definitions (genus = broader tag, difference from siblings, relations from evidence), related/broader on pairs whose evidence crosses the thresholds, merge/split raised in chat; memoized on member and evidence hashes. Thresholds set from labelled pairs first.
7. **UI:** chips on documents, the tag page, the tags list; agent tools.
8. **Optional:** SKOS/RDF export (`skos:Concept`, `broader`, `related`, `definition`) so an outside checker such as [open-ontologies](https://github.com/fabio-rovai/open-ontologies) can validate it.

## Open questions

- One tag per document or several. The data (40% of documents within 0.05 of a second tag) argues for a main tag plus a close second.
- The level-cut thresholds, set from the first runs.
