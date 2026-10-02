# Tag ontology: subjects the data defines and the agent describes

Status: proposal, 2026-10-02 (Ben). Not agreed yet. Builds on [structure-layers.md](structure-layers.md)'s tags; only `tag.parent` exists so far (daat e7f8eb8).

Today a tag is a flat cluster label with a fixed count (`k`) chosen by hand and a one-off name. The goal is a subject ontology that comes from the data and is described by the agent, the same way progressive summarisation and connections already work: the data decides how many subjects there are and how they nest; the agent names them, describes them and judges how they relate; people review and override through the same UI as everything else.

## Two concepts: links and tags

| | `[[link]]` | `#tag` |
|---|---|---|
| Is | an edge between two documents | a subject assigned to a group of documents |
| In the graph | a line between two nodes | colour, filter, legend group; never a node or an edge |
| Who sets it | a person or the agent, writing `[[Title]]` | a person writing `#tag`, or the clustering job |
| Stored in | `document_link`, synced from content | `tag` / `document_tag`; text-asserted rows synced from content |
| Relations | none beyond the edge | between tags only: broader, narrower, related, exact match (`tag_relation`) |

Nothing in this plan turns a tag into a document or a tag relation into a link. A tag's description and relations live on the tag; they're never written into any document's content, so they never become `document_link` rows or graph edges.

## What the ontology is

| Part | Stored as | Decided by |
|---|---|---|
| Subjects | `tag` rows | the data (clustering), at every level |
| Membership | `document_tag` rows | the data; a person, by writing `#tag` or on the subjects page |
| Broader / narrower | `tag.parent` | the data (the cluster tree); a person's move wins |
| Related (across branches) | `tag_relation` rows | the agent, on candidates the data proposes |
| Same subject twice | an `exact_match` proposal | the agent proposes, a person approves |
| Name and scope | `tag.label`, `tag.description` | the agent; a person's edit wins |

The relation vocabulary is SKOS's (broader, narrower, related, exact match) and nothing more. The job's computed memberships are never written into documents' text, since that would rewrite documents on every run ([structure-layers.md](structure-layers.md), Tags). A person's own assertion can be, exactly as a person writes a `[[link]]`.

### `#tag` in text

A person asserts a subject by writing it in a document's content, the way they assert a link:

- **Syntax.** `#tag`: a `#` not preceded by a letter, digit or `/`, then a letter, then letters, digits, `-`, `_` (`#fermentation`, `#cocoa-butter`). `#broad/specific` also asserts the broader relation (`#cocoa-science/fermentation`). Labels with spaces are matched by their **slug** (lowercase, spaces to `-`): `#cocoa-bean-fermentation` means the subject labelled "Cocoa bean fermentation". Not a tag: Markdown headings (`# Title`, a space follows), anything inside code spans and fences, URL fragments (`page#section`), and all-digit `#123`.
- **Sync on save**, alongside `document.sync_links`: each `#tag` in the content becomes a `document_tag` row with `decision = pinned` and `via = text`; removing it from the text archives that row. A slug that matches no subject creates one (`source = manual`, asserted), as a dangling `[[link]]` waits for its target. Only `via = text` rows are touched by the sync; memberships set on the subjects page (`via = page`) or by the job (`via = job`) are not.
- **Precedence.** A `#tag` in the text holds while it's in the text: the job never removes it, and the subjects page shows it as asserted in the document, with "edit the text" rather than a remove button. An `excluded` membership set on the page loses to the same subject written in the text, since the text is the more specific, visible assertion.
- **Display.** Rendered as a chip that opens the subject; never a `document_link` and never a graph edge.
- **For the job,** text-asserted memberships are labelled data: they stay put, and they steer naming and stable matching. A computed subject whose members mostly carry `#fermentation` takes that name.
- **The agent** may write `#tags` in documents it writes; they go through the same approval as the rest of the write and are recorded as asserted by that write, like a link the agent writes.

Each subject's **description** is `tag.description` (the field already exists): the agent's account of what the subject covers and what it doesn't. It's on the tag, not in a document, so a subject never appears as a graph node. A person edits it on the subjects page; edits are ledgered like any entity field.

