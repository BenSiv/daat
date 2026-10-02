# Tag ontology: subjects the data defines and the agent describes

Status: proposal, 2026-10-02 (Ben). Not agreed yet. Builds on [structure-layers.md](structure-layers.md)'s tags; only `tag.parent` exists so far (daat e7f8eb8).

Today a tag is a flat cluster label with a fixed count (`k`) chosen by hand and a one-off name. The goal is a subject ontology that comes from the data and is described by the agent, the same way progressive summarisation and connections already work: the data decides how many subjects there are and how they nest; the agent names them, describes them and judges how they relate; people review and override through the same UI as everything else.

## What the ontology is

| Part | Stored as | Decided by |
|---|---|---|
| Subjects | `tag` rows | the data (clustering), at every level |
| Membership | `document_tag` rows, as now | the data; `pinned`/`excluded` by people |
| Broader / narrower | `tag.parent` | the data (the cluster tree); a person's move wins |
| Related (across branches) | `tag_relation` rows | the agent, on candidates the data proposes |
| Same subject twice | an `exact_match` proposal | the agent proposes, a person approves |
| Name and scope | `tag.label`, the subject note | the agent; a person's rename wins |

The relation vocabulary is SKOS's (broader, narrower, related, exact match) and nothing more. Membership stays derived and is never written into documents' text ([structure-layers.md](structure-layers.md), Tags).

Each subject gets a **subject note**, an ordinary document filed under a "Subjects" folder: the agent's description of what the subject covers and what it doesn't. `tag.note` points at it. Because it's a document, it's searchable, shows in the graph, has history, enters tiering and heat, and a person edits it like any other page, as connections are ordinary connection documents.

### An inference is not an assertion

A relation the data or the agent produced must never look like one a person wrote (open-ontologies' [decision 0001](https://github.com/fabio-rovai/open-ontologies/blob/main/docs/decisions/0001-an-inference-is-not-an-assertion.md): keep inferences in their own graph, so a consumer that forgets to filter sees fewer statements, never wrong ones). So derived relations are not plain `[[links]]` in the note's text. They live in `tag_relation` (`from`, `to`, `kind`, `source`, `score`, `evidence`), and the note renders them in a delimited, regenerated block, the way `apply_citation_links` renders citations: the block is the system's, the rest of the note is whoever wrote it, and a link a person types outside the block is theirs.

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
- **Write the subject note**: scope, what's in and out, and its broader/narrower links (which the tree already decided).
- **Judge related pairs.** Candidates come from the data: subjects in different branches whose centres are close, that share many second-best memberships, or whose documents link to each other a lot. The agent answers yes or no per pair, with a reason grounded in both subjects' central documents, like the co-retrieval link judgment. A yes is a `tag_relation` row (`related`, opinion) shown in both notes' generated block.
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
| Related-pair candidates, with their scores (`tag_relation`, measured) | Subject notes, relation judgments, merge/split proposals |
| Writes through the REST API, ledgered | UI and manual overrides |

Moving naming from the job into daat means every judgment uses daat's provider, budgets and audit trail, and a person sees all of it in one place.

## The UI

Like everything else: no special screens beyond one page.

- **Subjects page** (core, next to `/knowledge`): the tree, broad to specific, with document counts, each subject linking to its note and its members. Controls: rename, move under another subject, pin or exclude a document, approve or reject the agent's proposals, request a recompute.
- **Subject notes** are ordinary documents: read, edit, history, graph.
- **Graph**: colour by broad subject or specific subject (built), filter by subject through the legend.
- **Document page**: its subjects, as breadcrumbs (broad › specific).
- **Chat agent tools**: `subject.tree`, `subject.get` (note, members, relations) and `subject.propose`, so the agent can answer "what do we know about X" by subject and propose changes that go through the same approval as other writes.

A person's change always wins over a recompute, at every level: a renamed or moved subject keeps its name and place, pinned and excluded memberships stay, and an edited subject note isn't overwritten (the agent appends a suggested revision instead).

## Phases

1. **Done:** `tag.parent`; graph colours by broad or specific subject (daat e7f8eb8).
2. **Data-driven tree** in the clustering job: micro-clusters, tree, gap-based levels, stable matching per level, the plan report as a tree. Validate on the current pool before applying: does it find sensible broad groups, and are the old literature subjects still there?
3. **Judgment in daat**: `tag_relation` with provenance and evidence; subject notes with their generated relation block; names, related-pair judgments and merge/split proposals, memoized on member hashes; `tag.note`.
4. **UI**: the subjects page with overrides and proposals; subjects on document pages; agent tools.
5. **Triggers and lifecycle**: incremental assignment after each sync; the recompute-due rule; the request button; plan risk and rollback.
6. **Interop, optional**: export the ontology as SKOS/RDF (subjects as `skos:Concept`, with `broader`, `related`, `exactMatch`; documents linked by membership). That lets an outside tool such as [open-ontologies](https://github.com/fabio-rovai/open-ontologies) (an MCP server) check it: no cycles in `broader`, every specific subject under a broad one, transitive closure. Its Obsidian plugin maps a note vault to RDF the same way (notes as individuals, typed links as properties, tags as SKOS concepts) and is the closest prior art for doing this to daat's documents more broadly.

## Open questions

- One subject per document or several. The current data (40% of documents within 0.05 of a second subject) still argues for a primary plus a close second.
- Whether people should be able to create subjects by hand that the data doesn't have (a `manual` tag with a note); storage already allows it.
- The gap rule's thresholds, set from the first runs rather than up front.
