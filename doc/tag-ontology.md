# Tag ontology: tags the data defines and the agent maintains

Status: proposal, 2026-10-02 (Ben). Not agreed yet. Builds on [structure-layers.md](structure-layers.md)'s tags; only `tag.parent` exists so far (daat e7f8eb8).

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

Nothing else is user-facing: no recompute button, no proposals queue, no scores or plan reviews. An admin sees those through the clustering job's reports and the CLI.

### `#tag` in text

- **Syntax:** `#` then a letter, then letters, digits, `-` or `_` (`#fermentation`, `#cocoa-butter`); a tag whose name has spaces is written with `-` (`#cocoa-bean-fermentation` = "Cocoa bean fermentation"). Not a tag: headings (`# Title`), code, URL fragments (`page#section`), `#123`. No `#a/b` paths: how tags nest is the system's job, and a path would look like a folder.
- **On save,** next to `document.sync_links`: each `#tag` becomes a membership the person asserted (`decision = pinned`, `via = text`); deleting it from the text removes it. An unknown tag is created, as a `[[link]]` to a page that doesn't exist yet waits for it.
- **It holds while it's in the text:** recomputes never remove it, and it wins over a removal elsewhere.
- **Shown** as a chip, never a link.
- The agent may write `#tags` in documents it writes, through the same approval as the rest of the write.

## What runs on its own

- **Tags and how they nest**, from the data (below). Recomputed when the pool has changed enough, not on a schedule and not by request; between recomputes, new documents just join their nearest tag.
- **Names and descriptions,** by the agent, when a tag is new or its documents changed.
- **"See also" tags,** by the agent, on pairs the data suggests.
- **A person's change always wins:** a renamed tag keeps its name, an edited description isn't overwritten, a `#tag` in the text stays, and a document a person removed from a tag isn't put back.

## Internals

### The data decides the shape

No fixed `k`, no fixed depth (implemented as `cluster_tags.py plan --tree`):

1. **Micro-clusters:** k-means into about √n small groups (~80 at 6,600 documents) on the cleaned, passage-sampled document embeddings.
2. **Tree:** Ward clustering over the micro-cluster centres.
3. **Levels:** cut where the tree's merge heights jump. The largest relative jump between 10 and n/2 tags is the tag level; the largest jump above it, at 3-12 tags, is the broader level, kept only if it's clearly larger than the jumps around it (`BROAD_GAP_FACTOR`). So depth is one or two, from the data.
4. **Assignment:** each document goes to its nearest tag centre; its broader tag follows from the tree, so the levels always nest.
5. **Stable names:** at each level, a tag inherits the previous run's name when their documents mostly overlap.

Recompute is due when about 15% of the pool is new since the last run, or when many new documents sit far from every tag centre.

### The agent describes and relates

Model calls only for judgment, each memoized on a hash of the tag's documents so an unchanged tag is never re-asked (as `knowledge_tier_review` does for tiers): a name (a broader tag from its sub-tags' names); a description (`tag.description`); "see also" judgments on candidate pairs (tags in different branches with close centres, shared second-best memberships, or many links between their documents), yes or no with a reason, like the co-retrieval link judgment; and merge or split suggestions, raised in chat for approval. A suggestion a person declines isn't raised again unless the tags' documents change. Additive work happens automatically, as distillation does.

### Provenance and evidence

Kept in the data, not shown as such (after open-ontologies' [decision 0001](https://github.com/fabio-rovai/open-ontologies/blob/main/docs/decisions/0001-an-inference-is-not-an-assertion.md), an inference is not an assertion): relations between tags live in `tag_relation` (`from`, `to`, `kind`, `source`, `score`, `evidence`), apart from content and document links. Each tag, membership and relation records whether it was computed from the data, judged by the agent, or set by a person (person over agent over data), plus enough evidence to check it: central documents and terms, the jump that made a level, a pair's scores, the documents the agent's reason cites.

### Lifecycle

After open-ontologies' [lifecycle](https://github.com/fabio-rovai/open-ontologies/blob/main/docs/lifecycle.md), all in the job and its reports: a plan is stored and never applied implicitly; it reports how many documents change tag and which tags are created, renamed or archived; anything a person set is locked; name inheritances are listed with their overlap scores; apply writes only the difference; and since nothing is deleted, a run can be rolled back by an admin.

### Where it runs

The [boundary](structure-layers.md#boundary) stays: numbers in the clustering job (`software`), judgment and display in daat. The job computes the tree, levels, assignment and candidate pairs and writes them through the REST API; daat runs the agent's judgment with its own provider and shows the result. Naming moves from the job into daat.

## Phases

1. **Done:** `tag.parent`; graph colours by tag or sub-tag (daat e7f8eb8).
2. **The data-driven tree** in the clustering job (`plan --tree`), checked on the current pool before anything is applied.
3. **`#tag` in text:** parse and sync on save, chips, precedence; `document_tag.via`.
4. **The agent's judgment in daat:** names, descriptions, "see also", merge and split suggestions in chat; `tag_relation`.
5. **UI:** tag chips on documents, the tag page, the tags list; agent tools.
6. **Self-management:** assignment after each sync, the recompute-due rule, plan reports and rollback for admins.
7. **Optional:** export as SKOS/RDF (tags as `skos:Concept` with `broader`, `related`) so an outside checker such as [open-ontologies](https://github.com/fabio-rovai/open-ontologies) can validate it; its Obsidian plugin, which maps a note vault to RDF, is the closest prior art.

## Open questions

- One tag per document or several. The data (40% of documents within 0.05 of a second tag) argues for a main tag plus a close second.
- The level-cut thresholds, set from the first runs.