### An inference is not an assertion

A relation the data or the agent produced must never look like one a person wrote (open-ontologies' [decision 0001](https://github.com/fabio-rovai/open-ontologies/blob/main/docs/decisions/0001-an-inference-is-not-an-assertion.md): keep inferences in their own graph, so a consumer that forgets to filter sees fewer statements, never wrong ones). Relations between tags live in `tag_relation` (`from`, `to`, `kind`, `source`, `score`, `evidence`), apart from content and apart from document links, with their provenance on every row.

Every subject and relation carries its provenance in one of three words, and the UI shows it:

| Word | Means | Example |
|---|---|---|
| measured | computed from the data, reproducible | membership score, the tree's gap at a level cut, centre similarity |
| opinion | the agent's judgment, with its reason | a name, a scope note, "these two subjects are related" |
| asserted | a person decided | a rename, a move, a pinned document, an approved merge |

Asserted beats opinion beats measured when they disagree, and nothing overwrites an assertion. Each row also keeps its **evidence**, enough for a person to check it: the central documents and terms for a subject, the gap size for a level, the scores for a candidate pair, and the documents the agent's reason cites.

## The data decides the shape

No fixed `k`, no fixed depth.

1. **Micro-clusters.** k-means into many small groups (about √n, ~80 at 6,600 documents) on the existing cleaned, passage-sampled document embeddings. Cheap, and fine-grained enough that nothing real is merged yet.
2. **Tree.** Agglomerative clustering (Ward) over the micro-cluster centres, weighted by size, gives one tree of all subjects.
3. **Levels.** Cut the tree where merge distances jump: a large gap means "these groups are genuinely separate". The largest gap above the leaves gives the specific level; the next one up gives the broad level, if there's a clear one. A level only exists if the gap is clearly larger than the gaps below it, so depth is 1-3 depending on the corpus, not set by hand.
4. **Guard rails, not targets.** A broad level with more than 12 groups (the graph's palette) or a subject with fewer than ~10 documents is reported as a warning in the plan, not forced.
5. **Stability.** Each level keeps names by member overlap with the previous run (as now); a subject with no match is new; one that disappears is archived unless a person pinned documents to it or renamed it.

The same numbers say *when* to recompute, as a rule rather than a schedule: after each sync, new and changed documents are assigned to their nearest specific subject (cheap, no reclustering). A full recompute is due when enough of the pool is new since the last one (e.g. 15%), or when many new documents sit far from every subject centre (the pool has grown a subject the ontology doesn't have). A person can also request one.

## The agent describes and relates

Model calls only for judgment, each memoized on a hash of the subject's members so an unchanged subject is never re-asked, as `knowledge_tier_review` does for tiers:

- **Name** each subject from its most central titles, its terms and, for a broad subject, its children's names.
- **Write the description** (`tag.description`): scope, what's in and out. Broader and narrower come from the tree, not from the description.
- **Judge related pairs.** Candidates come from the data: subjects in different branches whose centres are close, that share many second-best memberships, or whose documents link to each other a lot. The agent answers yes or no per pair, with a reason grounded in both subjects' central documents, like the co-retrieval link judgment. A yes is a `tag_relation` row (`related`, opinion), shown on both subjects' entries on the subjects page.
- **Propose merges and splits.** Two subjects the agent judges to be the same (`exact_match`), or one that covers two unrelated things, become proposals, not changes.
- **Remember rejections.** A proposal or relation a person rejects is kept as rejected and not raised again unless its evidence changes (its member hash), as declined co-retrieval pairs already are.

Additive work (names for new subjects, notes, related links) happens automatically, as distillation does. Structural changes a person might disagree with (merge, split, moving a subject) wait for approval, as the agent's destructive tools do.

## Lifecycle: plan, apply, drift, rollback

The clustering job already plans and applies separately. Borrowing the rest of open-ontologies' [lifecycle](https://github.com/fabio-rovai/open-ontologies/blob/main/docs/lifecycle.md):

- **Plan** is a stored artefact with an id (a `cluster_run`), never applied implicitly. It reports the **blast radius**: documents whose subject changes, subjects created, renamed, re-parented and archived, relations added and dropped. A plan that archives a subject people use, or moves more than a set share of documents, is marked high risk and needs explicit approval on the subjects page.
- **Locked subjects** are anything a person asserted (renamed, moved, pinned to); the plan can't remove or rename them and says so.
- **Rename bridges** are the stable-name matches: every match is reported with its overlap score, and every subject that found no match is listed, so a wrong inheritance is visible before apply.
- **Apply** writes only the delta, ledgered as now.
- **Drift** is the recompute-due rule above.
- **Rollback**: tags and memberships are archived, never deleted, so a run can be undone by restoring the previous run's state. The subjects page offers it for the most recent apply.

## Where it runs

The [boundary](structure-layers.md#boundary) stays: numbers outside daat, judgment and display inside.

| The clustering job (`software`) | daat |
|---|---|
| Embeddings, micro-clusters, the tree and its cuts | Stores subjects, membership, `tag.parent` |
| Stable matching, recompute-due rule, incremental assignment | Runs the judgment calls with its own agent provider, triggered when a subject is new or its member hash changes |
| Related-pair candidates, with their scores (`tag_relation`, measured) | Descriptions, relation judgments, merge/split proposals |
| Writes through the REST API, ledgered | UI and manual overrides |

Moving naming from the job into daat means every judgment uses daat's provider, budgets and audit trail, and a person sees all of it in one place.

## The UI

Like everything else: no special screens beyond one page.

- **Subjects page** (core, next to `/knowledge`): the tree, broad to specific, with document counts, each subject showing its description, its related subjects (with provenance) and its members. Controls: rename, edit the description, move under another subject, pin or exclude a document, approve or reject the agent's proposals, request a recompute.
- **Graph**: colour by broad subject or specific subject (built), filter by subject through the legend.
- **Document page**: its subjects, as breadcrumbs (broad › specific).
- **Chat agent tools**: `subject.tree`, `subject.get` (note, members, relations) and `subject.propose`, so the agent can answer "what do we know about X" by subject and propose changes that go through the same approval as other writes.

A person's change always wins over a recompute, at every level: a renamed or moved subject keeps its name and place, pinned and excluded memberships stay, and an edited description isn't overwritten (the agent offers a suggested revision instead).

## Phases

1. **Done:** `tag.parent`; graph colours by broad or specific subject (daat e7f8eb8).
2. **Data-driven tree** in the clustering job: micro-clusters, tree, gap-based levels, stable matching per level, the plan report as a tree. Validate on the current pool before applying: does it find sensible broad groups, and are the old literature subjects still there?
3. **`#tag` in text**: parse and sync on save (`via = text`), slugs, chips, the precedence rules; `document_tag.via`.
4. **Judgment in daat**: `tag_relation` with provenance and evidence; names and descriptions, related-pair judgments and merge/split proposals, memoized on member hashes.
5. **UI**: the subjects page with overrides and proposals; subjects on document pages; agent tools.
6. **Triggers and lifecycle**: incremental assignment after each sync; the recompute-due rule; the request button; plan risk and rollback.
7. **Interop, optional**: export the ontology as SKOS/RDF (subjects as `skos:Concept`, with `broader`, `related`, `exactMatch`; documents linked by membership). That lets an outside tool such as [open-ontologies](https://github.com/fabio-rovai/open-ontologies) (an MCP server) check it: no cycles in `broader`, every specific subject under a broad one, transitive closure. Its Obsidian plugin maps a note vault to RDF the same way (notes as individuals, typed links as properties, tags as SKOS concepts) and is the closest prior art for doing this to daat's documents more broadly.

## Open questions

- One subject per document or several. The current data (40% of documents within 0.05 of a second subject) still argues for a primary plus a close second.
- Whether people should be able to create subjects by hand that the data doesn't have (a `manual` tag with a note); storage already allows it.
- The gap rule's thresholds, set from the first runs rather than up front.
